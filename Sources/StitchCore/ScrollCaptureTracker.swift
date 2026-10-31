import Foundation

public enum ScrollTrackingResult: Equatable, Sendable {
    case seed
    case append(rows: Int)
    case prepend(rows: Int)
    case duplicate
    case recovering(MatchResult)
    case paused(MatchResult)
}

/// 双向会话规则与平台无关。维护当前视口和已确认的两端，在范围内回看不重复追加。
/// 失配不移动坐标或锚点；扩展前还必须与对应端点直接核对，避免回滚累计误差。
public struct ScrollCaptureTracker: Sendable {
    private struct Anchor: Sendable {
        let frame: GrayFrame
        let offset: Int
    }
    private var current: Anchor?
    private var head: Anchor?
    private var tail: Anchor?
    private var failureSince: Double?
    private var lastFailure: MatchResult = .insufficientOverlap
    private let matcher = StitchMatcher()
    public let recoveryInterval: Double
    public private(set) var hasUnmatchedFrame = false
    public private(set) var lastExtensionWasUpward = false
    public var height: Int { guard let head, let tail else { return 0 }; return tail.offset - head.offset + head.frame.height }
    public init(recoveryInterval: Double = 0.8) { self.recoveryInterval = recoveryInterval }

    /// 重试保留两端，不把当前未知画面当新起点。
    public mutating func retry() { failureSince = nil }

    public mutating func consume(_ frame: GrayFrame, at time: Double) -> ScrollTrackingResult {
        guard let current, let head, let tail else {
            let anchor = Anchor(frame: frame, offset: 0)
            self.current = anchor; self.head = anchor; self.tail = anchor
            return .seed
        }
        let measured = matcher.verticalMatch(previous: current.frame, next: frame)
        var location = position(measured, relativeTo: current.offset)
        var reason: MatchResult = .insufficientOverlap
        if case .rejected(let failure) = measured { reason = failure }
        if reason == .incompatibleSize { return fail(reason, at: time) }
        // 连续帧失配后也允许回到任一已确认端点，避免只能找回最后停留位置。
        if location == nil {
            var candidates = Set<Int>()
            for anchor in [head, tail] where anchor.offset != current.offset {
                if let offset = position(matcher.verticalMatch(previous: anchor.frame, next: frame), relativeTo: anchor.offset) {
                    candidates.insert(offset)
                }
            }
            if candidates.count > 1 { return fail(.ambiguous, at: time) }
            location = candidates.first
        }
        guard let location else { return fail(reason, at: time) }
        let result: ScrollTrackingResult
        if location < head.offset {
            let rows = head.offset - location
            let edge = current.offset == head.offset ? measured : matcher.verticalMatch(previous: head.frame, next: frame)
            guard edge == .translated(rows: -rows) else {
                return fail(.changedContent, at: time)
            }
            self.head = Anchor(frame: frame, offset: location)
            lastExtensionWasUpward = true; result = .prepend(rows: rows)
        } else if location > tail.offset {
            let rows = location - tail.offset
            let edge = current.offset == tail.offset ? measured : matcher.verticalMatch(previous: tail.frame, next: frame)
            guard edge == .translated(rows: rows) else {
                return fail(.changedContent, at: time)
            }
            self.tail = Anchor(frame: frame, offset: location)
            lastExtensionWasUpward = false; result = .append(rows: rows)
        } else { result = .duplicate }
        self.current = Anchor(frame: frame, offset: location)
        failureSince = nil; hasUnmatchedFrame = false
        return result
    }
    private func position(_ result: VerticalMatchResult, relativeTo offset: Int) -> Int? {
        switch result {
        case .unchanged: return offset
        case .translated(let rows): return offset + rows
        case .rejected: return nil
        }
    }
    private mutating func fail(_ reason: MatchResult, at time: Double) -> ScrollTrackingResult {
        hasUnmatchedFrame = true; lastFailure = reason
        if reason == .incompatibleSize { return .paused(reason) }
        if failureSince == nil { failureSince = time }
        return timeout(at: time) ?? .recovering(reason)
    }
    public func timeout(at time: Double) -> ScrollTrackingResult? {
        guard let failureSince, time - failureSince >= recoveryInterval else { return nil }
        return .paused(lastFailure)
    }
}
