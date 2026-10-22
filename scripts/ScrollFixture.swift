import AppKit

/// 只绘制测试页面的独立进程。供真实 ScreenCaptureKit 连续采集回归，不读取桌面。
final class DocumentView: NSView {
    let image: NSImage
    override var isFlipped: Bool { true }
    init(image: NSImage, size: NSSize) { self.image = image; super.init(frame: CGRect(origin: .zero, size: size)) }
    required init?(coder: NSCoder) { fatalError("不支持归档") }
    override func draw(_ dirtyRect: NSRect) {
        image.draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.none])
    }
}
final class Delegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var timer: Timer?
    var position = 0
    let directory = URL(fileURLWithPath: CommandLine.arguments[1])
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let screen = NSScreen.screens.first!
        let viewportWidth = min(756.0, screen.visibleFrame.width - 80)
        let viewportHeight = min(450.0, screen.visibleFrame.height - 80)
        let scale = screen.backingScaleFactor, width = Int(viewportWidth * scale), height = Int(2000 * scale)
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            // 高对比度、非周期的文档纹理，固定像素参考可检验缺行与翻转。
            var v = UInt64((y / 3) * width + x / 3 + 1) &* 0x9E3779B97F4A7C15
            v = (v ^ (v >> 30)) &* 0xBF58476D1CE4E5B9
            let i = (y * width + x) * 4
            let value = UInt8(truncatingIfNeeded: v ^ (v >> 27))
            pixels[i] = value; pixels[i + 1] = value; pixels[i + 2] = value
        } }
        let cg = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                         provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let bitmap = NSBitmapImageRep(cgImage: cg)
        try! bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("reference.png"))
        window = NSWindow(contentRect: CGRect(x: screen.visibleFrame.minX + 40, y: screen.visibleFrame.minY + 40, width: viewportWidth, height: viewportHeight),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.title = "Kirk 连续滚动测试页面"; window.isReleasedWhenClosed = false
        window.level = .floating; window.hasShadow = false
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: viewportWidth, height: viewportHeight))
        scroll.borderType = .noBorder; scroll.hasVerticalScroller = false; scroll.hasHorizontalScroller = false
        scroll.automaticallyAdjustsContentInsets = false; scroll.contentInsets = .init()
        scroll.documentView = DocumentView(image: NSImage(cgImage: cg, size: NSSize(width: viewportWidth, height: 2000)), size: NSSize(width: viewportWidth, height: 2000))
        window.contentView = scroll
        scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView)
        window.orderFrontRegardless(); window.displayIfNeeded()
        let rect = window.convertToScreen(scroll.convert(scroll.bounds, to: nil))
        let info: [String: Double] = ["x": rect.minX, "y": rect.minY, "width": rect.width, "height": rect.height, "scale": scale, "offset": 300 * scale]
        try! JSONSerialization.data(withJSONObject: info).write(to: directory.appendingPathComponent("ready.json"), options: .atomic)
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            guard let self, FileManager.default.fileExists(atPath: self.directory.appendingPathComponent("go").path), self.position < 300 else { return }
            self.position += 5
            scroll.contentView.scroll(to: CGPoint(x: 0, y: self.position)); scroll.reflectScrolledClipView(scroll.contentView)
            scroll.displayIfNeeded()
        }
    }
}
let app = NSApplication.shared
let delegate = Delegate()
app.delegate = delegate
app.run()
