import AppKit
import Carbon

func localized(_ key: String) -> String { NSLocalizedString(key, bundle: .module, comment: "") }

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var item: NSStatusItem!
    let hotkeys = HotkeyRegistry()
    private var selector: RegionSelector?
    private var session: ScrollSession?
    private var provider: MacCaptureProvider?
    private var editor: EditorController?
    private var settings: NSWindow?
    private var busy = false
    private var normal = Shortcut.normal
    private var scroll = Shortcut.scroll
    private var previousApp: NSRunningApplication?
    private var lastExternalApp: NSRunningApplication?
    private var activationObserver: NSObjectProtocol?
    private var hotkeyWarnings: [String] = []
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
            do { try runStartupSmokeTest(self); print("STARTUP SMOKE PASSED"); NSApp.terminate(nil) }
            catch { fputs("STARTUP SMOKE FAILED: \(error)\n", stderr); exit(1) }
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
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "Kirk Screenshot")
        buildMainMenu(); registerTools(); refreshMenu()
        if CommandLine.arguments.contains("--demo-editor") { present(makeDemoImage()); return }
        // 手动启动和权限重启后给出可见状态，避免菜单栏应用看起来没有启动。
        openSettings()
    }
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
        let title = NSMenuItem(title: "Kirk Screenshot", action: nil, keyEquivalent: ""); menu.addItem(title)
        menu.addItem(.separator())
        add(menu, "\(localized("capture.normal"))   \(normal.label)", #selector(normalCapture))
        add(menu, "\(localized("capture.scroll"))   \(scroll.label)", #selector(scrollCapture))
        if editor != nil { add(menu, "打开上次预览", #selector(showEditor)) }
        menu.addItem(.separator()); add(menu, localized("settings"), #selector(openSettings))
        add(menu, localized("quit"), #selector(quit)); item.menu = menu
    }
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector) { let i = NSMenuItem(title: title, action: action, keyEquivalent: ""); i.target = self; menu.addItem(i) }
    private func buildMainMenu() {
        let menu = NSMenu(), app = NSMenu(), edit = NSMenu()
        let appItem = NSMenuItem(); appItem.submenu = app; menu.addItem(appItem)
        let quit = NSMenuItem(title: "退出 Kirk Screenshot", action: #selector(quit), keyEquivalent: "q"); quit.target = self; app.addItem(quit)
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
        guard !busy else { return }
        guard CGPreflightScreenCaptureAccess() else { permissionGuide(); return }
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
    @objc private func showEditor() { busy = true; NSApp.activate(ignoringOtherApps: true); editor?.showWindow(nil) }
    @objc private func quit() { session?.cancelCapture(); NSApp.terminate(nil) }
    @objc private func permissionGuide() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert(); alert.messageText = "允许屏幕录制"
        alert.informativeText = "Kirk Screenshot 需要读取你选定区域的屏幕像素，用于截图和本机拼接。不会录音、上传，也不需要辅助功能权限。\n首次点击申请后按系统提示授权；若此前拒绝，请打开系统设置。重新授权后可能需要退出再启动应用。"
        alert.addButton(withTitle: "申请权限"); alert.addButton(withTitle: "打开系统设置"); alert.addButton(withTitle: "稍后")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if !CGRequestScreenCaptureAccess() { openPrivacy() }
        case .alertSecondButtonReturn: openPrivacy()
        default: break
        }
    }
    private func openPrivacy() { if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) } }
    @objc func openSettings() {
        if let settings { refreshSettingsStatus(); NSApp.activate(ignoringOtherApps: true); settings.makeKeyAndOrderFront(nil); return }
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 610, height: 610), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Kirk Screenshot · 设置"; window.isReleasedWhenClosed = false; window.center()
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
        let permissions = NSButton(title: "检查 / 申请屏幕录制权限…", target: self, action: #selector(permissionGuide)); views.append(permissions)
        let status = NSTextField(wrappingLabelWithString: "")
        permissionStatusLabel = status
        status.textColor = .secondaryLabelColor; views.append(status)
        let hotkeyStatus = NSTextField(wrappingLabelWithString: "")
        hotkeyStatusLabel = hotkeyStatus; views.append(hotkeyStatus)
        let version = NSTextField(labelWithString: "版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版") · macOS 14+ · MIT © kirktools")
        version.textColor = .secondaryLabelColor; views.append(version)
        let stack = NSStackView(views: views); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false; window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24), stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24), stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24), help.widthAnchor.constraint(equalTo: stack.widthAnchor), status.widthAnchor.constraint(equalTo: stack.widthAnchor), hotkeyStatus.widthAnchor.constraint(equalTo: stack.widthAnchor)])
        settings = window; refreshSettingsStatus(); NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
    }
    private func refreshSettingsStatus() {
        permissionStatusLabel?.stringValue = CGPreflightScreenCaptureAccess()
            ? "屏幕录制权限已开启。可点击上方按钮验证截图。"
            : "尚未获得屏幕录制权限。请授权后退出并重新打开此应用；重新打开时会显示本窗口。"
        hotkeyStatusLabel?.stringValue = hotkeyWarnings.isEmpty
            ? "当前快捷键：区域截图 \(normal.label) · 长截图 \(scroll.label)。关闭本窗口后仍常驻菜单栏。"
            : hotkeyWarnings.joined(separator: "\n")
    }
    func applicationDidBecomeActive(_ notification: Notification) { refreshSettingsStatus() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !busy { openSettings() }
        return false
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main struct KirkScreenshotMain {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--permission-status") {
            print("Screen capture authorized: \(CGPreflightScreenCaptureAccess())"); return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
