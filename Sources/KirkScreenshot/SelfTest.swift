import AppKit
import StitchCore

/// 不读取桌面、不申请权限：验证平台渲染、拼接方向和实际导出像素。
@MainActor func runSelfTest() throws {
    func require(_ condition: Bool, _ message: String) throws { if !condition { throw CaptureError.message(message) } }
    let width = 160, height = 400
    var pixels = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height { for x in 0..<width {
        let i = (y * width + x) * 4
        var value = UInt64(y * width + x + 1) &* 0x9E3779B97F4A7C15
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        pixels[i] = UInt8(value & 255); pixels[i+1] = UInt8((value >> 8) & 255); pixels[i+2] = UInt8((value >> 16) & 255)
    } }
    let data = Data(pixels) as CFData
    let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: CGDataProvider(data: data)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let a = image.cropping(to: CGRect(x: 0, y: 0, width: width, height: 260))!
    let b = image.cropping(to: CGRect(x: 0, y: 100, width: width, height: 260))!
    let match = StitchMatcher().match(previous: a.grayFrame(), next: b.grayFrame())
    try require(match == .append(rows: 100), "采样方向或接缝不正确：\(match)")
    let joined = compose([StitchPiece(image: a, addedRows: 260, frame: a.grayFrame()), StitchPiece(image: b, addedRows: 100, frame: b.grayFrame())])!
    let expected = image.cropping(to: CGRect(x: 0, y: 0, width: width, height: 360))!
    try require(StitchMatcher().difference(joined.grayFrame(), expected.grayFrame()) < 0.1, "拼接像素不等于原图")
    try require(StitchMatcher().difference(render(EditState(image: a))!.grayFrame(), a.grayFrame()) < 0.1, "编辑渲染发生翻转")
    let masked = EditState(image: a, annotations: [Annotation(tool: .redact, start: CGPoint(x: 20, y: 25), end: CGPoint(x: 80, y: 95))])
    let rendered = render(masked)!
    let png = try rendered.png()
    let decoded = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(png as CFData, nil)!, 0, nil)!
    let region = decoded.cropping(to: CGRect(x: 25, y: 30, width: 45, height: 55))!.grayFrame()
    try require(region.pixels.allSatisfy { $0 == 0 }, "导出 PNG 的打码未生效")
    let canvas = EditorCanvas(image: a)
    canvas.apply(Annotation(tool: .redact, start: CGPoint(x: 20, y: 25), end: CGPoint(x: 80, y: 95)))
    canvas.apply(Annotation(tool: .crop, start: CGPoint(x: 10, y: 10), end: CGPoint(x: 100, y: 120)))
    try require(canvas.state.image.width == 90 && canvas.state.image.height == 110, "裁剪尺寸不正确")
    canvas.undo(nil)
    try require(canvas.state.image.width == width && canvas.state.annotations.count == 1, "裁剪撤销失败")
    canvas.redo(nil)
    try require(canvas.state.image.width == 90, "裁剪重做失败")
    canvas.undo(nil); canvas.undo(nil)
    try require(canvas.state.annotations.isEmpty, "标注撤销失败")
    canvas.apply(Annotation(tool: .rectangle, start: .zero, end: CGPoint(x: 40, y: 40)))
    canvas.redo(nil)
    try require(canvas.state.annotations.count == 1 && canvas.state.image.width == width, "新编辑没有清空重做历史")
    let path = ProcessInfo.processInfo.environment["KIRK_SELFTEST_DIR"] ?? NSTemporaryDirectory()
    let output = URL(fileURLWithPath: path).appendingPathComponent("kirk-selftest.png")
    try png.write(to: output, options: .atomic)
    try require(FileManager.default.fileExists(atPath: output.path), "PNG 写入失败")
    // 显式启用时才修改真实剪贴板，避免 CI 或普通自测覆盖用户内容。
    if ProcessInfo.processInfo.environment["KIRK_TEST_CLIPBOARD"] == "1" {
        let pb = NSPasteboard.general
        let saved = (pb.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types { if let value = item.data(forType: type) { copy.setData(value, forType: type) } }
            return copy
        }
        defer { pb.clearContents(); if !saved.isEmpty { pb.writeObjects(saved) } }
        pb.clearContents()
        try require(pb.setData(png, forType: .png), "剪贴板写入失败")
        try require(pb.data(forType: .png) == png, "剪贴板读取失败")
    }
    print("PNG export, redaction, image orientation, composition verified: \(output.path)")
}

@MainActor func makeDemoImage() -> CGImage {
    let image = NSImage(size: NSSize(width: 1000, height: 1400))
    image.lockFocusFlipped(true)
    NSColor.white.setFill(); CGRect(x: 0, y: 0, width: 1000, height: 1400).fill()
    ("Kirk Screenshot" as NSString).draw(at: CGPoint(x: 60, y: 55), withAttributes: [.font: NSFont.systemFont(ofSize: 40, weight: .bold), .foregroundColor: NSColor.black])
    ("本机截图 · 手动滚动 · 自动拼接" as NSString).draw(at: CGPoint(x: 60, y: 125), withAttributes: [.font: NSFont.systemFont(ofSize: 26), .foregroundColor: NSColor.darkGray])
    for i in 0..<12 {
        let y = 215 + i * 90
        ("第 \(i + 1) 段：这是一张用于编辑验收的合成图片。" as NSString).draw(at: CGPoint(x: 60, y: y), withAttributes: [.font: NSFont.systemFont(ofSize: 22), .foregroundColor: NSColor.black])
        ("PNG 导出保留图片像素，打码使用不可逆实心覆盖。" as NSString).draw(at: CGPoint(x: 60, y: y + 35), withAttributes: [.font: NSFont.systemFont(ofSize: 18), .foregroundColor: NSColor.gray])
    }
    image.unlockFocus()
    return image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
}

@MainActor func runCaptureSmokeTest() async throws {
    guard CGPreflightScreenCaptureAccess() else { throw CaptureError.message("未授予屏幕录制权限；未申请、未截屏。") }
    guard let screen = NSScreen.screens.first else { throw CaptureError.message("没有可用显示器") }
    let provider = MacCaptureProvider()
    try await provider.prepare()
    let rect = CGRect(x: screen.frame.minX + 100, y: screen.frame.minY + 100, width: 160, height: 120)
    let image = try await provider.capture(rect)
    let scale = screen.backingScaleFactor
    guard image.width == Int(160 * scale), image.height == Int(120 * scale) else { throw CaptureError.message("Retina 截图尺寸不符合预期") }
    let directory = ProcessInfo.processInfo.environment["KIRK_SELFTEST_DIR"] ?? NSTemporaryDirectory()
    let path = URL(fileURLWithPath: directory).appendingPathComponent("desktop-smoke.png")
    try image.png().write(to: path, options: .atomic)
    print("CAPTURE SMOKE PASSED: \(image.width) x \(image.height), scale=\(scale). Local private output: \(path.path)")
}

@MainActor func runHotkeySmokeTest(_ registry: HotkeyRegistry) throws {
    let enter = Shortcut(key: 36, modifiers: 0, label: "Return")
    let escape = Shortcut(key: 53, modifiers: 0, label: "Esc")
    defer { registry.unregister("test.enter"); registry.unregister("test.escape"); registry.unregister("test.collision") }
    guard registry.register("test.enter", shortcut: enter, action: {}),
          registry.register("test.enter", shortcut: enter, action: {}),
          registry.register("test.escape", shortcut: escape, action: {}) else { throw CaptureError.message("会话热键无法注册") }
    guard !registry.register("test.collision", shortcut: enter, action: {}) else { throw CaptureError.message("未检测到重复热键注册") }
    print("HOTKEY SMOKE PASSED: Return / Escape registration, same-binding update and conflict detection")
}
