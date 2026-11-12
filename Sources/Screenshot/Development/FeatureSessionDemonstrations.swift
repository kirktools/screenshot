import AppKit
import StitchCore
import ImageIO

@MainActor final class FeatureFixtureStream: RegionFrameStream {
    let frames: AsyncThrowingStream<CapturedFrame, Error>
    private let continuation: AsyncThrowingStream<CapturedFrame, Error>.Continuation
    private var paused = false
    private(set) var stopped = false
    init() {
        let pair = AsyncThrowingStream<CapturedFrame, Error>.makeStream(bufferingPolicy: .bufferingNewest(2))
        frames = pair.stream; continuation = pair.continuation
    }
    func start() async throws {}
    func setPaused(_ paused: Bool) { self.paused = paused }
    func stop() async { stopped = true; continuation.finish() }
    func send(_ image: CGImage) {
        guard !paused, !stopped else { return }
        continuation.yield(CapturedFrame(image: image, time: ProcessInfo.processInfo.systemUptime))
    }
}
@MainActor final class FeatureFixtureProvider: RegionCaptureProvider {
    let source = FeatureFixtureStream()
    func prepare() async throws {}
    func capture(_ region: CGRect) async throws -> CGImage { throw CaptureError.message("合成测试不读取桌面") }
    func makeStream(_ region: CGRect) async throws -> any RegionFrameStream { source }
}

/// 给公开演示提供固定栏与 GIF 的真实会话输出，输入全部来自合成文档。
@MainActor func writeFeatureSessionDemonstrations(document: CGImage, to directory: URL) async throws {
    func wait(_ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime+6
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw CaptureError.message("功能演示会话等待超时") }
            try await Task.sleep(for: .milliseconds(15))
        }
    }
    let width = document.width, height = 600
    func viewport(_ offset: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.translateBy(x: 0, y: CGFloat(height)); ctx.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        document.cropping(to: CGRect(x: 0, y: offset, width: width, height: height))!.nsImage.draw(in: CGRect(x: 0, y: 0, width: width, height: height), from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        NSColor(srgbRed: 0.08, green: 0.28, blue: 0.25, alpha: 1).setFill(); CGRect(x: 0, y: 0, width: width, height: 64).fill()
        ("灵感手册  /  项目笔记                         固定导航栏" as NSString).draw(at: CGPoint(x: 32, y: 19), withAttributes: [.font: NSFont.systemFont(ofSize: 23, weight: .semibold), .foregroundColor: NSColor.white])
        NSColor(srgbRed: 0.15, green: 0.33, blue: 0.30, alpha: 1).setFill(); NSBezierPath(roundedRect: CGRect(x: 170, y: 532, width: 660, height: 64), xRadius: 16, yRadius: 16).fill()
        ("＋   补充一条想法……                         ↩" as NSString).draw(at: CGPoint(x: 204, y: 551), withAttributes: [.font: NSFont.systemFont(ofSize: 23), .foregroundColor: NSColor.white])
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()!
    }
    let screen = NSScreen.main!.frame
    let region = CGRect(x: screen.minX+20, y: screen.minY+20, width: min(500, screen.width-40), height: min(300, screen.height-40))
    let provider = FeatureFixtureProvider(), board = NSPasteboard(name: .init("Screenshot-Feature-Demo-"+UUID().uuidString))
    defer { board.releaseGlobally() }
    let session = ScrollSession(provider: provider, region: region, hotkeys: HotkeyRegistry(), clipboard: board)
    defer { session.cancelCapture() }
    var result: CGImage?
    session.completion = { image, _ in result = image }
    _ = session.start(registerHotkeys: false, showPanel: false)
    try await Task.sleep(for: .milliseconds(40))
    for i in 0..<featureDemoFrameCount {
        let before = session.diagnosticSnapshot.count, input = viewport(i * (featureDemoFrameCount == 24 ? 10 : 5))
        provider.source.send(input)
        try await wait { session.diagnosticSnapshot.count > before }
        try input.png().write(to: directory.appendingPathComponent(String(format: "viewport-%02d.png", i)))
        if featureDemoFrameCount > 24 { try await Task.sleep(for: .milliseconds(170)) }
        guard let view = session.diagnosticControls.first else { throw CaptureError.message("长图演示预览缺失") }
        try featureSnapshot(view, to: directory.appendingPathComponent(String(format: "scroll-%02d.png", i)))
    }
    session.finishCapture(); try await wait { result != nil }
    guard result!.height == height+(featureDemoFrameCount-1)*(featureDemoFrameCount == 24 ? 10 : 5) else { throw CaptureError.message("固定栏演示接缝高度异常：\(result!.height)，预期 \(height+(featureDemoFrameCount-1)*(featureDemoFrameCount == 24 ? 10 : 5))") }
    try result!.png().write(to: directory.appendingPathComponent("fixed-result.png"))
    let gifProvider = FeatureFixtureProvider(), recorder = GIFRecorder(provider: gifProvider, region: region, hotkeys: HotkeyRegistry())
    var gif: Data?
    recorder.completion = { gif = $0 }
    try recorder.show(registerHotkeys: false, showPanel: false)
    func button(_ title: String) -> NSButton? {
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        return all(recorder.documentationView).compactMap { $0 as? NSButton }.first { $0.title == title }
    }
    guard let start = button("开始录制"), let stop = button("停止并预览 ↩"), let cancel = button("取消 Esc") else { throw CaptureError.message("GIF 演示按钮缺失") }
    defer { cancel.performClick(nil) }
    start.performClick(nil); try await Task.sleep(for: .milliseconds(40))
    for i in 0..<featureDemoFrameCount {
        let frame = viewport(Int(Double(i)/Double(featureDemoFrameCount-1)*184))
        gifProvider.source.send(frame)
        try await Task.sleep(for: .milliseconds(featureDemoFrameCount == 24 ? 120 : 34))
        try featureSnapshot(recorder.documentationView, to: directory.appendingPathComponent(String(format: "gif-controls-%02d.png", i)))
        try frame.png().write(to: directory.appendingPathComponent(String(format: "gif-input-%02d.png", i)))
    }
    stop.performClick(nil); try await wait { gif != nil }
    guard let source = CGImageSourceCreateWithData(gif! as CFData, nil), CGImageSourceGetCount(source) >= 12 else { throw CaptureError.message("GIF 演示未录入连续帧") }
    try gif!.write(to: directory.appendingPathComponent("recorded-sample.gif"))
    let preview = GIFPreview(data: gif!); preview.showWindow(nil); defer { preview.close() }
    try featureSnapshot(preview.window!.contentView!, to: directory.appendingPathComponent("gif-preview.png"))
}
