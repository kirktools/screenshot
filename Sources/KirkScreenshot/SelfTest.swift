import AppKit
import Carbon
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
    // 原位编辑位置、浮动工具栏及关闭后遮罩释放；不读取桌面。
    let selection = CGRect(x: NSScreen.main!.visibleFrame.minX + 100, y: NSScreen.main!.visibleFrame.minY + 200, width: 80, height: 130)
    let overlay = EditorController(image: a, region: selection, allowScroll: true)
    overlay.showWindow(nil)
    try require(overlay.diagnosticGeometry.image == selection, "普通截图没有保留原选区位置")
    if let directory = ProcessInfo.processInfo.environment["KIRK_SELFTEST_DIR"],
       let view = overlay.diagnosticToolbarViews.first,
       let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("toolbar-check.png"))
    }
    print("OVERLAY GEOMETRY: \(overlay.diagnosticGeometry)")
    try require(overlay.diagnosticGeometry.toolbar.height >= 32, "工具栏高度不足，只有 isVisible 不能证明用户能看到它")
    try require(overlay.diagnosticGeometry.toolbarVisible && overlay.diagnosticGeometry.toolbar.width > 200, "浮动工具栏不可见或尺寸异常")
    try require(overlay.canvas.zoom == 0.5, "Retina 原位标注缩放不正确")
    try require(!overlay.diagnosticGeometry.scrolling && overlay.diagnosticGeometry.elasticity == .none, "普通截图仍允许滚动或弹性回弹")
    let toolbarViews = overlay.diagnosticToolbarViews
    guard let blue = toolbarViews.compactMap({ $0 as? NSButton }).first(where: { $0.toolTip == "蓝色" }),
          let widths = toolbarViews.compactMap({ $0 as? NSSegmentedControl }).first(where: { $0.label(forSegment: 0) == "细" }),
          let shapes = toolbarViews.compactMap({ $0 as? NSSegmentedControl }).first(where: { $0.segmentCount == EditTool.allCases.count }) else {
        throw CaptureError.message("工具栏缺少颜色、线宽或形状选择")
    }
    blue.performClick(nil)
    widths.selectedSegment = 2; _ = widths.sendAction(widths.action, to: widths.target)
    shapes.selectedSegment = EditTool.allCases.firstIndex(of: .ellipse)!; _ = shapes.sendAction(shapes.action, to: shapes.target)
    try require(overlay.canvas.selectedColor == .blue && overlay.canvas.strokeWidth == 6 && overlay.canvas.tool == .ellipse, "样式控件未改变当前画笔")
    let circle = Annotation(tool: .ellipse, start: CGPoint(x: 20, y: 20), end: CGPoint(x: 100, y: 120), color: .blue, lineWidth: 8)
    overlay.canvas.apply(circle)
    overlay.canvas.selectedColor = .green; overlay.canvas.strokeWidth = 1.5
    try require(overlay.canvas.state.annotations.first?.color == .blue && overlay.canvas.state.annotations.first?.lineWidth == 8, "改变样式意外修改已有标注")
    let color = NSBitmapImageRep(cgImage: render(overlay.canvas.state)!).colorAt(x: 99, y: 70)!.usingColorSpace(.sRGB)!
    try require(color.blueComponent > 0.9 && color.redComponent < 0.2, "圆形导出未使用选定颜色")
    overlay.canvas.undo(nil); overlay.canvas.redo(nil)
    try require(overlay.canvas.state.annotations.first?.color == .blue && overlay.canvas.state.annotations.first?.lineWidth == 8, "撤销重做未保留标注样式")

    overlay.canvas.apply(Annotation(tool: .redact, start: CGPoint(x: 20, y: 25), end: CGPoint(x: 80, y: 95)))
    try require(render(overlay.canvas.state)!.cropping(to: CGRect(x: 25, y: 30, width: 45, height: 55))!.grayFrame().pixels.allSatisfy { $0 == 0 }, "原位标注打码未生效")
    overlay.canvas.tool = .text
    let textClick = NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 20, y: 80), modifierFlags: [], timestamp: 0, windowNumber: overlay.window!.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
    overlay.canvas.mouseDown(with: textClick)
    guard let field = overlay.canvas.subviews.compactMap({ $0 as? NSTextField }).first else {
        throw CaptureError.message("文字工具没有在图片上创建输入框")
    }
    if let editor = field.currentEditor() { editor.string = "原位中文测试" } else { field.stringValue = "原位中文测试" }
    overlay.canvas.commitText()
    try require(overlay.canvas.state.annotations.last?.text == "原位中文测试", "内嵌文字尚未失焦时提交丢失内容")
    overlay.canvas.cancelRequested?()
    try require(!overlay.diagnosticGeometry.toolbarVisible && overlay.diagnosticGeometry.backdrops == 0 && overlay.window?.isVisible == false, "取消后遗留编辑遮罩或工具栏")
    let boundary = CaptureBoundary(region: selection)
    try require(boundary.window.ignoresMouseEvents && !boundary.window.canBecomeKey, "滚动边框抢占鼠标或键盘焦点")
    try require(!boundary.window.hidesOnDeactivate, "边框在目标应用恢复焦点后会自动隐藏")
    boundary.close()
    let negativeScreen = CGRect(x: -1600, y: -200, width: 1600, height: 1000)
    let placement = CaptureLayout.toolbar(near: CGRect(x: -900, y: 300, width: 600, height: 300), size: CGSize(width: 600, height: 50), within: negativeScreen)
    try require(negativeScreen.contains(placement) && placement.maxY < 300, "负坐标屏幕工具栏定位错误")
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
        let complete = EditorController(image: a, region: selection)
        var dismissed = false
        complete.dismissed = { dismissed = true }
        complete.showWindow(nil)
        complete.canvas.finishRequested?()
        try require(dismissed && complete.window?.isVisible == false && !complete.diagnosticGeometry.toolbarVisible, "回车没有复制并关闭原位编辑")
        try require(pb.data(forType: .png) != nil, "完成未输出剪贴板 PNG")
    }
    print("PNG export, redaction, image orientation, composition verified: \(output.path)")
}

@MainActor func makeDemoImage() -> CGImage {
    let image = NSImage(size: NSSize(width: 1000, height: 1400))
    image.lockFocusFlipped(true)
    NSColor.white.setFill(); CGRect(x: 0, y: 0, width: 1000, height: 1400).fill()
    ("Kirk Screenshot" as NSString).draw(at: CGPoint(x: 60, y: 55), withAttributes: [.font: NSFont.systemFont(ofSize: 40, weight: .bold), .foregroundColor: NSColor.black])
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
    for _ in 0..<3 {
        let stream = try await provider.makeStream(rect)
        try await stream.start()
        let frames = stream.frames
        do {
            let first = try await withThrowingTaskGroup(of: CapturedFrame.self) { group in
                group.addTask {
                    for try await frame in frames { return frame }
                    throw CaptureError.message("持续采集未产生有效帧")
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(4))
                    throw CaptureError.message("等待持续采集首帧超时")
                }
                defer { group.cancelAll() }
                return try await group.next()!
            }
            guard first.image.width == image.width, first.image.height == image.height else {
                throw CaptureError.message("持续采集 Retina 尺寸与普通截图不一致")
            }
            await stream.stop()
            await stream.stop() // 重复结束应安全，不保留系统缓冲区。
        } catch { await stream.stop(); throw error }
    }
    print("SCSTREAM SMOKE PASSED: 3 start / first-frame / stop cycles, 2x pixel dimensions verified")
    print("CAPTURE SMOKE PASSED: \(image.width) x \(image.height), scale=\(scale). Local private output: \(path.path)")
}

@MainActor func runHotkeySmokeTest(_ registry: HotkeyRegistry) throws {
    let enter = Shortcut(key: 36, modifiers: 0, label: "Return")
    let escape = Shortcut(key: 53, modifiers: 0, label: "Esc")
    defer {
        for name in ["test.enter", "test.escape", "test.collision", "test.system", "test.fallback"] { registry.unregister(name) }
    }
    guard registry.register("test.enter", shortcut: enter, action: {}),
          registry.register("test.enter", shortcut: enter, action: {}),
          registry.register("test.escape", shortcut: escape, action: {}) else { throw CaptureError.message("会话热键无法注册") }
    guard !registry.register("test.collision", shortcut: enter, action: {}) else { throw CaptureError.message("未检测到重复热键注册") }
    guard let reserved = Shortcut.systemBindings()?.first(where: { $0.modifiers != 0 && $0.key <= 127 }) else {
        throw CaptureError.message("无法找到启用的系统快捷键，不能验证系统冲突回归")
    }
    guard !registry.register("test.system", shortcut: reserved, action: {}), registry.lastError?.contains("macOS") == true else {
        throw CaptureError.message("错误接受了 macOS 已启用的系统快捷键")
    }
    guard registry.register("test.fallback", shortcut: .fallbackScroll, action: {}) else {
        throw CaptureError.message("备用长截图快捷键不可用：\(registry.lastError ?? "未知错误")")
    }
    print("HOTKEY SMOKE PASSED: Return / Escape, duplicate binding, macOS reserved shortcut rejection, fallback binding")
}

@MainActor func runStartupSmokeTest(_ delegate: AppDelegate) throws {
    // 与机器上的旧 hasOpened 偏好无关：重启后必须能看到状态，重开时不能变成无响应。
    delegate.openSettings()
    guard let window = NSApp.windows.first(where: { $0.title == "Kirk Screenshot · 设置" }), window.isVisible else {
        throw CaptureError.message("启动后没有可见的状态窗口")
    }
    func buttons(in view: NSView) -> [NSButton] {
        (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { buttons(in: $0) }
    }
    let titles = buttons(in: window.contentView!).map(\.title)
    guard titles.contains("区域截图"), titles.contains("滚动长截图") else { throw CaptureError.message("缺少无需快捷键的截图入口") }
    window.close()
    guard !window.isVisible else { throw CaptureError.message("无法关闭设置窗口") }
    _ = delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
    guard window.isVisible else { throw CaptureError.message("关闭设置后再次打开应用未恢复窗口") }
    _ = delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true)
    guard NSApp.windows.filter({ $0.title == window.title }).count == 1 else { throw CaptureError.message("重复打开生成了多个设置窗口") }
    window.close()
    print("Startup status window, direct capture buttons and reopen behavior verified")
}

/// 仅渲染本应用控件与生成内容，供文档使用；不读取桌面或私人聊天。
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
