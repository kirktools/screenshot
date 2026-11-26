import AppKit
import ImageIO
import UniformTypeIdentifiers

struct GIFFrame: @unchecked Sendable {
    let data: Data
    let time: Double
}

enum GIFEncoding {
    static func frame(_ image: CGImage, time: Double) throws -> GIFFrame {
        let scale = min(1, 1280 / CGFloat(max(image.width, image.height)))
        let w = max(1, Int(CGFloat(image.width) * scale)), h = max(1, Int(CGFloat(image.height) * scale))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CaptureError.message("GIF 帧内存不足") }
        ctx.interpolationQuality = .high; ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let result = ctx.makeImage() else { throw CaptureError.message("无法缩放 GIF 帧") }
        return GIFFrame(data: try result.png(), time: time)
    }
    static func encode(_ frames: [GIFFrame], end: Double) throws -> Data {
        guard !frames.isEmpty else { throw CaptureError.message("没有录制到画面，请重试") }
        let result = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(result, UTType.gif.identifier as CFString, frames.count, nil) else { throw CaptureError.message("无法创建 GIF") }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for (index, frame) in frames.enumerated() {
            guard let source = CGImageSourceCreateWithData(frame.data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw CaptureError.message("GIF 帧损坏") }
            let next = index + 1 < frames.count ? frames[index + 1].time : end
            let delay = max(0.1, next - frame.time)
            CGImageDestinationAddImage(dest, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay, kCGImagePropertyGIFUnclampedDelayTime: delay]] as CFDictionary)
        }
        guard CGImageDestinationFinalize(dest) else { throw CaptureError.message("GIF 编码失败") }
        return result as Data
    }
}

#if SCREENSHOT_DOCUMENTATION_DEMO
typealias GIFCaptureProvider = any RegionCaptureProvider
#else
typealias GIFCaptureProvider = MacCaptureProvider
#endif

@MainActor final class GIFRecorder: NSObject {
    private let provider: GIFCaptureProvider
    private let region: CGRect
    private let hotkeys: HotkeyRegistry
    private let panel: PassivePanel
    private let boundary: CaptureBoundary
    private let status = NSTextField(labelWithString: "准备录制 · 最长 60 秒 · 最长边 1280 px")
    private var stream: (any RegionFrameStream)?
    private var task: Task<Void, Never>?
    private var timer: Timer?
    private var displayObserver: NSObjectProtocol?
    private var recording = false
    private var finished = false
    private var frames: [GIFFrame] = []
    private var bytes = 0
    private var started: Double = 0
    private var timing: CaptureTiming?
    var completion: ((Data?) -> Void)?
    init(provider: GIFCaptureProvider, region: CGRect, hotkeys: HotkeyRegistry) {
        self.provider = provider; self.region = region; self.hotkeys = hotkeys
        boundary = CaptureBoundary(region: region)
        panel = PassivePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.isReleasedWhenClosed = false; panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.hidesOnDeactivate = false; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let start = NSButton(title: "开始录制", target: self, action: #selector(startRecording))
        let stop = NSButton(title: "停止并预览 ↩", target: self, action: #selector(stopRecording))
        let cancel = NSButton(title: "取消 Esc", target: self, action: #selector(cancelRecording))
        let buttons = NSStackView(views: [start, stop, cancel]); buttons.spacing = 8
        let rows = NSStackView(views: [status, buttons]); rows.orientation = .vertical; rows.alignment = .leading; rows.spacing = 8
        panel.contentView = captureToolbar(views: [rows])
        let screen = NSScreen.screens.first { $0.frame.contains(region) }!
        panel.setFrame(CaptureLayout.toolbar(near: region, size: panel.contentView!.fittingSize, within: screen.visibleFrame), display: false)
    }
    #if SCREENSHOT_DOCUMENTATION_DEMO
    private var documentationHotkeys = true
    private var documentationPanel = true
    var documentationView: NSView { panel.contentView! }
    func show(registerHotkeys: Bool, showPanel: Bool) throws {
        documentationHotkeys = registerHotkeys; documentationPanel = showPanel
        try show()
    }
    #endif
    private func registerControls() throws {
        guard hotkeys.register("gif.cancel", shortcut: Shortcut(key: 53, modifiers: 0, label: "Esc"), action: { [weak self] in self?.cancelRecording() }) else { throw CaptureError.message("无法注册 GIF 取消快捷键") }
        guard hotkeys.register("gif.finish", shortcut: Shortcut(key: 36, modifiers: 0, label: "↩"), action: { [weak self] in self?.stopRecording() }) else { hotkeys.unregister("gif.cancel"); throw CaptureError.message("无法注册 GIF 完成快捷键") }
    }
    func show() throws {
        #if SCREENSHOT_DOCUMENTATION_DEMO
        if documentationHotkeys { try registerControls() }
        #else
        try registerControls()
        #endif
        displayObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancelRecording() }
        }
        #if SCREENSHOT_DOCUMENTATION_DEMO
        if documentationPanel { boundary.show(); panel.orderFrontRegardless() }
        #else
        boundary.show(); panel.orderFrontRegardless()
        #endif
    }
    @objc private func startRecording() {
        guard !recording, !finished else { return }; recording = true; started = ProcessInfo.processInfo.systemUptime
        timing = CaptureTiming(source: "capture.gif")
        status.stringValue = "正在准备采集…"
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.recording else { return }
                let duration = ProcessInfo.processInfo.systemUptime - self.started
                self.status.stringValue = "● 录制中 \(Int(duration)) 秒 · \(self.frames.count) 帧"
                if duration >= 60 { self.stopRecording() }
            }
        }
        task = Task {
            do {
                #if SCREENSHOT_DOCUMENTATION_DEMO
                let source: any RegionFrameStream
                if let mac = provider as? MacCaptureProvider { source = try await mac.makeStream(region, frameRate: 10, maximumDimension: 1280) }
                else { source = try await provider.makeStream(region) }
                #else
                let source = try await provider.makeStream(region, frameRate: 10, maximumDimension: 1280)
                #endif
                stream = source
                guard !finished else { await source.stop(); return }
                try await source.start()
                guard !finished else { await source.stop(); return }
                timing?.mark("stream.ready")
                var last = -Double.infinity
                for try await frame in source.frames {
                    guard !finished, !Task.isCancelled else { break }
                    guard frame.time - last >= 0.1 else { continue }
                    let encoded = try await Task.detached { try GIFEncoding.frame(frame.image, time: frame.time) }.value
                    guard !finished else { break }
                    if bytes + encoded.data.count > 96_000_000 || frames.count >= 600 { stopRecording(); break }
                    frames.append(encoded); bytes += encoded.data.count; last = frame.time
                }
                await source.stop()
            } catch {
                if !finished {
                    timing?.finish("failed", error: "capture_failed")
                    cancelRecording(); showError(error)
                }
            }
        }
    }
    private func closeCapture() {
        if let displayObserver { NotificationCenter.default.removeObserver(displayObserver); self.displayObserver = nil }
        timer?.invalidate(); timer = nil; task?.cancel()
        hotkeys.unregister("gif.cancel"); hotkeys.unregister("gif.finish")
        boundary.close(); panel.orderOut(nil); panel.close()
    }
    @objc private func cancelRecording() {
        guard !finished else { return }; finished = true; closeCapture()
        timing?.finish("cancelled")
        let source = stream; stream = nil; frames.removeAll()
        Task { await source?.stop(); completion?(nil) }
    }
    @objc private func stopRecording() {
        guard recording, !finished else { return }; finished = true
        let end = ProcessInfo.processInfo.systemUptime, captured = frames
        closeCapture(); frames.removeAll()
        timing?.mark("encode.begin")
        status.stringValue = "正在编码 GIF，请稍候…"; panel.orderFrontRegardless()
        let source = stream; stream = nil
        Task {
            await source?.stop()
            defer { panel.orderOut(nil); panel.close() }
            do {
                let data = try await Task.detached { try GIFEncoding.encode(captured, end: end) }.value
                timing?.finish("success")
                completion?(data)
            } catch {
                timing?.finish("failed", error: "encoding_failed")
                completion?(nil); showError(error)
            }
        }
    }
}

@MainActor final class GIFPreview: NSWindowController, NSWindowDelegate {
    var closed: (() -> Void)?
    private let data: Data
    private let clipboard: NSPasteboard
    private let feedback = NSTextField(labelWithString: "")

    init(data: Data, clipboard: NSPasteboard = .general) {
        self.data = data
        self.clipboard = clipboard
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let available = screen?.visibleFrame.size ?? CGSize(width: 700, height: 540)
        let size = CGSize(width: min(700, available.width * 0.9), height: min(540, available.height * 0.9))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "GIF 预览"
        window.isReleasedWhenClosed = false
        window.contentMinSize = CGSize(width: 320, height: 220)
        super.init(window: window)
        window.delegate = self

        let image = NSImageView()
        image.image = NSImage(data: data)
        image.animates = true
        image.imageScaling = .scaleProportionallyUpOrDown
        for orientation in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            image.setContentHuggingPriority(.defaultLow, for: orientation)
            image.setContentCompressionResistancePriority(.defaultLow, for: orientation)
        }

        let copy = NSButton(title: "复制 GIF", target: self, action: #selector(copy(_:)))
        copy.keyEquivalent = "c"
        copy.keyEquivalentModifierMask = .command
        let save = NSButton(title: "保存 GIF…", target: self, action: #selector(saveDocument(_:)))
        save.keyEquivalent = "s"
        save.keyEquivalentModifierMask = .command
        let actions = NSStackView(views: [copy, save])
        actions.spacing = 10
        feedback.textColor = .secondaryLabelColor

        let content = window.contentView!
        for view in [image, actions, feedback] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            image.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            image.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            image.bottomAnchor.constraint(equalTo: actions.topAnchor, constant: -12),
            actions.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            actions.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            feedback.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            feedback.trailingAnchor.constraint(lessThanOrEqualTo: actions.leadingAnchor, constant: -8),
            feedback.centerYAnchor.constraint(equalTo: actions.centerYAnchor)
        ])
        if let screen {
            let visible = screen.visibleFrame
            window.setFrameOrigin(CGPoint(x: visible.midX - window.frame.width / 2, y: visible.midY - window.frame.height / 2))
        } else {
            window.center()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func windowWillClose(_ notification: Notification) { closed?() }

    @objc private func copy(_ sender: Any?) {
        let item = NSPasteboardItem()
        let type = NSPasteboard.PasteboardType(UTType.gif.identifier)
        guard item.setData(data, forType: type) else {
            feedback.stringValue = "无法复制 GIF"
            return
        }
        clipboard.clearContents()
        feedback.stringValue = clipboard.writeObjects([item]) ? "已复制 GIF" : "无法复制 GIF"
    }

    @objc private func saveDocument(_ sender: Any?) {
        guard let window, window.attachedSheet == nil else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.gif]
        panel.nameFieldStringValue = "Screenshot.gif"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do {
                try self.exportGIF(to: url)
                self.feedback.stringValue = "已保存 GIF"
            } catch { showError(error) }
        }
    }

    func exportGIF(to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }
}
