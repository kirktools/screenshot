import AppKit

/// 系统 tooltip 的层级低于截图浮层，因此在同一浮层之上绘制提示。
@MainActor enum EditorHoverHelp {
    private static var panel: NSPanel?
    static var diagnosticWindow: NSWindow? { panel }
    private static var pending: DispatchWorkItem?
    static func hide() { pending?.cancel(); pending = nil; panel?.orderOut(nil) }
    static func show(for button: NSButton) {
        hide()
        guard let text = button.toolTip, !text.isEmpty else { return }
        let work = DispatchWorkItem { [weak button] in
            guard let button, let window = button.window, window.isVisible else { return }
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: 12); label.textColor = .labelColor
            let popup = panel ?? NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            popup.isReleasedWhenClosed = false; popup.ignoresMouseEvents = true; popup.hidesOnDeactivate = false
            popup.backgroundColor = .clear; popup.isOpaque = false
            popup.level = NSWindow.Level(rawValue: window.level.rawValue + 2)
            popup.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            popup.contentView = captureToolbar(views: [label])
            let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
            let size = popup.contentView!.fittingSize
            let screen = window.screen?.visibleFrame ?? NSScreen.main!.visibleFrame
            popup.setFrame(CaptureLayout.toolbar(near: rect, size: size, within: screen), display: true)
            panel = popup; popup.orderFrontRegardless()
        }
        pending = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }
}
class EditorIconButton: NSButton {
    private var hoverTracking: NSTrackingArea?
    override func updateTrackingAreas() {
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(tracking); hoverTracking = tracking; super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { EditorHoverHelp.show(for: self) }
    override func mouseExited(with event: NSEvent) { EditorHoverHelp.hide() }
    override func mouseDown(with event: NSEvent) { EditorHoverHelp.hide(); super.mouseDown(with: event) }
}

/// 形状主体和窄下拉区是一个控件：共享背景，内部不使用工具间距。
final class EditorShapeGroup: NSStackView {
    var selected = false { didSet { refreshBackground() } }
    private var hovering = false
    private var hoverTracking: NSTrackingArea?
    override func updateTrackingAreas() {
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(tracking); hoverTracking = tracking; super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; refreshBackground() }
    override func mouseExited(with event: NSEvent) { hovering = false; refreshBackground() }
    private func refreshBackground() {
        wantsLayer = true; layer?.cornerRadius = 5
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(selected ? 0.1 : hovering ? 0.06 : 0).cgColor
    }
}

final class EditorToolbarDragHandle: EditorIconButton {
    var began: (() -> Void)?
    var moved: ((CGPoint) -> Void)?
    var reset: (() -> Void)?
    private var start: CGPoint?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.secondaryLabelColor.setFill()
        for x in [5.0, 10.0] { for y in [8.0, 14.0, 20.0] {
            NSBezierPath(ovalIn: CGRect(x: x-1, y: y-1, width: 2, height: 2)).fill()
        } }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func mouseDown(with event: NSEvent) {
        EditorHoverHelp.hide()
        if event.clickCount == 2 { start = nil; reset?(); return }
        start = NSEvent.mouseLocation; began?(); NSCursor.closedHand.set()
    }
    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let p = NSEvent.mouseLocation; moved?(CGPoint(x: p.x-start.x, y: p.y-start.y))
    }
    override func mouseUp(with event: NSEvent) { start = nil; NSCursor.openHand.set() }
}
