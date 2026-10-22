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
        return denseError(a, b, shift: 0)
    }
    public func match(previous a: GrayFrame, next b: GrayFrame) -> MatchResult {
        guard a.width == b.width, a.height == b.height, a.sourceWidth == b.sourceWidth else { return .incompatibleSize }
        guard a.height >= 80, a.width >= 16 else { return .insufficientOverlap }
        // 全图均值很小也可能是稀疏文字在移动，须同时检查显著变化的像素比例。
        if difference(a, b) < 0.6 {
            var changed = 0
            for i in a.pixels.indices where abs(Int(a.pixels[i]) - Int(b.pixels[i])) > 3 { changed += 1 }
            if changed <= max(1, a.pixels.count / 10_000) { return .duplicate }
        }
        let limit = Int(Double(a.height) * 0.78)
        // 原始纵向像素搜索；每条候选行检查所有列，再对最佳候选做全重叠校验。
        let step = 1
        let rows = informativeRows(a)
        var coarse: [(Int, Double)] = []
        for shift in stride(from: -limit, through: limit, by: step) where abs(shift) >= 1 {
            coarse.append((shift, error(a, b, shift: shift, rows: rows)))
        }
        let ordered = coarse.sorted { $0.1 < $1.1 }
        guard let first = ordered.first, first.1 < 12 else { return .insufficientOverlap }
        let seeds = ordered.prefix(24)
        var candidates: [Int: Double] = [:]
        for (seed, _) in seeds {
            for d in max(-limit, seed - step)...min(limit, seed + step) where abs(d) >= 1 {
                if candidates[d] == nil { candidates[d] = denseError(a, b, shift: d) }
            }
        }
        let ranked = candidates.sorted { $0.value < $1.value }
        guard let best = ranked.first else { return .insufficientOverlap }
        guard best.value < 3.0 else { return .insufficientOverlap }
        // 周期性内容可能出现多个同样好的位移；保守拒绝，而不是猜。
        if ranked.contains(where: { abs($0.key - best.key) > max(4, step * 2) && $0.value <= best.value * 1.15 + 0.0001 }) {
            return .ambiguous
        }
        // 对接缝外的静止顶栏、动画或局部改变再做逐带校验。
        let shift = best.key
        let overlap = a.height - abs(shift)
        let aStart = max(shift, 0), bStart = max(-shift, 0)
        for band in 0..<6 {
            let start = overlap * band / 6, end = overlap * (band + 1) / 6
            var sum = 0.0, count = 0
            var signal = 0.0, excess = 0.0
            for y in start..<end {
                for x in 0..<a.width {
                    let delta = abs(Int(a.pixels[(y + aStart) * a.width + x]) - Int(b.pixels[(y + bStart) * b.width + x]))
                    sum += Double(delta); excess += Double(max(0, delta - 2))
                    let ai = (y + aStart) * a.width + x, bi = (y + bStart) * b.width + x
                    if x > 0 {
                        signal += Double(max(abs(Int(a.pixels[ai]) - Int(a.pixels[ai - 1])), abs(Int(b.pixels[bi]) - Int(b.pixels[bi - 1]))))
                    }
                    count += 1
                }
            }
            // 不能让大面积相同背景掩盖文字差异；误差还须小于局部字形信号。
            if count > 0 && (sum / Double(count) > 5 || excess > signal * 0.3) {
                return .changedContent
            }
        }
        return shift > 0 ? .append(rows: shift) : .reverse
    }
    /// 每个纵向小区间保留最有横向纹理的两行，避免固定网格恰好落在字间留白。
    private func informativeRows(_ frame: GrayFrame) -> [Int] {
        var rows: [Int] = []
        let size = max(1, frame.height / 32)
        for start in stride(from: 0, to: frame.height, by: size) {
            let end = min(frame.height, start + size)
            var ranked: [(Int, Int)] = []
            for y in start..<end {
                var energy = 0
                for x in 1..<frame.width {
                    energy += abs(Int(frame.pixels[y * frame.width + x]) - Int(frame.pixels[y * frame.width + x - 1]))
                }
                ranked.append((y, energy))
            }
            ranked.sort { lhs, rhs in
                if lhs.1 == rhs.1 { return lhs.0 < rhs.0 }
                return lhs.1 > rhs.1
            }
            rows.append(contentsOf: ranked.prefix(2).map { $0.0 })
        }
        return rows
    }
    private func denseError(_ a: GrayFrame, _ b: GrayFrame, shift: Int) -> Double {
        error(a, b, shift: shift, rows: Array(max(shift, 0)..<min(a.height, a.height + shift)))
    }
    private func error(_ a: GrayFrame, _ b: GrayFrame, shift: Int, rows: [Int]) -> Double {
        var total = 0, count = 0
        for y in rows where y - shift >= 0 && y - shift < b.height {
            for x in 0..<a.width {
                total += abs(Int(a.pixels[y * a.width + x]) - Int(b.pixels[(y - shift) * b.width + x]))
                count += 1
            }
        }
        return count > 0 ? Double(total) / Double(count) : 255
    }
}
