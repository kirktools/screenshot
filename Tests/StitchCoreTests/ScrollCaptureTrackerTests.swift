#if !STANDALONE_TESTS
import XCTest
#endif
@testable import StitchCore

final class ScrollCaptureTrackerTests: XCTestCase {
    private func frame(_ offset: Int, sourceWidth: Int = 640) -> GrayFrame {
        let width = 64, height = 240
        var pixels = [UInt8](); pixels.reserveCapacity(width * height)
        for y in offset..<(offset + height) { for x in 0..<width {
            var value = UInt64(y * width + x + 1) &* 0x9E3779B97F4A7C15
            value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
            value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
            pixels.append(UInt8(truncatingIfNeeded: value ^ (value >> 31)))
        } }
        return GrayFrame(width: width, height: height, pixels: pixels, sourceWidth: sourceWidth)
    }
    func testSignedDisplacementKeepsLegacyContract() {
        let matcher = StitchMatcher()
        XCTAssertEqual(matcher.verticalMatch(previous: frame(300), next: frame(240)), .translated(rows: -60))
        XCTAssertEqual(matcher.match(previous: frame(300), next: frame(240)), .reverse)
    }
    func testUpwardCaptureAndRepeatedFrames() {
        var tracker = ScrollCaptureTracker()
        XCTAssertEqual(tracker.consume(frame(300), at: 0), .seed)
        XCTAssertEqual(tracker.consume(frame(240), at: 0.1), .prepend(rows: 60))
        XCTAssertEqual(tracker.consume(frame(240), at: 0.2), .duplicate)
        XCTAssertEqual(tracker.consume(frame(160), at: 0.3), .prepend(rows: 80))
        XCTAssertEqual(tracker.height, 380)
        XCTAssertTrue(tracker.lastExtensionWasUpward)
    }
    func testReversingInsideCapturedRangeDoesNotAddRows() {
        var tracker = ScrollCaptureTracker()
        _ = tracker.consume(frame(300), at: 0)
        _ = tracker.consume(frame(400), at: 0.1)
        XCTAssertEqual(tracker.consume(frame(340), at: 0.2), .duplicate)
        XCTAssertEqual(tracker.consume(frame(280), at: 0.3), .prepend(rows: 20))
        XCTAssertEqual(tracker.consume(frame(380), at: 0.4), .duplicate)
        XCTAssertEqual(tracker.consume(frame(440), at: 0.5), .append(rows: 40))
        XCTAssertEqual(tracker.height, 400)
        XCTAssertFalse(tracker.hasUnmatchedFrame)
    }
    func testLargeGapCannotMoveAnchorAndEitherEndpointRecovers() {
        var tracker = ScrollCaptureTracker()
        _ = tracker.consume(frame(300), at: 0)
        _ = tracker.consume(frame(460), at: 0.1)
        _ = tracker.consume(frame(620), at: 0.2)
        XCTAssertEqual(tracker.consume(frame(1200), at: 0.3), .recovering(.insufficientOverlap))
        XCTAssertEqual(tracker.timeout(at: 1.2), .paused(.insufficientOverlap))
        XCTAssertEqual(tracker.height, 560)
        XCTAssertEqual(tracker.consume(frame(280), at: 1.3), .prepend(rows: 20))
        XCTAssertEqual(tracker.consume(frame(650), at: 1.4), .append(rows: 30))
        XCTAssertEqual(tracker.height, 610)
        XCTAssertFalse(tracker.hasUnmatchedFrame)
    }
    func testUndoCheckpointRestoresBothBounds() {
        var tracker = ScrollCaptureTracker()
        _ = tracker.consume(frame(300), at: 0)
        _ = tracker.consume(frame(400), at: 0.1)
        let checkpoint = tracker
        _ = tracker.consume(frame(250), at: 0.2)
        XCTAssertEqual(tracker.height, 390)
        tracker = checkpoint; tracker.retry()
        XCTAssertEqual(tracker.height, 340)
        XCTAssertEqual(tracker.consume(frame(270), at: 0.3), .prepend(rows: 30))
        XCTAssertEqual(tracker.consume(frame(430), at: 0.4), .append(rows: 30))
        XCTAssertEqual(tracker.height, 400)
    }
    func testScaleChangePausesImmediately() {
        var tracker = ScrollCaptureTracker()
        _ = tracker.consume(frame(300), at: 0)
        XCTAssertEqual(tracker.consume(frame(280, sourceWidth: 1280), at: 0.1), .paused(.incompatibleSize))
        XCTAssertEqual(tracker.height, 240)
        XCTAssertTrue(tracker.hasUnmatchedFrame)
    }
    func testRepeatedPatternDoesNotGuessUpwardSeam() {
        func pattern(_ offset: Int) -> GrayFrame {
            GrayFrame(width: 64, height: 240, pixels: (0..<(64 * 240)).map { UInt8((($0 / 64 + offset) % 24) * 10) })
        }
        var tracker = ScrollCaptureTracker()
        _ = tracker.consume(pattern(7), at: 0)
        XCTAssertEqual(tracker.consume(pattern(0), at: 0.1), .recovering(.ambiguous))
        XCTAssertEqual(tracker.height, 240)
    }
    func testChangedContentIsNotPrepended() {
        var tracker = ScrollCaptureTracker()
        _ = tracker.consume(frame(300), at: 0)
        var changed = frame(260).pixels
        for index in (40 * 64)..<(80 * 64) { changed[index] = 255 }
        let result = tracker.consume(GrayFrame(width: 64, height: 240, pixels: changed, sourceWidth: 640), at: 0.1)
        if case .recovering = result {} else { XCTFail("变化内容被接受：\(result)") }
        XCTAssertEqual(tracker.height, 240)
    }
    func testCancelDuringFinishRejectsLateOutput() {
        var lifecycle = CaptureLifecycle()
        let generation = lifecycle.beginFinish()!
        lifecycle.stop()
        XCTAssertFalse(lifecycle.authorizeCommit(generation: generation))
        XCTAssertTrue(lifecycle.isStopped)
        XCTAssertNil(lifecycle.beginFinish())
    }
    func testInvalidatedResultCannotCommitAndCommitOnlyOnce() {
        var lifecycle = CaptureLifecycle()
        let stale = lifecycle.beginFinish()!
        lifecycle.invalidateProcessing()
        XCTAssertFalse(lifecycle.authorizeCommit(generation: stale))
        lifecycle.resumeCapture()
        let current = lifecycle.beginFinish()!
        XCTAssertTrue(lifecycle.authorizeCommit(generation: current))
        XCTAssertFalse(lifecycle.authorizeCommit(generation: current))
        lifecycle.outputFailed()
        XCTAssertNotNil(lifecycle.beginFinish())
    }
}
