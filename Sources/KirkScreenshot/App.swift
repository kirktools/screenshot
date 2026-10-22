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
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
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
        if !UserDefaults.standard.bool(forKey: "hasOpened") {
            UserDefaults.standard.set(true, forKey: "hasOpened"); openSettings()
        }
    }
    private func load(_ key: String, fallback: Shortcut) -> Shortcut {
        guard let data = UserDefaults.standard.data(forKey: key), let value = try? JSONDecoder().decode(Shortcut.self, from: data) else { return fallback }; return value
    }
    private func registerTools() {
        if !hotkeys.register("screenshot.region", shortcut: normal, action: { [weak self] in self?.capture(scrolling: false) }) { hotkeyWarnings.append("区域截图快捷键被占用，请在设置中重新配置。") }
        if !hotkeys.register("screenshot.scroll", shortcut: scroll, action: { [weak self] in self?.capture(scrolling: true) }) { hotkeyWarnings.append("长截图快捷键被占用，请在设置中重新配置。") }
    }
    private func refreshMenu() {
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
                        let session = ScrollSession(provider: provider, region: rect, hotkeys: self.hotkeys)
                        self.session = session
                        session.completion = { [weak self] image in
                            self?.session = nil; self?.provider = nil; self?.busy = false
                            if let image { self?.present(image) }
                        }
                        guard session.start() else { self.session = nil; throw CaptureError.message("无法注册回车/Esc 会话快捷键，请关闭占用这些按键的工具后重试。") }
                    } else {
                        let image = try await provider.capture(rect)
                        self.busy = false; self.provider = nil; self.present(image)
                    }
                } catch { self.busy = false; self.provider = nil; showError(CaptureError.message("\(error.localizedDescription)\n若刚授予屏幕录制权限，请退出应用后重新打开。")) }
            }
        }
        selector.begin()
    }
    private func present(_ image: CGImage) {
        editor?.close(); editor = EditorController(image: image); showEditor(); refreshMenu()
    }
    @objc private func showEditor() { NSApp.activate(ignoringOtherApps: true); editor?.showWindow(nil) }
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
    @objc private func openSettings() {
        if let settings { NSApp.activate(ignoringOtherApps: true); settings.makeKeyAndOrderFront(nil); return }
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 570, height: 510), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Kirk Screenshot · 设置"; window.isReleasedWhenClosed = false; window.center()
        let title = NSTextField(labelWithString: "随时截图，内容留在本机。")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        let help = NSTextField(wrappingLabelWithString: "点击快捷键框，再按新的组合键。长截图时请框选可滚动正文，避开固定顶部栏、输入框和悬浮按钮；每次缓慢向下滚动半屏并停顿。")
        var views: [NSView] = [title, help]
        for (name, shortcut) in [("screenshot.region", normal), ("screenshot.scroll", scroll)] {
            let label = NSTextField(labelWithString: name == "screenshot.region" ? "区域截图" : "滚动长截图")
            let recorder = ShortcutRecorder(string: shortcut.label); recorder.isEditable = false; recorder.isSelectable = false
            recorder.widthAnchor.constraint(equalToConstant: 250).isActive = true
            recorder.onRecord = { [weak self, weak recorder] value in
                guard let self else { return }
                let other = name == "screenshot.region" ? self.scroll : self.normal
                guard value.key != other.key || value.modifiers != other.modifiers else { recorder?.stringValue = "与另一个工具冲突"; return }
                let ok = self.hotkeys.register(name, shortcut: value) { [weak self] in self?.capture(scrolling: name == "screenshot.scroll") }
                guard ok else { recorder?.stringValue = "快捷键已被占用，请重试"; return }
                UserDefaults.standard.set(try? JSONEncoder().encode(value), forKey: name)
                if name == "screenshot.region" { self.normal = value } else { self.scroll = value }
                recorder?.stringValue = value.label; self.refreshMenu()
            }
            let row = NSStackView(views: [label, recorder]); row.spacing = 24; views.append(row)
        }
        let permissions = NSButton(title: "检查 / 申请屏幕录制权限…", target: self, action: #selector(permissionGuide)); views.append(permissions)
        let status = NSTextField(wrappingLabelWithString: CGPreflightScreenCaptureAccess() ? "屏幕录制权限已开启。若捕获失败，请重新启动应用。" : "尚未授予屏幕录制权限。首次截图前请授权。")
        status.textColor = .secondaryLabelColor; views.append(status)
        if !hotkeyWarnings.isEmpty { views.append(NSTextField(wrappingLabelWithString: hotkeyWarnings.joined(separator: "\n"))) }
        let version = NSTextField(labelWithString: "版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版") · macOS 14+ · MIT © kirktools")
        version.textColor = .secondaryLabelColor; views.append(version)
        let stack = NSStackView(views: views); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false; window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24), stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24), stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24), help.widthAnchor.constraint(equalTo: stack.widthAnchor), status.widthAnchor.constraint(equalTo: stack.widthAnchor)])
        settings = window; NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
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
