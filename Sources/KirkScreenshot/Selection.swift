import AppKit

/// Quartz 窗口坐标以主显示器左上为原点；选择器统一使用 AppKit 屏幕点坐标。
/// 每次唤起只读取一次窗口列表，保持前后顺序；不查询标题或辅助功能树。
enum WindowPreselection {
    static func regions(from info: [[String: Any]], excludingPID: Int32, screenTop: CGFloat, desktop: CGRect) -> [CGRect] {
        info.compactMap { entry in
            guard let pid = entry[kCGWindowOwnerPID as String] as? NSNumber, pid.int32Value != excludingPID,
                  let layer = entry[kCGWindowLayer as String] as? NSNumber, layer.intValue == 0,
                  let alpha = entry[kCGWindowAlpha as String] as? NSNumber, alpha.doubleValue > 0,
                  let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
                  let quartz = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  quartz.minX.isFinite, quartz.minY.isFinite, quartz.width.isFinite, quartz.height.isFinite,
                  quartz.width >= 32, quartz.height >= 32 else { return nil }
            let screen = CGRect(x: quartz.minX, y: screenTop - quartz.maxY, width: quartz.width, height: quartz.height)
            let visible = screen.intersection(desktop)
            guard !visible.isNull, visible.width >= 32, visible.height >= 32 else { return nil }
            return visible.integral
        }
    }
}

/// 将命中与手势状态独立出来，测试不需要读取用户桌面或发送系统鼠标事件。
struct RegionSelectionState {
    let candidates: [CGRect]
    private(set) var selection: CGRect = .zero
    private var start: CGPoint?
    private var drawing = false
    init(candidates: [CGRect]) { self.candidates = candidates }
    mutating func hover(at point: CGPoint) {
        guard start == nil else { return }
        selection = candidates.first { $0.contains(point) } ?? .zero
    }
    mutating func mouseDown(at point: CGPoint) {
        hover(at: point)
        start = point; drawing = false
    }
    mutating func drag(to point: CGPoint) {
        guard let start else { return }
        if hypot(point.x - start.x, point.y - start.y) >= 4 { drawing = true }
        guard drawing else { return }
        selection = CGRect(x: min(start.x, point.x), y: min(start.y, point.y), width: abs(point.x - start.x), height: abs(point.y - start.y)).integral
    }
    mutating func mouseUp(at point: CGPoint) -> CGRect? {
        guard start != nil else { return nil }
        drag(to: point)
        start = nil
        // 一旦开始手动拖选，即使最后区域太小，也不能回退误选整个窗口。
        return selection.width >= 32 && selection.height >= 32 ? selection : nil
    }
}

final class SelectionWindow: NSWindow {
    weak var selectionOwner: RegionSelector?
    override var canBecomeKey: Bool { true }
    override func keyDown(with event: NSEvent) {
        if selectionOwner?.handleKey(event) != true { super.keyDown(with: event) }
    }
    override func cancelOperation(_ sender: Any?) { selectionOwner?.finish(cancel: true) }
}

@MainActor final class RegionSelector {
    private var windows: [NSWindow] = []
    private var state = RegionSelectionState(candidates: [])
    private var cursorPushed = false
    private var keyMonitor: Any?
    private var activationObserver: NSObjectProtocol?
    private var deactivationObserver: NSObjectProtocol?
    var completion: ((CGRect?) -> Void)?
    func begin(candidates: [CGRect]? = nil) {
        guard windows.isEmpty else { return }
        let screens = NSScreen.screens
        guard !screens.isEmpty else { let callback = completion; completion = nil; callback?(nil); return }
        let desktop = screens.reduce(CGRect.null) { $0.union($1.frame) }
        let regions: [CGRect]
        if let candidates { regions = candidates }
        else {
            let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            regions = WindowPreselection.regions(from: info, excludingPID: ProcessInfo.processInfo.processIdentifier,
                                                 screenTop: screens.first?.frame.maxY ?? 0, desktop: desktop)
        }
        state = RegionSelectionState(candidates: regions)
        state.hover(at: NSEvent.mouseLocation)
        for screen in screens {
            let window = SelectionWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.level = .screenSaver; window.backgroundColor = .clear; window.isOpaque = false
            window.selectionOwner = self; window.ignoresMouseEvents = false
            window.acceptsMouseMovedEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; window.isReleasedWhenClosed = false
            let view = SelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
            view.owner = self; window.contentView = view; window.initialFirstResponder = view
            windows.append(window); window.orderFrontRegardless()
            window.makeFirstResponder(view)
        }
        // 激活是异步的；键盘不能只依赖 initialFirstResponder 恰好仍是框选视图。
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.handleKey(event) == true ? nil : event }
        }
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: NSApp, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.focusSelectionWindow() }
        }
        deactivationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: NSApp, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish(cancel: true) }
        }
        NSApp.activate(ignoringOtherApps: true)
        focusSelectionWindow()
        NSCursor.crosshair.push(); cursorPushed = true
    }
    private func focusSelectionWindow() {
        guard let window = windows.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? windows.first else { return }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(window.contentView)
    }
    @discardableResult func handleKey(_ event: NSEvent) -> Bool {
        guard !windows.isEmpty else { return false }
        switch event.keyCode {
        case 53: finish(cancel: true)
        case 36, 76: finish()
        default: return false
        }
        return true
    }
    private func redraw() { windows.forEach { $0.contentView?.needsDisplay = true } }
    func mouseMoved() { state.hover(at: NSEvent.mouseLocation); redraw() }
    func mouseDown() { state.mouseDown(at: NSEvent.mouseLocation); redraw() }
    func drag() { state.drag(to: NSEvent.mouseLocation); redraw() }
    func mouseUp() {
        if state.mouseUp(at: NSEvent.mouseLocation) != nil { finish() }
        else { redraw() }
    }
    func finish(cancel: Bool = false) {
        guard !windows.isEmpty else { return }
        let selection = state.selection
        guard cancel || (selection.width >= 32 && selection.height >= 32) else { return }
        let result: CGRect? = cancel ? nil : selection
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver); self.activationObserver = nil }
        if let deactivationObserver { NotificationCenter.default.removeObserver(deactivationObserver); self.deactivationObserver = nil }
        windows.forEach { $0.orderOut(nil); $0.close() }; windows.removeAll()
        if cursorPushed { NSCursor.pop(); cursorPushed = false }
        let cb = completion; completion = nil; cb?(result)
    }
    func rect(in view: NSView) -> CGRect {
        guard let window = view.window else { return .zero }
        return state.selection.offsetBy(dx: -window.frame.minX, dy: -window.frame.minY)
    }
}

final class SelectionView: NSView {
    weak var owner: RegionSelector?
    private var pointerTracking: NSTrackingArea?
    override var acceptsFirstResponder: Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTracking { removeTrackingArea(pointerTracking) }
        let tracking = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(tracking); pointerTracking = tracking
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func cancelOperation(_ sender: Any?) { owner?.finish(cancel: true) }
    override func mouseMoved(with event: NSEvent) { owner?.mouseMoved() }
    override func mouseEntered(with event: NSEvent) { owner?.mouseMoved() }
    override func mouseDown(with event: NSEvent) { owner?.mouseDown() }
    override func mouseDragged(with event: NSEvent) { owner?.drag() }
    override func mouseUp(with event: NSEvent) { owner?.mouseUp() }
    override func keyDown(with event: NSEvent) {
        if owner?.handleKey(event) != true { super.keyDown(with: event) }
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.28).setFill(); bounds.fill()
        let rect = owner?.rect(in: self) ?? .zero
        if rect.width > 0 {
            // 完全透明的孔洞可能让 WindowServer 把点击交给下层窗口。
            // 极低 alpha 保持选区可命中；截图采集仍排除本应用的覆盖窗口。
            NSColor.black.withAlphaComponent(0.01).setFill(); rect.fill(using: .copy)
            CaptureOutline.draw(rect.insetBy(dx: 2, dy: 2))
        }
        let help = "单击选择高亮窗口 · 拖动自选区域 · Esc 取消 · 长图请避开固定栏"
        (help as NSString).draw(at: CGPoint(x: 28, y: bounds.height - 70), withAttributes: [.font: NSFont.systemFont(ofSize: 17, weight: .medium), .foregroundColor: NSColor.white])
    }
}
