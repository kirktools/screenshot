import AppKit

final class SelectionWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

@MainActor final class RegionSelector {
    private var windows: [NSWindow] = []
    private var start: CGPoint?
    private var selection: CGRect = .zero
    var completion: ((CGRect?) -> Void)?
    func begin() {
        for screen in NSScreen.screens {
            let window = SelectionWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.level = .screenSaver; window.backgroundColor = .clear; window.isOpaque = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; window.isReleasedWhenClosed = false
            let view = SelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
            view.owner = self; window.contentView = view; window.initialFirstResponder = view
            windows.append(window); window.orderFrontRegardless()
        }
        NSApp.activate(ignoringOtherApps: true)
        windows.first?.makeKey()
        NSCursor.crosshair.push()
    }
    func mouseDown() { start = NSEvent.mouseLocation }
    func drag() {
        guard let start else { return }
        let p = NSEvent.mouseLocation
        selection = CGRect(x: min(start.x, p.x), y: min(start.y, p.y), width: abs(p.x - start.x), height: abs(p.y - start.y)).integral
        windows.forEach { $0.contentView?.needsDisplay = true }
    }
    func finish(cancel: Bool = false) {
        let result: CGRect? = !cancel && selection.width >= 32 && selection.height >= 32 ? selection : nil
        windows.forEach { $0.orderOut(nil); $0.close() }; windows.removeAll(); NSCursor.pop()
        let cb = completion; completion = nil; cb?(result)
    }
    func rect(in view: NSView) -> CGRect {
        guard let window = view.window else { return .zero }
        return selection.offsetBy(dx: -window.frame.minX, dy: -window.frame.minY)
    }
}

final class SelectionView: NSView {
    weak var owner: RegionSelector?
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) { owner?.mouseDown() }
    override func mouseDragged(with event: NSEvent) { owner?.drag() }
    override func mouseUp(with event: NSEvent) { owner?.drag(); owner?.finish() }
    override func keyDown(with event: NSEvent) { if event.keyCode == 53 { owner?.finish(cancel: true) } }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.28).setFill(); bounds.fill()
        let rect = owner?.rect(in: self) ?? .zero
        if rect.width > 0 {
            NSColor.clear.setFill(); rect.fill(using: .copy)
            NSColor.systemTeal.setStroke(); let path = NSBezierPath(rect: rect); path.lineWidth = 2; path.stroke()
        }
        let help = "拖动选择区域 · Esc 取消 · 长截图请避开固定栏和悬浮元素"
        (help as NSString).draw(at: CGPoint(x: 28, y: bounds.height - 70), withAttributes: [.font: NSFont.systemFont(ofSize: 17, weight: .medium), .foregroundColor: NSColor.white])
    }
}
