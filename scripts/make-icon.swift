import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// 可复现的原生矢量图形，无第三方图像素材。
let directory = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for retina in [false, true] {
        let size = retina ? base * 2 : base
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
        ctx.addPath(CGPath(roundedRect: CGRect(x: 70, y: 70, width: 884, height: 884), cornerWidth: 204, cornerHeight: 204, transform: nil)); ctx.clip()
        let colors = [CGColor(srgbRed: 0.06, green: 0.30, blue: 0.44, alpha: 1), CGColor(srgbRed: 0.02, green: 0.68, blue: 0.68, alpha: 1)] as CFArray
        ctx.drawLinearGradient(CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])!, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 900, y: 1024), options: [])
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 1)); ctx.setLineWidth(52); ctx.setLineCap(.round); ctx.setLineJoin(.round)
        for (x, y, dx, dy) in [(270.0, 270.0, 1.0, 1.0), (754, 270, -1, 1), (270, 754, 1, -1), (754, 754, -1, -1)] {
            ctx.move(to: CGPoint(x: x + dx * 125, y: y)); ctx.addLine(to: CGPoint(x: x, y: y)); ctx.addLine(to: CGPoint(x: x, y: y + dy * 125)); ctx.strokePath()
        }
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.95)); ctx.fillEllipse(in: CGRect(x: 465, y: 465, width: 94, height: 94))
        let name = "icon_\(base)x\(base)\(retina ? "@2x" : "").png"
        let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        guard CGImageDestinationFinalize(dest) else { fatalError("图标 PNG 写入失败") }
    }
}
