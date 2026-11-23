import Foundation
import KirkTranslation
import Security

enum CaptureTranslationSettings {
    private static let urlKey = "capture.translation.cloud.baseURL"
    private static let modelKey = "capture.translation.cloud.model"
    private static let service = (Bundle.main.bundleIdentifier ?? "com.kirktools.screenshot") + ".translation"

    @MainActor static let chatGPT = ChatGPTPlan(
        service: service, applicationName: "Screenshot", hostPreferenceKey: "capture.translation.chatgpt.host"
    )

    static var initialProvider: AITranslationProvider { baseURL.isEmpty ? .chatGPT : .apiKey }
    static var baseURL: String { UserDefaults.standard.string(forKey: urlKey) ?? "" }
    static var model: String { UserDefaults.standard.string(forKey: modelKey) ?? "" }

    private static func query(for endpoint: URL) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: endpoint.absoluteString]
    }

    static func apiKey(for endpoint: URL) -> String? {
        var item = query(for: endpoint)
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(item as CFDictionary, &result) == errSecSuccess,
              let bytes = result as? Data else { return nil }
        return String(data: bytes, encoding: .utf8)
    }

    static func save(baseURL: String, model: String, apiKey: String) throws {
        let config = try CloudTranslation(baseURL: baseURL, model: model)
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty {
            guard Self.apiKey(for: config.endpoint) != nil else { throw CloudTranslation.Failure.invalidConfiguration }
        } else {
            guard !key.contains(where: { $0.isWhitespace || $0.isNewline }) else {
                throw CloudTranslation.Failure.invalidConfiguration
            }
            let query = query(for: config.endpoint)
            let value = [kSecValueData as String: Data(key.utf8)]
            var status = SecItemUpdate(query as CFDictionary, value as CFDictionary)
            if status == errSecItemNotFound {
                status = SecItemAdd(query.merging(value) { _, new in new } as CFDictionary, nil)
            }
            guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        }
        UserDefaults.standard.set(baseURL, forKey: urlKey)
        UserDefaults.standard.set(config.model, forKey: modelKey)
    }
}
