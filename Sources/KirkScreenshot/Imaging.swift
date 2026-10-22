import AppKit
import ScreenCaptureKit
import StitchCore
import ImageIO
import UniformTypeIdentifiers

extension CGImage {
    var nsImage: NSImage { NSImage(cgImage: self, size: NSSize(width: width, height: height)) }
    func grayFrame() -> GrayFrame {
        let w = min(128, width), h = height
        var bytes = [UInt8](repeating: 0, count: w * h)
        bytes.withUnsafeMutableBytes { buffer in
            let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)!
            ctx.interpolationQuality = .low
            ctx.draw(self, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return GrayFrame(width: w, height: h, pixels: bytes, sourceWidth: width)
    }
    func png() throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw CaptureError.message("无法创建 PNG") }
        CGImageDestinationAddImage(dest, self, nil)
        guard CGImageDestinationFinalize(dest) else { throw CaptureError.message("PNG 编码失败") }
        return data as Data
    }
}

enum CaptureError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}

/// UI 和平台采集分离；Windows 实现应提供相同的区域捕获语义。
@MainActor protocol RegionCaptureProvider {
    func prepare() async throws
    func capture(_ region: CGRect) async throws -> CGImage
}

@MainActor final class MacCaptureProvider: RegionCaptureProvider {
    private var content: SCShareableContent?
    private var screenSnapshot: [CGDirectDisplayID: CGRect] = [:]
    func prepare() async throws {
        content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        screenSnapshot = Dictionary(uniqueKeysWithValues: NSScreen.screens.compactMap { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return nil }
            return (id, screen.frame)
        })
    }
    func capture(_ region: CGRect) async throws -> CGImage {
        guard let content else { throw CaptureError.message("屏幕采集尚未准备好") }
        let screens = NSScreen.screens.filter { $0.frame.intersects(region) }
        guard !screens.isEmpty else { throw CaptureError.message("截图区域不在有效屏幕内") }
        let scale = screens.map(\.backingScaleFactor).max() ?? 1
        let width = Int((region.width * scale).rounded()), height = Int((region.height * scale).rounded())
        guard width > 0, height > 0, width * height <= 40_000_000,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CaptureError.message("截图区域过大，或内存不足，请缩小区域")
        }
        // 跨屏空隙透明；低分辨率屏幕按最高 backingScale 归一化。
        let excluded = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        for screen in screens {
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                  screenSnapshot[id] == screen.frame,
                  let display = content.displays.first(where: { $0.displayID == id }) else {
                throw CaptureError.message("显示器布局已改变，请重新框选")
            }
            let part = screen.frame.intersection(region)
            let config = SCStreamConfiguration()
            config.sourceRect = CGRect(x: part.minX - screen.frame.minX, y: screen.frame.maxY - part.maxY, width: part.width, height: part.height)
            config.width = Int((part.width * scale).rounded()); config.height = Int((part.height * scale).rounded())
            config.showsCursor = false; config.scalesToFit = true
            let filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
            let shot = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            ctx.draw(shot, in: CGRect(x: (part.minX - region.minX) * scale, y: (part.minY - region.minY) * scale,
                                     width: part.width * scale, height: part.height * scale))
        }
        guard let image = ctx.makeImage() else { throw CaptureError.message("无法生成截图") }
        return image
    }
}

struct StitchPiece {
    let image: CGImage
    let addedRows: Int
    let frame: GrayFrame
}

func compose(_ pieces: [StitchPiece]) -> CGImage? {
    guard let first = pieces.first else { return nil }
    let height = pieces.reduce(0) { $0 + $1.addedRows }
    guard height <= 30_000, height * first.image.width <= 32_000_000,
          let ctx = CGContext(data: nil, width: first.image.width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    var top = 0
    for piece in pieces {
        guard let strip = piece.image.cropping(to: CGRect(x: 0, y: piece.image.height - piece.addedRows, width: piece.image.width, height: piece.addedRows)) else { return nil }
        ctx.draw(strip, in: CGRect(x: 0, y: height - top - piece.addedRows, width: strip.width, height: strip.height))
        top += piece.addedRows
    }
    return ctx.makeImage()
}
