import AppKit
import StitchCore
import ImageIO
import UniformTypeIdentifiers

/// 合成连续帧经真实会话、后台识别、条带存储、收尾与导出；不读取桌面或占用会话热键。
@MainActor private final class FixtureStream: RegionFrameStream {
    let frames: AsyncThrowingStream<CapturedFrame, Error>
    private let continuation: AsyncThrowingStream<CapturedFrame, Error>.Continuation
    private var paused = false
    private(set) var stopped = false
    init() {
        let pair = AsyncThrowingStream<CapturedFrame, Error>.makeStream(bufferingPolicy: .bufferingNewest(2))
        frames = pair.stream; continuation = pair.continuation
    }
    func start() async throws {}
    func setPaused(_ paused: Bool) { self.paused = paused }
    func stop() async { stopped = true; continuation.finish() }
    func send(_ image: CGImage) {
        guard !paused, !stopped else { return }
        continuation.yield(CapturedFrame(image: image, time: ProcessInfo.processInfo.systemUptime))
    }
}
@MainActor private final class FixtureProvider: RegionCaptureProvider {
    let source = FixtureStream()
    func prepare() async throws {}
    func capture(_ region: CGRect) async throws -> CGImage { throw CaptureError.message("合成测试不读取桌面") }
    func makeStream(_ region: CGRect) async throws -> any RegionFrameStream { source }
}

@MainActor private final class CompositionPause {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    private(set) var returned = false
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
    func markReturned() { returned = true }
}

@MainActor func runScrollSessionSelfTest() async throws {
    func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw CaptureError.message(message) }
    }
    func wait(file: StaticString = #fileID, line: UInt = #line, _ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !condition() {
            if ProcessInfo.processInfo.systemUptime > deadline { throw CaptureError.message("会话自测等待超时：\(file):\(line)") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    let width = 128, height = 1600
    var pixels = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height { for x in 0..<width {
        var v = UInt64(y * width + x + 1) &* 0x9E3779B97F4A7C15
        v = (v ^ (v >> 30)) &* 0xBF58476D1CE4E5B9
        v = (v ^ (v >> 27)) &* 0x94D049BB133111EB
        let i = (y * width + x) * 4
        pixels[i] = UInt8(truncatingIfNeeded: v); pixels[i + 1] = UInt8(truncatingIfNeeded: v >> 8)
        pixels[i + 2] = UInt8(truncatingIfNeeded: v >> 16)
    } }
    let document = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                           space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                           provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    func image(_ offset: Int) -> CGImage { document.cropping(to: CGRect(x: 0, y: offset, width: width, height: 240))! }
    let clipboard = NSPasteboard(name: .init("Screenshot-Scroll-Test-" + UUID().uuidString))
    defer { clipboard.releaseGlobally() }
    let region = CGRect(x: 100, y: 100, width: 128, height: 240)
    let provider = FixtureProvider()
    let session = ScrollSession(provider: provider, region: region, hotkeys: HotkeyRegistry(), clipboard: clipboard)
    var completed = false, output: CGImage?
    session.completion = { image, action in output = image; completed = action == .copy }
    defer { session.cancelCapture() }
    try require(session.start(registerHotkeys: false, showPanel: false), "合成会话启动失败")
    try await Task.sleep(for: .milliseconds(30))
    for i in 0...45 {
        provider.source.send(image(i * 7))
        if i < 45 { try await Task.sleep(for: .milliseconds(33)) }
    }
    let retainedBytes = session.diagnosticSnapshot.bytes
    let fullScreens = 46 * (width * 240 * 4 + width * 240)
    try require(retainedBytes < fullScreens / 2, "新增片段仍保留了整屏图像")
    let preview = session.diagnosticPreview
    try require(preview.visible && preview.width > 100 && preview.contentHeight > preview.viewportHeight && preview.originY > 0,
                "连续滚动虽成功，但常驻预览没有保留比例或跟随末尾")
    let zoomIndex = session.diagnosticMoreMenu.items.firstIndex(where: { $0.title == "放大预览" })
    guard let zoomIndex else {
        throw CaptureError.message("常驻预览缺少放大控件")
    }
    session.diagnosticMoreMenu.performActionForItem(at: zoomIndex)
    try await wait { session.diagnosticPreview.width > preview.width + 100 }
    session.diagnosticMoreMenu.performActionForItem(at: zoomIndex)
    try await wait { abs(session.diagnosticPreview.width - preview.width) < 1 }
    try require(session.diagnosticPanelSize.height < 310, "正常状态仍占用大段文字空间")
    let buttons = session.diagnosticControls.compactMap { $0 as? NSButton }
    try require(buttons.count == 5 && buttons.allSatisfy { $0.image != nil && $0.toolTip != nil }, "主操作未精简为带说明的图标")
    if let directory = ProcessInfo.processInfo.environment["SCREENSHOT_SELFTEST_DIR"],
       let view = session.diagnosticControls.first,
       let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("scroll-panel.png"))
    }
    // 保留真正的最后一帧排空检查：末帧投递后立即完成，不等待处理。
    provider.source.send(image(322))
    session.finishCapture()
    do { try await wait { completed } }
    catch {
        print("结束阶段状态：\(session.diagnosticSnapshot)，采集已停止：\(provider.source.stopped)，提示：\(session.diagnosticNotice.text)")
        throw error
    }
    try require(provider.source.stopped, "完成后未停止采集源")
    guard let output else { throw CaptureError.message("连续滚动未生成图片") }
    let copiedPNG = try output.png()
    try require(clipboard.data(forType: .png) == copiedPNG, "默认完成未将完整 PNG 写入剪贴板")
    try require(output.height == 562, "连续滚动末段丢失：\(output.height)")
    let expected = document.cropping(to: CGRect(x: 0, y: 0, width: width, height: 562))!
    // 直接比较解码后的 RGBA 字节，验证每一行和每个颜色通道，而非只看尺寸。
    func rgba(_ image: CGImage) -> Data {
        let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: ctx.data!, count: image.width * image.height * 4)
    }
    try require(rgba(output) == rgba(expected), "连续合成存在错行、漏行或颜色变化")
    let directory = ProcessInfo.processInfo.environment["SCREENSHOT_SELFTEST_DIR"] ?? NSTemporaryDirectory()
    try output.png().write(to: URL(fileURLWithPath: directory).appendingPathComponent("continuous-scroll.png"), options: .atomic)

    let otherProvider = FixtureProvider()
    let other = ScrollSession(provider: otherProvider, region: region, hotkeys: HotkeyRegistry(), clipboard: clipboard)
    defer { other.cancelCapture() }
    var otherCompleted = false, otherImage: CGImage?
    other.completion = { image, _ in otherImage = image; otherCompleted = true }
    _ = other.start(registerHotkeys: false, showPanel: false)
    try await Task.sleep(for: .milliseconds(30))
    otherProvider.source.send(image(0))
    try await wait { other.diagnosticSnapshot.count == 1 }
    let stableLayout = other.diagnosticNotice
    otherProvider.source.send(image(600))
    try await wait { other.diagnosticSnapshot.pending }
    try require(!other.diagnosticNotice.visible, "短暂失配不应显示滚动提示")
    try require(other.diagnosticNotice.panelFrame == stableLayout.panelFrame && other.diagnosticNotice.previewFrame == stableLayout.previewFrame,
                "短暂失配改变了预览位置")
    otherProvider.source.send(image(40))
    try await wait { other.diagnosticSnapshot.count == 2 }
    try require(!other.diagnosticSnapshot.pending, "短暂失配未恢复")
    otherProvider.source.send(image(700))
    try await wait { other.diagnosticSnapshot.paused }
    try require(other.diagnosticNotice.visible && !other.diagnosticNotice.text.isEmpty, "明确失配后没有悬浮提示")
    try require(other.diagnosticNotice.panelFrame == stableLayout.panelFrame && other.diagnosticNotice.previewFrame == stableLayout.previewFrame,
                "异常提示挤动了预览或工具栏")
    // 超时后仍应监听；回到已确认锚点附近，无需点击重试。
    otherProvider.source.send(image(60))
    try await wait { other.diagnosticSnapshot.count == 3 && !other.diagnosticSnapshot.paused }
    try require(!other.diagnosticNotice.visible && other.diagnosticNotice.panelFrame == stableLayout.panelFrame && other.diagnosticNotice.previewFrame == stableLayout.previewFrame,
                "恢复后提示未消失，或预览产生了布局跳动")
    other.undo()
    try require(other.diagnosticSnapshot.count == 2, "自动恢复后撤销失败")
    other.undo()
    try require(other.diagnosticSnapshot.count == 1 && other.diagnosticSnapshot.height == 240, "撤销没有恢复锚点")
    otherProvider.source.send(image(30))
    try await wait { other.diagnosticSnapshot.count == 2 }
    otherProvider.source.send(image(600))
    try await wait { other.diagnosticSnapshot.pending }
    other.finishCapture()
    try await wait { other.diagnosticSnapshot.paused && otherProvider.source.stopped }
    try require(!otherCompleted, "未确认的末段被静默丢弃")
    other.finishCapture()
    try await wait { otherCompleted }
    try require(otherImage?.height == 270, "完成已确认部分的尺寸不正确")
    let editProvider = FixtureProvider()
    let editing = ScrollSession(provider: editProvider, region: region, hotkeys: HotkeyRegistry(), clipboard: clipboard)
    defer { editing.cancelCapture() }
    var editComplete = false
    editing.completion = { image, action in editComplete = image != nil && action == .edit }
    _ = editing.start(registerHotkeys: false, showPanel: false)
    try await Task.sleep(for: .milliseconds(30))
    editProvider.source.send(image(0))
    try await wait { editing.diagnosticSnapshot.count == 1 }
    let beforeEdit = clipboard.data(forType: .png)
    guard let editButton = editing.diagnosticControls.compactMap({ $0 as? NSButton }).first(where: { $0.toolTip == "编辑长截图" }) else {
        throw CaptureError.message("缺少显式编辑入口")
    }
    editButton.performClick(nil)
    try await wait { editComplete }
    try require(clipboard.data(forType: .png) == beforeEdit, "点击编辑不应先覆盖剪贴板")
    let saveProvider = FixtureProvider()
    let saving = ScrollSession(provider: saveProvider, region: region, hotkeys: HotkeyRegistry(), clipboard: clipboard)
    defer { saving.cancelCapture() }
    var saveComplete = false
    saving.completion = { image, action in saveComplete = image != nil && action == .save }
    _ = saving.start(registerHotkeys: false, showPanel: false)
    try await Task.sleep(for: .milliseconds(30))
    saveProvider.source.send(image(0))
    try await wait { saving.diagnosticSnapshot.count == 1 }
    guard let saveButton = saving.diagnosticControls.compactMap({ $0 as? NSButton }).first(where: { $0.toolTip == "保存 PNG" }) else {
        throw CaptureError.message("缺少保存入口")
    }
    saveButton.performClick(nil)
    try await wait { saveComplete }
    let expectedSavedPNG = try image(0).png()
    try require(clipboard.data(forType: .png) == expectedSavedPNG, "保存分支没有先保留 PNG 到剪贴板")
    let cancelProvider = FixtureProvider()
    let cancelled = ScrollSession(provider: cancelProvider, region: region, hotkeys: HotkeyRegistry(), clipboard: clipboard)
    var callbacks = 0
    cancelled.completion = { value, _ in if value == nil { callbacks += 1 } }
    _ = cancelled.start(registerHotkeys: false, showPanel: false)
    try await Task.sleep(for: .milliseconds(30))
    cancelProvider.source.send(image(0))
    cancelled.cancelCapture()
    try await wait { cancelProvider.source.stopped }
    try await Task.sleep(for: .milliseconds(100))
    try require(callbacks == 1 && cancelled.diagnosticSnapshot.count == 0 && cancelled.diagnosticSnapshot.bytes == 0,
                "取消后旧结果写回或资源未释放")
    // 从文档中部开始，向上、向下越过原始范围；往返范围内的内容只保存一次。
    let bidirectionalProvider = FixtureProvider()
    let bidirectional = ScrollSession(provider: bidirectionalProvider, region: region, hotkeys: HotkeyRegistry(), clipboard: clipboard)
    defer { bidirectional.cancelCapture() }
    var bidirectionalDone = false, bidirectionalImage: CGImage?
    bidirectional.completion = { image, _ in bidirectionalImage = image; bidirectionalDone = true }
    _ = bidirectional.start(registerHotkeys: false, showPanel: false)
    try await Task.sleep(for: .milliseconds(30))
    for (offset, rows) in [(300, 240), (240, 300), (160, 380), (280, 380), (400, 480), (250, 480), (140, 500)] {
        bidirectionalProvider.source.send(image(offset))
        if bidirectional.diagnosticSnapshot.height != rows { try await wait { bidirectional.diagnosticSnapshot.height == rows } }
        // 回看帧不增加条带，仍需让后台完成坐标更新。
        try await Task.sleep(for: .milliseconds(60))
    }
    try require(bidirectional.diagnosticPreview.originY == 0, "向上补图后预览未跟随顶部")
    bidirectional.undo()
    try require(bidirectional.diagnosticSnapshot.height == 480, "撤销向上片段错误地删除底部")
    bidirectionalProvider.source.send(image(180))
    try await Task.sleep(for: .milliseconds(100))
    try require(bidirectional.diagnosticSnapshot.height == 480, "撤销后回看产生重复内容")
    bidirectionalProvider.source.send(image(120))
    try await wait { bidirectional.diagnosticSnapshot.height == 520 }
    bidirectional.finishCapture(); try await wait { bidirectionalDone }
    let expectedBidirectional = document.cropping(to: CGRect(x: 0, y: 120, width: width, height: 520))!
    guard let bidirectionalImage else { throw CaptureError.message("双向会话没有输出") }
    try require(rgba(bidirectionalImage) == rgba(expectedBidirectional), "双向输出存在重行、漏行或方向颠倒")
    try require(clipboard.data(forType: .png) == bidirectionalImage.png(), "双向结果未完整复制")

    // 一次性突发投递，消费者尚未运行时必然超过队列容量；末帧不能被旧帧取代。
    let burstProvider = FixtureProvider()
    let burst = ScrollSession(provider: burstProvider, region: region, hotkeys: HotkeyRegistry(), clipboard: clipboard)
    defer { burst.cancelCapture() }
    var burstDone = false, burstImage: CGImage?
    burst.completion = { image, _ in burstImage = image; burstDone = true }
    _ = burst.start(registerHotkeys: false, showPanel: false)
    try await Task.sleep(for: .milliseconds(30))
    burstProvider.source.send(image(0)); try await wait { burst.diagnosticSnapshot.count == 1 }
    for offset in stride(from: 7, through: 140, by: 7) { burstProvider.source.send(image(offset)) }
    burst.finishCapture(); try await wait { burstDone }
    let expectedBurst = document.cropping(to: CGRect(x: 0, y: 0, width: width, height: 380))!
    guard let burstImage else { throw CaptureError.message("突发帧会话未完成") }
    try require(rgba(burstImage) == rgba(expectedBurst), "慢消费者未保留最后一帧或末段未排空")

    // 在后台合成已经开始、尚未返回时取消，迟到结果不能写剪贴板或二次回调。
    let latch = CompositionPause(), lateProvider = FixtureProvider()
    let late = ScrollSession(provider: lateProvider, region: region, hotkeys: HotkeyRegistry(), clipboard: clipboard,
        composeImage: { pieces in
            await latch.wait()
            let result = compose(pieces)
            await latch.markReturned(); return result
        })
    var lateCallbacks = 0
    late.completion = { image, _ in lateCallbacks += 1; if image != nil { fatalError("取消后输出了合成结果") } }
    _ = late.start(registerHotkeys: false, showPanel: false)
    try await Task.sleep(for: .milliseconds(30))
    lateProvider.source.send(image(0)); try await wait { late.diagnosticSnapshot.count == 1 }
    let beforeLate = clipboard.data(forType: .png)
    late.finishCapture(); try await wait { latch.entered }
    late.cancelCapture(); late.cancelCapture(); latch.release()
    try await wait { latch.returned }
    try await Task.sleep(for: .milliseconds(50))
    try require(lateCallbacks == 1 && clipboard.data(forType: .png) == beforeLate && late.diagnosticSnapshot.bytes == 0,
                "合成中取消未阻断迟到输出或未释放片段")
    print("连续帧、双向扩展/往返去重/向上撤销逐像素一致；突发队列末帧排空、合成中取消、PNG复制、编辑/保存和异常确认通过")
}

/// 真正经过窗口合成器和 SCStream 的集成测试。独立测试进程绘制并连续滚动，不读取用户聊天。
@MainActor func runLiveScrollSelfTest() async throws {
    guard CGPreflightScreenCaptureAccess() else { throw CaptureError.message("真实滚动测试需要已有录屏授权；未申请或修改权限") }
    guard let executable = ProcessInfo.processInfo.environment["SCREENSHOT_SCROLL_FIXTURE_EXEC"] else {
        throw CaptureError.message("请通过 scripts/test-live-scroll.sh 运行")
    }
    let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("screenshot-scroll-test-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable); process.arguments = [directory.path]
    try process.run()
    defer { if process.isRunning { process.terminate() }; try? FileManager.default.removeItem(at: directory) }
    var recordDocumentationFrame: (() -> Void)?
    var documentationFrames: [CGImage] = []
    var lastDocumentationFrame = 0.0
    func wait(_ condition: () -> Bool, seconds: Double = 8) async throws {
        let end = ProcessInfo.processInfo.systemUptime + seconds
        while !condition() {
            recordDocumentationFrame?()
            guard process.isRunning else { throw CaptureError.message("测试页面进程已退出") }
            guard ProcessInfo.processInfo.systemUptime < end else { throw CaptureError.message("真实滚动回归超时") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
    let ready = directory.appendingPathComponent("ready.json")
    try await wait { FileManager.default.fileExists(atPath: ready.path) }
    let info = try JSONSerialization.jsonObject(with: Data(contentsOf: ready)) as! [String: Double]
    let rect = CGRect(x: info["x"]!, y: info["y"]!, width: info["width"]!, height: info["height"]!)
    let provider = MacCaptureProvider()
    try await provider.prepare()
    let reference = NSImage(contentsOf: directory.appendingPathComponent("reference.png"))!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    let firstExpected = reference.cropping(to: CGRect(x: 0, y: 0, width: reference.width, height: Int(rect.height * info["scale"]!)))!
    let firstCapture = try await provider.capture(rect)
    let initialError = StitchMatcher().difference(firstCapture.grayFrame(), firstExpected.grayFrame())
    guard initialError < 1 else { throw CaptureError.message("测试窗口首帧与参考不符（可能遮挡或尚未显示），亮度误差 \(initialError)") }
    let clipboard = NSPasteboard(name: .init("Screenshot-Live-Test-" + UUID().uuidString))
    defer { clipboard.releaseGlobally() }
    let session = ScrollSession(provider: provider, region: rect, hotkeys: HotkeyRegistry(), clipboard: clipboard)
    var complete = false, result: CGImage?
    session.completion = { image, _ in result = image; complete = true }
    defer { session.cancelCapture() }
    _ = session.start(registerHotkeys: false, showPanel: true)
    try await wait { session.diagnosticSnapshot.count > 0 }
    if ProcessInfo.processInfo.environment["SCREENSHOT_DOCUMENTATION_DIR"] != nil {
        recordDocumentationFrame = {
            let now = ProcessInfo.processInfo.systemUptime
            guard now - lastDocumentationFrame >= 0.15, documentationFrames.count < 64,
                  let view = session.diagnosticControls.first,
                  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            if let image = bitmap.cgImage { documentationFrames.append(image); lastDocumentationFrame = now }
        }
    }
    try Data().write(to: directory.appendingPathComponent("go"))
    let expectedHeight = Int((info["height"]! * info["scale"]!) + info["offset"]!)
    do { try await wait { session.diagnosticSnapshot.height >= expectedHeight || session.diagnosticSnapshot.paused } }
    catch {
        let progress = (try? String(contentsOf: directory.appendingPathComponent("progress.json"), encoding: .utf8)) ?? "no progress"
        throw CaptureError.message("真实滚动未完成：\(session.diagnosticSnapshot)，fixture=\(progress)，\(error.localizedDescription)")
    }
    guard !session.diagnosticSnapshot.paused else { throw CaptureError.message("真实滚动发生暂停：\(session.diagnosticSnapshot)，\(session.diagnosticControls.compactMap { ($0 as? NSTextField)?.stringValue }.joined(separator: " / "))") }
    var documentationPreview: Data?
    if ProcessInfo.processInfo.environment["SCREENSHOT_DOCUMENTATION_DIR"] != nil,
       let view = session.diagnosticControls.first,
       let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
        view.cacheDisplay(in: view.bounds, to: bitmap)
        documentationPreview = bitmap.representation(using: .png, properties: [:])
    }
    recordDocumentationFrame = nil
    session.finishCapture()
    try await wait { complete }
    guard let result, result.height == expectedHeight else { throw CaptureError.message("真实滚动的最终高度不正确") }
    let expected = reference.cropping(to: CGRect(x: 0, y: 0, width: result.width, height: expectedHeight))!
    let actualGray = result.grayFrame(), expectedGray = expected.grayFrame()
    let difference = StitchMatcher().difference(actualGray, expectedGray)
    // 边框只占很少像素，全图均值可能仍通过；逐行、逐列检查以捕捉控件污染。
    var worstRow = 0.0, worstColumn = 0.0
    for y in 0..<actualGray.height {
        var sum = 0
        for x in 0..<actualGray.width { sum += abs(Int(actualGray.pixels[y * actualGray.width + x]) - Int(expectedGray.pixels[y * actualGray.width + x])) }
        worstRow = max(worstRow, Double(sum) / Double(actualGray.width))
    }
    for x in 0..<actualGray.width {
        var sum = 0
        for y in 0..<actualGray.height { sum += abs(Int(actualGray.pixels[y * actualGray.width + x]) - Int(expectedGray.pixels[y * actualGray.width + x])) }
        worstColumn = max(worstColumn, Double(sum) / Double(actualGray.height))
    }
    guard worstRow < 1, worstColumn < 1 else { throw CaptureError.message("真实输出含错行或边框污染：row=\(worstRow), column=\(worstColumn)") }
    guard difference < 1 else { throw CaptureError.message("真实屏幕输出与原始测试页面不一致：亮度误差 \(difference)") }
    // 文档素材仅在输出与生成参考完全一致后写出，避免把遮挡内容带进仓库。
    if let directory = ProcessInfo.processInfo.environment["SCREENSHOT_DOCUMENTATION_DIR"] {
        guard difference == 0, let documentationPreview else { throw CaptureError.message("文档素材与参考不完全一致，未导出") }
        try documentationPreview.write(to: URL(fileURLWithPath: directory).appendingPathComponent("scroll-preview.png"), options: .atomic)
        try result.png().write(to: URL(fileURLWithPath: directory).appendingPathComponent("scroll-result.png"), options: .atomic)
        let gifURL = URL(fileURLWithPath: directory).appendingPathComponent("scrolling.gif")
        if !documentationFrames.isEmpty,
           let gif = CGImageDestinationCreateWithURL(gifURL as CFURL, UTType.gif.identifier as CFString, documentationFrames.count, nil) {
            CGImageDestinationSetProperties(gif, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
            for (index, frame) in documentationFrames.enumerated() {
                let delay = index == documentationFrames.count - 1 ? 1.5 : 0.15
                CGImageDestinationAddImage(gif, frame, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary)
            }
            guard CGImageDestinationFinalize(gif) else { throw CaptureError.message("无法生成滚动演示 GIF") }
        }
    }
    print("LIVE SCROLL PASSED: SCStream + native scrolling window, \(result.width)x\(result.height), mean luminance error=\(difference)")
}

/// 用生成页面驱动真实会话和原生控件，离线更新文档素材，不读取屏幕。
@MainActor func writeDocumentationScroll(to directory: URL) async throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let document = makeDemoImage(), height = min(600, document.height), end = min(900, document.height - height)
    let provider = FixtureProvider(), board = NSPasteboard(name: .init("Screenshot-Documentation-" + UUID().uuidString))
    defer { board.releaseGlobally() }
    let session = ScrollSession(provider: provider, region: CGRect(x: 0, y: 0, width: document.width, height: height), hotkeys: HotkeyRegistry(), clipboard: board)
    defer { session.cancelCapture() }
    var done = false, output: CGImage?, frames: [CGImage] = []
    session.completion = { image, _ in output = image; done = true }
    guard session.start(registerHotkeys: false, showPanel: false) else { throw CaptureError.message("文档演示无法启动") }
    try await Task.sleep(for: .milliseconds(50))
    func wait(_ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw CaptureError.message("文档演示等待超时") }
            try await Task.sleep(for: .milliseconds(15))
        }
    }
    for offset in stride(from: 0, through: end, by: 30) {
        let before = session.diagnosticSnapshot.count
        provider.source.send(document.cropping(to: CGRect(x: 0, y: offset, width: document.width, height: height))!)
        try await wait { session.diagnosticSnapshot.count > before }
        try await Task.sleep(for: .milliseconds(160))
        if let view = session.diagnosticControls.first, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            if let frame = bitmap.cgImage { frames.append(frame) }
        }
    }
    session.finishCapture(); try await wait { done }
    guard let output, output.height == height + end, let last = frames.last else { throw CaptureError.message("文档演示输出不完整") }
    let expected = document.cropping(to: CGRect(x: 0, y: 0, width: document.width, height: height + end))!
    func rgba(_ image: CGImage) -> Data {
        let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: ctx.data!, count: image.width * image.height * 4)
    }
    guard rgba(output) == rgba(expected) else { throw CaptureError.message("文档演示与生成参考不一致，未导出") }
    try output.png().write(to: directory.appendingPathComponent("scroll-result.png"), options: .atomic)
    try last.png().write(to: directory.appendingPathComponent("scroll-preview.png"), options: .atomic)
    guard let gif = CGImageDestinationCreateWithURL(directory.appendingPathComponent("scrolling.gif") as CFURL, UTType.gif.identifier as CFString, frames.count, nil) else { throw CaptureError.message("无法创建文档 GIF") }
    CGImageDestinationSetProperties(gif, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
    for (i, frame) in frames.enumerated() {
        CGImageDestinationAddImage(gif, frame, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: i == frames.count - 1 ? 1.5 : 0.15]] as CFDictionary)
    }
    guard CGImageDestinationFinalize(gif) else { throw CaptureError.message("文档 GIF 写入失败") }
    print("离线文档素材通过：原生控件、合成滚动帧及逐像素结果验证；未读取桌面。")
}
