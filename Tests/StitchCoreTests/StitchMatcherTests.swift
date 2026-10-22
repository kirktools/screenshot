#if STANDALONE_TESTS
import Foundation
class XCTestCase {}
func XCTAssertEqual<T: Equatable>(_ a: T, _ b: T, _ message: String = "") {
    guard a == b else { fatalError("断言失败：\(a) != \(b) \(message)") }
}
func XCTAssertFalse(_ value: Bool) { guard !value else { fatalError("断言失败：预期 false") } }
#else
import XCTest
#endif
@testable import StitchCore

final class StitchMatcherTests: XCTestCase {
    let matcher = StitchMatcher()
    func frame(offset: Int, width: Int = 64, height: Int = 240, sourceWidth: Int = 640, noise: Int = 0) -> GrayFrame {
        var pixels: [UInt8] = []
        for y in offset..<(offset + height) { for x in 0..<width {
            var v = UInt64(y * width + x + 1) &* 0x9E3779B97F4A7C15
            v = (v ^ (v >> 30)) &* 0xBF58476D1CE4E5B9
            v = (v ^ (v >> 27)) &* 0x94D049BB133111EB
            let byte = Int((v ^ (v >> 31)) & 255)
            pixels.append(UInt8(clamping: byte + ((x + y) % 2 == 0 ? noise : -noise)))
        } }
        return GrayFrame(width: width, height: height, pixels: pixels, sourceWidth: sourceWidth)
    }
    func testNormalOverlapAndExactPixelOffsets() {
        for shift in [1, 2, 3, 17, 61, 119, 180] {
            XCTAssertEqual(matcher.match(previous: frame(offset: 0), next: frame(offset: shift)), .append(rows: shift), "shift=\(shift)")
        }
    }
    func testDuplicate() { let a = frame(offset: 0); XCTAssertEqual(matcher.match(previous: a, next: a), .duplicate) }
    func testSmallRenderingNoise() { XCTAssertEqual(matcher.match(previous: frame(offset: 0), next: frame(offset: 73, noise: 1)), .append(rows: 73)) }
    func testInsufficientOverlap() { XCTAssertEqual(matcher.match(previous: frame(offset: 0), next: frame(offset: 220)), .insufficientOverlap) }
    func testUnrelatedFrame() { XCTAssertEqual(matcher.match(previous: frame(offset: 0), next: frame(offset: 400)), .insufficientOverlap) }
    func testReverseScroll() { XCTAssertEqual(matcher.match(previous: frame(offset: 90), next: frame(offset: 30)), .reverse) }
    func testScaleChangesRejected() {
        XCTAssertEqual(matcher.match(previous: frame(offset: 0), next: frame(offset: 0, sourceWidth: 1280)), .incompatibleSize)
        XCTAssertEqual(matcher.match(previous: frame(offset: 0), next: frame(offset: 0, height: 480)), .incompatibleSize)
    }
    func testZoomWithSameViewportRejected() {
        let a = frame(offset: 0)
        var pixels = a.pixels
        for y in 0..<a.height { for x in 0..<a.width { pixels[y*a.width+x] = a.pixels[(y/2)*a.width+x/2] } }
        let b = GrayFrame(width: a.width, height: a.height, pixels: pixels, sourceWidth: a.sourceWidth)
        XCTAssertEqual(matcher.match(previous: a, next: b), .insufficientOverlap)
    }
    func testRepeatedPatternsAreAmbiguous() {
        func pattern(_ offset: Int) -> GrayFrame {
            GrayFrame(width: 64, height: 240, pixels: (0..<(64*240)).map { UInt8((($0 / 64 + offset) % 24) * 10) })
        }
        XCTAssertEqual(matcher.match(previous: pattern(0), next: pattern(7)), .ambiguous)
    }
    func testStickyHeaderRejected() {
        let a = frame(offset: 0), b = frame(offset: 80)
        var pixels = b.pixels
        pixels.replaceSubrange(0..<(64*40), with: a.pixels[0..<(64*40)])
        let result = matcher.match(previous: a, next: GrayFrame(width: 64, height: 240, pixels: pixels, sourceWidth: 640))
        XCTAssertFalse({ if case .append = result { return true }; return false }())
    }
    func testDynamicMessageRejected() {
        let a = frame(offset: 0), b = frame(offset: 70)
        var pixels = b.pixels
        for y in 40..<80 { for x in 0..<64 { pixels[y*64+x] = 255 } }
        let result = matcher.match(previous: a, next: GrayFrame(width: 64, height: 240, pixels: pixels, sourceWidth: 640))
        XCTAssertFalse({ if case .append = result { return true }; return false }())
    }

    func testTextLikePageWithWhitespace() {
        func page(_ offset: Int) -> GrayFrame {
            let width = 128, height = 700
            var pixels = [UInt8](repeating: 255, count: width * height)
            for y in 0..<height { for x in 12..<116 {
                let documentY = y + offset, line = documentY / 28, row = documentY % 28
                let word = x / 7
                // 不同行有不同字形/长度，模拟正文和留白，不使用纯随机噪声。
                if row >= 5 && row < 19 && x % 7 < 5 && word < 8 + (line * 13 % 9) {
                    var glyph = UInt64(line * 7919 + word * 131 + (row / 2) * 17 + x % 7 + 1) &* 0x9E3779B97F4A7C15
                    glyph = (glyph ^ (glyph >> 30)) &* 0xBF58476D1CE4E5B9
                    pixels[y * width + x] = glyph & 3 == 0 ? 255 : 35
                }
            } }
            return GrayFrame(width: width, height: height, pixels: pixels, sourceWidth: 1280)
        }
        for offset in [37, 151, 303] {
            XCTAssertEqual(matcher.match(previous: page(0), next: page(offset)), .append(rows: offset), "正文 offset=\(offset)")
        }
    }
    func testRetinaHeight() { XCTAssertEqual(matcher.match(previous: frame(offset: 0, height: 1200), next: frame(offset: 377, height: 1200)), .append(rows: 377)) }
    func testContinuousMotionWithoutStableFrames() {
        var tracker = ContinuousStitchTracker()
        XCTAssertEqual(tracker.consume(frame(offset: 0), at: 0), .seed)
        var rows = 240
        // 每帧均有位移，从不提供相同的停稳帧；包含偶发丢帧后的大位移。
        var previous = 0
        for (i, offset) in [4, 11, 23, 40, 62, 89, 124, 168, 221, 282, 350, 424, 503].enumerated() {
            XCTAssertEqual(tracker.consume(frame(offset: offset), at: Double(i + 1) / 30), .append(rows: offset - previous))
            rows += offset - previous; previous = offset
        }
        XCTAssertEqual(rows, 743)
        XCTAssertFalse(tracker.hasUnmatchedFrame)
    }
    func testTransientFailureRecoversAgainstConfirmedAnchor() {
        var tracker = ContinuousStitchTracker()
        XCTAssertEqual(tracker.consume(frame(offset: 0), at: 0), .seed)
        XCTAssertEqual(tracker.consume(frame(offset: 400), at: 0.1), .recovering(.insufficientOverlap))
        XCTAssertEqual(tracker.consume(frame(offset: 85), at: 0.2), .append(rows: 85))
        XCTAssertEqual(tracker.timeout(at: 2), nil)
        XCTAssertFalse(tracker.hasUnmatchedFrame)
    }
    func testPersistentGapAndIdleTimeout() {
        var tracker = ContinuousStitchTracker()
        _ = tracker.consume(frame(offset: 0), at: 0)
        XCTAssertEqual(tracker.consume(frame(offset: 400), at: 0.1), .recovering(.insufficientOverlap))
        XCTAssertEqual(tracker.timeout(at: 0.5), nil)
        XCTAssertEqual(tracker.timeout(at: 1), .paused(.insufficientOverlap))
        XCTAssertEqual(tracker.hasUnmatchedFrame, true)
        // 重试不得把缺失处当新起点。
        tracker.reset(anchor: frame(offset: 0))
        XCTAssertEqual(tracker.consume(frame(offset: 400), at: 2), .recovering(.insufficientOverlap))
        XCTAssertEqual(tracker.consume(frame(offset: 70), at: 2.1), .append(rows: 70))
    }
    func testReverseBounceAndUndoAnchor() {
        var tracker = ContinuousStitchTracker()
        _ = tracker.consume(frame(offset: 100), at: 0)
        XCTAssertEqual(tracker.consume(frame(offset: 80), at: 0.1), .recovering(.reverse))
        XCTAssertEqual(tracker.consume(frame(offset: 125), at: 0.2), .append(rows: 25))
        XCTAssertEqual(tracker.consume(frame(offset: 50), at: 0.3), .recovering(.reverse))
        XCTAssertEqual(tracker.timeout(at: 1.2), .paused(.reverse))
        tracker.reset(anchor: frame(offset: 100))
        XCTAssertEqual(tracker.consume(frame(offset: 130), at: 2), .append(rows: 30))
        XCTAssertEqual(tracker.consume(frame(offset: 130, sourceWidth: 1280), at: 2.1), .paused(.incompatibleSize))
    }

}
