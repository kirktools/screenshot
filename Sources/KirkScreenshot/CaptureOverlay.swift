import AppKit

/// 统一使用屏幕点坐标，工具栏优先避开选区；屏幕边缘时夹在可见范围。
enum CaptureLayout {
    static func toolbar(near region: CGRect, size: CGSize, within bounds: CGRect) -> CGRect {
        let x = min(max(region.midX - size.width / 2, bounds.minX + 8), bounds.maxX - size.width - 8)
        let below = region.minY - size.height - 10
        let y: CGFloat
        if below >= bounds.minY + 8 { y = below }
        else if region.maxY + 10 + size.height <= bounds.maxY - 8 { y = region.maxY + 10 }
        else { y = bounds.minY + 8 }
        return CGRect(x: max(bounds.minX, x), y: y, width: size.width, height: size.height)
    }
}

final class CaptureBorderView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemTeal.setStroke()
        let line = NSBezierPath(rect: bounds.insetBy(dx: 2, dy: 2))
        line.lineWidth = 2; line.stroke()
    }
}

/// 边框本身完全不接收鼠标与滚轮。整个本应用由 ScreenCaptureKit 排除。
@MainActor final class CaptureBoundary {
    let window: NSPanel
    init(region: CGRect) {
        window = PassivePanel(contentRect: region.insetBy(dx: -4, dy: -4), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.level = .screenSaver; window.backgroundColor = .clear; window.isOpaque = false
        window.hasShadow = false; window.ignoresMouseEvents = true; window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = CaptureBorderView(frame: CGRect(origin: .zero, size: window.frame.size))
    }
    func show() { window.orderFrontRegardless() }
    func close() { window.orderOut(nil); window.close() }
}

final class EditorCaptureWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class EditorBackdrop: NSView {
    var cancel: (() -> Void)?
    var frozenCapture: FrozenCapture?
    override func draw(_ dirtyRect: NSRect) {
        if let screenFrame = window?.frame {
            for tile in frozenCapture?.tiles ?? [] {
                tile.image.nsImage.draw(in: tile.region.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY))
            }
        }
        NSColor.black.withAlphaComponent(0.32).setFill(); bounds.fill()
    }
    override func mouseDown(with event: NSEvent) { NSSound.beep() }
}

@MainActor func captureToolbar(views: [NSView]) -> NSView {
    let material = NSVisualEffectView()
    material.material = .hudWindow; material.blendingMode = .behindWindow; material.state = .active
    material.wantsLayer = true; material.layer?.cornerRadius = 12; material.layer?.masksToBounds = true
    let row = NSStackView(views: views); row.spacing = 8; row.alignment = .centerY
    row.translatesAutoresizingMaskIntoConstraints = false; material.addSubview(row)
    NSLayoutConstraint.activate([row.leadingAnchor.constraint(equalTo: material.leadingAnchor, constant: 12), row.trailingAnchor.constraint(equalTo: material.trailingAnchor, constant: -12), row.topAnchor.constraint(equalTo: material.topAnchor, constant: 10), row.bottomAnchor.constraint(equalTo: material.bottomAnchor, constant: -10)])
    return material
}
