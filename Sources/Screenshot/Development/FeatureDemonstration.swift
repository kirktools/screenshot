import AppKit

/// 高帧率素材只在独立演示构建中生成，普通导出保持原有 24 帧兼容。
let featureDemoFrameCount = ProcessInfo.processInfo.environment["SCREENSHOT_DEMO_SMOOTH"] == "1" ? 180 : 24

/// 离线素材使用真实编辑控件及变换逻辑；只捕获本应用视图，不读取桌面。
@MainActor func featureSnapshot(_ view: NSView, to url: URL) throws {
    view.appearance = NSAppearance(named: .aqua)
    view.layoutSubtreeIfNeeded()
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CaptureError.message("演示视图无法绘制") }
    view.effectiveAppearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: bitmap) }
    guard let image = bitmap.cgImage else { throw CaptureError.message("演示视图为空") }
    try image.png().write(to: url, options: .atomic)
}

@MainActor func featureDocument() -> CGImage {
    let image = NSImage(size: NSSize(width: 1000, height: 1500))
    image.lockFocusFlipped(true)
    NSColor(srgbRed: 0.96, green: 0.98, blue: 0.97, alpha: 1).setFill(); CGRect(x: 0, y: 0, width: 1000, height: 1500).fill()
    func text(_ value: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat, bold: Bool = false) {
        (value as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular), .foregroundColor: NSColor(srgbRed: 0.1, green: 0.24, blue: 0.22, alpha: 1)])
    }
    text("我的灵感手册", 56, 50, 38, bold: true)
    text("把值得留住的内容，变成下一步行动。", 56, 110, 24)
    let sections = [("01  整理线索", "阅读资料，圈出重点。", "先保留现场，再慢慢消化。"),
                    ("02  记下想法", "给文字换个角度，也给想法一点空间。", "拖动缩放、旋转，不必反复输入数值。"),
                    ("03  连起来看", "一屏装不下，就向上或向下继续滚动。", "稳定的顶部和底部，只出现一次。"),
                    ("04  让步骤动起来", "复用选区录成 GIF，分享一段简短操作。", "手动开始与停止，先预览，再保存。"),
                    ("05  放在眼前", "把截图钉到屏幕，边看边做。", "内容在本机处理，无需账号。")]
    for (index, section) in sections.enumerated() {
        let y = CGFloat(185+index*235)
        NSColor.white.setFill(); NSBezierPath(roundedRect: CGRect(x: 40, y: y, width: 920, height: 200), xRadius: 16, yRadius: 16).fill()
        text(section.0, 64, y+24, 26, bold: true)
        text(section.1, 64, y+78, 23); text(section.2, 64, y+123, 22)
    }
    image.unlockFocus()
    let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    let ctx = CGContext(data: nil, width: 1000, height: 1500, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(source, in: CGRect(x: 0, y: 0, width: 1000, height: 1500))
    return ctx.makeImage()!
}

@MainActor private func featureEditorSnapshot(_ editor: EditorController, to url: URL) throws {
    guard let content = editor.window?.contentView, let toolbar = editor.diagnosticToolbarViews.first else { return }
    let geometry = editor.diagnosticGeometry, extent = geometry.image.union(geometry.toolbar).insetBy(dx: -16, dy: -16)
    let ctx = CGContext(data: nil, width: Int(extent.width*2), height: Int(extent.height*2), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(gray: 0.12, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
    for (view, rect) in [(content, geometry.image), (toolbar, geometry.toolbar)] {
        view.appearance = NSAppearance(named: view === toolbar ? .darkAqua : .aqua)
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CaptureError.message("编辑演示无法绘制") }
        view.effectiveAppearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: bitmap) }
        if let image = bitmap.cgImage { ctx.draw(image, in: CGRect(x: (rect.minX-extent.minX)*2, y: (rect.minY-extent.minY)*2, width: rect.width*2, height: rect.height*2)) }
    }
    try ctx.makeImage()!.png().write(to: url, options: .atomic)
}

@MainActor func writeFeatureDemonstration(to directory: URL) async throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let doc = featureDocument(), image = doc.cropping(to: CGRect(x: 0, y: 0, width: 1000, height: 620))!
    let screen = NSScreen.main!.visibleFrame
    let editor = EditorController(image: image, region: CGRect(x: screen.midX-320, y: screen.midY-170, width: 640, height: 400), allowScroll: true)
    defer { editor.close() }
    editor.showWindow(nil)
    try featureEditorSnapshot(editor, to: directory.appendingPathComponent("selection.png"))
    editor.chooseTool(.text)
    let base = Annotation(tool: .text, start: CGPoint(x: 440, y: 370), end: .zero, text: "先把灵感留下来", color: .red, fontSize: 28)
    editor.canvas.apply(base); editor.canvas.selectText(at: CGPoint(x: 442, y: 372))
    let handle = base.textHandlePoints(zoom: editor.canvas.zoom)[3]
    let center = base.textPoint(CGPoint(x: base.textSize.width/2, y: base.textSize.height/2))
    guard editor.canvas.beginTextTransform(at: handle) else { throw CaptureError.message("演示缩放手柄未命中") }
    for i in 0..<(featureDemoFrameCount/2) {
        let scale = 1 + CGFloat(i)/CGFloat(featureDemoFrameCount/2-1)*0.6
        editor.canvas.updateTextTransform(at: CGPoint(x: center.x+(handle.x-center.x)*scale, y: center.y+(handle.y-center.y)*scale))
        try featureEditorSnapshot(editor, to: directory.appendingPathComponent(String(format: "text-%02d.png", i)))
    }
    editor.canvas.endTextTransform()
    let a = editor.canvas.state.annotations.last!, pivot = a.textPoint(CGPoint(x: a.textSize.width/2, y: a.textSize.height/2))
    let rotationHandle = a.textHandlePoints(zoom: editor.canvas.zoom)[4]
    guard editor.canvas.beginTextTransform(at: rotationHandle) else { throw CaptureError.message("演示旋转手柄未命中") }
    for i in 0..<(featureDemoFrameCount/2) {
        let angle = -CGFloat(i)/CGFloat(featureDemoFrameCount/2-1) * .pi/10
        let x = rotationHandle.x-pivot.x, y = rotationHandle.y-pivot.y
        editor.canvas.updateTextTransform(at: CGPoint(x: pivot.x+x*cos(angle)-y*sin(angle), y: pivot.y+x*sin(angle)+y*cos(angle)))
        try featureEditorSnapshot(editor, to: directory.appendingPathComponent(String(format: "text-%02d.png", i+featureDemoFrameCount/2)))
    }
    editor.canvas.endTextTransform()
    try featureEditorSnapshot(editor, to: directory.appendingPathComponent("editor.png"))
    if ProcessInfo.processInfo.environment["SCREENSHOT_DEMO_EDITOR_ONLY"] == "1" { return }
    let pinned = render(editor.canvas.state)!
    editor.close()
    try await writeFeatureSessionDemonstrations(document: doc, to: directory)
    try PinnedImage.show(pinned, near: nil)
    guard let window = PinnedImage.diagnosticWindows.last, let view = window.contentView else { throw CaptureError.message("演示贴图未生成") }
    defer { window.close() }
    for i in 0..<featureDemoFrameCount {
        let width = 440+CGFloat(i)/CGFloat(featureDemoFrameCount-1)*115
        window.setContentSize(CGSize(width: width, height: width*CGFloat(pinned.height)/CGFloat(pinned.width)))
        window.setFrameOrigin(CGPoint(x: screen.minX+80+CGFloat(i)/CGFloat(featureDemoFrameCount-1)*115, y: screen.minY+80))
        try featureSnapshot(view.superview ?? view, to: directory.appendingPathComponent(String(format: "pin-%02d.png", i)))
    }
    print("新功能演示素材已导出：文字实际变换、固定栏会话、GIF 会话与置顶贴图；无桌面采集。")
}
