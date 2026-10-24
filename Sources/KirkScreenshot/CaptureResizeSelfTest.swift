import AppKit
import StitchCore

/// 使用生成像素和本应用窗口事件验证改选区，不读取桌面、不写入真实剪贴板。
@MainActor func runCaptureResizeSelfTest(image: CGImage) throws {
    func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw CaptureError.message("选区调整：" + message) }
    }
    func same(_ actual: CGImage, _ expected: CGImage) -> Bool {
        actual.width == expected.width && actual.height == expected.height && StitchMatcher().difference(actual.grayFrame(), expected.grayFrame()) < 0.1
    }
    let negative = CGRect(x: -400, y: -100, width: 80, height: 200)
    let negativeSource = FrozenCapture(tiles: [FrozenCaptureTile(region: negative, image: image)])
    let selected = CGRect(x: -380, y: -80, width: 40, height: 50)
    guard let cropped = negativeSource.crop(selected), let expected = image.cropping(to: CGRect(x: 40, y: 260, width: 80, height: 100)) else {
        throw CaptureError.message("选区调整：无法裁取合成源")
    }
    try require(same(cropped, expected), "Retina 负坐标或上下方向发生偏移")
    try require(negativeSource.crop(negative.offsetBy(dx: -1, dy: 0)) == nil, "允许读取冻结范围外的内容")
    let mixed = FrozenCapture(tiles: [FrozenCaptureTile(region: negative, image: image),
                                    FrozenCaptureTile(region: CGRect(x: -320, y: -100, width: 160, height: 200), image: image.cropping(to: CGRect(x: 0, y: 0, width: 160, height: 200))!)])
    guard let combined = mixed.crop(mixed.bounds) else { throw CaptureError.message("选区调整：跨屏合成失败") }
    try require(combined.width == 480 && combined.height == 400 && same(combined.cropping(to: CGRect(x: 0, y: 0, width: 160, height: 400))!, image), "混合缩放跨屏拼接位置不正确")
    let gapSource = FrozenCapture(tiles: [FrozenCaptureTile(region: negative, image: image),
                                        FrozenCaptureTile(region: negative.offsetBy(dx: 100, dy: 0), image: image)])
    try require(gapSource.crop(CGRect(x: -320, y: -100, width: 20, height: 200)) == nil, "屏幕空隙被当作有效选区")
    let clamped = CaptureResizeGeometry.resized(CGRect(x: -380, y: -80, width: 40, height: 80), edges: [.left, .top],
                                               delta: CGPoint(x: 500, y: 500), within: negative)
    try require(clamped.width == 32 && clamped.maxY == negative.maxY, "边缘没有限制最小尺寸或越界")
    let halfPixel = CGRect(x: -380.5, y: -80, width: 40, height: 80)
    let aligned = CaptureResizeGeometry.resized(halfPixel, edges: .right, delta: CGPoint(x: 0.4, y: 0), within: negative, pixelScale: 2)
    try require(aligned.minX == halfPixel.minX && aligned.width == 40.5, "Retina 半点坐标调整使未拖动的边缘漂移")
    for point in [CGPoint(x: 1, y: 1), CGPoint(x: 79, y: 1), CGPoint(x: 1, y: 199), CGPoint(x: 79, y: 199)] {
        try require(CaptureResizeGeometry.edges(at: point, in: CGRect(x: 0, y: 0, width: 80, height: 200)).rawValue.nonzeroBitCount == 2, "角点未同时命中两条边")
    }

    let screen = NSScreen.main!.visibleFrame
    let sourceRect = CGRect(x: screen.minX + 100, y: screen.minY + 100, width: 80, height: 200)
    let source = FrozenCapture(tiles: [FrozenCaptureTile(region: sourceRect, image: image)])
    let initial = sourceRect.insetBy(dx: 20, dy: 40)
    let controller = EditorController(image: source.crop(initial)!, region: initial, allowScroll: true, frozenCapture: source)
    defer { controller.close() }
    controller.showWindow(nil)
    let handles = controller.diagnosticResizeHandles
    try require(handles.enabled && handles.hitTest(CGPoint(x: 20, y: 60)) == nil && handles.hitTest(CGPoint(x: 2, y: 60)) === handles,
                "手柄未启用或抢走了画布内部标注事件")
    try require(controller.window!.contentView!.hitTest(CGPoint(x: 20, y: 60)) === controller.canvas,
                "容器或手柄截获了画布内部的实际命中")
    func event(_ type: NSEvent.EventType, at global: CGPoint) -> NSEvent {
        let window = controller.window!
        return NSEvent.mouseEvent(with: type, location: window.convertPoint(fromScreen: global), modifierFlags: [], timestamp: 0,
                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
    func growTopRight(dx: CGFloat, dy: CGFloat) {
        let rect = controller.captureRegion!
        let start = CGPoint(x: rect.maxX - 2, y: rect.maxY - 2)
        handles.mouseDown(with: event(.leftMouseDown, at: start))
        handles.mouseDragged(with: event(.leftMouseDragged, at: CGPoint(x: start.x + dx / 2, y: start.y + dy / 2)))
        handles.mouseDragged(with: event(.leftMouseDragged, at: CGPoint(x: start.x + dx, y: start.y + dy)))
        handles.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: start.x + dx, y: start.y + dy)))
    }
    controller.canvas.apply(Annotation(tool: .redact, start: CGPoint(x: 10, y: 20), end: CGPoint(x: 30, y: 40)))
    growTopRight(dx: 12, dy: 15)
    let resized = CGRect(x: initial.minX, y: initial.minY, width: initial.width + 12, height: initial.height + 15)
    try require(controller.captureRegion == resized && controller.diagnosticGeometry.image == resized && controller.canvas.zoom == 0.5, "原位窗口或缩放未跟随手柄")
    try require(controller.canvas.state.annotations.first?.start == CGPoint(x: 10, y: 50), "扩选移动了打码在屏幕上的位置")
    controller.canvas.undo(nil)
    try require(controller.captureRegion == initial && controller.canvas.state.annotations.count == 1, "一次拖动产生了多条撤销或丢失标注")
    controller.canvas.redo(nil)
    try require(controller.captureRegion == resized, "重做没有恢复选区")
    controller.canvas.apply(Annotation(tool: .crop, start: CGPoint(x: 4, y: 8), end: CGPoint(x: 60, y: 100)))
    try require(controller.canvas.state.image.width == 56 && controller.canvas.state.image.height == 92 && handles.enabled, "裁剪后不能继续调整选区")
    growTopRight(dx: 10, dy: 10)
    let mask = controller.canvas.state.annotations[0].rect
    let exported = render(controller.canvas.state)!
    try require(exported.cropping(to: mask.insetBy(dx: 2, dy: 2))!.grayFrame().pixels.allSatisfy { $0 == 0 }, "裁剪后扩选使打码失效")
    controller.canvas.undo(nil); controller.canvas.undo(nil); controller.canvas.undo(nil); controller.canvas.undo(nil)
    try require(controller.captureRegion == initial && controller.canvas.state.annotations.isEmpty && same(render(controller.canvas.state)!, source.crop(initial)!), "多次撤销未恢复原始像素，或手柄进入导出")
    let beforeClose = render(controller.canvas.state)!
    controller.close()
    try require(!controller.diagnosticFrozenCaptureRetained && !handles.enabled && controller.diagnosticGeometry.backdrops == 0,
                "关闭后未释放快照或界面资源")
    try require(same(render(controller.canvas.state)!, beforeClose), "释放快照改变了保留预览的内容")
    let next = EditorController(image: source.crop(initial)!, region: initial, allowScroll: true, frozenCapture: source)
    defer { next.close() }
    var scrollRegion: CGRect?
    next.requestScroll = { [weak next] in scrollRegion = next?.captureRegion }
    let grip = next.diagnosticResizeHandles
    let start = CGPoint(x: initial.maxX - 2, y: initial.midY)
    grip.began?(.right, start); grip.moved?(CGPoint(x: start.x + 10, y: start.y)); grip.ended?()
    let adjusted = next.captureRegion
    guard let scroll = next.diagnosticToolbarViews.compactMap({ $0 as? NSButton }).first(where: { $0.toolTip == "滚动长截图（重新采集选区）" }) else {
        throw CaptureError.message("选区调整：缺少长截图入口")
    }
    scroll.performClick(nil)
    try require(scrollRegion == adjusted && scrollRegion != initial && !next.diagnosticFrozenCaptureRetained, "长截图入口仍使用旧选区，或关闭后丢失新范围")
    print("选区调整：Retina/负坐标/混合跨屏、边缘命中、原位拖动、标注偏移、裁剪后打码、撤销重做、长图范围和释放通过")
}
