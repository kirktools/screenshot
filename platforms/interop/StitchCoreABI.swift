// 同一份 Sources/StitchCore 经 C ABI 暴露给平台适配层；这里不实现第二套算法。
// 每个 tracker 由调用者串行使用，销毁时不得仍有未完成的调用。
private final class TrackerBox { var value = ContinuousStitchTracker() }
private func frame(_ bytes: UnsafePointer<UInt8>?, _ count: Int32, _ width: Int32, _ height: Int32, _ sourceWidth: Int32) -> GrayFrame? {
    guard let bytes, width > 0, width <= 128, height > 0, height <= 30_000, sourceWidth >= width,
          Int64(width) * Int64(height) == Int64(count), count <= 4_000_000 else { return nil }
    return GrayFrame(width: Int(width), height: Int(height), pixels: Array(UnsafeBufferPointer(start: bytes, count: Int(count))), sourceWidth: Int(sourceWidth))
}
private func result(_ value: MatchResult, _ rows: UnsafeMutablePointer<Int32>) -> Int32 {
    rows.pointee = 0
    switch value {
    case .duplicate: return 0
    case .append(let n): rows.pointee = Int32(n); return 1
    case .reverse: return 2
    case .incompatibleSize: return 3
    case .insufficientOverlap: return 4
    case .ambiguous: return 5
    case .changedContent: return 6
    }
}
#if compiler(>=6.3)
@c(screenshot_stitch_abi_version)
#else
@_cdecl("screenshot_stitch_abi_version")
#endif
public func stitchABIVersion() -> Int32 { 1 }
#if compiler(>=6.3)
@c(screenshot_stitch_match)
#else
@_cdecl("screenshot_stitch_match")
#endif
public func stitchMatch(_ a: UnsafePointer<UInt8>?, _ an: Int32, _ aw: Int32, _ ah: Int32, _ asw: Int32,
                        _ b: UnsafePointer<UInt8>?, _ bn: Int32, _ bw: Int32, _ bh: Int32, _ bsw: Int32,
                        _ rows: UnsafeMutablePointer<Int32>?) -> Int32 {
    guard let rows, let previous = frame(a, an, aw, ah, asw), let next = frame(b, bn, bw, bh, bsw) else { return -1 }
    return result(StitchMatcher().match(previous: previous, next: next), rows)
}
#if compiler(>=6.3)
@c(screenshot_stitch_difference)
#else
@_cdecl("screenshot_stitch_difference")
#endif
public func stitchDifference(_ a: UnsafePointer<UInt8>?, _ an: Int32, _ aw: Int32, _ ah: Int32, _ asw: Int32,
                             _ b: UnsafePointer<UInt8>?, _ bn: Int32, _ bw: Int32, _ bh: Int32, _ bsw: Int32) -> Double {
    guard let previous = frame(a, an, aw, ah, asw), let next = frame(b, bn, bw, bh, bsw) else { return -1 }
    return StitchMatcher().difference(previous, next)
}
#if compiler(>=6.3)
@c(screenshot_stitch_tracker_create)
#else
@_cdecl("screenshot_stitch_tracker_create")
#endif
public func stitchTrackerCreate() -> UnsafeMutableRawPointer { Unmanaged.passRetained(TrackerBox()).toOpaque() }
#if compiler(>=6.3)
@c(screenshot_stitch_tracker_destroy)
#else
@_cdecl("screenshot_stitch_tracker_destroy")
#endif
public func stitchTrackerDestroy(_ handle: UnsafeMutableRawPointer?) { if let handle { Unmanaged<TrackerBox>.fromOpaque(handle).release() } }
#if compiler(>=6.3)
@c(screenshot_stitch_tracker_reset)
#else
@_cdecl("screenshot_stitch_tracker_reset")
#endif
public func stitchTrackerReset(_ handle: UnsafeMutableRawPointer?, _ bytes: UnsafePointer<UInt8>?, _ count: Int32, _ width: Int32, _ height: Int32, _ sourceWidth: Int32) -> Int32 {
    guard let handle else { return -1 }
    let box = Unmanaged<TrackerBox>.fromOpaque(handle).takeUnretainedValue()
    if bytes == nil && count == 0 && width == 0 && height == 0 && sourceWidth == 0 { box.value.reset(); return 0 }
    guard let anchor = frame(bytes, count, width, height, sourceWidth) else { return -1 }
    box.value.reset(anchor: anchor); return 0
}
#if compiler(>=6.3)
@c(screenshot_stitch_tracker_unmatched)
#else
@_cdecl("screenshot_stitch_tracker_unmatched")
#endif
public func stitchTrackerUnmatched(_ handle: UnsafeMutableRawPointer?) -> Int32 {
    guard let handle else { return -1 }
    return Unmanaged<TrackerBox>.fromOpaque(handle).takeUnretainedValue().value.hasUnmatchedFrame ? 1 : 0
}
#if compiler(>=6.3)
@c(screenshot_stitch_tracker_consume)
#else
@_cdecl("screenshot_stitch_tracker_consume")
#endif
public func stitchTrackerConsume(_ handle: UnsafeMutableRawPointer?, _ bytes: UnsafePointer<UInt8>?, _ count: Int32, _ width: Int32, _ height: Int32, _ sourceWidth: Int32, _ time: Double, _ match: UnsafeMutablePointer<Int32>?, _ rows: UnsafeMutablePointer<Int32>?) -> Int32 {
    guard let handle, let match, let rows, time.isFinite, time >= 0, let next = frame(bytes, count, width, height, sourceWidth) else { return -1 }
    let box = Unmanaged<TrackerBox>.fromOpaque(handle).takeUnretainedValue()
    rows.pointee = 0; match.pointee = 0
    switch box.value.consume(next, at: time) {
    case .seed: return 0
    case .append(let n): rows.pointee = Int32(n); match.pointee = 1; return 1
    case .duplicate: return 2
    case .recovering(let reason): match.pointee = result(reason, rows); return 3
    case .paused(let reason): match.pointee = result(reason, rows); return 4
    }
}
