import Foundation
import CryptoKit

private func updateRequire(_ value: Bool, _ message: String) throws {
    if !value { throw UpdateError("更新回归：" + message) }
}
private func rejects(_ message: String, _ body: () throws -> Void) throws {
    var failed = false
    do { try body() } catch { failed = true }
    try updateRequire(failed, message)
}

/// 只生成本应用的临时副本，不更新 /Applications，也不访问网络或申请权限。
func makeUpdateFixture(in root: URL) throws -> URL {
    let fm = FileManager.default, app = root.appendingPathComponent("Screenshot.app")
    let macOS = app.appendingPathComponent("Contents/MacOS"), resources = app.appendingPathComponent("Contents/Resources")
    try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
    try fm.createDirectory(at: resources, withIntermediateDirectories: true)
    try fm.copyItem(at: Bundle.main.executableURL!, to: macOS.appendingPathComponent("Screenshot"))
    try fm.copyItem(at: AppLocalization.bundle.bundleURL, to: resources.appendingPathComponent("Screenshot_Screenshot.bundle"))
    let info: [String: Any] = ["CFBundleIdentifier": "com.kirktools.screenshot", "CFBundleExecutable": "Screenshot", "CFBundlePackageType": "APPL", "CFBundleName": "Screenshot", "CFBundleShortVersionString": "999.0.0", "CFBundleVersion": "1", "LSMinimumSystemVersion": "14.0"]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
    _ = try UpdateCommand.run("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", app.path])
    return app
}

@MainActor func runUpdateSelfTest() throws {
    let delegate = AppDelegate()
    var permissionChecks = 0
    delegate.permissionAccess = ScreenPermissionAccess(isAuthorized: { permissionChecks += 1; return false }, request: { false }, openSettings: {})
    try updateRequire(delegate.reserveUpdateInstallation(), "不能占用安装状态")
    delegate.capture(scrolling: false); delegate.capture(scrolling: true)
    try updateRequire(permissionChecks == 0 && !delegate.reserveUpdateInstallation(), "安装期间仍能开始截图或重复安装")
    delegate.releaseUpdateInstallation()
    try updateRequire(delegate.reserveUpdateInstallation(), "失败后安装状态没有释放")
    delegate.releaseUpdateInstallation()
    let helper = Process(); helper.executableURL = URL(fileURLWithPath: "/bin/sleep"); helper.arguments = ["5"]
    try helper.run()
    try updateRequire(!AppUpdateController.acceptReadyHelper(helper, cancelled: true), "助手就绪后取消仍继续退出")
    helper.waitUntilExit()
    try updateRequire(helper.terminationReason == .uncaughtSignal, "取消未停止已就绪助手")
    for (left, right) in [("0.1.9", "0.1.10"), ("1.9.9", "2.0.0"), ("v1.0.0", "1.0.1")] {
        try updateRequire(ReleaseVersion(left) < ReleaseVersion(right), "版本比较按字符串排序")
    }
    for value in ["1.2", "01.2.3", "1.2.3-beta", "1.2.3+test", "-1.0.0", "1.2.999999999999999999999999", "1/2/3"] {
        try rejects("非法版本被接受") { _ = try ReleaseVersion(value) }
    }
    let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("screenshot-update-test-\(UUID().uuidString)")
    try fm.createDirectory(at: root, withIntermediateDirectories: true); defer { try? fm.removeItem(at: root) }
    let source = try makeUpdateFixture(in: root)
    let candidate = try UpdateBundle.inspect(source)
    try candidate.requireCompatible(expected: ReleaseVersion("999.0.0"), currentTeam: nil)
    try rejects("包内版本不一致仍接受") { try candidate.requireCompatible(expected: ReleaseVersion("999.0.1"), currentTeam: nil) }
    try rejects("签名身份降级仍接受") { try candidate.requireCompatible(expected: ReleaseVersion("999.0.0"), currentTeam: "OTHERTEAM") }
    let archive = root.appendingPathComponent("good.zip")
    _ = try UpdateCommand.run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", source.path, archive.path])
    let zip = try Data(contentsOf: archive)
    try UpdateZipPolicy.validate(zip)
    var corrupt = zip; corrupt[0] = 0
    try rejects("ZIP 本地目录损坏未拒绝") { try UpdateZipPolicy.validate(corrupt) }
    // 改写真实中央目录的首个路径，不执行或解压不可信内容。
    func alteredName(_ value: String) throws -> Data {
        var data = zip
        let signature = Data([0x50, 0x4b, 0x01, 0x02])
        var search = 0, found: Int?
        while let range = data.range(of: signature, in: search..<data.count) {
            let at = range.lowerBound
            let length = Int(data[at + 28]) | Int(data[at + 29]) << 8
            if length >= value.utf8.count { found = at; break }
            search = at + 4
        }
        guard let at = found else { throw UpdateError("缺少足够长的 ZIP 条目") }
        let length = Int(data[at + 28]) | Int(data[at + 29]) << 8
        let bytes = Array((value + String(repeating: "x", count: length)).utf8.prefix(length))
        let local = (0..<4).reduce(0) { $0 | Int(data[at + 42 + $1]) << ($1 * 8) }
        data.replaceSubrange(at + 46..<at + 46 + length, with: bytes)
        data.replaceSubrange(local + 30..<local + 30 + length, with: bytes)
        return data
    }
    for name in ["../escape/", "/absolute/", "Screenshot.app/../", "Screenshot.app\\"] {
        try rejects("不安全路径未拒绝") { try UpdateZipPolicy.validate(alteredName(name)) }
    }
    var link = zip
    let at = link.range(of: Data([0x50, 0x4b, 0x01, 0x02]))!.lowerBound
    let attributes = UInt32(0o120777) << 16
    for i in 0..<4 { link[at + 38 + i] = UInt8((attributes >> (i * 8)) & 255) }
    try rejects("符号链接未拒绝") { try UpdateZipPolicy.validate(link) }
    let parent = root.appendingPathComponent("Applications"), destination = parent.appendingPathComponent("Screenshot.app")
    try fm.createDirectory(at: parent, withIntermediateDirectories: true)
    try fm.copyItem(at: source, to: destination)
    let marker = destination.appendingPathComponent("old-marker")
    try Data("old".utf8).write(to: marker)
    let backup = root.appendingPathComponent("backups")
    try rejects("新应用校验失败仍替换") {
        try UpdateInstaller.swap(source: source, destination: destination, backupDirectory: backup, validate: { _ in throw UpdateError("invalid") })
    }
    try updateRequire(fm.fileExists(atPath: marker.path), "校验失败后旧版丢失")
    var failNew = true
    try rejects("模拟替换失败未报告") {
        try UpdateInstaller.swap(source: source, destination: destination, backupDirectory: backup, move: { from, to in
            if from.lastPathComponent == "Screenshot.app" && from.path.contains(".screenshot-update-") && failNew { failNew = false; throw UpdateError("install failed") }
            try fm.moveItem(at: from, to: to)
        })
    }
    try updateRequire(fm.fileExists(atPath: marker.path), "替换失败没有回滚")
    try rejects("双重失败未报告") {
        try UpdateInstaller.swap(source: source, destination: destination, backupDirectory: backup, move: { from, to in
            if to == destination { throw UpdateError("restore failed") }
            try fm.moveItem(at: from, to: to)
        })
    }
    let retained = try fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix(".screenshot-update-") }
    try updateRequire(retained != nil && fm.fileExists(atPath: retained!.appendingPathComponent("previous.app/old-marker").path), "恢复失败没有保留旧目录")
    // 名称迁移必须先备份旧目录，失败仍恢复旧名称，而不是留下两份应用。
    let migration = root.appendingPathComponent("migration")
    try fm.createDirectory(at: migration, withIntermediateDirectories: true)
    let legacy = migration.appendingPathComponent("Kirk Screenshot.app"), renamed = migration.appendingPathComponent("Screenshot.app")
    try fm.copyItem(at: source, to: legacy)
    // 旧包不只有外层名称不同，内部可执行文件和资源包也使用旧名字。
    try fm.moveItem(at: legacy.appendingPathComponent("Contents/MacOS/Screenshot"), to: legacy.appendingPathComponent("Contents/MacOS/KirkScreenshot"))
    try fm.moveItem(at: legacy.appendingPathComponent("Contents/Resources/Screenshot_Screenshot.bundle"), to: legacy.appendingPathComponent("Contents/Resources/KirkScreenshot_KirkScreenshot.bundle"))
    let legacyInfo = legacy.appendingPathComponent("Contents/Info.plist")
    var info = try PropertyListSerialization.propertyList(from: Data(contentsOf: legacyInfo), format: nil) as! [String: Any]
    info["CFBundleExecutable"] = "KirkScreenshot"
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: legacyInfo)
    _ = try UpdateCommand.run("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", legacy.path])
    _ = try UpdateBundle.inspect(legacy)
    let oldZip = root.appendingPathComponent("legacy.zip")
    _ = try UpdateCommand.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", legacy.path, oldZip.path])
    try UpdateZipPolicy.validate(Data(contentsOf: oldZip))
    try UpdateInstaller.swap(source: source, destination: renamed, backupDirectory: root.appendingPathComponent("migration-backups"), previousDestination: legacy)
    try updateRequire(!fm.fileExists(atPath: legacy.path) && fm.fileExists(atPath: renamed.path), "改名后留下两份应用")
    try fm.moveItem(at: renamed, to: legacy)
    try rejects("改名替换失败未报告") {
        try UpdateInstaller.swap(source: source, destination: renamed, backupDirectory: root.appendingPathComponent("migration-backups"), previousDestination: legacy, move: { from, to in
            if to.path == renamed.path { throw UpdateError("rename failure") }
            try fm.moveItem(at: from, to: to)
        })
    }
    try updateRequire(fm.fileExists(atPath: legacy.path) && !fm.fileExists(atPath: renamed.path), "改名失败没有恢复旧名称")
    print("更新本地回归：数字版本、非法版本、签名/包版本、真实 ZIP、路径/链接拒绝、校验失败、替换回滚与双重失败保留通过")
}

final class UpdateHTTPStub: URLProtocol {
    static let lock = NSLock()
    static var responses: [String: (Int, Data)] = [:]
    static func set(_ values: [String: (Int, Data)]) { lock.lock(); responses = values; lock.unlock() }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let value = Self.responses[request.url!.absoluteString]; Self.lock.unlock()
        guard let (code, data) = value else { client?.urlProtocol(self, didFailWithError: UpdateError("测试禁止真实网络访问")); return }
        let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": "\(data.count)"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

func runUpdateNetworkSelfTest() async throws {
    let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("screenshot-update-http-\(UUID().uuidString)")
    try fm.createDirectory(at: root, withIntermediateDirectories: true); defer { try? fm.removeItem(at: root) }
    let source = try makeUpdateFixture(in: root)
    let file = root.appendingPathComponent("app.zip")
    _ = try UpdateCommand.run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", source.path, file.path])
    let zip = try Data(contentsOf: file), hash = SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
    let name = "Screenshot-999.0.0-macOS.zip", base = "https://github.com/kirktools/screenshot/releases/download/v999.0.0/"
    let api = "https://api.github.com/repos/kirktools/screenshot/releases/latest"
    let checksum = Data("\(hash)  dist/\(name)\n".utf8)
    let object: [String: Any] = ["tag_name": "v999.0.0", "draft": false, "prerelease": false, "assets": [
        ["id": 1, "name": name, "size": zip.count, "browser_download_url": base + name, "digest": "sha256:\(hash)"],
        ["id": 2, "name": "SHA256SUMS.txt", "size": checksum.count, "browser_download_url": base + "SHA256SUMS.txt"]]]
    let json = try JSONSerialization.data(withJSONObject: object)
    let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [UpdateHTTPStub.self]
    let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
    let downloader = UpdateDownload(session: session, cli: nil, cacheRoot: root.appendingPathComponent("cache"))
    UpdateHTTPStub.set([api: (200, json), base + name: (200, zip), base + "SHA256SUMS.txt": (200, checksum)])
    let found = try await downloader.check(current: ReleaseVersion("998.0.0"))!
    try updateRequire(found.package.version == ReleaseVersion("999.0.0"), "未发现新版本")
    try await AppUpdateController.verifyCloseReset(offer: found)
    let prepared = try await downloader.prepare(found, currentApp: source)
    try updateRequire(fm.fileExists(atPath: prepared.app.appendingPathComponent("Contents/Info.plist").path), "下载准备链路没有得到应用")
    let quarantine = try UpdateCommand.run("/usr/bin/xattr", ["-p", "com.apple.quarantine", prepared.app.path])
    try updateRequire(!quarantine.isEmpty, "更新没有保留系统下载验证")
    prepared.clean()
    let latest = try await downloader.check(current: ReleaseVersion("999.0.0"))
    try updateRequire(latest == nil, "当前版本错误地被降级")
    UpdateHTTPStub.set([api: (404, Data())])
    do { _ = try await downloader.check(current: ReleaseVersion("998.0.0")); throw UpdateError("404 私有仓库没有提示") }
    catch { try updateRequire(error.localizedDescription.contains("私有仓库"), "私有仓库错误未解释") }
    UpdateHTTPStub.set([api: (200, json), base + name: (200, Data(repeating: 0, count: zip.count)), base + "SHA256SUMS.txt": (200, checksum)])
    do { _ = try await downloader.prepare(found, currentApp: source); throw UpdateError("损坏下载没有拒绝") }
    catch { try updateRequire(error.localizedDescription.contains("SHA-256"), "损坏下载未因校验被拒绝") }
    let release = try JSONDecoder().decode(AppRelease.self, from: json)
    var legacyRelease = object
    let legacyName = "Kirk-Screenshot-999.0.0-macOS.zip"
    legacyRelease["assets"] = [
        ["id": 1, "name": legacyName, "size": zip.count, "browser_download_url": base + legacyName],
        ["id": 2, "name": "SHA256SUMS.txt", "size": checksum.count, "browser_download_url": base + "SHA256SUMS.txt"]]
    let legacyOffer = try JSONDecoder().decode(AppRelease.self, from: JSONSerialization.data(withJSONObject: legacyRelease)).package(current: ReleaseVersion("998.0.0"))
    try updateRequire(legacyOffer?.archive.name == legacyName, "旧名称的更新资源无法读取")
    try rejects("重复校验值未拒绝") { _ = try found.package.expectedHash(String(decoding: checksum + checksum, as: UTF8.self)) }
    try updateRequire(!AppRelease.isOfficialDownload(URL(string: "https://evil.example/\(name)")!, tag: release.tag_name, name: name), "接受第三方下载地址")
    try updateRequire(!UpdateHTTPSPolicy.allowed(URL(string: "http://github.com")), "接受 HTTP 降级")
    print("更新下载回归：模拟 GitHub 正式版、完整下载/哈希/解压/签名准备、当前版本、私有 404、损坏下载及恶意 URL 拒绝通过；未真实访问网络或安装应用")
}
