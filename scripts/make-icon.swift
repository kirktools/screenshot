import CoreGraphics
import Foundation
import CoreText
import ImageIO
import UniformTypeIdentifiers

// 可复现的原生矢量图形，无第三方图像素材。
let directory = CommandLine.arguments[1]
let development = CommandLine.arguments.contains("--development")
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
        if development {
            // 小尺寸用 D，大尺寸用 DEV，保持 Finder、Dock 中的角标可辨认。
            let compact = size <= 32
            let badge = CGRect(x: compact ? 596 : 516, y: 110, width: compact ? 292 : 382, height: compact ? 292 : 194)
            ctx.addPath(CGPath(roundedRect: badge, cornerWidth: 54, cornerHeight: 54, transform: nil))
            ctx.setFillColor(CGColor(srgbRed: 0.98, green: 0.47, blue: 0.06, alpha: 1)); ctx.fillPath()
            ctx.addPath(CGPath(roundedRect: badge.insetBy(dx: 4, dy: 4), cornerWidth: 50, cornerHeight: 50, transform: nil))
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.9)); ctx.setLineWidth(12); ctx.strokePath()
            let font = CTFontCreateWithName("Helvetica-Bold" as CFString, compact ? 220 : 136, nil)
            let text = CFAttributedStringCreate(nil, (compact ? "D" : "DEV") as CFString,
                [kCTFontAttributeName: font, kCTForegroundColorAttributeName: CGColor(gray: 1, alpha: 1)] as CFDictionary)!
            let line = CTLineCreateWithAttributedString(text)
            let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
            ctx.textMatrix = .identity
            ctx.textPosition = CGPoint(x: badge.midX - bounds.midX, y: badge.midY - bounds.midY)
            CTLineDraw(line, ctx)
        }
        let name = "icon_\(base)x\(base)\(retina ? "@2x" : "").png"
        let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        guard CGImageDestinationFinalize(dest) else { fatalError("图标 PNG 写入失败") }
    }
}
