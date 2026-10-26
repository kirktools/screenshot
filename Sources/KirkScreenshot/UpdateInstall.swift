import Foundation
import Security
import Darwin

struct UpdateBundle {
    let version: ReleaseVersion, minimumOS: ReleaseVersion
    let team: String?
    static func inspect(_ app: URL) throws -> UpdateBundle {
        let fm = FileManager.default
        guard app.lastPathComponent == "Kirk Screenshot.app", let iterator = fm.enumerator(at: app, includingPropertiesForKeys: [.isSymbolicLinkKey, .fileSizeKey]) else { throw UpdateError("更新中没有正确的应用目录。") }
        var total = 0
        for case let url as URL in iterator {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
            guard values.isSymbolicLink != true else { throw UpdateError("更新应用含不支持的符号链接。") }
            total += values.fileSize ?? 0
            guard total <= 512 * 1024 * 1024 else { throw UpdateError("更新应用内容超过大小限制。") }
        }
        guard try app.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw UpdateError("应用根目录不能是链接。") }
        let infoURL = app.appendingPathComponent("Contents/Info.plist")
        guard (try infoURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 1024 * 1024 else { throw UpdateError("应用版本信息过大。") }
        let data = try Data(contentsOf: infoURL)
        guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == "com.kirktools.screenshot",
              info["CFBundleExecutable"] as? String == "KirkScreenshot",
              let versionText = info["CFBundleShortVersionString"] as? String else { throw UpdateError("更新应用的标识或版本信息无效。") }
        let version = try ReleaseVersion(versionText)
        let minimum = info["LSMinimumSystemVersion"] as? String ?? "14.0"
        let minimumOS = try ReleaseVersion(minimum.split(separator: ".").count == 2 ? minimum + ".0" : minimum)
        _ = try UpdateCommand.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        guard try supportsArchitecture(app.appendingPathComponent("Contents/MacOS/KirkScreenshot"), cpu: architecture == "arm64" ? 0x0100000c : 0x01000007) else { throw UpdateError("更新应用不包含当前芯片架构。") }

        var code: SecStaticCode?, signing: CFDictionary?
        guard SecStaticCodeCreateWithPath(app as CFURL, SecCSFlags(), &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &signing) == errSecSuccess else { throw UpdateError("无法读取更新应用的签名身份。") }
        let team = (signing as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
        let resources = app.appendingPathComponent("Contents/Resources/KirkScreenshot_KirkScreenshot.bundle")
        guard fm.fileExists(atPath: resources.path) else { throw UpdateError("更新应用缺少语言资源包。") }
        return UpdateBundle(version: version, minimumOS: minimumOS, team: team)
    }
    /// 直接读取 Mach-O 头；发行应用不能依赖需安装 Xcode/CLT 的 lipo。
    static func supportsArchitecture(_ executable: URL, cpu: UInt32) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: executable); defer { try? handle.close() }
        let data = [UInt8](try handle.read(upToCount: 4096) ?? Data())
        guard data.count >= 8 else { return false }
        func word(_ offset: Int, little: Bool) -> UInt32 {
            let bytes = Array(data[offset..<(offset + 4)])
            return little ? bytes.enumerated().reduce(0) { $0 | UInt32($1.element) << ($1.offset * 8) } : bytes.reduce(0) { ($0 << 8) | UInt32($1) }
        }
        let magic = word(0, little: false)
        if magic == 0xcffaedfe { return word(4, little: true) == cpu }
        if magic == 0xfeedfacf { return word(4, little: false) == cpu }
        let little = magic == 0xbebafeca || magic == 0xbfbafeca
        guard [0xcafebabe, 0xcafebabf, 0xbebafeca, 0xbfbafeca].contains(magic) else { return false }
        let count = Int(word(4, little: little)), stride = (magic == 0xcafebabf || magic == 0xbfbafeca) ? 32 : 20
        guard count > 0, count <= 64, 8 + count * stride <= data.count else { return false }
        return (0..<count).contains { word(8 + $0 * stride, little: little) == cpu }
    }
    func requireCompatible(expected: ReleaseVersion, currentTeam: String?) throws {
        guard version == expected else { throw UpdateError("更新包内版本与 Release 标签不一致。") }
        if let currentTeam, team != currentTeam { throw UpdateError("更新签名身份与当前应用不同，不能自动替换。") }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let running = try ReleaseVersion("\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")
        guard minimumOS <= running else { throw UpdateError("新版需要 macOS \(minimumOS) 或更新版本。") }
    }
}

enum UpdatePaths {
    static let destination = URL(fileURLWithPath: "/Applications/Kirk Screenshot.app", isDirectory: true)
    static var cache: URL { FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("com.kirktools.screenshot/Updates", isDirectory: true) }
    static var receipt: URL { cache.appendingPathComponent("last-result.txt") }
}

struct PreparedUpdate {
    let root: URL, app: URL
    let version: ReleaseVersion
    let team: String?
    func clean() { try? FileManager.default.removeItem(at: root) }
    /// 辅助进程复制到缓存，不从即将被替换的旧应用内执行。
    func startHelper(parent: Int32, currentApp: URL) async throws -> Process {
        guard currentApp.standardizedFileURL.path == UpdatePaths.destination.standardizedFileURL.path,
              FileManager.default.isWritableFile(atPath: UpdatePaths.destination.deletingLastPathComponent().path) else {
            throw UpdateError("请先安装到 /Applications/Kirk Screenshot.app，并确保当前用户可写。不会自动使用管理员权限。")
        }
        let helper = root.appendingPathComponent("UpdateInstaller")
        try? FileManager.default.removeItem(at: helper)
        try? FileManager.default.removeItem(at: root.appendingPathComponent("ready.txt"))
        try FileManager.default.copyItem(at: currentApp.appendingPathComponent("Contents/MacOS/KirkScreenshot"), to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let manifest = UpdateManifest(parentPID: parent, app: app.path, version: version.description, team: team)
        let file = root.appendingPathComponent("manifest.json")
        try JSONEncoder().encode(manifest).write(to: file, options: .atomic)
        let process = Process(); process.executableURL = helper; process.arguments = ["--apply-update", file.path]
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        do {
            let deadline = Date().addingTimeInterval(8)
            let ready = root.appendingPathComponent("ready.txt")
            while Date() < deadline {
                try Task.checkCancellation()
                if let result = try? String(contentsOf: ready, encoding: .utf8) {
                    guard result == "ready" else { throw UpdateError(result) }
                    return process
                }
                guard process.isRunning else { throw UpdateError("安装助手启动失败，当前应用没有退出。") }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw UpdateError("安装助手未就绪，当前应用没有退出。")
        } catch {
            if process.isRunning { process.terminate() }
            throw error
        }
    }
}

struct UpdateManifest: Codable {
    let parentPID: Int32
    let app: String, version: String
    let team: String?
}

/// 同盘目录替换，不覆写运行中 Mach-O；失败保留旧目录和 ZIP，下一次检查可读结果。
enum UpdateInstaller {
    static func swap(source: URL, destination: URL, backupDirectory: URL,
                     validate: (URL) throws -> Void = { _ in }, move: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }) throws {
        let fm = FileManager.default
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".kirk-update-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let newApp = staging.appendingPathComponent("Kirk Screenshot.app"), oldApp = staging.appendingPathComponent("previous.app")
        var preserve = false
        defer { if !preserve { try? fm.removeItem(at: staging) } }
        _ = try UpdateCommand.run("/usr/bin/ditto", [source.path, newApp.path])
        try validate(newApp)
        guard fm.fileExists(atPath: destination.path) else { throw UpdateError("原应用已移动或移除，停止更新。") }
        try fm.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        let backup = backupDirectory.appendingPathComponent("Kirk-Screenshot-\(UUID().uuidString).zip")
        _ = try UpdateCommand.run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", destination.path, backup.path])
        try move(destination, oldApp)
        do { try move(newApp, destination) }
        catch {
            do { try move(oldApp, destination) }
            catch { preserve = true; throw UpdateError("自动恢复失败，旧应用保留在 \(oldApp.path)；备份为 \(backup.path)。") }
            throw UpdateError("安装失败，已恢复旧版。备份：\(backup.path)")
        }
    }
    static func runHelper(manifest file: String) -> Int32 {
        let fm = FileManager.default, url = URL(fileURLWithPath: file).standardizedFileURL
        guard url.lastPathComponent == "manifest.json", url.deletingLastPathComponent().lastPathComponent.hasPrefix("pending-"),
              url.deletingLastPathComponent().deletingLastPathComponent().path == UpdatePaths.cache.standardizedFileURL.path else { return 1 }
        let root = url.deletingLastPathComponent()
        do {
            guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) < 8192 else { throw UpdateError("更新任务信息过大。") }
            let data = try Data(contentsOf: url)
            guard data.count < 8192 else { throw UpdateError("更新任务信息过大。") }
            let manifest = try JSONDecoder().decode(UpdateManifest.self, from: data)
            guard manifest.parentPID > 1, URL(fileURLWithPath: manifest.app).standardizedFileURL.path == root.appendingPathComponent("extracted/Kirk Screenshot.app").path else { throw UpdateError("更新任务路径无效。") }
            let lock = fm.temporaryDirectory.appendingPathComponent("kirk-screenshot-dev-install.lock")
            let descriptor = open(lock.path, O_CREAT | O_RDWR, 0o600)
            guard descriptor >= 0 else { throw UpdateError("无法创建安装互斥锁。") }
            defer { close(descriptor) }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw UpdateError("另一更新任务正在安装，已取消重复更新。") }
            let version = try ReleaseVersion(manifest.version)
            let original = try UpdateBundle.inspect(UpdatePaths.destination)
            guard original.version < version, original.team == manifest.team else { throw UpdateError("当前应用的版本或签名已改变，请重新检查更新。") }
            try UpdateBundle.inspect(URL(fileURLWithPath: manifest.app)).requireCompatible(expected: version, currentTeam: original.team)
            try "ready".write(to: root.appendingPathComponent("ready.txt"), atomically: true, encoding: .utf8)
            let deadline = Date().addingTimeInterval(30)
            while kill(manifest.parentPID, 0) == 0 && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
            guard kill(manifest.parentPID, 0) != 0 else { throw UpdateError("原应用尚未退出，未进行安装。") }
            try swap(source: URL(fileURLWithPath: manifest.app), destination: UpdatePaths.destination,
                     backupDirectory: UpdatePaths.cache.appendingPathComponent("Backups"), validate: { app in
                try UpdateBundle.inspect(app).requireCompatible(expected: version, currentTeam: original.team)
            })
            try "已更新到 \(version)。旧版备份保留在 \(UpdatePaths.cache.appendingPathComponent("Backups").path)。".write(to: UpdatePaths.receipt, atomically: true, encoding: .utf8)
            _ = try UpdateCommand.run("/usr/bin/open", [UpdatePaths.destination.path])
            try? fm.removeItem(at: root)
            return 0
        } catch {
            try? error.localizedDescription.write(to: root.appendingPathComponent("ready.txt"), atomically: true, encoding: .utf8)
            try? fm.createDirectory(at: UpdatePaths.cache, withIntermediateDirectories: true)
            try? "上次更新失败：\(error.localizedDescription)".write(to: UpdatePaths.receipt, atomically: true, encoding: .utf8)
            if fm.fileExists(atPath: UpdatePaths.destination.path) { _ = try? UpdateCommand.run("/usr/bin/open", [UpdatePaths.destination.path]) }
            return 1
        }
    }
}
