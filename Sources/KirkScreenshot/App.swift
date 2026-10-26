import AppKit
import Carbon

// SwiftPM 的独立可执行文件查找位置与标准 .app/Contents/Resources 不同。
// 安装版必须显式使用包内资源，不能依赖开发机或 CI 的 .build 目录。
enum AppLocalization {
    static let embeddedBundle: Bundle? = Bundle.main.resourceURL
        .flatMap { Bundle(url: $0.appendingPathComponent("KirkScreenshot_KirkScreenshot.bundle")) }
    static var bundle: Bundle {
        if Bundle.main.bundleURL.pathExtension == "app" { return embeddedBundle ?? .main }
        return .module
    }
    static func verifyPackagedResources() throws {
        guard let bundle = embeddedBundle else { throw CaptureError.message("安装包缺少语言资源包") }
        for (language, expected) in [("en", "Capture Region"), ("zh-Hans", "区域截图")] {
            guard let path = bundle.paths(forResourcesOfType: "lproj", inDirectory: nil).first(where: { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent.caseInsensitiveCompare(language) == .orderedSame }),
                  let languageBundle = Bundle(path: path),
                  languageBundle.localizedString(forKey: "capture.normal", value: nil, table: nil) == expected else {
                throw CaptureError.message("安装包语言资源无效：\(language)")
            }
        }
        guard Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String == "Screenshot", Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String == "Screenshot" else { throw CaptureError.message("应用展示名称未统一") }
        guard localized("capture.normal") != "capture.normal" else { throw CaptureError.message("菜单语言资源加载失败") }
    }
}
func localized(_ key: String) -> String { NSLocalizedString(key, bundle: AppLocalization.bundle, comment: "") }

/// 将系统调用集中在一处，回归测试可替换为无权限副作用的实现。
struct ScreenPermissionAccess {
    var isAuthorized: () -> Bool = { CGPreflightScreenCaptureAccess() }
    var request: () -> Bool = { CGRequestScreenCaptureAccess() }
    var openSettings: () -> Void = {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var item: NSStatusItem!
    let hotkeys = HotkeyRegistry()
    private var selector: RegionSelector?
    private var session: ScrollSession?
    private var provider: MacCaptureProvider?
    private var editor: EditorController?
    private var settings: NSWindow?
    private var permissionHint: PassivePanel?
    private var permissionHintTimer: Timer?
    private var updateController: AppUpdateController?
    private var busy = false
    private var installingUpdate = false
    private var normal = Shortcut.normal
    private var scroll = Shortcut.scroll
    private var previousApp: NSRunningApplication?
    private var lastExternalApp: NSRunningApplication?
    private var activationObserver: NSObjectProtocol?
    private var hotkeyWarnings: [String] = []
    var permissionAccess = ScreenPermissionAccess()
    var schedulePermissionRequest: (@escaping () -> Void) -> Void = { action in DispatchQueue.main.async(execute: action) }
    private var permissionRequestPending = false
    private var hasRequestedPermission = false
    private weak var permissionButton: NSButton?
    private var permissionStatusLabel: NSTextField?
    private var hotkeyStatusLabel: NSTextField?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if CommandLine.arguments.contains("--overlay-demo") {
            buildMainMenu()
            let screen = NSScreen.main!.visibleFrame
            let demo = makeDemoImage()
            let image = ProcessInfo.processInfo.environment["KIRK_DOCUMENTATION_DIR"] != nil
                ? demo.cropping(to: CGRect(x: 0, y: 0, width: demo.width, height: Int(Double(demo.width) * 0.54)))! : demo
            present(image, region: CGRect(x: screen.midX - 300, y: screen.midY - 150, width: 600, height: 420), allowScroll: true)
            if let directory = ProcessInfo.processInfo.environment["KIRK_DOCUMENTATION_DIR"], let editor {
                do {
                    try writeDocumentationEditor(editor, to: URL(fileURLWithPath: directory).appendingPathComponent("editor.png"))
                    NSApp.terminate(nil)
                } catch { fputs("文档界面导出失败：\(error)\n", stderr); exit(1) }
                return
            }
            if let number = editor?.diagnosticToolbarViews.first?.window?.windowNumber { print("OVERLAY TOOLBAR WINDOW: \(number)"); fflush(stdout) }
            return
        }
        if CommandLine.arguments.contains("--startup-smoke-test") {
            Task { @MainActor in
                do { try await runStartupSmokeTest(self); print("STARTUP SMOKE PASSED"); NSApp.terminate(nil) }
                catch { fputs("STARTUP SMOKE FAILED: \(error)\n", stderr); exit(1) }
            }
            return
        }
        if CommandLine.arguments.contains("--live-scroll-self-test") {
            Task { @MainActor in
                do { try await runLiveScrollSelfTest(); NSApp.terminate(nil) }
                catch { fputs("LIVE SCROLL FAILED: \(error)\n", stderr); exit(1) }
            }
            return
        }
        if CommandLine.arguments.contains("--scroll-session-self-test") {
            Task { @MainActor in
                do { try await runScrollSessionSelfTest(); print("SCROLL SESSION SELF-TEST PASSED"); NSApp.terminate(nil) }
                catch { fputs("SCROLL SESSION SELF-TEST FAILED: \(error)\n", stderr); exit(1) }
            }
            return
        }
        if CommandLine.arguments.contains("--capture-smoke-test") {
            Task { @MainActor in
                do { try await runCaptureSmokeTest(); NSApp.terminate(nil) }
                catch { fputs("CAPTURE SMOKE FAILED: \(error)\n", stderr); exit(1) }
            }
            return
        }
        if CommandLine.arguments.contains("--hotkey-smoke-test") {
            do { try runHotkeySmokeTest(hotkeys); NSApp.terminate(nil) }
            catch { fputs("HOTKEY SMOKE FAILED: \(error)\n", stderr); exit(1) }
            return
        }
        if CommandLine.arguments.contains("--update-network-self-test") {
            Task { @MainActor in
                do { try await runUpdateNetworkSelfTest(); NSApp.terminate(nil) }
                catch { fputs("UPDATE NETWORK SELF-TEST FAILED: \(error)\n", stderr); exit(1) }
            }
            return
        }
        if CommandLine.arguments.contains("--self-test") {
            do { try runSelfTest(); print("SELF-TEST PASSED"); NSApp.terminate(nil) }
            catch { fputs("SELF-TEST FAILED: \(error)\n", stderr); exit(1) }
            return
        }
        lastExternalApp = NSWorkspace.shared.frontmostApplication
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let running = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, running.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            MainActor.assumeIsolated { self?.lastExternalApp = running }
        }
        normal = load("screenshot.region", fallback: .normal); scroll = load("screenshot.scroll", fallback: .scroll)
        configureMenuBar(); registerTools(); refreshMenu()
        if CommandLine.arguments.contains("--demo-editor") { present(makeDemoImage()); return }
        // 菜单栏工具启动时保持安静；设置只由明确的菜单或快捷键动作打开。
    }
    func configureMenuBar() {
        guard item == nil else { return }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "Screenshot")
        item.button?.toolTip = "Screenshot · 点击开始截图或打开设置"
        buildMainMenu(); refreshMenu()
    }
    func showPermissionHint() {
        let panel = permissionHint ?? PassivePanel(contentRect: CGRect(x: 0, y: 0, width: 288, height: 112), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating; panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let label = NSTextField(wrappingLabelWithString: "截图需要屏幕录制权限。请在设置中申请或检查当前应用的权限。")
        let settings = NSButton(title: "打开设置…", target: self, action: #selector(openSettings))
        let close = NSButton(title: "关闭", target: self, action: #selector(dismissPermissionHint))
        let actions = NSStackView(views: [settings, close]); actions.spacing = 10
        let stack = NSStackView(views: [label, actions]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        label.widthAnchor.constraint(equalToConstant: 260).isActive = true
        panel.contentView = stack
        // 使用与长图提示相同的非激活面板，避免依赖菜单栏宿主和弹出框焦点。
        let point = NSEvent.mouseLocation
        let bounds = (NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main)?.visibleFrame ?? CGRect(x: 0, y: 0, width: 800, height: 600)
        panel.setFrame(CGRect(x: bounds.maxX - 304, y: bounds.maxY - 128, width: 288, height: 112), display: true)
        permissionHint = panel; panel.orderFrontRegardless()
        permissionHintTimer?.invalidate()
        permissionHintTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismissPermissionHint() }
        }
    }
    var menuBarMenu: NSMenu? { item?.menu }
    var permissionHintDiagnostics: String { "hint=\(String(describing: permissionHint?.frame)) visible=\(String(describing: permissionHint?.isVisible)) settings=\(String(describing: settings?.isVisible))" }
    var hasVisiblePermissionHint: Bool { permissionHint?.isVisible == true }
    @objc func dismissPermissionHint() { permissionHintTimer?.invalidate(); permissionHintTimer = nil; permissionHint?.orderOut(nil) }
    private func load(_ key: String, fallback: Shortcut) -> Shortcut {
        guard let data = UserDefaults.standard.data(forKey: key), let value = try? JSONDecoder().decode(Shortcut.self, from: data) else { return fallback }; return value
    }
    private func registerTools() {
        for (name, requested, fallback, scrolling) in [
            ("screenshot.region", normal, Shortcut.fallbackNormal, false),
            ("screenshot.scroll", scroll, Shortcut.fallbackScroll, true)
        ] {
            let action: () -> Void = { [weak self] in self?.capture(scrolling: scrolling) }
            if hotkeys.register(name, shortcut: requested, action: action) { continue }
            let reason = hotkeys.lastError ?? "快捷键不可用"
            if !requested.hasSameBinding(as: fallback), hotkeys.register(name, shortcut: fallback, action: action) {
                if scrolling { scroll = fallback } else { normal = fallback }
                UserDefaults.standard.set(try? JSONEncoder().encode(fallback), forKey: name)
                hotkeyWarnings.append("\(reason)，已改用 \(fallback.label)。")
            } else { hotkeyWarnings.append("\(reason)。请点击截图按钮，或在设置中重新配置。") }
        }
    }
    private func refreshMenu() {
        guard item != nil else { return }
        let menu = NSMenu()
        let title = NSMenuItem(title: "Screenshot", action: nil, keyEquivalent: ""); menu.addItem(title)
        menu.addItem(.separator())
        add(menu, "\(localized("capture.normal"))   \(normal.label)", #selector(normalCapture))
        add(menu, "\(localized("capture.scroll"))   \(scroll.label)", #selector(scrollCapture))
        if editor != nil { add(menu, "打开上次预览", #selector(showEditor)) }
        menu.addItem(.separator()); add(menu, "检查更新…", #selector(checkForUpdates)); add(menu, localized("settings"), #selector(openSettings))
        add(menu, localized("quit"), #selector(quit)); item.menu = menu
    }
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector) { let i = NSMenuItem(title: title, action: action, keyEquivalent: ""); i.target = self; menu.addItem(i) }
    private func buildMainMenu() {
        let menu = NSMenu(), app = NSMenu(), edit = NSMenu()
        let appItem = NSMenuItem(); appItem.submenu = app; menu.addItem(appItem)
        let settings = NSMenuItem(title: localized("settings"), action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self; app.addItem(settings); app.addItem(.separator())
        let quit = NSMenuItem(title: "退出 Screenshot", action: #selector(quit), keyEquivalent: "q"); quit.target = self; app.addItem(quit)
        let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: ""); editItem.submenu = edit; menu.addItem(editItem)
        edit.addItem(withTitle: "撤销", action: #selector(EditorCanvas.undo(_:)), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "重做", action: #selector(EditorCanvas.redo(_:)), keyEquivalent: "z"); redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(withTitle: "保存 PNG", action: #selector(EditorCanvas.saveDocument(_:)), keyEquivalent: "s")
        NSApp.mainMenu = menu
    }
    @objc private func normalCapture() { capture(scrolling: false) }
    @objc private func scrollCapture() { capture(scrolling: true) }
    func capture(scrolling: Bool) {
        guard !busy && !installingUpdate else { return }
        guard permissionAccess.isAuthorized() else { showPermissionHint(); return }
        busy = true
        let frontmost = NSWorkspace.shared.frontmostApplication
        previousApp = frontmost?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? lastExternalApp : frontmost
        settings?.orderOut(nil); editor?.window?.orderOut(nil)
        let selector = RegionSelector(); self.selector = selector
        selector.completion = { [weak self] rect in
            guard let self else { return }
            self.selector = nil
            self.previousApp?.activate(options: [])
            guard let rect else { self.busy = false; return }
            if scrolling && !NSScreen.screens.contains(where: { $0.frame.contains(rect) }) {
                self.busy = false; showError(CaptureError.message("长截图需在同一块显示器内选择单一滚动区域。普通截图支持跨屏。")); return
            }
            Task { @MainActor [self] in
                do {
                    let provider = MacCaptureProvider(); self.provider = provider
                    try await provider.prepare()
                    try await Task.sleep(for: .milliseconds(250))
                    if scrolling {
                        guard rect.height >= 100, rect.width >= 80 else { throw CaptureError.message("长截图区域至少需要 80 × 100 点，请框选正文内容。") }
                        try self.beginScroll(rect, provider: provider)
                    } else {
                        let frozen = try await provider.frozenCapture(containing: rect)
                        guard let image = frozen.crop(rect) else { throw CaptureError.message("无法从屏幕快照裁取选区") }
                        self.busy = false; self.provider = nil; self.present(image, region: rect, allowScroll: true, frozenCapture: frozen)
                    }
                } catch { self.busy = false; self.provider = nil; showError(CaptureError.message("\(error.localizedDescription)\n若刚授予屏幕录制权限，请退出应用后重新打开。")) }
            }
        }
        selector.begin()
    }
    private func beginScroll(_ region: CGRect, provider: MacCaptureProvider) throws {
        let session = ScrollSession(provider: provider, region: region, hotkeys: hotkeys)
        self.session = session
        session.completion = { [weak self] image, action in
            self?.session = nil; self?.provider = nil; self?.busy = false
            guard let image else { return }
            switch action {
            case .copy: break
            case .edit: self?.present(image, region: region)
            case .save:
                NSApp.activate(ignoringOtherApps: true)
                let panel = NSSavePanel(); panel.allowedContentTypes = [.png]
                panel.nameFieldStringValue = "Kirk-\(Date.now.formatted(.iso8601).replacingOccurrences(of: ":", with: "-")).png"
                guard panel.runModal() == .OK, let url = panel.url else { return }
                do { try image.png().write(to: url, options: .atomic) } catch { showError(error) }
            }
        }
        guard session.start() else { self.session = nil; throw CaptureError.message("无法注册回车/Esc 会话快捷键") }
    }
    private func present(_ image: CGImage, region: CGRect? = nil, allowScroll: Bool = false, frozenCapture: FrozenCapture? = nil) {
        editor?.close()
        let controller = EditorController(image: image, region: region, allowScroll: allowScroll, frozenCapture: frozenCapture)
        editor = controller
        controller.dismissed = { [weak self] in self?.busy = false }
        controller.requestScroll = { [weak self, weak controller] in
            guard let self, let region = controller?.captureRegion ?? region else { return }
            guard region.width >= 80, region.height >= 100, NSScreen.screens.contains(where: { $0.frame.contains(region) }) else {
                self.busy = false; showError(CaptureError.message("长截图需在单一显示器内框选至少 80 × 100 点的正文区域。")); return
            }
            self.previousApp?.activate(options: [])
            Task { @MainActor in
                do {
                    let provider = MacCaptureProvider(); self.provider = provider
                    try await provider.prepare()
                    try await Task.sleep(for: .milliseconds(250))
                    try self.beginScroll(region, provider: provider)
                } catch { self.busy = false; self.provider = nil; showError(error) }
            }
        }
        showEditor(); refreshMenu()
    }
    @objc private func showEditor() { guard !installingUpdate else { return }; busy = true; NSApp.activate(ignoringOtherApps: true); editor?.showWindow(nil) }
    @objc private func quit() { session?.cancelCapture(); NSApp.terminate(nil) }
    @objc private func permissionGuide() {
        openSettings()
        guard !permissionRequestPending else { return }
        guard !permissionAccess.isAuthorized() else { refreshSettingsStatus(); return }
        // 两个按钮职责分开：重复点击主按钮仅重新检查，系统设置只由独立按钮打开。
        guard !hasRequestedPermission else { refreshSettingsStatus(); return }
        hasRequestedPermission = true; permissionRequestPending = true
        refreshSettingsStatus()
        // 先退出按钮/辅助功能的 action 调用栈，再交给系统显示原生授权。
        schedulePermissionRequest { [weak self] in
            guard let self else { return }
            let granted = self.permissionAccess.request()
            self.permissionRequestPending = false; self.permissionButton?.isEnabled = true
            self.refreshSettingsStatus()
            if granted && !self.permissionAccess.isAuthorized() {
                self.permissionStatusLabel?.stringValue = "系统已接受授权，请退出并重新打开当前路径的应用。"
            }
        }
    }
    func reserveUpdateInstallation() -> Bool {
        guard !busy, !installingUpdate else { return false }
        installingUpdate = true; return true
    }
    func releaseUpdateInstallation() { installingUpdate = false }
    @objc private func checkForUpdates() {
        if updateController == nil { updateController = AppUpdateController(canInstall: { [weak self] in self?.busy == false && self?.installingUpdate == false }, beginInstall: { [weak self] in
            self?.reserveUpdateInstallation() ?? false
        }, endInstall: { [weak self] in self?.releaseUpdateInstallation() }) }
        updateController?.show()
    }
    @objc private func openPrivacy() { permissionAccess.openSettings() }
    @objc func openSettings() {
        dismissPermissionHint()
        if let settings { refreshSettingsStatus(); NSApp.activate(ignoringOtherApps: true); settings.makeKeyAndOrderFront(nil); return }
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 610, height: 610), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Screenshot · 设置"; window.isReleasedWhenClosed = false; window.center()
        let title = NSTextField(labelWithString: "随时截图，内容留在本机。")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        let help = NSTextField(wrappingLabelWithString: "点击快捷键框，再按新的组合键。长截图时请框选可滚动正文，避开固定顶部栏、输入框和悬浮按钮；可连续向下滚动，无需逐次停顿；快速跳跃或内容重排可能无法接续。")
        let captureButtons = NSStackView(views: [NSButton(title: "区域截图", target: self, action: #selector(normalCapture)), NSButton(title: "滚动长截图", target: self, action: #selector(scrollCapture))])
        captureButtons.spacing = 12
        var views: [NSView] = [title, help, captureButtons]
        for (name, shortcut) in [("screenshot.region", normal), ("screenshot.scroll", scroll)] {
            let label = NSTextField(labelWithString: name == "screenshot.region" ? "区域截图" : "滚动长截图")
            let recorder = ShortcutRecorder(string: shortcut.label); recorder.isEditable = false; recorder.isSelectable = false
            recorder.widthAnchor.constraint(equalToConstant: 250).isActive = true
            recorder.onRecord = { [weak self, weak recorder] value in
                guard let self else { return }
                let other = name == "screenshot.region" ? self.scroll : self.normal
                guard value.key != other.key || value.modifiers != other.modifiers else { recorder?.stringValue = "与另一个工具冲突"; return }
                let ok = self.hotkeys.register(name, shortcut: value) { [weak self] in self?.capture(scrolling: name == "screenshot.scroll") }
                guard ok else { recorder?.stringValue = "设置失败，请重试"; self.hotkeyStatusLabel?.stringValue = self.hotkeys.lastError ?? "快捷键不可用"; return }
                UserDefaults.standard.set(try? JSONEncoder().encode(value), forKey: name)
                if name == "screenshot.region" { self.normal = value } else { self.scroll = value }
                self.hotkeyWarnings.removeAll(); self.refreshSettingsStatus()
                recorder?.stringValue = value.label; self.refreshMenu()
            }
            let row = NSStackView(views: [label, recorder]); row.spacing = 24; views.append(row)
        }
        let permissions = NSButton(title: "检查 / 申请屏幕录制权限…", target: self, action: #selector(permissionGuide))
        permissionButton = permissions
        let privacy = NSButton(title: "打开系统录屏设置", target: self, action: #selector(openPrivacy))
        let permissionActions = NSStackView(views: [permissions, privacy]); permissionActions.spacing = 12
        views.append(permissionActions)
        let status = NSTextField(wrappingLabelWithString: "")
        permissionStatusLabel = status
        status.textColor = .secondaryLabelColor; views.append(status)
        let hotkeyStatus = NSTextField(wrappingLabelWithString: "")
        hotkeyStatusLabel = hotkeyStatus; views.append(hotkeyStatus)
        let version = NSTextField(labelWithString: "版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版") · macOS 14+ · MIT © kirktools")
        version.textColor = .secondaryLabelColor
        let updates = NSButton(title: "检查更新…", target: self, action: #selector(checkForUpdates))
        let versionActions = NSStackView(views: [version, updates]); versionActions.spacing = 12; views.append(versionActions)
        let source = Bundle.main.object(forInfoDictionaryKey: "KirkBuildSource") as? String ?? "开发构建"
        let location = NSTextField(wrappingLabelWithString: "源码：\(source)\n当前应用：\(Bundle.main.bundlePath)")
        location.font = .systemFont(ofSize: 11); location.textColor = .secondaryLabelColor; views.append(location)
        let stack = NSStackView(views: views); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false; window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24), stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24), stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24), help.widthAnchor.constraint(equalTo: stack.widthAnchor), status.widthAnchor.constraint(equalTo: stack.widthAnchor), hotkeyStatus.widthAnchor.constraint(equalTo: stack.widthAnchor)])
        settings = window; refreshSettingsStatus(); NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
    }
    private func refreshSettingsStatus() {
        let authorized = permissionAccess.isAuthorized()
        permissionButton?.isEnabled = !permissionRequestPending && !authorized
        permissionButton?.title = permissionRequestPending ? "正在申请…" : (authorized ? "录屏权限已开启" : (hasRequestedPermission ? "重新检查权限" : "申请录屏权限"))
        if permissionRequestPending {
            permissionStatusLabel?.stringValue = "正在等待系统授权。只会发起一次请求，请处理 macOS 的提示。"
        } else if authorized {
            permissionStatusLabel?.stringValue = "屏幕录制权限已开启。可点击上方按钮验证截图。"
        } else if hasRequestedPermission {
            permissionStatusLabel?.stringValue = "系统尚未授予当前应用录屏权限。可点击右侧‘打开系统录屏设置’处理；此按钮只重新检查，不会打开系统设置。授权后退出并重新打开。"
        } else {
            permissionStatusLabel?.stringValue = "点击‘申请录屏权限’向系统发起一次授权请求；‘打开系统录屏设置’仅打开设置页面。若开关已开启仍不可用，请核对下方安装路径。"
        }
        hotkeyStatusLabel?.stringValue = hotkeyWarnings.isEmpty
            ? "当前快捷键：区域截图 \(normal.label) · 长截图 \(scroll.label)。关闭本窗口后仍常驻菜单栏。"
            : hotkeyWarnings.joined(separator: "\n")
    }
    func applicationDidBecomeActive(_ notification: Notification) { refreshSettingsStatus() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // 再次启动只复用菜单栏进程，不把设置当主窗口。
        return false
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main struct KirkScreenshotMain {
    @MainActor static func main() {
        if let index = CommandLine.arguments.firstIndex(of: "--apply-update") {
            guard CommandLine.arguments.count == index + 2 else { exit(1) }
            exit(UpdateInstaller.runHelper(manifest: CommandLine.arguments[index + 1]))
        }
        if CommandLine.arguments.contains("--permission-status") {
            print("Screen capture authorized: \(CGPreflightScreenCaptureAccess())"); return
        }
        if CommandLine.arguments.contains("--packaged-resources-test") {
            do { try AppLocalization.verifyPackagedResources(); print("PACKAGED RESOURCES PASSED") }
            catch { fputs("PACKAGED RESOURCES FAILED: \(error)\n", stderr); exit(1) }
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
