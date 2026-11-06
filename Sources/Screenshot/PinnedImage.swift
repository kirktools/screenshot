import AppKit

final class PinnedImageView: NSImageView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
}
final class PinnedImageWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) { close() }
    override func keyDown(with event: NSEvent) { if event.keyCode == 53 { close() } else { super.keyDown(with: event) } }
}

@MainActor final class PinnedImage: NSWindowController, NSWindowDelegate {
    private static var instances: [UUID: PinnedImage] = [:]
    static var diagnosticWindows: [NSWindow] { instances.values.compactMap(\.window) }
    private let id = UUID()
    private let byteCount: Int
    static func show(_ image: CGImage, near region: CGRect?) throws {
        let bytes = image.bytesPerRow * image.height
        guard instances.count < 10, instances.values.reduce(bytes, { $0 + $1.byteCount }) <= 256_000_000 else {
            throw CaptureError.message("贴图已达内存上限，请关闭一些贴图后再试")
        }
        let controller = PinnedImage(image: image, region: region)
        instances[controller.id] = controller; controller.showWindow(nil)
    }
    private init(image: CGImage, region: CGRect?) {
        byteCount = image.bytesPerRow * image.height
        let screen = NSScreen.screens.first { $0.frame.intersects(region ?? .zero) } ?? NSScreen.main!
        let available = screen.visibleFrame.insetBy(dx: 30, dy: 30)
        let scale = min(1, min(available.width / CGFloat(image.width), available.height / CGFloat(image.height)))
        let size = NSSize(width: max(80, CGFloat(image.width)*scale), height: max(60, CGFloat(image.height)*scale))
        let window = PinnedImageWindow(contentRect: CGRect(origin: CGPoint(x: available.midX-size.width/2, y: available.midY-size.height/2), size: size), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "贴图 · 拖动移动，拖边缩放"; window.level = .floating
        window.isReleasedWhenClosed = false; window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentAspectRatio = NSSize(width: image.width, height: image.height)
        window.minSize = NSSize(width: 80, height: 60)
        let view = PinnedImageView(); view.image = image.nsImage; view.imageScaling = .scaleProportionallyUpOrDown
        window.contentView = view; window.isMovableByWindowBackground = true
        super.init(window: window); window.delegate = self
    }
    required init?(coder: NSCoder) { fatalError() }
    func windowWillClose(_ notification: Notification) { Self.instances.removeValue(forKey: id) }
}
