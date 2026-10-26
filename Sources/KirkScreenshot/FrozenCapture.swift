import AppKit

struct FrozenCaptureTile {
    let region: CGRect
    let image: CGImage
    var scale: CGFloat { CGFloat(image.width) / region.width }
}

/// 保留首次拍下的画面，扩选时裁取同一批像素，不重新捕获已变化的桌面。
struct FrozenCapture {
    let tiles: [FrozenCaptureTile]
    let bounds: CGRect
    let scale: CGFloat
    let limitsExpansion: Bool
    init(tiles: [FrozenCaptureTile], limitsExpansion: Bool = false) {
        self.tiles = tiles
        bounds = tiles.reduce(CGRect.null) { $0.union($1.region) }
        scale = tiles.map(\.scale).max() ?? 1
        self.limitsExpansion = limitsExpansion
    }
    func crop(_ region: CGRect) -> CGImage? {
        guard !region.isEmpty, bounds.contains(region), tiles.contains(where: { $0.region.intersects(region) }) else { return nil }
        let w = (region.width * scale).rounded(), h = (region.height * scale).rounded()
        guard w.isFinite, h.isFinite, w > 0, h > 0, w * h <= 40_000_000 else { return nil }
        func pixels(_ part: CGRect, in tile: FrozenCaptureTile) -> CGRect {
            CGRect(x: (part.minX - tile.region.minX) * tile.scale, y: (tile.region.maxY - part.maxY) * tile.scale,
                   width: part.width * tile.scale, height: part.height * tile.scale).integral
        }
        if tiles.count == 1, let tile = tiles.first, tile.region.contains(region) {
            return tile.image.cropping(to: pixels(region, in: tile))
        }
        guard let context = CGContext(data: nil, width: Int(w), height: Int(h), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .none
        for tile in tiles {
            let part = tile.region.intersection(region)
            guard !part.isEmpty, !part.isNull, let image = tile.image.cropping(to: pixels(part, in: tile)) else { continue }
            context.draw(image, in: CGRect(x: (part.minX - region.minX) * scale, y: (part.minY - region.minY) * scale,
                                          width: part.width * scale, height: part.height * scale))
        }
        return context.makeImage()
    }
}

extension MacCaptureProvider {
    func frozenCapture(containing region: CGRect) async throws -> FrozenCapture {
        let all = NSScreen.screens
        func pixelCount(_ screens: [NSScreen]) -> CGFloat {
            screens.reduce(CGFloat(0)) { $0 + $1.frame.width * $1.frame.height * $1.backingScaleFactor * $1.backingScaleFactor }
        }
        let screens = pixelCount(all) <= 40_000_000 ? all : all.filter { $0.frame.intersects(region) }
        let pixels = pixelCount(screens)
        // 超大显示器组合仍可正常截图，但不为扩选保留无限大的整屏位图。
        if pixels > 40_000_000 {
            return FrozenCapture(tiles: [FrozenCaptureTile(region: region, image: try await capture(region))], limitsExpansion: true)
        }
        var tiles: [FrozenCaptureTile] = []
        for screen in screens { tiles.append(FrozenCaptureTile(region: screen.frame, image: try await capture(screen.frame))) }
        guard !tiles.isEmpty else { throw CaptureError.message("截图区域不在有效屏幕内") }
        return FrozenCapture(tiles: tiles, limitsExpansion: screens.count != all.count)
    }
}
