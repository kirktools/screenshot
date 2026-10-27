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
    var position = 0.0
    let directory = URL(fileURLWithPath: CommandLine.arguments[1])
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let screen = NSScreen.screens.first!
        let viewportWidth = min(756.0, screen.visibleFrame.width - 80)
        let requestedHeight = Double(ProcessInfo.processInfo.environment["SCREENSHOT_SCROLL_FIXTURE_HEIGHT"] ?? "450") ?? 450
        let viewportHeight = min(max(100, requestedHeight), screen.visibleFrame.height - 80)
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
        var cg = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                         provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let showcase = ProcessInfo.processInfo.environment["SCREENSHOT_SCROLL_FIXTURE_STYLE"] == "showcase"
        if showcase || ProcessInfo.processInfo.environment["SCREENSHOT_SCROLL_FIXTURE_STYLE"] == "dark-text" {
            let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(CGColor(gray: 0.09, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            for line in 0..<65 {
                let top = CGFloat(line * 57 + 35) * scale
                if line % 7 == 4 {
                    NSColor(calibratedRed: 0.12, green: 0.3, blue: 0.56, alpha: 1).setFill()
                    NSBezierPath(roundedRect: CGRect(x: 170 * scale, y: CGFloat(height) - top - 38 * scale, width: CGFloat(width) - 205 * scale, height: 46 * scale), xRadius: 12 * scale, yRadius: 12 * scale).fill()
                }
                let showcaseLines = ["Screenshot", "把截图变成一件顺手的小事。", "01  随时唤起", "菜单栏常驻，按下快捷键就能开始。", "不用先打开微信，也不用切换应用。", "02  连续滚动", "框选正文，像平时一样向下滚动。", "自动捕获与拼接，预览一直看得见。", "03  复制就走", "回车直接复制，需要时再编辑。", "保存 PNG，把完整内容分享出去。", "04  内容留在本机", "无需注册，不上传截图。", "默认中文，使用原生 macOS 控件。", "05  少一点打扰", "正常滚动保持安静，出错再提示。"]
                let text = showcase ? showcaseLines[line % showcaseLines.count] : ["第 \(line) 段：连续滚动，保留文字与段落间距。", "• ScreenCaptureKit 测试 \(line * 7919)，浅色细字 / dark theme", "收到消息 \(line)：正文较短。", "let offset = \(line * 37);  // 不应重复，也不应缺行"] [line % 4]
                (text as NSString).draw(at: CGPoint(x: CGFloat(line % 7 == 4 ? 190 : 30) * scale, y: CGFloat(height) - top - 24 * scale),
                    withAttributes: [.font: NSFont.systemFont(ofSize: 15 * scale), .foregroundColor: NSColor(calibratedWhite: 0.86, alpha: 1)])
            }
            NSGraphicsContext.restoreGraphicsState()
            cg = ctx.makeImage()!
        }
        let bitmap = NSBitmapImageRep(cgImage: cg)
        try! bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("reference.png"))
        window = NSWindow(contentRect: CGRect(x: screen.visibleFrame.minX + 40, y: screen.visibleFrame.minY + 40, width: viewportWidth, height: viewportHeight),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.title = "Screenshot 连续滚动测试页面"; window.isReleasedWhenClosed = false
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
            self.position = min(300, self.position + (ProcessInfo.processInfo.environment["SCREENSHOT_SCROLL_FIXTURE_STYLE"] != nil ? 2.35 : 5))
            scroll.contentView.scroll(to: CGPoint(x: 0, y: self.position)); scroll.reflectScrolledClipView(scroll.contentView)
            scroll.displayIfNeeded()
            let progress: [String: Double] = ["position": self.position, "origin": scroll.contentView.bounds.origin.y]
            if let data = try? JSONSerialization.data(withJSONObject: progress) {
                try? data.write(to: self.directory.appendingPathComponent("progress.json"), options: .atomic)
            }
        }
    }
}
let app = NSApplication.shared
let delegate = Delegate()
app.delegate = delegate
app.run()
