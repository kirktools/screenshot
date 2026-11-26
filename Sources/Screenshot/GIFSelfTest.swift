import AppKit
import ImageIO
import UniformTypeIdentifiers

@MainActor func runGIFEncodingSelfTest() throws {
    func require(_ value: Bool, _ message: String) throws { if !value { throw CaptureError.message(message) } }
    let ctx = CGContext(data: nil, width: 1600, height: 400, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(NSColor.red.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: 1600, height: 400))
    let first = try GIFEncoding.frame(ctx.makeImage()!, time: 10)
    ctx.setFillColor(NSColor.blue.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: 1600, height: 400))
    let second = try GIFEncoding.frame(ctx.makeImage()!, time: 10.4)
    let data = try GIFEncoding.encode([first, second], end: 11)
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { throw CaptureError.message("GIF 无法解码") }
    try require(CGImageSourceGetCount(source) == 2, "GIF 帧数错误")
    let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
    try require(image.width == 1280 && image.height == 320, "GIF 缩放错误")
    for (index, delay) in [0.4, 0.6].enumerated() {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil)! as NSDictionary
        let gif = properties[kCGImagePropertyGIFDictionary] as! NSDictionary
        let actual = gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double ?? gif[kCGImagePropertyGIFDelayTime] as! Double
        try require(abs(actual - delay) < 0.02, "GIF 静态停留时序错误")
    }
    let staticData = try GIFEncoding.encode([first], end: 12)
    try require(CGImageSourceGetCount(CGImageSourceCreateWithData(staticData as CFData, nil)!) == 1, "静态录制导出失败")
    try verifyGIFPreview(data)
    do { _ = try GIFEncoding.encode([], end: 1); throw CaptureError.message("空 GIF 应拒绝") }
    catch let error as CaptureError { if error.localizedDescription == "空 GIF 应拒绝" { throw error } }
}

/// 用竖向画面验证缩窗后操作仍可达，并核对复制、保存保留全部帧。
@MainActor private func verifyGIFPreview(_ data: Data) throws {
    let clipboard = NSPasteboard(name: .init("Screenshot-GIF-Test-" + UUID().uuidString))
    defer { clipboard.releaseGlobally() }
    let ctx = CGContext(data: nil, width: 320, height: 1280, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let frame = try GIFEncoding.frame(ctx.makeImage()!, time: 0)
    let tall = GIFPreview(data: try GIFEncoding.encode([frame], end: 1), clipboard: clipboard)
    defer { tall.close() }
    guard let window = tall.window, let content = window.contentView,
          let actions = content.subviews.compactMap({ $0 as? NSStackView }).first,
          let image = content.subviews.compactMap({ $0 as? NSImageView }).first
    else { throw CaptureError.message("GIF 预览缺少图片或操作区") }

    for size in [NSSize(width: 700, height: 540), NSSize(width: 360, height: 260)] {
        window.setContentSize(size)
        content.layoutSubtreeIfNeeded()
        guard content.bounds.size == size, content.bounds.contains(actions.frame),
              content.bounds.contains(image.frame), !image.frame.intersects(actions.frame)
        else { throw CaptureError.message("竖向 GIF 撑大了窗口，或遮住了底部操作区") }
    }

    let motion = GIFPreview(data: data, clipboard: clipboard)
    defer { motion.close() }
    guard let copy = motion.window?.contentView?.subviews.compactMap({ $0 as? NSStackView }).first?
        .arrangedSubviews.compactMap({ $0 as? NSButton }).first(where: { $0.keyEquivalent == "c" })
    else { throw CaptureError.message("GIF 预览缺少复制按钮") }
    copy.performClick(nil)
    guard clipboard.data(forType: .init(UTType.gif.identifier)) == data
    else { throw CaptureError.message("剪贴板没有保留原始动图") }

    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".gif")
    defer { try? FileManager.default.removeItem(at: url) }
    try motion.exportGIF(to: url)
    guard try Data(contentsOf: url) == data else { throw CaptureError.message("GIF 保存内容发生变化") }
    print("GIF 预览：竖图缩窗、底部操作区、动图剪贴板和文件保存通过")
}
