import Foundation

/// 与 XCTest 共用同一份测试方法，适用于只有 Command Line Tools 的机器。
@main struct CoreTestMain {
    static func main() {
        let suite = StitchMatcherTests()
        let scroll = ScrollCaptureTrackerTests()
        let tests: [(String, () -> Void)] = [
            ("连续滚动不停稳", suite.testContinuousMotionWithoutStableFrames),
            ("短暂失败恢复", suite.testTransientFailureRecoversAgainstConfirmedAnchor),
            ("丢帧及静止超时", suite.testPersistentGapAndIdleTimeout),
            ("惯性回弹和撤销锚点", suite.testReverseBounceAndUndoAnchor),
            ("暗色细字采样", suite.testThinDarkTextCannotDisappearBetweenSampleColumns),
            ("稀疏文字不能误判静止", suite.testVerySparseTextIsNotDuplicate),
            ("稀疏文本错误匹配", suite.testSparseDifferentTextCannotBeAcceptedAsOverlap),
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
            ("正文与留白", suite.testTextLikePageWithWhitespace),
            ("双向位移与旧接口兼容", scroll.testSignedDisplacementKeepsLegacyContract),
            ("向上扩展及重复帧", scroll.testUpwardCaptureAndRepeatedFrames),
            ("往返去重与两端扩展", scroll.testReversingInsideCapturedRangeDoesNotAddRows),
            ("失配及任一端点恢复", scroll.testLargeGapCannotMoveAnchorAndEitherEndpointRecovers),
            ("双向撤销检查点", scroll.testUndoCheckpointRestoresBothBounds),
            ("双向缩放拒绝", scroll.testScaleChangePausesImmediately),
            ("向上重复纹理拒绝", scroll.testRepeatedPatternDoesNotGuessUpwardSeam),
            ("向上动态内容拒绝", scroll.testChangedContentIsNotPrepended),
            ("取消阻止迟到输出", scroll.testCancelDuringFinishRejectsLateOutput),
            ("输出提交只授权一次", scroll.testInvalidatedResultCannotCommitAndCommitOnlyOnce)
        ]
        for (name, run) in tests { run(); print("PASS: \(name)") }
        print("\(tests.count) suites passed")
    }
}
