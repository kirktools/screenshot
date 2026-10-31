import AppKit

enum CaptureIcons {
    /// 选区的四角与纵向双箭头表示延长捕获；避免使用与保存/下载相同的单向向下箭头。
    static var scrollCapture: NSImage {
        let image = NSImage(size: NSSize(width: 22, height: 22), flipped: false) { _ in
            NSColor.labelColor.setStroke()
            let path = NSBezierPath(); path.lineWidth = 1.6; path.lineCapStyle = .round; path.lineJoinStyle = .round
            // 完整的细长截图框；侧边断开表示画面还可纵向延伸，而不是下载托盘。
            path.move(to: NSPoint(x: 4, y: 6)); path.line(to: NSPoint(x: 4, y: 2))
            path.line(to: NSPoint(x: 18, y: 2)); path.line(to: NSPoint(x: 18, y: 6))
            path.move(to: NSPoint(x: 4, y: 16)); path.line(to: NSPoint(x: 4, y: 20))
            path.line(to: NSPoint(x: 18, y: 20)); path.line(to: NSPoint(x: 18, y: 16))
            for x in [4.0, 18.0] {
                path.move(to: NSPoint(x: x, y: 9)); path.line(to: NSPoint(x: x, y: 13))
            }
            path.move(to: NSPoint(x: 11, y: 6)); path.line(to: NSPoint(x: 11, y: 16))
            path.move(to: NSPoint(x: 8.5, y: 13.5)); path.line(to: NSPoint(x: 11, y: 16)); path.line(to: NSPoint(x: 13.5, y: 13.5))
            path.move(to: NSPoint(x: 8.5, y: 8.5)); path.line(to: NSPoint(x: 11, y: 6)); path.line(to: NSPoint(x: 13.5, y: 8.5))
            path.stroke(); return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "滚动长截图"
        return image
    }
}
