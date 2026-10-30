public enum TrackingResult: Equatable, Sendable {
    case seed
    case append(rows: Int)
    case duplicate
    case recovering(MatchResult)
    case paused(MatchResult)
}

/// 仅以已确认的末帧作为锚点；丢帧和动画不会悄悄重设基准、跳过内容。
/// 时间由采集端注入，便于跨平台复用和确定性测试。
public struct ContinuousStitchTracker: Sendable {
    private var anchor: GrayFrame?
    private var failureSince: Double?
    private var lastFailure: MatchResult = .insufficientOverlap
    private let matcher = StitchMatcher()
    public let recoveryInterval: Double
    public private(set) var hasUnmatchedFrame = false
    public init(recoveryInterval: Double = 0.8) { self.recoveryInterval = recoveryInterval }
    public mutating func reset(anchor: GrayFrame? = nil) {
        self.anchor = anchor; failureSince = nil; hasUnmatchedFrame = false
    }
    public mutating func consume(_ frame: GrayFrame, at time: Double) -> TrackingResult {
        guard let anchor else { self.anchor = frame; return .seed }
        let result = matcher.match(previous: anchor, next: frame)
        switch result {
        case .duplicate:
            failureSince = nil; hasUnmatchedFrame = false; return .duplicate
        case .append(let rows):
            self.anchor = frame; failureSince = nil; hasUnmatchedFrame = false
            return .append(rows: rows)
        case .incompatibleSize:
            hasUnmatchedFrame = true; lastFailure = result
            return .paused(result)
        default:
            hasUnmatchedFrame = true; lastFailure = result
            if failureSince == nil { failureSince = time }
            return timeout(at: time) ?? .recovering(result)
        }
    }
    /// 静止画面可能不再产生新帧，仍需让持续的接缝失败明确进入暂停状态。
    public func timeout(at time: Double) -> TrackingResult? {
        guard let failureSince, time - failureSince >= recoveryInterval else { return nil }
        return .paused(lastFailure)
    }
}
