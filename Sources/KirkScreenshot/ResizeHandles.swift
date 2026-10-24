import AppKit

struct CaptureEdges: OptionSet {
    let rawValue: Int
    static let left = CaptureEdges(rawValue: 1)
    static let right = CaptureEdges(rawValue: 2)
    static let bottom = CaptureEdges(rawValue: 4)
    static let top = CaptureEdges(rawValue: 8)
}

enum CaptureResizeGeometry {
    static func edges(at point: CGPoint, in bounds: CGRect, tolerance: CGFloat = 7) -> CaptureEdges {
        guard bounds.contains(point) else { return [] }
        var edges: CaptureEdges = []
        if point.x - bounds.minX <= tolerance { edges.insert(.left) }
        else if bounds.maxX - point.x <= tolerance { edges.insert(.right) }
        if point.y - bounds.minY <= tolerance { edges.insert(.bottom) }
        else if bounds.maxY - point.y <= tolerance { edges.insert(.top) }
        return edges
    }
    static func resized(_ rect: CGRect, edges: CaptureEdges, delta: CGPoint, within bounds: CGRect, pixelScale: CGFloat = 1) -> CGRect {
        var x1 = rect.minX, x2 = rect.maxX, y1 = rect.minY, y2 = rect.maxY
        let minWidth = min(32, rect.width), minHeight = min(32, rect.height)
        func aligned(_ value: CGFloat) -> CGFloat { (value * pixelScale).rounded() / pixelScale }
        if edges.contains(.left) { x1 = min(x2 - minWidth, max(bounds.minX, aligned(x1 + delta.x))) }
        if edges.contains(.right) { x2 = max(x1 + minWidth, min(bounds.maxX, aligned(x2 + delta.x))) }
        if edges.contains(.bottom) { y1 = min(y2 - minHeight, max(bounds.minY, aligned(y1 + delta.y))) }
        if edges.contains(.top) { y2 = max(y1 + minHeight, min(bounds.maxY, aligned(y2 + delta.y))) }
        return CGRect(x: x1, y: y1, width: x2 - x1, height: y2 - y1)
    }
}

/// 只命中选区边缘，内部鼠标事件交给画布；手柄不参与图片导出。
final class ResizeHandles: NSView {
    var enabled = false { didSet { needsDisplay = true; window?.invalidateCursorRects(for: self) } }
    var began: ((CaptureEdges, CGPoint) -> Void)?
    var moved: ((CGPoint) -> Void)?
    var ended: (() -> Void)?
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return enabled && !CaptureResizeGeometry.edges(at: local, in: bounds).isEmpty ? self : nil
    }
    override func resetCursorRects() {
        guard enabled else { return }
        addCursorRect(CGRect(x: 0, y: 0, width: 7, height: bounds.height), cursor: .resizeLeftRight)
        addCursorRect(CGRect(x: max(0, bounds.width - 7), y: 0, width: 7, height: bounds.height), cursor: .resizeLeftRight)
        addCursorRect(CGRect(x: 0, y: 0, width: bounds.width, height: 7), cursor: .resizeUpDown)
        addCursorRect(CGRect(x: 0, y: max(0, bounds.height - 7), width: bounds.width, height: 7), cursor: .resizeUpDown)
    }
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let point = convert(event.locationInWindow, from: nil)
        began?(CaptureResizeGeometry.edges(at: point, in: bounds), window.convertPoint(toScreen: event.locationInWindow))
    }
    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        moved?(window.convertPoint(toScreen: event.locationInWindow))
    }
    override func mouseUp(with event: NSEvent) { mouseDragged(with: event); ended?() }
    override func draw(_ dirtyRect: NSRect) {
        guard enabled else { return }
        for x in [CGFloat(4), bounds.midX, bounds.maxX - 4] {
            for y in [CGFloat(4), bounds.midY, bounds.maxY - 4] {
                if x == bounds.midX && y == bounds.midY { continue }
                let handle = NSBezierPath(rect: CGRect(x: x - 3, y: y - 3, width: 6, height: 6))
                NSColor.white.setFill(); handle.fill(); NSColor.systemTeal.setStroke(); handle.lineWidth = 1; handle.stroke()
            }
        }
    }
}
