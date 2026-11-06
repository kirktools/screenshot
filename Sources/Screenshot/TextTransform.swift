import AppKit

/// 图片像素坐标下的文字变换；缩放和旋转都保持视觉中心不动。
struct TextTransformGesture {
    enum Mode { case scale, rotate }
    let original: Annotation
    let pointer: CGPoint
    let mode: Mode
    var center: CGPoint { original.textPoint(CGPoint(x: original.textSize.width / 2, y: original.textSize.height / 2)) }
    func annotation(at point: CGPoint) -> Annotation {
        let pivot = center
        let a = CGPoint(x: pointer.x - pivot.x, y: pointer.y - pivot.y)
        let b = CGPoint(x: point.x - pivot.x, y: point.y - pivot.y)
        var result = original
        switch mode {
        case .scale:
            result.fontSize = min(300, max(8, original.fontSize * hypot(b.x, b.y) / max(1, hypot(a.x, a.y))))
        case .rotate:
            let delta = atan2(b.y, b.x) - atan2(a.y, a.x)
            result.rotation = original.rotation + atan2(sin(delta), cos(delta)) * 180 / .pi
        }
        let half = result.textSize, angle = result.rotation * .pi / 180
        result.start = CGPoint(x: pivot.x - half.width/2*cos(angle) + half.height/2*sin(angle),
                               y: pivot.y - half.width/2*sin(angle) - half.height/2*cos(angle))
        result.end = result.start
        return result
    }
}
extension Annotation {
    func textPoint(_ point: CGPoint) -> CGPoint {
        let angle = rotation * .pi / 180
        return CGPoint(x: start.x + point.x*cos(angle) - point.y*sin(angle), y: start.y + point.x*sin(angle) + point.y*cos(angle))
    }
    func textHandlePoints(zoom: CGFloat) -> [CGPoint] {
        let size = textSize, gap = 24 / max(zoom, 0.01)
        return [CGPoint(x: -4, y: -4), CGPoint(x: size.width+4, y: -4), CGPoint(x: -4, y: size.height+4), CGPoint(x: size.width+4, y: size.height+4), CGPoint(x: size.width/2, y: -gap)].map(textPoint)
    }
}
