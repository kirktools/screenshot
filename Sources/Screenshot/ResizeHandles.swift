import AppKit

struct CaptureEdges: OptionSet {
    let rawValue: Int
    static let left = CaptureEdges(rawValue: 1)
    static let right = CaptureEdges(rawValue: 2)
    static let bottom = CaptureEdges(rawValue: 4)
    static let top = CaptureEdges(rawValue: 8)
}

enum CaptureResizeCursor { case horizontal, vertical, northWestSouthEast, northEastSouthWest }

enum CaptureResizeGeometry {
    static func cursor(for edges: CaptureEdges) -> CaptureResizeCursor {
        if edges == [.left, .top] || edges == [.right, .bottom] { return .northWestSouthEast }
        if edges == [.left, .bottom] || edges == [.right, .top] { return .northEastSouthWest }
        return edges.contains(.left) || edges.contains(.right) ? .horizontal : .vertical
    }
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
    private static func diagonal(rising: Bool) -> NSCursor {
        let image = NSImage(size: NSSize(width: 24, height: 24), flipped: false) { _ in
            let start = CGPoint(x: 5, y: rising ? 5 : 19), end = CGPoint(x: 19, y: rising ? 19 : 5)
            let ux: CGFloat = 1 / sqrt(2), uy: CGFloat = rising ? ux : -ux
            let path = NSBezierPath(); path.move(to: start); path.line(to: end)
            for (point, direction) in [(start, CGFloat(1)), (end, CGFloat(-1))] {
                path.move(to: CGPoint(x: point.x + direction * ux * 5 - uy * 4, y: point.y + direction * uy * 5 + ux * 4))
                path.line(to: point)
                path.line(to: CGPoint(x: point.x + direction * ux * 5 + uy * 4, y: point.y + direction * uy * 5 - ux * 4))
            }
            path.lineCapStyle = .round; path.lineJoinStyle = .round
            NSColor.black.setStroke(); path.lineWidth = 4; path.stroke()
            NSColor.white.setStroke(); path.lineWidth = 2; path.stroke()
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: 12, y: 12))
    }
    private static let northwest = diagonal(rising: false)
    private static let northeast = diagonal(rising: true)
    override func resetCursorRects() {
        guard enabled else { return }
        let t = min(CGFloat(7), min(bounds.width, bounds.height) / 2)
        for x in [CGFloat(0), bounds.width - t] {
            addCursorRect(CGRect(x: x, y: t, width: t, height: max(0, bounds.height - 2 * t)), cursor: .resizeLeftRight)
        }
        for y in [CGFloat(0), bounds.height - t] {
            addCursorRect(CGRect(x: t, y: y, width: max(0, bounds.width - 2 * t), height: t), cursor: .resizeUpDown)
        }
        for x in [CGFloat(0), bounds.width - t] {
            for y in [CGFloat(0), bounds.height - t] {
                let rect = CGRect(x: x, y: y, width: t, height: t)
                let edges = CaptureResizeGeometry.edges(at: CGPoint(x: rect.midX, y: rect.midY), in: bounds)
                let cursor = CaptureResizeGeometry.cursor(for: edges) == .northWestSouthEast ? Self.northwest : Self.northeast
                addCursorRect(rect, cursor: cursor)
            }
        }
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
        CaptureOutline.draw(bounds.insetBy(dx: 2, dy: 2))
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
