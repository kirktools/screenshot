import Foundation

/// 平台无关的亮度帧。采样必须保持原始纵向像素，避免接缝量化误差。
public struct GrayFrame: Sendable {
    public let width: Int
    public let height: Int
    public let pixels: [UInt8]
    public let sourceWidth: Int
    public init(width: Int, height: Int, pixels: [UInt8], sourceWidth: Int? = nil) {
        precondition(width > 0 && height > 0 && pixels.count == width * height)
        self.width = width; self.height = height; self.pixels = pixels
        self.sourceWidth = sourceWidth ?? width
    }
}

public enum MatchResult: Equatable, Sendable {
    case duplicate
    case append(rows: Int)
    case reverse
    case incompatibleSize
    case insufficientOverlap
    case ambiguous
    case changedContent
}

public struct StitchMatcher: Sendable {
    public init() {}
    public func difference(_ a: GrayFrame, _ b: GrayFrame) -> Double {
        guard a.width == b.width, a.height == b.height, a.sourceWidth == b.sourceWidth else { return 255 }
        return error(a, b, shift: 0)
    }
    public func match(previous a: GrayFrame, next b: GrayFrame) -> MatchResult {
        guard a.width == b.width, a.height == b.height, a.sourceWidth == b.sourceWidth else { return .incompatibleSize }
        guard a.height >= 80, a.width >= 16 else { return .insufficientOverlap }
        if difference(a, b) < 0.6 { return .duplicate }
        let limit = Int(Double(a.height) * 0.78)
        // 按原始纵向像素搜索，横向/逐行抽样限制 CPU，避免粗搜漏掉细纹理。
        let step = 1
        var coarse: [(Int, Double)] = []
        for shift in stride(from: -limit, through: limit, by: step) where abs(shift) >= 1 {
            coarse.append((shift, error(a, b, shift: shift)))
        }
        let seeds = coarse.sorted { $0.1 < $1.1 }.prefix(8)
        var candidates: [Int: Double] = [:]
        for (seed, _) in seeds {
            for d in max(-limit, seed - step)...min(limit, seed + step) where abs(d) >= 1 {
                candidates[d] = error(a, b, shift: d)
            }
        }
        let ranked = candidates.sorted { $0.value < $1.value }
        guard let best = ranked.first else { return .insufficientOverlap }
        guard best.value < 3.0 else { return .insufficientOverlap }
        // 周期性内容可能出现多个同样好的位移；保守拒绝，而不是猜。
        if ranked.contains(where: { abs($0.key - best.key) > max(4, step * 2) && $0.value < best.value + 1.0 }) {
            return .ambiguous
        }
        // 对接缝外的静止顶栏、动画或局部改变再做逐带校验。
        let shift = best.key
        let overlap = a.height - abs(shift)
        let aStart = max(shift, 0), bStart = max(-shift, 0)
        for band in 0..<6 {
            let start = overlap * band / 6, end = overlap * (band + 1) / 6
            var sum = 0.0, count = 0
            for y in stride(from: start, to: end, by: 2) {
                for x in stride(from: 0, to: a.width, by: 2) {
                    sum += Double(abs(Int(a.pixels[(y + aStart) * a.width + x]) - Int(b.pixels[(y + bStart) * b.width + x])))
                    count += 1
                }
            }
            if count > 0 && sum / Double(count) > 5 { return .changedContent }
        }
        return shift > 0 ? .append(rows: shift) : .reverse
    }
    private func error(_ a: GrayFrame, _ b: GrayFrame, shift: Int) -> Double {
        let overlap = a.height - abs(shift)
        guard overlap > 0 else { return 255 }
        let aStart = max(shift, 0), bStart = max(-shift, 0)
        let yStep = max(1, overlap / 64)
        var total: Int = 0, count = 0
        for y in stride(from: 0, to: overlap, by: yStep) {
            for x in stride(from: 0, to: a.width, by: 2) {
                total += abs(Int(a.pixels[(y + aStart) * a.width + x]) - Int(b.pixels[(y + bStart) * b.width + x]))
                count += 1
            }
        }
        return Double(total) / Double(max(1, count))
    }
}
