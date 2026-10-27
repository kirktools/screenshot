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

/// 用会在选区出现后“消失”的合成提示验证启动顺序，不读取桌面或操作系统鼠标。
@MainActor func runFrozenSelectionSelfTest() async throws {
    func require(_ value: Bool, _ message: String) throws {
        if !value { throw CaptureError.message("冻结选区：" + message) }
    }
    func wait(_ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw CaptureError.message("冻结选区：等待超时") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main!
    let region = screen.frame
    let ctx = CGContext(data: nil, width: Int(region.width), height: Int(region.height), bitsPerComponent: 8,
                        bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 1, green: 0, blue: 1, alpha: 1)); ctx.fill(CGRect(origin: .zero, size: region.size))
    let original = ctx.makeImage()!
    let snapshot = FrozenCapture(tiles: [FrozenCaptureTile(region: region, image: original)])
    let delegate = AppDelegate()
    delegate.permissionAccess = ScreenPermissionAccess(isAuthorized: { true }, request: { false }, openSettings: {})
    var pending: CheckedContinuation<FrozenCapture, Error>?, captures = 0
    delegate.freezeSelection = {
        captures += 1
        return try await withCheckedThrowingContinuation { pending = $0 }
    }
    func activeSelection() -> SelectionView? {
        NSApp.windows.first { $0 is SelectionWindow && $0.isVisible && $0.frame == region }?.contentView as? SelectionView
    }
    delegate.capture(scrolling: false)
    try await wait { pending != nil || activeSelection() != nil }
    try require(pending != nil, "选区已经出现，但触发时的快照尚未开始")
    try require(activeSelection() == nil, "快照完成前已经显示选区，悬浮提示会被焦点或鼠标打断")
    delegate.capture(scrolling: false)
    try require(captures == 1, "准备期间重复快捷键启动多次采集")
    pending!.resume(returning: snapshot); pending = nil
    try await wait { activeSelection() != nil }
    let view = activeSelection()!, selector = view.owner!
    defer { selector.finish(cancel: true); delegate.diagnosticEditor?.close() }
    try require(selector.diagnosticRetainsSnapshot, "选择器没有保留按键时的画面")
    // 目标内容此时已消失；选区与导出都必须继续使用原先的紫色像素。
    ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1)); ctx.fill(CGRect(origin: .zero, size: region.size))
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CaptureError.message("冻结选区：无法渲染") }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    let color = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)!.usingColorSpace(.deviceRGB)!
    try require(color.redComponent - color.greenComponent > 0.3 && color.blueComponent - color.greenComponent > 0.3, "选区背景仍显示实时桌面，冻结的提示不可见：\(color)")
    let selected = CGRect(x: region.midX - 120, y: region.midY - 80, width: 240, height: 160)
    selector.mouseDown(at: selected.origin)
    selector.mouseUp(at: CGPoint(x: selected.maxX, y: selected.maxY))
    try await wait { delegate.diagnosticEditor != nil }
    let editor = delegate.diagnosticEditor!
    try require(captures == 1 && !selector.diagnosticRetainsSnapshot, "框选后重新采集，或已关闭选择器仍持有整屏快照")
    let expected = snapshot.crop(selected)!, actual = editor.canvas.state.image
    try require(actual.width == expected.width && actual.height == expected.height && (try actual.png()) == (try expected.png()), "编辑结果没有使用触发时的像素")
    let board = NSPasteboard(name: .init("Screenshot-Frozen-Selection-\(UUID().uuidString)")); defer { board.releaseGlobally() }
    try actual.copyPNG(to: board)
    try require(board.data(forType: .png) == (try actual.png()), "冻结截图复制结果不一致")
    editor.close()
    try require(!editor.diagnosticFrozenCaptureRetained, "关闭编辑后未释放冻结背景")
    let cancel = RegionSelector()
    var cancelled = 0
    cancel.completion = { if $0 == nil { cancelled += 1 } }
    cancel.begin(candidates: [region], frozenCapture: snapshot)
    NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
    try require(cancelled == 1 && !cancel.diagnosticRetainsSnapshot && activeSelection() == nil, "显示器布局变化后没有取消并释放快照")
    print("冻结选区：快照先于选区/准星、重复按键、提示消失后仍可见、原像素编辑/复制、关闭及显示器变化释放通过")
}
