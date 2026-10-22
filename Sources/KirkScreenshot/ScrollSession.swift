import AppKit
import StitchCore

final class PassivePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct ProcessedFrame: @unchecked Sendable {
    let result: TrackingResult
    let piece: StitchPiece?
}

private actor ScrollProcessor {
    private var tracker = ContinuousStitchTracker()
    init(anchor: GrayFrame? = nil) { tracker.reset(anchor: anchor) }
    func process(_ input: CapturedFrame) -> ProcessedFrame {
        let frame = input.image.grayFrame()
        let result = tracker.consume(frame, at: input.time)
        let rows: Int
        switch result {
        case .seed: rows = input.image.height
        case .append(let added): rows = added
        default: return ProcessedFrame(result: result, piece: nil)
        }
        let piece = copiedStrip(input.image, rows: rows).map { StitchPiece(image: $0, addedRows: rows, frame: frame) }
        return ProcessedFrame(result: result, piece: piece)
    }
    func timeout(at time: Double) -> TrackingResult? { tracker.timeout(at: time) }
}

/// 按固定横向比例绘制，不把整张长图压进一张越来越小的缩略图。
private final class ScrollPreviewCanvas: NSView {
    var pieces: [StitchPiece] = []
    var zoom: CGFloat = 1
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.underPageBackgroundColor.setFill(); bounds.fill()
        var top: CGFloat = 0
        for piece in pieces {
            let height = CGFloat(piece.addedRows) * zoom
            let rect = CGRect(x: 0, y: top, width: CGFloat(piece.image.width) * zoom, height: height)
            if rect.intersects(dirtyRect) {
                piece.image.nsImage.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            top += height
        }
    }
}

@MainActor final class ScrollSession {
    private let provider: RegionCaptureProvider
    private let region: CGRect
    private let hotkeys: HotkeyRegistry
    private var task: Task<Void, Never>?
    private var pieces: [StitchPiece] = []
    private var stream: (any RegionFrameStream)?
    private var watchdog: Task<Void, Never>?
    private var finishTask: Task<Void, Never>?
    private var processor = ScrollProcessor()
    private var generation = 0
    private var revision = 0
    private var pending = false
    private var finishing = false
    private var confirmPartial = false
    private var layoutInvalid = false
    private var screenObserver: NSObjectProtocol?
    private var previewTime = 0.0
    private var paused = false
    private var automaticRecovery = false
    private var stopped = false
    private var memoryBytes = 0
    private let boundary: CaptureBoundary
    private var previewExpanded = false
    private var previewHeight: NSLayoutConstraint!
    private var panelWidth: NSLayoutConstraint!
    private let panel: PassivePanel
    private let status = NSTextField(wrappingLabelWithString: "准备捕获…")
    private let preview = NSScrollView()
    private let previewCanvas = ScrollPreviewCanvas()
    private let followPreview = NSButton(checkboxWithTitle: "跟随末尾", target: nil, action: nil)
    private let count = NSTextField(labelWithString: "")
    var diagnosticSnapshot: (height: Int, count: Int, paused: Bool, pending: Bool, bytes: Int) {
        (pieces.reduce(0) { $0 + $1.addedRows }, pieces.count, paused, pending, memoryBytes)
    }
    var diagnosticControls: [NSView] {
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        return panel.contentView.map(descendants) ?? []
    }
    var diagnosticPreview: (visible: Bool, width: CGFloat, contentHeight: CGFloat, viewportHeight: CGFloat, originY: CGFloat) {
        (!preview.isHidden, preview.frame.width, previewCanvas.frame.height, preview.contentSize.height, preview.contentView.bounds.origin.y)
    }
    var completion: ((CGImage?) -> Void)?
    init(provider: RegionCaptureProvider, region: CGRect, hotkeys: HotkeyRegistry) {
        self.provider = provider; self.region = region; self.hotkeys = hotkeys
        boundary = CaptureBoundary(region: region)
        panel = PassivePanel(contentRect: CGRect(x: 0, y: 0, width: 300, height: 190),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "滚动捕获"; panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1); panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = true; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        status.font = .systemFont(ofSize: 13); status.maximumNumberOfLines = 3
        preview.hasVerticalScroller = true; preview.autohidesScrollers = true; preview.scrollerStyle = .overlay
        preview.verticalScrollElasticity = .none; preview.horizontalScrollElasticity = .none
        preview.documentView = previewCanvas
        previewHeight = preview.heightAnchor.constraint(equalToConstant: 240); previewHeight.isActive = true
        followPreview.state = .on
        let retry = NSButton(title: "重试", target: self, action: #selector(resume))
        let undo = NSButton(title: "撤销上一段", target: self, action: #selector(undo))
        let finish = NSButton(title: "完成 ↩", target: self, action: #selector(finishCapture))
        let cancel = NSButton(title: "取消 Esc", target: self, action: #selector(cancelCapture))
        let thumbnail = NSButton(title: "放大预览", target: self, action: #selector(toggleThumbnail(_:)))
        let row = NSStackView(views: [retry, undo, thumbnail]); row.orientation = .horizontal
        let bottom = NSStackView(views: [finish, cancel]); bottom.orientation = .horizontal
        let meta = NSStackView(views: [count, followPreview]); meta.spacing = 8
        let stack = NSStackView(views: [status, meta, preview, row, bottom]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        panelWidth = stack.widthAnchor.constraint(equalToConstant: 296); panelWidth.isActive = true
        panel.contentView = captureToolbar(views: [stack])
        positionPanel()
    }
    private func positionPanel() {
        let screen = NSScreen.screens.first(where: { $0.frame.contains(region) }) ?? NSScreen.main!
        let bounds = screen.visibleFrame
        let width = previewExpanded ? min(720, bounds.width - 24) : min(320, bounds.width - 24)
        panelWidth.constant = width - 24
        previewHeight.constant = min(previewExpanded ? 420 : 240, max(100, bounds.height - 230))
        panel.contentView?.layoutSubtreeIfNeeded()
        let size = CGSize(width: width, height: min(bounds.height - 16, max(360, panel.contentView!.fittingSize.height)))
        var frame = CaptureLayout.toolbar(near: region, size: size, within: bounds)
        if region.maxX + size.width + 20 <= bounds.maxX {
            frame.origin = CGPoint(x: region.maxX + 10, y: max(bounds.minY + 8, min(region.maxY - size.height, bounds.maxY - size.height - 8)))
        } else if region.minX - size.width - 20 >= bounds.minX {
            frame.origin = CGPoint(x: region.minX - size.width - 10, y: max(bounds.minY + 8, min(region.maxY - size.height, bounds.maxY - size.height - 8)))
        }
        panel.setFrame(frame, display: true)
    }
    @objc private func toggleThumbnail(_ sender: NSButton) {
        previewExpanded.toggle(); sender.title = previewExpanded ? "缩小预览" : "放大预览"
        positionPanel(); updatePreview()
    }

    func start(registerHotkeys: Bool = true, showPanel: Bool = true) -> Bool {
        if registerHotkeys {
            guard hotkeys.register("session.finish", shortcut: Shortcut(key: 36, modifiers: 0, label: "↩"), action: { [weak self] in self?.finishCapture() }) else { return false }
            guard hotkeys.register("session.cancel", shortcut: Shortcut(key: 53, modifiers: 0, label: "Esc"), action: { [weak self] in self?.cancelCapture() }) else { hotkeys.unregister("session.finish"); return false }
        }
        if showPanel { boundary.show(); panel.orderFrontRegardless() }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.stopped else { return }
                self.layoutInvalid = true; self.pending = true
                self.pause("显示器布局或缩放已变化，请完成已有部分或取消后重新框选。")
            }
        }
        launchStream()
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self, !self.stopped else { return }
                guard !self.paused, !self.finishing else { continue }
                let epoch = self.generation, revision = self.revision
                let timeout = await self.processor.timeout(at: ProcessInfo.processInfo.systemUptime)
                guard epoch == self.generation, revision == self.revision, self.pending, !self.paused, !self.stopped, !self.finishing else { continue }
                if case .paused(let reason) = timeout { self.pause(self.message(reason), automatically: reason != .incompatibleSize) }
            }
        }
        return true
    }
    private func launchStream() {
        task = Task { [weak self] in
            guard let self, !self.stopped, !Task.isCancelled else { return }
            var retainedSource: (any RegionFrameStream)?
            defer { if let retainedSource, self.stream === retainedSource { self.stream = nil } }
            do {
                let source = try await self.provider.makeStream(self.region)
                retainedSource = source; self.stream = source
                guard !self.stopped, !Task.isCancelled else { await source.stop(); return }
                try await source.start()
                if self.stopped || Task.isCancelled { await source.stop(); return }
                for try await frame in source.frames {
                    guard !self.stopped, !Task.isCancelled else { break }
                    guard !self.paused || self.automaticRecovery else { continue }
                    let activeProcessor = self.processor
                    let frameEpoch = self.generation
                    let output = await activeProcessor.process(frame)
                    guard frameEpoch == self.generation, !self.stopped, (!self.paused || self.automaticRecovery) else { continue }
                    self.consume(output)
                }
                await source.stop()
            } catch {
                if !self.stopped {
                    self.pending = true
                    self.pause("捕获失败：\(error.localizedDescription)。请检查权限或重新框选。")
                }
                await retainedSource?.stop()
            }
        }
    }
    private func consume(_ output: ProcessedFrame) {
        revision += 1
        switch output.result {
        case .seed, .append:
            guard let piece = output.piece else { pending = true; pause("内存不足，无法保存新增片段。已有内容仍保留。"); return }
            paused = false; automaticRecovery = false
            pending = false; confirmPartial = false
            append(piece)
        case .duplicate:
            paused = false; automaticRecovery = false
            pending = false; confirmPartial = false
            status.stringValue = "捕获中 · 可连续向下滚动，无需逐次停顿。回车完成，Esc 取消。"
        case .recovering:
            pending = true; confirmPartial = false
            status.stringValue = "正在恢复接缝…可稍停或回滚一点；已确认的内容已保留。"
        case .paused(let reason): pending = true; pause(message(reason), automatically: reason != .incompatibleSize)
        }
    }
    private func message(_ reason: MatchResult) -> String {
        switch reason {
        case .reverse: return "持续向上滚动。请回到预览末尾附近，会自动接续；需要删除内容时用撤销。"
        case .ambiguous: return "重复内容无法唯一定位接缝。请回到预览末尾附近，会自动接续，或扩大选区以包含更多特征。"
        case .incompatibleSize: return "像素尺寸或缩放发生变化，请取消并重新框选。"
        case .changedContent: return "内容持续变化。请避开固定栏、动画或新消息，再回到预览末尾附近，会自动接续。"
        default: return "持续无法找到可靠重叠，可能滚动过快或内容重排。请回到预览末尾附近，会自动接续；可撤销上一段。"
        }
    }
    private func append(_ piece: StitchPiece) {
        let totalRows = pieces.reduce(piece.addedRows) { $0 + $1.addedRows }
        let bytes = piece.image.bytesPerRow * piece.image.height + piece.frame.pixels.count
        guard totalRows <= 30_000, totalRows * piece.image.width <= 32_000_000, memoryBytes + bytes <= 256_000_000 else {
            pending = true; pause("达到本次捕获的尺寸或内存上限，请完成已有部分并另起一张。")
            return
        }
        pieces.append(piece); memoryBytes += bytes
        let now = ProcessInfo.processInfo.systemUptime
        if now - previewTime >= 0.15 { updatePreview(); previewTime = now }
        status.stringValue = "正在连续捕获 · 向下滚动即可，回车完成，Esc 取消。"
    }
    private func updatePreview() {
        let height = pieces.reduce(0) { $0 + $1.addedRows }, width = pieces.first?.image.width ?? 1
        count.stringValue = "\(width) × \(height) · \(pieces.count) 段"
        guard height > 0 else { return }
        let targetWidth = max(1, panel.frame.width - 24)
        let scale = targetWidth / CGFloat(width)
        previewCanvas.zoom = scale; previewCanvas.pieces = pieces
        previewCanvas.setFrameSize(CGSize(width: targetWidth, height: max(preview.contentSize.height, CGFloat(height) * scale)))
        previewCanvas.needsDisplay = true
        if followPreview.state == .on {
            preview.contentView.scroll(to: CGPoint(x: 0, y: max(0, previewCanvas.frame.height - preview.contentSize.height)))
            preview.reflectScrolledClipView(preview.contentView)
        }
    }
    private func pause(_ message: String, automatically: Bool = false) {
        let entering = !paused
        paused = true; automaticRecovery = automatically; stream?.setPaused(!automatically)
        if entering { updatePreview() }
        status.stringValue = (automatically ? "等待接续（仍在识别）：" : "已暂停：") + message
    }
    @objc func resume() {
        guard !stopped, !finishing else { return }
        guard !layoutInvalid else { status.stringValue = "显示器布局已变化，请完成已有部分或取消后重新框选。"; return }
        generation += 1
        processor = ScrollProcessor(anchor: pieces.last?.frame)
        pending = !pieces.isEmpty; confirmPartial = false; paused = false; automaticRecovery = false
        status.stringValue = "重新接续中…请回到预览末尾附近，保留重叠内容。"
        if let stream { stream.setPaused(false) } else { launchStream() }
    }
    @objc func undo() {
        guard !stopped, !finishing else { return }
        guard pieces.count > 1 else { status.stringValue = "已是第一段。"; return }
        generation += 1
        let removed = pieces.removeLast()
        memoryBytes -= removed.image.bytesPerRow * removed.image.height + removed.frame.pixels.count
        processor = ScrollProcessor(anchor: pieces.last?.frame)
        pending = true; confirmPartial = false
        updatePreview()
        pause("已撤销。请回滚至保留片段末尾附近，会自动接续。", automatically: true)
    }
    @objc func finishCapture() {
        guard !stopped, !finishing else { return }
        guard !pieces.isEmpty else { status.stringValue = "尚未取得首帧，请稍候；Esc 可取消。"; return }
        finishing = true
        status.stringValue = "正在处理最后画面…"
        // 先停止生产，再排空最多两帧的队列，避免回车时丢掉尚在处理的末段。
        let source = stream
        let captureTask = task
        finishTask = Task { [weak self] in
            guard let self else { return }
            await source?.stop()
            await captureTask?.value
            guard !self.stopped else { return }
            if self.pending && !self.confirmPartial {
                self.confirmPartial = true; self.finishing = false
                self.pause("末尾仍有未能接续的画面。再次按回车仅导出已确认部分，或回滚后重试。")
                return
            }
            let retained = self.pieces
            let image = await Task.detached(priority: .userInitiated) { compose(retained) }.value
            guard !self.stopped else { return }
            guard let image else {
                self.finishing = false
                self.pause("暂时无法生成长图，已有内容仍保留。可撤销一段或取消。")
                return
            }
            self.stop(); self.completion?(image)
        }
    }
    @objc func cancelCapture() { guard !stopped else { return }; stop(); completion?(nil) }
    private func stop() {
        stopped = true; generation += 1
        task?.cancel(); task = nil
        watchdog?.cancel(); watchdog = nil
        finishTask?.cancel(); finishTask = nil
        let source = stream; stream = nil
        Task { await source?.stop() }
        hotkeys.unregister("session.finish"); hotkeys.unregister("session.cancel")
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver); self.screenObserver = nil }
        boundary.close(); panel.orderOut(nil); panel.close(); pieces.removeAll(); previewCanvas.pieces.removeAll(); memoryBytes = 0
        processor = ScrollProcessor()
    }
}
