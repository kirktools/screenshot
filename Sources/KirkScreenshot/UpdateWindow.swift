import AppKit

/// 更新窗口不使用 runModal；安装只由用户明确点击发起。
@MainActor final class AppUpdateController: NSWindowController, NSWindowDelegate {
    private let status = NSTextField(wrappingLabelWithString: "")
    private let action = NSButton(title: "检查更新", target: nil, action: nil)
    private let progress = NSProgressIndicator()
    private let client: UpdateDownload
    private let canInstall: () -> Bool
    private let beginInstall: () -> Bool
    private let endInstall: () -> Void
    private var task: Task<Void, Never>?
    private var offer: UpdateOffer?
    private var prepared: PreparedUpdate?
    init(canInstall: @escaping () -> Bool, beginInstall: @escaping () -> Bool, endInstall: @escaping () -> Void, client: UpdateDownload = UpdateDownload()) {
        self.canInstall = canInstall; self.beginInstall = beginInstall; self.endInstall = endInstall; self.client = client
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 510, height: 410), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Kirk Screenshot · 检查更新"; window.isReleasedWhenClosed = false; window.center()
        super.init(window: window); window.delegate = self
        let title = NSTextField(labelWithString: "更新 Kirk Screenshot")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        status.maximumNumberOfLines = 5; status.lineBreakMode = .byTruncatingTail
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知"
        let version = NSTextField(labelWithString: "当前版本 \(current) · 仅检查 GitHub 正式 Release")
        version.textColor = .secondaryLabelColor
        let note = NSTextField(wrappingLabelWithString: "更新会先校验并备份旧版，再替换并重启。未签名/未公证版本仍可能被 macOS 拦截，或需要重新授予录屏权限；不会自动放宽系统保护。")
        note.textColor = .secondaryLabelColor; note.font = .systemFont(ofSize: 12)
        progress.style = .spinning; progress.controlSize = .small; progress.isDisplayedWhenStopped = false
        action.target = self; action.action = #selector(primary)
        let page = NSButton(title: "打开 Release 页面", target: self, action: #selector(openRelease))
        let buttons = NSStackView(views: [action, page, progress]); buttons.spacing = 10
        let stack = NSStackView(views: [title, version, status, note, buttons])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false; window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
                                     stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24),
                                     stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24),
                                     status.widthAnchor.constraint(equalTo: stack.widthAnchor), note.widthAnchor.constraint(equalTo: stack.widthAnchor)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func show() {
        showWindow(nil); NSApp.activate(ignoringOtherApps: true); window?.makeKeyAndOrderFront(nil)
        if task == nil && offer == nil { check() }
    }
    private func working(_ message: String) { status.stringValue = message; action.isEnabled = false; progress.startAnimation(nil) }
    private func idle(_ title: String) { action.title = title; action.isEnabled = true; progress.stopAnimation(nil); task = nil }
    private func check() {
        working("正在检查正式版本…")
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let current = try ReleaseVersion(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0")
                let result = try await client.check(current: current)
                guard !Task.isCancelled else { return }
                offer = result
                if let result {
                    status.stringValue = "发现新版本 \(result.package.version)。点击更新将下载、校验并安装。" + (result.usesCLI ? " 当前使用本机已登录的 GitHub CLI 读取私有仓库。" : "")
                    idle("更新并重启")
                } else { status.stringValue = "当前已是最新正式版本。"; idle("重新检查") }
            } catch {
                guard !Task.isCancelled else { return }
                let previous = (try? Data(contentsOf: UpdatePaths.receipt)).flatMap { $0.count <= 8192 ? String(data: $0, encoding: .utf8) : nil }.map { "\n\($0)" } ?? ""
                status.stringValue = error.localizedDescription + previous; idle("重试检查")
            }
        }
    }
    @objc private func primary() {
        if let prepared { install(prepared); return }
        guard let offer else { check(); return }
        guard canInstall() else { status.stringValue = "请先完成或取消当前截图，再进行更新。"; return }
        working("正在下载并校验更新，请勿移动当前应用…")
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let value = try await client.prepare(offer, currentApp: Bundle.main.bundleURL)
                guard !Task.isCancelled else { value.clean(); return }
                prepared = value; idle("安装并重启"); install(value)
            } catch {
                guard !Task.isCancelled else { return }
                status.stringValue = error.localizedDescription; idle("重试下载")
            }
        }
    }
    private func install(_ prepared: PreparedUpdate) {
        guard beginInstall() else { status.stringValue = "下载已完成。请先完成或取消当前截图，再点击安装并重启。"; return }
        working("正在启动安装助手…")
        task = Task { [self] in
            defer { endInstall() }
            do {
                let helper = try await prepared.startHelper(parent: ProcessInfo.processInfo.processIdentifier, currentApp: Bundle.main.bundleURL)
                guard Self.acceptReadyHelper(helper, cancelled: Task.isCancelled) else { return }
                // 只在助手完成校验并报告就绪后退出，避免助手失败导致应用白白关闭。
                self.prepared = nil
                NSApp.terminate(nil)
            } catch {
                guard !Task.isCancelled else { return }
                status.stringValue = error.localizedDescription; idle("重试安装")
            }
        }
    }
    static func acceptReadyHelper(_ process: Process, cancelled: Bool) -> Bool {
        // 从非隔离助手返回主线程时，窗口可能已经关闭；必须再次检查取消。
        if cancelled { if process.isRunning { process.terminate() }; return false }
        return true
    }
    @objc private func openRelease() {
        NSWorkspace.shared.open(offer?.package.page ?? URL(string: "https://github.com/kirktools/screenshot/releases")!)
    }
    func windowWillClose(_ notification: Notification) {
        task?.cancel(); task = nil; prepared?.clean(); prepared = nil; offer = nil
        idle("检查更新")
    }
    static func verifyCloseReset(offer: UpdateOffer) throws {
        let controller = AppUpdateController(canInstall: { true }, beginInstall: { true }, endInstall: {})
        controller.offer = offer; controller.working("下载中")
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        guard controller.offer == nil, controller.prepared == nil, controller.action.isEnabled, controller.action.title == "检查更新" else { throw UpdateError("关闭更新窗口后操作状态未恢复。") }
    }
}
