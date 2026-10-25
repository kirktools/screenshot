import AppKit

/// 合成窗口元数据与手势，不读取真实窗口列表、不发送系统输入。
@MainActor func runSelectionSelfTest() throws {
    func require(_ value: Bool, _ message: String) throws {
        if !value { throw CaptureError.message("窗口预选：" + message) }
    }
    let front = CGRect(x: 100, y: 100, width: 400, height: 300)
    let back = CGRect(x: 0, y: 0, width: 800, height: 600)
    var state = RegionSelectionState(candidates: [front, back])
    state.hover(at: CGPoint(x: 200, y: 200))
    try require(state.selection == front, "重叠位置没有选择最前面的窗口")
    state.hover(at: CGPoint(x: 20, y: 20))
    try require(state.selection == back, "移动鼠标没有更新预选")
    state.mouseDown(at: CGPoint(x: 200, y: 200))
    try require(state.mouseUp(at: CGPoint(x: 201, y: 201)) == front, "单击的轻微抖动误触发拖选")
    state.mouseDown(at: CGPoint(x: 300, y: 280))
    state.drag(to: CGPoint(x: 130, y: 120))
    state.hover(at: CGPoint(x: 20, y: 20))
    try require(state.selection == CGRect(x: 130, y: 120, width: 170, height: 160), "手动反向拖选被悬停候选覆盖")
    try require(state.mouseUp(at: CGPoint(x: 130, y: 120)) == state.selection, "手动框选没有提交当前区域")
    state.mouseDown(at: CGPoint(x: 200, y: 200))
    state.drag(to: CGPoint(x: 210, y: 210))
    try require(state.mouseUp(at: CGPoint(x: 210, y: 210)) == nil, "过小拖选错误回退为整窗截图")
    state.mouseDown(at: CGPoint(x: 200, y: 200))
    state.drag(to: CGPoint(x: 300, y: 300))
    try require(state.mouseUp(at: CGPoint(x: 201, y: 201)) == nil, "拖选缩回起点后错误确认整窗")
    var empty = RegionSelectionState(candidates: [])
    empty.mouseDown(at: .zero)
    try require(empty.mouseUp(at: .zero) == nil, "无窗口处的单击产生无效截图")
    empty.mouseDown(at: CGPoint(x: -150, y: -100))
    try require(empty.mouseUp(at: CGPoint(x: 50, y: 100)) == CGRect(x: -150, y: -100, width: 200, height: 200), "没有候选窗口时不能手动跨屏框选")

    func entry(_ rect: CGRect, pid: Int = 5, layer: Int = 0, alpha: Double = 1) -> [String: Any] {
        [kCGWindowOwnerPID as String: pid, kCGWindowLayer as String: layer, kCGWindowAlpha as String: alpha,
         kCGWindowBounds as String: ["X": rect.minX, "Y": rect.minY, "Width": rect.width, "Height": rect.height]]
    }
    let desktop = CGRect(x: -1000, y: -500, width: 2000, height: 1500)
    let data = [entry(CGRect(x: 20, y: 30, width: 200, height: 100), pid: 99),
                entry(CGRect(x: 20, y: 30, width: 200, height: 100), layer: 3),
                entry(CGRect(x: 20, y: 30, width: 200, height: 100), alpha: 0),
                entry(CGRect(x: -300, y: 250, width: 200, height: 400)),
                entry(CGRect(x: 900, y: 100, width: 200, height: 100)),
                entry(CGRect(x: 0, y: 0, width: 20, height: 20)),
                entry(CGRect(x: 5000, y: 0, width: 100, height: 100)),
                [kCGWindowOwnerPID as String: 5]]
    let regions = WindowPreselection.regions(from: data, excludingPID: 99, screenTop: 800, desktop: desktop)
    try require(regions == [CGRect(x: -300, y: 150, width: 200, height: 400), CGRect(x: 900, y: 600, width: 100, height: 100)],
                "窗口过滤、负坐标转换、屏幕边缘裁切或前后顺序不正确：\(regions)")
    try require(WindowPreselection.regions(from: [], excludingPID: 99, screenTop: 800, desktop: desktop).isEmpty, "空窗口列表不能降级")
    // 故意把第一响应者从框选视图移走，复现 Esc 只依赖视图时无法退出。
    let selector = RegionSelector()
    var cancelled = 0
    selector.completion = { if $0 == nil { cancelled += 1 } }
    selector.begin(candidates: [NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }])
    defer { selector.finish(cancel: true) }
    guard let window = NSApp.windows.first(where: { $0 is SelectionWindow && $0.isVisible }) else {
        throw CaptureError.message("窗口预选：测试选择器未显示")
    }
    window.makeFirstResponder(window)
    let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                  windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                                  charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
    window.keyDown(with: escape)
    try require(cancelled == 1 && !window.isVisible, "响应者移走后 Esc 失效，蓝框仍残留")
    selector.finish(cancel: true)
    try require(cancelled == 1, "重复结束触发多次回调")
    let desktopRect = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
    for keyCode: UInt16 in [36, 76] {
        var confirmed: CGRect?
        selector.completion = { confirmed = $0 }
        selector.begin(candidates: [desktopRect])
        let active = NSApp.windows.first { $0 is SelectionWindow && $0.isVisible }!
        let view = active.contentView as! SelectionView
        try require(view.acceptsFirstMouse(for: nil), "非关键窗口首次点击被吞掉")
        if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let alpha = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)!.alphaComponent
            try require(alpha > 0 && alpha < 0.03, "预选区域完全透明，可能让点击穿透：\(alpha)")
        } else { throw CaptureError.message("窗口预选：无法验证选区像素") }
        active.makeFirstResponder(active)
        let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                    windowNumber: active.windowNumber, context: nil, characters: "\r",
                                    charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: keyCode)!
        active.keyDown(with: enter)
        try require(confirmed == desktopRect && !active.isVisible, "第一响应者移走后回车无法确认窗口")
    }
    var deactivated = 0
    selector.completion = { if $0 == nil { deactivated += 1 } }
    selector.begin(candidates: [desktopRect])
    NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
    try require(deactivated == 1 && !NSApp.windows.contains { $0 is SelectionWindow && $0.isVisible }, "切走应用后残留框选窗口")
    // 已完成的选择器不能继续吞掉用户按键。
    try require(!selector.handleKey(escape), "选择器结束后仍拦截键盘")
    print("窗口交互：失去第一响应者时 Esc/双回车、首击、透明区域 alpha、失活清理及重复完成通过")
    print("窗口预选：前后层级、单击、鼠标抖动、手动/反向拖选、过小选区、空候选、跨屏负坐标和元数据过滤通过")
}
