import Foundation
import CryptoKit
import Darwin

/// 所有外部命令使用参数数组；不读取令牌、不启动 shell、不自动执行 gh auth login。
enum UpdateCommand {
    static func run(_ executable: String, _ arguments: [String], maximumOutput: Int = 1024 * 1024) throws -> Data {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("screenshot-command-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("output")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let handle = try FileHandle(forWritingTo: output); defer { try? handle.close() }
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardInput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice; process.standardOutput = handle
        var environment = ProcessInfo.processInfo.environment; environment["GH_PROMPT_DISABLED"] = "1"; process.environment = environment
        try process.run()
        let deadline = Date().addingTimeInterval(120)
        var exceeded = false
        while process.isRunning {
            let size = (try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if Date() > deadline || size > maximumOutput { exceeded = true; process.terminate(); break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        if exceeded {
            let timeout = Date().addingTimeInterval(2)
            while process.isRunning && Date() < timeout { Thread.sleep(forTimeInterval: 0.05) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        guard !exceeded && process.terminationStatus == 0 else { throw UpdateError("\(URL(fileURLWithPath: executable).lastPathComponent) 执行失败或超时，已保留当前应用。") }
        let result = try Data(contentsOf: output)
        guard result.count <= maximumOutput else { throw UpdateError("更新命令输出超过大小限制。") }
        return result
    }
    static var githubCLI: String? {
        ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

final class UpdateHTTPSPolicy: NSObject, URLSessionTaskDelegate {
    static func allowed(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.scheme == "https" && url.user == nil && url.password == nil && (url.port == nil || url.port == 443) &&
            ["api.github.com", "github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com", "objects-origin.githubusercontent.com"].contains(url.host ?? "")
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(Self.allowed(request.url) ? request : nil)
    }
}

struct UpdateOffer {
    let package: ReleasePackage
    let usesCLI: Bool
}

actor UpdateDownload {
    private let session: URLSession
    private let cli: String?
    private let cacheRoot: URL
    init(session: URLSession? = nil, cli: String? = UpdateCommand.githubCLI, cacheRoot: URL = UpdatePaths.cache) {
        self.cacheRoot = cacheRoot
        if let session { self.session = session }
        else {
            let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 120
            self.session = URLSession(configuration: config, delegate: UpdateHTTPSPolicy(), delegateQueue: nil)
        }
        self.cli = cli
    }
    private func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Screenshot-Updater", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        return request
    }
    func check(current: ReleaseVersion) async throws -> UpdateOffer? {
        let url = URL(string: "https://api.github.com/repos/kirktools/screenshot/releases/latest")!
        let (bytes, response) = try await session.bytes(for: request(url))
        guard let http = response as? HTTPURLResponse, UpdateHTTPSPolicy.allowed(http.url) else { throw UpdateError("更新接口响应无效。") }
        let data: Data, usesCLI: Bool
        if http.statusCode == 404 {
            guard let cli else { throw UpdateError("没有可公开读取的正式版。私有仓库需要本机已安装并登录的 GitHub CLI；应用不会保存令牌或自动登录。") }
            do { data = try await Task.detached { try UpdateCommand.run(cli, ["api", "repos/kirktools/screenshot/releases/latest"]) }.value }
            catch { throw UpdateError("无法读取私有 Release。请确认本机 gh 已登录且有仓库访问权限，或等待仓库公开及发布正式版。") }
            usesCLI = true
        } else {
            guard http.statusCode == 200 else { throw UpdateError("检查更新失败（HTTP \(http.statusCode)）。请稍后手动重试。") }
            var value = Data()
            for try await byte in bytes { value.append(byte); if value.count > 1024 * 1024 { throw UpdateError("更新元数据超过大小限制。") } }
            data = value; usesCLI = false
        }
        try Task.checkCancellation()
        let release = try JSONDecoder().decode(AppRelease.self, from: data)
        return try release.package(current: current).map { UpdateOffer(package: $0, usesCLI: usesCLI) }
    }
    private func download(_ asset: ReleaseAsset, offer: UpdateOffer, to file: URL, limit: Int) async throws {
        if offer.usesCLI {
            guard let cli else { throw UpdateError("GitHub CLI 不可用。") }
            let data = try await Task.detached { try UpdateCommand.run(cli, ["api", "repos/kirktools/screenshot/releases/assets/\(asset.id)", "-H", "Accept: application/octet-stream"], maximumOutput: limit) }.value
            try Task.checkCancellation(); try data.write(to: file, options: .atomic)
        } else {
            let (bytes, response) = try await session.bytes(for: URLRequest(url: asset.browser_download_url))
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, UpdateHTTPSPolicy.allowed(http.url),
                  response.expectedContentLength <= Int64(limit) else { throw UpdateError("更新下载响应无效或超过大小限制。") }
            FileManager.default.createFile(atPath: file.path, contents: nil)
            let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }
            var chunk = Data(), total = 0
            for try await byte in bytes {
                chunk.append(byte); total += 1
                guard total <= limit else { throw UpdateError("更新下载超过大小限制。") }
                if chunk.count == 65536 { try Task.checkCancellation(); try handle.write(contentsOf: chunk); chunk.removeAll(keepingCapacity: true) }
            }
            try handle.write(contentsOf: chunk)
        }
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard size == asset.size else { throw UpdateError("更新文件大小与 Release 声明不一致。") }
    }
    func prepare(_ offer: UpdateOffer, currentApp: URL) async throws -> PreparedUpdate {
        let root = cacheRoot.appendingPathComponent("pending-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var keep = false
        defer { if !keep { try? FileManager.default.removeItem(at: root) } }
        let checksum = root.appendingPathComponent("SHA256SUMS.txt"), archive = root.appendingPathComponent(offer.package.archive.name)
        try await download(offer.package.checksums, offer: offer, to: checksum, limit: 64 * 1024)
        let expected = try offer.package.expectedHash(String(contentsOf: checksum, encoding: .utf8))
        try await download(offer.package.archive, offer: offer, to: archive, limit: 128 * 1024 * 1024)
        let directory = root.appendingPathComponent("extracted")
        let package = offer.package
        let prepared = try await Task.detached { () throws -> PreparedUpdate in
            let data = try Data(contentsOf: archive)
            guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == expected else { throw UpdateError("更新包 SHA-256 不匹配，已拒绝安装。") }
            try UpdateZipPolicy.validate(data)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            _ = try UpdateCommand.run("/usr/bin/ditto", ["-x", "-k", archive.path, directory.path])
            let candidates = ["Screenshot.app", "Kirk Screenshot.app"].map { directory.appendingPathComponent($0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
            guard candidates.count == 1, let app = candidates.first else { throw UpdateError("更新包必须只包含一份应用。") }
            let current = try UpdateBundle.inspect(currentApp)
            let candidate = try UpdateBundle.inspect(app)
            try candidate.requireCompatible(expected: package.version, currentTeam: current.team, currentCertificate: current.certificate)
            // 保留系统的下载验证机制，不通过去除隔离属性或重新签名绕过 Gatekeeper。
            _ = try UpdateCommand.run("/usr/bin/xattr", ["-w", "com.apple.quarantine", "0083;\(String(Int(Date().timeIntervalSince1970), radix: 16));Screenshot;", app.path])
            return PreparedUpdate(root: root, app: app, version: package.version, team: current.team)
        }.value
        try Task.checkCancellation(); keep = true; return prepared
    }
}
