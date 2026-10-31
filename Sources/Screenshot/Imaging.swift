import AppKit
import ScreenCaptureKit
import StitchCore
import ImageIO
import UniformTypeIdentifiers
import CoreMedia
import CoreVideo

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
    @MainActor func copyPNG(to board: NSPasteboard = .general) throws {
        let data = try png()
        board.clearContents()
        guard board.setData(data, forType: .png) else { throw CaptureError.message("写入剪贴板失败") }
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
    func makeStream(_ region: CGRect) async throws -> any RegionFrameStream
}

@MainActor final class MacCaptureProvider: RegionCaptureProvider {
    // 仅缓存显示器/应用元数据，不缓存屏幕像素、不后台采集。
    // 连续截图复用短期有效的枚举结果，省去每次重新枚举窗口的等待。
    private static var recentContent: (value: SCShareableContent, layout: String, time: Double)?
    private static var layout: String {
        NSScreen.screens.map { "\($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] ?? ""):\($0.frame):\($0.backingScaleFactor)" }.joined(separator: ";")
    }
    static func invalidateSelectionContent() { recentContent = nil }
    func prepareForSelection() async throws {
        let now = ProcessInfo.processInfo.systemUptime
        if let cached = Self.recentContent, cached.layout == Self.layout, now - cached.time < 30 {
            content = cached.value
            screenSnapshot = Dictionary(uniqueKeysWithValues: NSScreen.screens.compactMap { screen in
                guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return nil }
                return (id, screen.frame)
            })
            return
        }
        try await prepare()
    }
    private var content: SCShareableContent?
    private var screenSnapshot: [CGDirectDisplayID: CGRect] = [:]
    func prepare() async throws {
        content = nil
        let available = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard !available.displays.isEmpty else {
            throw CaptureError.message("当前没有可捕获的显示器。请确认屏幕已解锁并点亮、录屏权限有效，再重新开始。")
        }
        content = available
        Self.recentContent = (available, Self.layout, ProcessInfo.processInfo.systemUptime)
        screenSnapshot = Dictionary(uniqueKeysWithValues: NSScreen.screens.compactMap { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return nil }
            return (id, screen.frame)
        })
    }
    func makeStream(_ region: CGRect) async throws -> any RegionFrameStream {
        // 选框和状态面板已经显示后再取应用列表。prepare 时本应用可能还没有可见窗口，
        // 复用旧列表会漏掉自身，从而把新出现的边框/面板截进首帧。
        let latest = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard content != nil, let screen = NSScreen.screens.first(where: { $0.frame.contains(region) }),
              let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              screenSnapshot[id] == screen.frame,
              let display = latest.displays.first(where: { $0.displayID == id }) else {
            throw CaptureError.message("长截图需要同一显示器内的有效选区；显示器布局改变后请重新框选")
        }
        let scale = screen.backingScaleFactor
        let config = SCStreamConfiguration()
        config.sourceRect = CGRect(x: region.minX - screen.frame.minX, y: screen.frame.maxY - region.maxY,
                                   width: region.width, height: region.height)
        config.width = Int((region.width * scale).rounded()); config.height = Int((region.height * scale).rounded())
        guard config.width > 0, config.height > 0, config.width * config.height <= 32_000_000 else {
            throw CaptureError.message("长截图区域过大，请缩小区域")
        }
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.queueDepth = 3; config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false; config.scalesToFit = true; config.capturesAudio = false
        config.colorSpaceName = CGColorSpace.sRGB
        let excluded = latest.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        return try MacRegionStream(filter: SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: []), configuration: config)
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

struct StitchPiece: @unchecked Sendable {
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

/// cropping 会共享原图存储，重新绘制后只保留新增条带，避免每次微小滚动保存整屏。
func copiedStrip(_ image: CGImage, rows: Int, fromTop: Bool = false) -> CGImage? {
    guard rows > 0, rows <= image.height,
          let crop = image.cropping(to: CGRect(x: 0, y: fromTop ? 0 : image.height - rows, width: image.width, height: rows)),
          let context = CGContext(data: nil, width: image.width, height: rows, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    context.draw(crop, in: CGRect(x: 0, y: 0, width: image.width, height: rows))
    return context.makeImage()
}
