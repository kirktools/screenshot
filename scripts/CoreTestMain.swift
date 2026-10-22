import Foundation

/// 与 XCTest 共用同一份测试方法，适用于只有 Command Line Tools 的机器。
@main struct CoreTestMain {
    static func main() {
        let suite = StitchMatcherTests()
        let tests: [(String, () -> Void)] = [
            ("精确重叠", suite.testNormalOverlapAndExactPixelOffsets),
            ("重复帧", suite.testDuplicate),
            ("渲染噪声", suite.testSmallRenderingNoise),
            ("重叠不足", suite.testInsufficientOverlap),
            ("无关画面", suite.testUnrelatedFrame),
            ("反向滚动", suite.testReverseScroll),
            ("尺寸变化", suite.testScaleChangesRejected),
            ("视口内缩放", suite.testZoomWithSameViewportRejected),
            ("重复纹理", suite.testRepeatedPatternsAreAmbiguous),
            ("固定顶栏", suite.testStickyHeaderRejected),
            ("动态消息", suite.testDynamicMessageRejected),
            ("Retina 接缝", suite.testRetinaHeight),
            ("正文与留白", suite.testTextLikePageWithWhitespace)
        ]
        for (name, run) in tests { run(); print("PASS: \(name)") }
        print("\(tests.count) suites passed")
    }
}
