import CryptoKit
import Foundation
import Security

/// OpenAI 的开源客户端授权，凭据只发送到 OpenAI 的固定 HTTPS 端点。
@MainActor public final class ChatGPTPlan {
    public static let defaultTranslationModel = "gpt-6-luna"

    private static let resource = "https://api.openai.com/v1"
    private static let auth = "https://auth.openai.com"
    nonisolated private static let permission = "chatgpt.tokens.use.direct"

    public enum Failure: String, Error {
        case invalidAuthorization, signInTimedOut, signInRequired, accessDenied, busy
        case usageLimit, unavailable, invalidResponse, revocationFailed, noModels, keychainUnavailable, invalidModelCatalog, sessionStorageUnavailable
    }

    public struct HTTPFailure: Error {
        public let status: Int
        public let reason: Failure
    }

    public struct Model: Identifiable {
        public var id: String { slug }
        public let slug: String
        public let displayName: String
    }

    private struct Catalog: Decodable {
        struct Entry: Decodable {
            let slug: String?
            let visibility: String?
            let display_name: String?
        }
        let models: [Entry]
    }

    private struct Tokens: Codable {
        let access_token: String
        let refresh_token: String?
        let id_token: String?
        let scope: String
        let expires_in: Double
        var permitsUsage: Bool { scope.split(separator: " ").contains(Substring(ChatGPTPlan.permission)) }
    }

    private struct Account: Codable {
        let clientID: String
        let identity: ChatGPTIDToken.Identity
        var tokens: Tokens?
        var expiresAt: Date
    }

    private let service: String
    private let store: ChatGPTSessionStore
    private var changingAccount = false
    private var refreshing: Task<String, Error>?
    private let client: URLSession

    public init(service: String, session: URLSession? = nil) {
        self.service = service
        // 使用宿主的服务名隔离开发版与正式版，路径不依赖二进制或工作区。
        let identifier = ChatGPTIDToken.encode(Data(service.utf8))
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        store = ChatGPTSessionStore(directory: support.appendingPathComponent("KirkTranslation-" + identifier))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 55
        client = session ?? URLSession(configuration: configuration)
    }

    public var isSignedIn: Bool { account?.tokens != nil }
    public var email: String? { account?.identity.email }
    public var needsKeychainAccess: Bool {
        do {
            guard try store.read() == nil else { return false }
            return try loadLegacyAccount() != nil
        } catch Failure.keychainUnavailable {
            return true
        } catch {
            return false
        }
    }

    public func restoreAuthorization() throws {
        guard let saved = try loadLegacyAccount(interactive: true), saved.tokens != nil else {
            throw Failure.signInRequired
        }
        try save(saved)
    }

    public func signIn(newAccount: Bool = false, openBrowser: @escaping (URL) -> Bool) async throws {
        guard !changingAccount, refreshing == nil else { throw Failure.busy }
        changingAccount = true
        defer { changingAccount = false }

        let current: Account?
        do {
            current = try loadAccount()
        } catch Failure.keychainUnavailable {
            current = nil
        }
        let previous = newAccount ? nil : current
        let hostKey = "capture.translation.chatgpt.host"
        let host = UserDefaults.standard.string(forKey: hostKey) ?? "urn:uuid:" + UUID().uuidString.lowercased()
        UserDefaults.standard.set(host, forKey: hostKey)
        let state = try randomToken()
        let nonce = try randomToken()
        let verifier = try randomToken()
        let challenge = ChatGPTIDToken.encode(Data(SHA256.hash(data: Data(verifier.utf8))))
        var redirect = ""
        let callback = try await ChatGPTLoopback().wait(state: state) { uri in
            redirect = uri
            var values = [
                "client_id": previous?.clientID ?? "dynamic_agent_client",
                "ext_agent_host_id": host, "redirect_uri": uri, "response_type": "code",
                "scope": "openid profile email offline_access resource.invoke " + Self.permission,
                "resource": Self.resource, "state": state, "nonce": nonce,
                "code_challenge_method": "S256", "code_challenge": challenge
            ]
            if previous == nil { values["agent_name_hint"] = "Screenshot" }
            if let hint = previous?.tokens?.id_token { values["id_token_hint"] = hint }
            var url = URLComponents(string: Self.auth + "/api/accounts/authorize")!
            url.queryItems = values.map { URLQueryItem(name: $0.key, value: $0.value) }
            guard let address = url.url, openBrowser(address) else { throw Failure.invalidAuthorization }
        }
        func field(_ name: String) -> String? {
            let items = callback.queryItems?.filter { $0.name == name } ?? []
            return items.count == 1 ? items[0].value : nil
        }
        guard callback.queryItems?.contains(where: { $0.name == "error" }) != true else { throw Failure.accessDenied }
        let issued = field("client_id")
        guard let code = field("code"), !code.isEmpty,
              let clientID = issued ?? previous?.clientID, !clientID.isEmpty,
              clientID != "dynamic_agent_client", previous == nil || clientID == previous?.clientID else {
            throw Failure.invalidAuthorization
        }
        let tokens = try await exchange([
            "grant_type": "authorization_code", "client_id": clientID, "code": code,
            "code_verifier": verifier, "redirect_uri": redirect, "resource": Self.resource
        ])
        guard let token = tokens.id_token else { throw Failure.invalidAuthorization }
        let keys = try await read(URLRequest(url: URL(string: Self.auth + "/.well-known/jwks.json")!))
        let identity = try ChatGPTIDToken.verify(token, keys: keys, clientID: clientID, nonce: nonce)
        guard previous == nil || previous?.identity.sub == identity.sub else { throw Failure.invalidAuthorization }
        try Task.checkCancellation()
        guard tokens.permitsUsage else { throw Failure.accessDenied }
        try save(Account(clientID: clientID, identity: identity, tokens: tokens,
                         expiresAt: Date().addingTimeInterval(tokens.expires_in)))
        if newAccount, let current { try await revoke(current) }
    }

    public func signOut() async throws {
        guard !changingAccount, refreshing == nil else { throw Failure.busy }
        guard let current = try loadAccount(), current.tokens != nil else { return }
        var saved = current
        changingAccount = true
        defer { changingAccount = false }

        saved.tokens = nil
        try save(saved)
        try await revoke(current)
    }

    private func revoke(_ account: Account) async throws {
        guard let token = account.tokens?.refresh_token else { return }
        do {
            _ = try await read(form(path: "/api/accounts/oauth/revoke", fields: [
                "token": token, "token_type_hint": "refresh_token", "client_id": account.clientID
            ]))
        } catch {
            throw Failure.revocationFailed
        }
    }

    public enum ModelListEvent {
        case sessionReady
        case httpStatus(Int)
        case bodyBytes(Int)
        case bodyShape(BodyShape)

        public enum BodyShape: String {
            case chatGPTCatalog = "chatgpt_catalog"
            case standardCatalog = "standard_catalog"
            case errorObject = "error_object"
            case otherJSON = "other_json"
            case nonJSON = "non_json"
        }
    }

    public func models(diagnostics: ((ModelListEvent) -> Void)? = nil) async throws -> [Model] {
        let token = try await accessToken()
        diagnostics?(.sessionReady)
        return try await fetchModels(token: token, diagnostics: diagnostics)
    }

    func fetchModels(token: String, diagnostics: ((ModelListEvent) -> Void)?) async throws -> [Model] {
        var request = api("/models", token: token)
        request.timeoutInterval = 12
        let data = try await read(request, modelListDiagnostics: diagnostics)
        return try Self.decodeModels(data)
    }

    static func modelListBodyShape(_ data: Data) -> ModelListEvent.BodyShape {
        guard let json = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) else { return .nonJSON }
        guard let fields = json as? [String: Any] else { return .otherJSON }
        if fields["models"] is [Any] { return .chatGPTCatalog }
        if fields["data"] is [Any] { return .standardCatalog }
        if fields["error"] != nil || fields["detail"] != nil { return .errorObject }
        return .otherJSON
    }

    static func decodeModels(_ data: Data) throws -> [Model] {
        guard let catalog = try? JSONDecoder().decode(Catalog.self, from: data) else {
            throw Failure.invalidModelCatalog
        }
        return catalog.models.compactMap { entry in
            guard entry.visibility == "list", let slug = entry.slug, !slug.isEmpty else { return nil }
            return Model(slug: slug, displayName: entry.display_name ?? slug)
        }
    }

    public func translate(_ text: String, target: String, model: String, segmentMarker: String? = nil,
                          onHeaders: ((Int) -> Void)? = nil, onSessionReady: (() -> Void)? = nil,
                          onText: ((String) -> Void)? = nil,
                          onNetworkTiming: (@Sendable (TranslationNetworkTiming) -> Void)? = nil) async throws -> String {
        guard text.utf8.count <= 12_000 else { throw CloudTranslation.Failure.inputTooLong }
        let token = try await accessToken()
        onSessionReady?()
        let request = try Self.translationRequest(text, target: target, model: model, token: token, segmentMarker: segmentMarker)
        return try await streamTranslation(request, onHeaders: onHeaders, onText: onText, onNetworkTiming: onNetworkTiming)
    }

    func streamTranslation(_ request: URLRequest, onHeaders: ((Int) -> Void)? = nil,
                           onText: ((String) -> Void)? = nil,
                           onNetworkTiming: (@Sendable (TranslationNetworkTiming) -> Void)? = nil) async throws -> String {
        let delegate = CloudTranslation.RejectRedirects(onNetworkTiming: onNetworkTiming)
        let (bytes, response) = try await client.bytes(for: request, delegate: delegate)
        guard let response = response as? HTTPURLResponse else { throw Failure.invalidResponse }
        onHeaders?(response.statusCode)
        guard (200..<300).contains(response.statusCode) else {
            throw try await Self.httpFailure(response.statusCode, bytes: bytes)
        }

        var stream = TranslationStream()
        var line = Data()
        var size = 0
        for try await byte in bytes {
            size += 1
            guard size <= 512 * 1024 else { throw Failure.invalidResponse }
            if byte == 10 {
                let previousLength = stream.text.utf8.count
                if let completed = try stream.consume(String(decoding: line, as: UTF8.self)) { return completed }
                if stream.text.utf8.count != previousLength { onText?(stream.text) }
                line.removeAll(keepingCapacity: true)
            } else {
                line.append(byte)
            }
        }
        throw Failure.invalidResponse
    }

    static func translationRequest(_ text: String, target: String, model: String, token: String, segmentMarker: String? = nil) throws -> URLRequest {
        let selected = model.isEmpty ? defaultTranslationModel : model
        var request = URLRequest(url: URL(string: resource + "/responses")!, timeoutInterval: 45)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        var payload: [String: Any] = [
            "model": selected, "store": false, "stream": true,
            "instructions": CloudTranslation.instructions(target: target, segmentMarker: segmentMarker),
            "input": [["role": "user", "content": text]]
        ]
        if selected == defaultTranslationModel { payload["reasoning"] = ["effort": "low"] }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return request
    }

    static func translation(from data: Data) throws -> String {
        var stream = TranslationStream()
        for line in String(decoding: data, as: UTF8.self).components(separatedBy: .newlines) {
            if let completed = try stream.consume(line) { return completed }
        }
        throw Failure.invalidResponse
    }

    private struct TranslationStream {
        private(set) var text = ""

        mutating func consume(_ line: String) throws -> String? {
            guard line.hasPrefix("data:"),
                  let event = (try? JSONSerialization.jsonObject(with: Data(line.dropFirst(5).utf8))) as? [String: Any],
                  let type = event["type"] as? String else { return nil }
            switch type {
            case "response.output_text.delta":
                text += event["delta"] as? String ?? ""
            case "response.completed":
                let result = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !result.isEmpty else { throw Failure.invalidResponse }
                return result
            case "response.failed", "response.incomplete", "error":
                let body = (event["response"] as? [String: Any]) ?? event
                let error = (body["error"] as? [String: Any]) ?? body
                throw ChatGPTPlan.failure(code: error["code"] as? String, status: 0)
            default: break
            }
            return nil
        }
    }

    private func accessToken() async throws -> String {
        guard !changingAccount else { throw Failure.busy }
        guard var saved = try loadAccount(), let tokens = saved.tokens, tokens.permitsUsage else { throw Failure.signInRequired }
        if saved.expiresAt.timeIntervalSinceNow > 60 { return tokens.access_token }
        if let refreshing { return try await refreshing.value }
        guard let refresh = tokens.refresh_token else { throw Failure.signInRequired }

        let task = Task {
            let renewed = try await exchange([
                "grant_type": "refresh_token", "client_id": saved.clientID,
                "refresh_token": refresh, "resource": Self.resource
            ])
            guard renewed.permitsUsage else { throw Failure.accessDenied }
            saved.tokens = Tokens(access_token: renewed.access_token, refresh_token: renewed.refresh_token ?? refresh,
                                  id_token: tokens.id_token, scope: renewed.scope, expires_in: renewed.expires_in)
            saved.expiresAt = Date().addingTimeInterval(renewed.expires_in)
            try save(saved)
            return renewed.access_token
        }
        refreshing = task
        defer { refreshing = nil }
        return try await task.value
    }

    private func exchange(_ fields: [String: String]) async throws -> Tokens {
        let data = try await read(form(path: "/api/accounts/oauth/token", fields: fields))
        let tokens = try JSONDecoder().decode(Tokens.self, from: data)
        guard !tokens.access_token.isEmpty, tokens.expires_in.isFinite, tokens.expires_in > 0 else {
            throw Failure.invalidAuthorization
        }
        return tokens
    }

    private func form(path: String, fields: [String: String]) -> URLRequest {
        var request = URLRequest(url: URL(string: Self.auth + path)!, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        func encode(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
        request.httpBody = Data(fields.map { encode($0.key) + "=" + encode($0.value) }.joined(separator: "&").utf8)
        return request
    }

    private func api(_ path: String, token: String) -> URLRequest {
        var request = URLRequest(url: URL(string: Self.resource + path)!, timeoutInterval: 45)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        return request
    }

    private func read(_ request: URLRequest, modelListDiagnostics: ((ModelListEvent) -> Void)? = nil) async throws -> Data {
        try Task.checkCancellation()
        let (bytes, response) = try await client.bytes(for: request, delegate: CloudTranslation.RejectRedirects())
        guard let response = response as? HTTPURLResponse else { throw Failure.invalidResponse }
        modelListDiagnostics?(.httpStatus(response.statusCode))
        var data = Data()
        for try await byte in bytes {
            guard data.count < 512 * 1024 else { throw Failure.invalidResponse }
            data.append(byte)
        }
        modelListDiagnostics?(.bodyBytes(data.count))
        modelListDiagnostics?(.bodyShape(Self.modelListBodyShape(data)))
        guard (200..<300).contains(response.statusCode) else {
            throw Self.httpFailure(response.statusCode, data: data)
        }
        return data
    }

    private static func httpFailure(_ status: Int, bytes: URLSession.AsyncBytes) async throws -> HTTPFailure {
        var data = Data()
        for try await byte in bytes {
            guard data.count < 512 * 1024 else { break }
            data.append(byte)
        }
        return httpFailure(status, data: data)
    }

    private static func httpFailure(_ status: Int, data: Data) -> HTTPFailure {
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let error = body?["error"] as? [String: Any]
        let reason = failure(code: error?["code"] as? String ?? body?["error"] as? String, status: status)
        return HTTPFailure(status: status, reason: reason)
    }

    nonisolated private static func failure(code: String?, status: Int) -> Failure {
        switch code {
        case "subscription_sharing_usage_limit_exceeded": return .usageLimit
        case "subscription_sharing_usage_unavailable": return .unavailable
        case "subscription_sharing_user_not_eligible": return .accessDenied
        case "invalid_grant", "invalid_token": return .signInRequired
        default:
            if status == 401 { return .signInRequired }
            if status == 403 { return .accessDenied }
            if status == 429 { return .usageLimit }
            return status >= 500 ? .unavailable : .invalidResponse
        }
    }

    private func randomToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
        guard status == errSecSuccess else { throw Failure.invalidAuthorization }
        return ChatGPTIDToken.encode(Data(bytes))
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: "chatgpt-plan"]
    }

    private var account: Account? { try? loadAccount() }

    private func loadAccount() throws -> Account? {
        if let bytes = try store.read() { return try JSONDecoder().decode(Account.self, from: bytes) }
        guard let saved = try loadLegacyAccount() else { return nil }
        try save(saved)
        return saved
    }

    private func loadLegacyAccount(interactive: Bool = false) throws -> Account? {
        var search = query
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = try withKeychainInteraction(interactive) {
            SecItemCopyMatching(search as CFDictionary, &value)
        }
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data else { throw Failure.keychainUnavailable }
        return try JSONDecoder().decode(Account.self, from: data)
    }

    private func save(_ account: Account) throws {
        do { try store.write(JSONEncoder().encode(account)) }
        catch { throw Failure.sessionStorageUnavailable }
    }

    // 旧版本的钥匙串用于一次性恢复，只有用户主动恢复时可显示系统授权。
    private func withKeychainInteraction(_ interactive: Bool, _ operation: () -> OSStatus) throws -> OSStatus {
        if interactive { return operation() }
        var previous = DarwinBoolean(false)
        guard SecKeychainGetUserInteractionAllowed(&previous) == errSecSuccess,
              SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else { throw Failure.keychainUnavailable }
        defer { SecKeychainSetUserInteractionAllowed(previous.boolValue) }
        return operation()
    }
}
