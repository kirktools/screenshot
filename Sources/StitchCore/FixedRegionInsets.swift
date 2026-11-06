import Foundation

public struct FixedRegionInsets: Equatable, Sendable {
    public let top: Int
    public let bottom: Int
    public static let none = FixedRegionInsets(top: 0, bottom: 0)
    public init(top: Int, bottom: Int) { precondition(top >= 0 && bottom >= 0); self.top = top; self.bottom = bottom }
    public func crop(_ frame: GrayFrame) -> GrayFrame {
        precondition(top >= 0 && bottom >= 0 && top + bottom < frame.height)
        return GrayFrame(width: frame.width, height: frame.height-top-bottom,
                         pixels: Array(frame.pixels[(top*frame.width)..<((frame.height-bottom)*frame.width)]), sourceWidth: frame.sourceWidth)
    }
}

extension StitchMatcher {
    /// 先在中央正文估位移，再用全宽残差确定边缘遮挡范围；不改变原有接缝容差。
    public func fixedRegionInsets(previous a: GrayFrame, next b: GrayFrame) -> FixedRegionInsets? {
        guard a.width == b.width, a.height == b.height, a.sourceWidth == b.sourceWidth, a.height >= 160 else { return nil }
        let margin = a.height / 3
        var measured: Int?
        for trim in [a.height/4, margin] {
            let middle = FixedRegionInsets(top: trim, bottom: trim)
            if case .translated(let shift) = verticalMatch(previous: middle.crop(a), next: middle.crop(b)), abs(shift) >= 2 { measured = shift; break }
        }
        guard let shift = measured else { return nil }
        let overlap = a.height-abs(shift), aStart = max(0, shift), bStart = max(0, -shift)
        var bad = [Bool](repeating: false, count: overlap)
        for y in 0..<overlap {
            var sum = 0.0, excess = 0.0, signal = 0.0
            for x in 0..<a.width {
                let ai = (y+aStart)*a.width+x, bi = (y+bStart)*b.width+x
                let delta = abs(Int(a.pixels[ai])-Int(b.pixels[bi]))
                sum += Double(delta); excess += Double(max(0, delta-2))
                if x > 0 { signal += Double(max(abs(Int(a.pixels[ai])-Int(a.pixels[ai-1])), abs(Int(b.pixels[bi])-Int(b.pixels[bi-1])))) }
            }
            bad[y] = sum / Double(a.width) > 5 || excess > max(1, signal)*0.3
        }
        let central = margin..<max(margin, overlap-margin)
        guard !central.contains(where: { bad[$0] }) else { return nil }
        let top = (bad.indices.filter { $0 < margin && bad[$0] }.last.map { $0+1 }) ?? 0
        let bottom = (bad.indices.first { $0 >= overlap-margin && bad[$0] }.map { overlap-$0 }) ?? 0
        guard top+bottom > 0, top <= margin, bottom <= margin, a.height-top-bottom >= 80 else { return nil }
        // 遮挡候选还必须在原坐标下包含稳定特征；不能把边缘任意重排误当固定栏。
        func stable(_ range: Range<Int>) -> Bool {
            guard !range.isEmpty else { return true }
            var stableEdges = 0, edges = 0
            for y in range { for x in 1..<a.width {
                let i = y*a.width+x
                if abs(Int(a.pixels[i])-Int(a.pixels[i-1])) >= 8 {
                    edges += 1
                    if abs(Int(a.pixels[i])-Int(b.pixels[i])) <= 2 && abs(Int(a.pixels[i-1])-Int(b.pixels[i-1])) <= 2 { stableEdges += 1 }
                }
            } }
            return stableEdges >= 8 && Double(stableEdges) / Double(max(1, edges)) >= 0.3
        }
        guard stable(0..<top), stable((a.height-bottom)..<a.height) else { return nil }
        let insets = FixedRegionInsets(top: top, bottom: bottom)
        guard verticalMatch(previous: insets.crop(a), next: insets.crop(b)) == .translated(rows: shift) else { return nil }
        return insets
    }
}
