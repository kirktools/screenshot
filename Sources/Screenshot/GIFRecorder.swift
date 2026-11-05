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

@MainActor final class GIFRecorder: NSObject {
    private let provider: MacCaptureProvider
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
    var completion: ((Data?) -> Void)?
    init(provider: MacCaptureProvider, region: CGRect, hotkeys: HotkeyRegistry) {
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
    func show() throws {
        guard hotkeys.register("gif.cancel", shortcut: Shortcut(key: 53, modifiers: 0, label: "Esc"), action: { [weak self] in self?.cancelRecording() }) else { throw CaptureError.message("无法注册 GIF 取消快捷键") }
        guard hotkeys.register("gif.finish", shortcut: Shortcut(key: 36, modifiers: 0, label: "↩"), action: { [weak self] in self?.stopRecording() }) else { hotkeys.unregister("gif.cancel"); throw CaptureError.message("无法注册 GIF 完成快捷键") }
        displayObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancelRecording() }
        }
        boundary.show(); panel.orderFrontRegardless()
    }
    @objc private func startRecording() {
        guard !recording, !finished else { return }; recording = true; started = ProcessInfo.processInfo.systemUptime
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
                let source = try await provider.makeStream(region, frameRate: 10, maximumDimension: 1280); stream = source
                guard !finished else { await source.stop(); return }
                try await source.start()
                guard !finished else { await source.stop(); return }
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
            } catch { if !finished { cancelRecording(); showError(error) } }
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
        let source = stream; stream = nil; frames.removeAll()
        Task { await source?.stop(); completion?(nil) }
    }
    @objc private func stopRecording() {
        guard recording, !finished else { return }; finished = true
        let end = ProcessInfo.processInfo.systemUptime, captured = frames
        closeCapture(); frames.removeAll()
        status.stringValue = "正在编码 GIF，请稍候…"; panel.orderFrontRegardless()
        let source = stream; stream = nil
        Task {
            await source?.stop()
            defer { panel.orderOut(nil); panel.close() }
            do { let data = try await Task.detached { try GIFEncoding.encode(captured, end: end) }.value; completion?(data) }
            catch { completion?(nil); showError(error) }
        }
    }
}

@MainActor final class GIFPreview: NSWindowController, NSWindowDelegate {
    var closed: (() -> Void)?
    private let data: Data
    init(data: Data) {
        self.data = data
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 700, height: 540), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "GIF 预览"; window.isReleasedWhenClosed = false
        super.init(window: window); window.delegate = self
        let image = NSImageView(); image.image = NSImage(data: data); image.animates = true; image.imageScaling = .scaleProportionallyUpOrDown
        let save = NSButton(title: "保存 GIF…", target: self, action: #selector(saveGIF))
        let stack = NSStackView(views: [image, save]); stack.orientation = .vertical; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false; window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 16), stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -16), stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 16), stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -16), image.heightAnchor.constraint(greaterThanOrEqualToConstant: 100)])
        window.center()
    }
    required init?(coder: NSCoder) { fatalError() }
    func windowWillClose(_ notification: Notification) { closed?() }
    @objc private func saveGIF() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.gif]; panel.nameFieldStringValue = "Screenshot.gif"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try data.write(to: url, options: .atomic) } catch { showError(error) }
    }
}
