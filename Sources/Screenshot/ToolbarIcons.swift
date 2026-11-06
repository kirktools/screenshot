import AppKit

extension CaptureIcons {
    /// 截图工具栏统一使用 24 pt 画布、1.8 pt 圆角描边与单色模板。
    /// 避免系统符号的字形度量与自绘图标混排产生尺寸和视觉重量差异。
    static func toolbar(_ name: String) -> NSImage? {
        let supported = ["rectangle", "circle", "arrow.up.right", "textbox", "square.grid.3x3.fill", "arrow.uturn.backward", "arrow.uturn.forward", "square.and.arrow.down", "pin", "xmark", "checkmark", "ellipsis", "chevron.down", "arrow.up.and.down", "crop", "video"]
        guard supported.contains(name) else { return nil }
        let image = NSImage(size: NSSize(width: 24, height: 24), flipped: false) { _ in
            NSColor.black.setStroke(); NSColor.black.setFill()
            func path(_ points: [CGPoint]) {
                guard let first = points.first else { return }
                let p = NSBezierPath(); p.lineWidth = 1.8; p.lineCapStyle = .round; p.lineJoinStyle = .round
                p.move(to: first); points.dropFirst().forEach { p.line(to: $0) }; p.stroke()
            }
            func roundedRect(_ rect: CGRect) {
                let p = NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5); p.lineWidth = 1.8; p.stroke()
            }
            switch name {
            case "rectangle": roundedRect(CGRect(x: 3, y: 4, width: 18, height: 16))
            case "circle":
                let p = NSBezierPath(ovalIn: CGRect(x: 3, y: 3, width: 18, height: 18)); p.lineWidth = 1.8; p.stroke()
            case "arrow.up.right":
                path([CGPoint(x: 4, y: 4), CGPoint(x: 20, y: 20)])
                path([CGPoint(x: 9, y: 20), CGPoint(x: 20, y: 20), CGPoint(x: 20, y: 9)])
            case "textbox":
                roundedRect(CGRect(x: 3, y: 3, width: 18, height: 18))
                path([CGPoint(x: 7, y: 16), CGPoint(x: 17, y: 16)])
                path([CGPoint(x: 12, y: 16), CGPoint(x: 12, y: 7)])
            case "square.grid.3x3.fill":
                roundedRect(CGRect(x: 3, y: 3, width: 18, height: 18))
                // 留出外轮廓与内部的间距，棋盘块保持与其他图标一致的单色视觉重量。
                for y in 0..<3 { for x in 0..<3 where (x+y) % 2 == 0 {
                    CGRect(x: CGFloat(6+x*4), y: CGFloat(6+y*4), width: 4, height: 4).fill()
                } }
            case "arrow.uturn.backward", "arrow.uturn.forward":
                NSGraphicsContext.saveGraphicsState()
                if name == "arrow.uturn.forward" {
                    let t = NSAffineTransform(); t.translateX(by: 24, yBy: 0); t.scaleX(by: -1, yBy: 1); t.concat()
                }
                let p = NSBezierPath(); p.lineWidth = 1.8; p.lineCapStyle = .round; p.lineJoinStyle = .round
                p.move(to: CGPoint(x: 4, y: 16)); p.line(to: CGPoint(x: 14, y: 16))
                p.curve(to: CGPoint(x: 14, y: 5), controlPoint1: CGPoint(x: 23, y: 16), controlPoint2: CGPoint(x: 23, y: 5))
                p.line(to: CGPoint(x: 10, y: 5)); p.stroke()
                path([CGPoint(x: 9, y: 21), CGPoint(x: 4, y: 16), CGPoint(x: 9, y: 11)])
                NSGraphicsContext.restoreGraphicsState()
            case "square.and.arrow.down":
                path([CGPoint(x: 4, y: 13), CGPoint(x: 4, y: 4), CGPoint(x: 20, y: 4), CGPoint(x: 20, y: 13)])
                path([CGPoint(x: 12, y: 22), CGPoint(x: 12, y: 9)])
                path([CGPoint(x: 8, y: 13), CGPoint(x: 12, y: 9), CGPoint(x: 16, y: 13)])
            case "pin":
                path([CGPoint(x: 7, y: 21), CGPoint(x: 17, y: 21), CGPoint(x: 15, y: 18), CGPoint(x: 15, y: 13), CGPoint(x: 18, y: 9), CGPoint(x: 6, y: 9), CGPoint(x: 9, y: 13), CGPoint(x: 9, y: 18), CGPoint(x: 7, y: 21)])
                path([CGPoint(x: 12, y: 9), CGPoint(x: 12, y: 3)])
            case "xmark":
                path([CGPoint(x: 5, y: 5), CGPoint(x: 19, y: 19)])
                path([CGPoint(x: 5, y: 19), CGPoint(x: 19, y: 5)])
            case "checkmark": path([CGPoint(x: 3, y: 12), CGPoint(x: 10, y: 5), CGPoint(x: 21, y: 19)])
            case "ellipsis":
                for x in [5, 12, 19] { NSBezierPath(ovalIn: CGRect(x: CGFloat(x)-1.2, y: 10.8, width: 2.4, height: 2.4)).fill() }
            case "chevron.down": path([CGPoint(x: 9, y: 13.5), CGPoint(x: 12, y: 10.5), CGPoint(x: 15, y: 13.5)])
            case "arrow.up.and.down":
                path([CGPoint(x: 4, y: 16), CGPoint(x: 4, y: 21), CGPoint(x: 20, y: 21), CGPoint(x: 20, y: 16)])
                path([CGPoint(x: 4, y: 8), CGPoint(x: 4, y: 3), CGPoint(x: 20, y: 3), CGPoint(x: 20, y: 8)])
                path([CGPoint(x: 4, y: 11), CGPoint(x: 4, y: 13)])
                path([CGPoint(x: 20, y: 11), CGPoint(x: 20, y: 13)])
                path([CGPoint(x: 12, y: 6), CGPoint(x: 12, y: 18)])
                path([CGPoint(x: 9, y: 15), CGPoint(x: 12, y: 18), CGPoint(x: 15, y: 15)])
                path([CGPoint(x: 9, y: 9), CGPoint(x: 12, y: 6), CGPoint(x: 15, y: 9)])
            case "video":
                roundedRect(CGRect(x: 3, y: 6, width: 13, height: 12))
                path([CGPoint(x: 16, y: 14), CGPoint(x: 21, y: 18), CGPoint(x: 21, y: 6), CGPoint(x: 16, y: 10)])
            case "crop":
                path([CGPoint(x: 7, y: 22), CGPoint(x: 7, y: 7), CGPoint(x: 22, y: 7)])
                path([CGPoint(x: 2, y: 17), CGPoint(x: 17, y: 17), CGPoint(x: 17, y: 2)])
            default: break
            }
            return true
        }
        image.isTemplate = true; image.accessibilityDescription = name
        return image
    }
}
