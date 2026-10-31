/// 采集和输出的生命周期，不依赖窗口或剪贴板。平台层必须在执行副作用前取得提交资格。
public struct CaptureLifecycle: Sendable {
    public enum Phase: Sendable { case capturing, finishing, committing, stopped }
    public private(set) var phase: Phase = .capturing
    public private(set) var generation: UInt64 = 0
    public var isStopped: Bool { phase == .stopped }
    public var isFinishing: Bool { phase == .finishing || phase == .committing }
    public init() {}
    public mutating func invalidateProcessing() { generation &+= 1 }
    public mutating func beginFinish() -> UInt64? {
        guard phase == .capturing else { return nil }
        phase = .finishing; return generation
    }
    public mutating func resumeCapture() {
        guard phase == .finishing else { return }
        phase = .capturing
    }
    /// 此调用与平台输出之间不可再 await；取消后的旧结果无权写剪贴板。
    public mutating func authorizeCommit(generation expected: UInt64) -> Bool {
        guard phase == .finishing, generation == expected else { return false }
        phase = .committing; return true
    }
    public mutating func outputFailed() {
        guard phase == .committing else { return }
        phase = .capturing
    }
    public mutating func stop() { phase = .stopped; invalidateProcessing() }
}
