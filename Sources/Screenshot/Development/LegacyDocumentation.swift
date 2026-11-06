import AppKit
import ImageIO
import UniformTypeIdentifiers

@MainActor func makeDemoImage() -> CGImage {
    let image = NSImage(size: NSSize(width: 1000, height: 1400))
    image.lockFocusFlipped(true)
    NSColor.white.setFill(); CGRect(x: 0, y: 0, width: 1000, height: 1400).fill()
    ("Screenshot" as NSString).draw(at: CGPoint(x: 60, y: 55), withAttributes: [.font: NSFont.systemFont(ofSize: 40, weight: .bold), .foregroundColor: NSColor.black])
    ("本机截图 · 手动滚动 · 自动拼接" as NSString).draw(at: CGPoint(x: 60, y: 125), withAttributes: [.font: NSFont.systemFont(ofSize: 26), .foregroundColor: NSColor.darkGray])
    let sections = [
        ("随时唤起", "菜单栏常驻。框选区域，立刻开始截图。"),
        ("轻量标注", "箭头、形状、文字、裁剪和打码，直接在原位完成。"),
        ("连续长截图", "像平时一样向下滚动，自动捕获并拼接。"),
        ("复制就走", "回车直接复制，需要时再进入编辑。"),
        ("内容留在本机", "无需注册，不上传截图，也不依赖微信。")
    ]
    for (index, section) in sections.enumerated() {
        let y = 230 + index * 180
        (section.0 as NSString).draw(at: CGPoint(x: 60, y: y), withAttributes: [.font: NSFont.systemFont(ofSize: 28, weight: .semibold), .foregroundColor: NSColor.black])
        (section.1 as NSString).draw(at: CGPoint(x: 60, y: y + 56), withAttributes: [.font: NSFont.systemFont(ofSize: 23), .foregroundColor: NSColor.darkGray])
    }
    image.unlockFocus()
    return image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
}

@MainActor func writeDocumentationEditor(_ editor: EditorController, to url: URL) throws {
    guard let content = editor.window?.contentView, let toolbar = editor.diagnosticToolbarViews.first else { throw CaptureError.message("编辑界面尚未就绪") }
    let factor = CGFloat(editor.canvas.state.image.width) / 1000
    editor.canvas.apply(Annotation(tool: .rectangle, start: CGPoint(x: 42 * factor, y: 205 * factor), end: CGPoint(x: 945 * factor, y: 345 * factor), color: .blue, lineWidth: 5 * factor))
    editor.canvas.apply(Annotation(tool: .arrow, start: CGPoint(x: 805 * factor, y: 420 * factor), end: CGPoint(x: 655 * factor, y: 350 * factor), color: .blue, lineWidth: 5 * factor))
    let geometry = editor.diagnosticGeometry
    let extent = geometry.image.union(geometry.toolbar).insetBy(dx: -24, dy: -24)
    let scale = 2.0
    let ctx = CGContext(data: nil, width: Int(extent.width * scale), height: Int(extent.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(gray: 0.12, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
    for (view, frame) in [(content, geometry.image), (toolbar, geometry.toolbar)] {
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CaptureError.message("无法捕获原生控件") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let image = bitmap.cgImage else { throw CaptureError.message("无法读取控件图像") }
        ctx.draw(image, in: CGRect(x: (frame.minX - extent.minX) * scale, y: (frame.minY - extent.minY) * scale, width: frame.width * scale, height: frame.height * scale))
    }
    try ctx.makeImage()!.png().write(to: url, options: .atomic)
}

@MainActor func writeDocumentationScroll(to directory: URL) async throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let document = makeDemoImage(), height = min(600, document.height), end = min(900, document.height - height)
    let provider = FeatureFixtureProvider(), board = NSPasteboard(name: .init("Screenshot-Documentation-" + UUID().uuidString))
    defer { board.releaseGlobally() }
    let session = ScrollSession(provider: provider, region: CGRect(x: 0, y: 0, width: document.width, height: height), hotkeys: HotkeyRegistry(), clipboard: board)
    defer { session.cancelCapture() }
    var done = false, output: CGImage?, frames: [CGImage] = []
    session.completion = { image, _ in output = image; done = true }
    guard session.start(registerHotkeys: false, showPanel: false) else { throw CaptureError.message("文档演示无法启动") }
    try await Task.sleep(for: .milliseconds(50))
    func wait(_ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw CaptureError.message("文档演示等待超时") }
            try await Task.sleep(for: .milliseconds(15))
        }
    }
    for offset in stride(from: 0, through: end, by: 30) {
        let before = session.diagnosticSnapshot.count
        provider.source.send(document.cropping(to: CGRect(x: 0, y: offset, width: document.width, height: height))!)
        try await wait { session.diagnosticSnapshot.count > before }
        try await Task.sleep(for: .milliseconds(160))
        if let view = session.diagnosticControls.first, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            if let frame = bitmap.cgImage { frames.append(frame) }
        }
    }
    session.finishCapture(); try await wait { done }
    guard let output, output.height == height + end, let last = frames.last else { throw CaptureError.message("文档演示输出不完整") }
    let expected = document.cropping(to: CGRect(x: 0, y: 0, width: document.width, height: height + end))!
    func rgba(_ image: CGImage) -> Data {
        let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: ctx.data!, count: image.width * image.height * 4)
    }
    guard rgba(output) == rgba(expected) else { throw CaptureError.message("文档演示与生成参考不一致，未导出") }
    try output.png().write(to: directory.appendingPathComponent("scroll-result.png"), options: .atomic)
    try last.png().write(to: directory.appendingPathComponent("scroll-preview.png"), options: .atomic)
    guard let gif = CGImageDestinationCreateWithURL(directory.appendingPathComponent("scrolling.gif") as CFURL, UTType.gif.identifier as CFString, frames.count, nil) else { throw CaptureError.message("无法创建文档 GIF") }
    CGImageDestinationSetProperties(gif, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
    for (i, frame) in frames.enumerated() {
        CGImageDestinationAddImage(gif, frame, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: i == frames.count - 1 ? 1.5 : 0.15]] as CFDictionary)
    }
    guard CGImageDestinationFinalize(gif) else { throw CaptureError.message("文档 GIF 写入失败") }
    print("离线文档素材通过：原生控件、合成滚动帧及逐像素结果验证；未读取桌面。")
}

