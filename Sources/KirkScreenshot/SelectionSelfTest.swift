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
    print("窗口预选：前后层级、单击、鼠标抖动、手动/反向拖选、过小选区、空候选、跨屏负坐标和元数据过滤通过")
}
