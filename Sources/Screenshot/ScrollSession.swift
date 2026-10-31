import AppKit
import StitchCore

enum ScrollOutputAction { case copy, edit, save }

final class PassivePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct ProcessedFrame: @unchecked Sendable {
    let result: ScrollTrackingResult
    let piece: StitchPiece?
    let checkpoint: ScrollCaptureTracker
}

private actor ScrollProcessor {
    private var tracker: ScrollCaptureTracker
    init(checkpoint: ScrollCaptureTracker = ScrollCaptureTracker()) { tracker = checkpoint }
    func process(_ input: CapturedFrame) -> ProcessedFrame {
        let frame = input.image.grayFrame()
        let result = tracker.consume(frame, at: input.time)
        let rows: Int
        switch result {
        case .seed: rows = input.image.height
        case .append(let added): rows = added
        case .prepend(let added): rows = added
        default: return ProcessedFrame(result: result, piece: nil, checkpoint: tracker)
        }
        let piece = copiedStrip(input.image, rows: rows, fromTop: tracker.lastExtensionWasUpward).map { StitchPiece(image: $0, addedRows: rows, frame: frame) }
        return ProcessedFrame(result: result, piece: piece, checkpoint: tracker)
    }
    func timeout(at time: Double) -> ScrollTrackingResult? { tracker.timeout(at: time) }
}

/// 按固定横向比例绘制，不把整张长图压进一张越来越小的缩略图。
private final class ScrollPreviewCanvas: NSView {
    var pieces: [StitchPiece] = []
    var zoom: CGFloat = 1
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.underPageBackgroundColor.setFill(); bounds.fill()
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current?.shouldAntialias = false
        var top: CGFloat = 0
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        for piece in pieces {
            let height = CGFloat(piece.addedRows) * zoom
            // 相邻条带共享同一条物理像素边界，避免缩略缩放时逐段抗锯齿产生细横线。
            let start = (top * scale).rounded() / scale
            let end = ((top + height) * scale).rounded() / scale
            let rect = CGRect(x: 0, y: start, width: CGFloat(piece.image.width) * zoom, height: end - start)
            if rect.height > 0 && rect.intersects(dirtyRect) {
                piece.image.nsImage.draw(in: rect, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.none])
            }
            top += height
        }
    }
}

@MainActor final class ScrollSession {
    private let provider: RegionCaptureProvider
    private let region: CGRect
    private let hotkeys: HotkeyRegistry
    private let clipboard: NSPasteboard
    private let composeImage: @Sendable ([StitchPiece]) async -> CGImage?
    private var task: Task<Void, Never>?
    private var pieces: [StitchPiece] = []
    // 操作历史按捕获顺序保存；图像条带按文档顺序保存，向上补图也能撤销最近一次操作。
    private var history: [(upward: Bool, checkpoint: ScrollCaptureTracker)] = []
    private var stream: (any RegionFrameStream)?
    private var watchdog: Task<Void, Never>?
    private var finishTask: Task<Void, Never>?
    private var processor = ScrollProcessor()
    private var lifecycle = CaptureLifecycle()
    private var generation: UInt64 { lifecycle.generation }
    private var revision = 0
    private var pending = false
    private var finishing: Bool { lifecycle.isFinishing }
    private var confirmPartial = false
    private var layoutInvalid = false
    private var screenObserver: NSObjectProtocol?
    private var previewTime = 0.0
    private var paused = false
    private var automaticRecovery = false
    private var stopped: Bool { lifecycle.isStopped }
    private var started = false
    private var memoryBytes = 0
    private let boundary: CaptureBoundary
    private var previewExpanded = false
    private var previewHeight: NSLayoutConstraint!
    private var panelWidth: NSLayoutConstraint!
    private let panel: PassivePanel
    private let notice = PassivePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private var noticeWidth: NSLayoutConstraint!
    private var showsUI = false
    private let status = NSTextField(wrappingLabelWithString: "准备捕获…")
    private let preview = NSScrollView()
    private let previewCanvas = ScrollPreviewCanvas()
    private var followsTail = true
    private let moreMenu = NSMenu()
    private let followItem = NSMenuItem(title: "跟随新增内容", action: nil, keyEquivalent: "")
    private let count = NSTextField(labelWithString: "")
    var diagnosticSnapshot: (height: Int, count: Int, paused: Bool, pending: Bool, bytes: Int) {
        (pieces.reduce(0) { $0 + $1.addedRows }, pieces.count, paused, pending, memoryBytes)
    }
    var diagnosticControls: [NSView] {
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        return (panel.contentView.map(descendants) ?? []) + (notice.contentView.map(descendants) ?? [])
    }
    var diagnosticPreview: (visible: Bool, width: CGFloat, contentHeight: CGFloat, viewportHeight: CGFloat, originY: CGFloat) {
        (!preview.isHidden, preview.frame.width, previewCanvas.frame.height, preview.contentSize.height, preview.contentView.bounds.origin.y)
    }
    var diagnosticMoreMenu: NSMenu { moreMenu }
    var diagnosticPanelSize: CGSize { panel.frame.size }
    var diagnosticNotice: (visible: Bool, text: String, panelFrame: CGRect, previewFrame: CGRect, frame: CGRect) {
        (!status.isHidden, status.stringValue, panel.frame, preview.convert(preview.bounds, to: nil), notice.frame)
    }
    var completion: ((CGImage?, ScrollOutputAction) -> Void)?
    init(provider: RegionCaptureProvider, region: CGRect, hotkeys: HotkeyRegistry, clipboard: NSPasteboard = .general,
         composeImage: @escaping @Sendable ([StitchPiece]) async -> CGImage? = { pieces in
             await Task.detached(priority: .userInitiated) { compose(pieces) }.value
         }) {
        self.provider = provider; self.region = region; self.hotkeys = hotkeys; self.clipboard = clipboard
        self.composeImage = composeImage
        boundary = CaptureBoundary(region: region)
        panel = PassivePanel(contentRect: CGRect(x: 0, y: 0, width: 300, height: 190),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "滚动捕获"; panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1); panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = true; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        status.font = .systemFont(ofSize: 13); status.maximumNumberOfLines = 0
        notice.title = "长截图提示"; notice.level = NSWindow.Level(rawValue: panel.level.rawValue + 1)
        notice.backgroundColor = .clear; notice.isOpaque = false; notice.hasShadow = true
        notice.hidesOnDeactivate = false; notice.ignoresMouseEvents = true; notice.isReleasedWhenClosed = false
        notice.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        noticeWidth = status.widthAnchor.constraint(equalToConstant: 336); noticeWidth.isActive = true
        notice.contentView = captureToolbar(views: [status])
        preview.hasVerticalScroller = true; preview.autohidesScrollers = true; preview.scrollerStyle = .overlay
        preview.verticalScrollElasticity = .none; preview.horizontalScrollElasticity = .none
        preview.documentView = previewCanvas
        previewHeight = preview.heightAnchor.constraint(equalToConstant: 240); previewHeight.isActive = true
        status.isHidden = true; count.isHidden = true
        preview.toolTip = "已捕获内容；回车复制并结束，Esc 取消"
        moreMenu.autoenablesItems = false
        for (title, action) in [("撤销上一段", #selector(undo)), ("重试接续", #selector(resume)), ("放大预览", #selector(toggleThumbnail(_:)))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self
            moreMenu.addItem(item)
        }
        moreMenu.addItem(.separator())
        followItem.action = #selector(toggleFollow(_:)); followItem.target = self; followItem.state = .on; moreMenu.addItem(followItem)
        let details = NSMenuItem(title: "显示尺寸与段数", action: #selector(toggleDetails(_:)), keyEquivalent: ""); details.target = self; moreMenu.addItem(details)
        let more = icon("ellipsis", "更多", #selector(showMore(_:)))
        let edit = icon("square.and.pencil", "编辑长截图", #selector(finishForEditing))
        let save = icon("square.and.arrow.down", "保存 PNG", #selector(finishForSaving))
        let cancel = icon("xmark", "取消（Esc）", #selector(cancelCapture))
        let finish = icon("checkmark", "复制并完成（回车）", #selector(finishCapture))
        finish.contentTintColor = .systemGreen; cancel.contentTintColor = .systemRed
        let spacer = NSView(); spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = NSStackView(views: [more, spacer, edit, save, cancel, finish]); row.spacing = 6
        let stack = NSStackView(views: [count, preview, row]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8; stack.detachesHiddenViews = true
        preview.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        panelWidth = stack.widthAnchor.constraint(equalToConstant: 296); panelWidth.isActive = true
        panel.contentView = captureToolbar(views: [stack])
        positionPanel()
    }
    private func positionPanel() {
        let screen = NSScreen.screens.first(where: { $0.frame.contains(region) }) ?? NSScreen.main!
        let bounds = screen.visibleFrame
        let width = previewExpanded ? min(720, bounds.width - 24) : min(280, bounds.width - 24)
        panelWidth.constant = width - 24
        previewHeight.constant = min(previewExpanded ? 420 : 220, max(100, bounds.height - 150))
        panel.contentView?.layoutSubtreeIfNeeded()
        let size = CGSize(width: width, height: min(bounds.height - 16, panel.contentView!.fittingSize.height))
        var frame = CaptureLayout.toolbar(near: region, size: size, within: bounds)
        if region.maxX + size.width + 20 <= bounds.maxX {
            frame.origin = CGPoint(x: region.maxX + 10, y: max(bounds.minY + 8, min(region.maxY - size.height, bounds.maxY - size.height - 8)))
        } else if region.minX - size.width - 20 >= bounds.minX {
            frame.origin = CGPoint(x: region.minX - size.width - 10, y: max(bounds.minY + 8, min(region.maxY - size.height, bounds.maxY - size.height - 8)))
        }
        panel.setFrame(frame, display: true)
    }
    @objc private func toggleThumbnail(_ sender: NSMenuItem) {
        previewExpanded.toggle(); sender.title = previewExpanded ? "缩小预览" : "放大预览"
        positionPanel(); updatePreview()
    }

    private func icon(_ symbol: String, _ label: String, _ action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!, target: self, action: action)
        button.isBordered = false; button.imagePosition = .imageOnly
        button.toolTip = label; button.setAccessibilityLabel(label)
        button.widthAnchor.constraint(equalToConstant: 30).isActive = true
        button.heightAnchor.constraint(equalToConstant: 30).isActive = true
        return button
    }
    @objc private func showMore(_ sender: NSButton) { moreMenu.popUp(positioning: nil, at: CGPoint(x: 0, y: sender.bounds.maxY), in: sender) }
    @objc private func toggleFollow(_ sender: NSMenuItem) {
        followsTail.toggle(); sender.state = followsTail ? .on : .off; updatePreview()
    }
    @objc private func toggleDetails(_ sender: NSMenuItem) {
        count.isHidden.toggle(); sender.state = count.isHidden ? .off : .on; positionPanel()
    }
    /// 提示独立于预览布局，只在确定的异常/操作失败时出现，不抢焦点或滚轮。
    private func showStatus(_ message: String?) {
        guard let message else {
            status.stringValue = ""; status.isHidden = true; notice.orderOut(nil); return
        }
        guard status.isHidden || status.stringValue != message else { return }
        status.stringValue = message; status.isHidden = false
        let screen = NSScreen.screens.first(where: { $0.frame.contains(region) }) ?? NSScreen.main!
        let bounds = screen.visibleFrame
        let width = min(380, bounds.width - 16)
        noticeWidth.constant = width - 24
        notice.contentView?.layoutSubtreeIfNeeded()
        let height = min(bounds.height - 16, notice.contentView!.fittingSize.height)
        let x = min(max(region.midX - width / 2, bounds.minX + 8), bounds.maxX - width - 8)
        // 有空间时放在选区上方，否则悬浮在选区内；不参与预览面板的尺寸计算。
        let above = region.maxY + 10
        let y = above + height <= bounds.maxY - 8 ? above : max(bounds.minY + 8, region.maxY - height - 10)
        notice.setFrame(CGRect(x: x, y: y, width: width, height: height), display: true)
        if showsUI { notice.orderFrontRegardless() }
    }

    func start(registerHotkeys: Bool = true, showPanel: Bool = true) -> Bool {
        guard !started, !stopped else { return false }
        if registerHotkeys {
            guard hotkeys.register("session.finish", shortcut: Shortcut(key: 36, modifiers: 0, label: "↩"), action: { [weak self] in self?.finishCapture() }) else { return false }
            guard hotkeys.register("session.cancel", shortcut: Shortcut(key: 53, modifiers: 0, label: "Esc"), action: { [weak self] in self?.cancelCapture() }) else { hotkeys.unregister("session.finish"); return false }
        }
        started = true; showsUI = showPanel
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
        case .seed, .append, .prepend:
            guard let piece = output.piece else { pending = true; pause("内存不足，无法保存新增片段。已有内容仍保留。"); return }
            paused = false; automaticRecovery = false
            pending = false; confirmPartial = false
            append(piece, checkpoint: output.checkpoint)
        case .duplicate:
            paused = false; automaticRecovery = false
            pending = false; confirmPartial = false
            showStatus(nil)
        case .recovering:
            pending = true; confirmPartial = false
            if !paused { showStatus(nil) }
        case .paused(let reason): pending = true; pause(message(reason), automatically: reason != .incompatibleSize)
        }
    }
    private func message(_ reason: MatchResult) -> String {
        switch reason {
        case .reverse: return "滚动位置无法确认。请回到已捕获内容附近，会自动接续。"
        case .ambiguous: return "重复内容无法唯一定位接缝。请回到预览顶部或底部附近，会自动接续，或扩大选区以包含更多特征。"
        case .incompatibleSize: return "像素尺寸或缩放发生变化，请取消并重新框选。"
        case .changedContent: return "内容持续变化。请避开固定栏、动画或新消息，再回到预览顶部或底部附近，会自动接续。"
        default: return "持续无法找到可靠重叠，可能滚动过快或内容重排。请回到预览顶部或底部附近，会自动接续；可撤销上一段。"
        }
    }
    private func append(_ piece: StitchPiece, checkpoint: ScrollCaptureTracker) {
        let totalRows = pieces.reduce(piece.addedRows) { $0 + $1.addedRows }
        let bytes = retainedBytes(piece)
        guard totalRows <= 30_000, totalRows * piece.image.width <= 32_000_000,
              memoryBytes + bytes + piece.frame.pixels.count * 3 <= 256_000_000 else {
            pending = true; pause("达到本次捕获的尺寸或内存上限，请完成已有部分并另起一张。")
            return
        }
        let upward = !pieces.isEmpty && checkpoint.lastExtensionWasUpward
        let changedDirection = history.last?.upward != upward
        if upward { pieces.insert(piece, at: 0) } else { pieces.append(piece) }
        history.append((upward, checkpoint)); memoryBytes += bytes
        let now = ProcessInfo.processInfo.systemUptime
        if changedDirection || now - previewTime >= 0.15 { updatePreview(); previewTime = now }
        showStatus(nil)
    }
    private func updatePreview() {
        let height = pieces.reduce(0) { $0 + $1.addedRows }, width = pieces.first?.image.width ?? 1
        count.stringValue = "\(width) × \(height) · \(pieces.count) 段"
        preview.toolTip = count.stringValue + "；回车复制并结束，Esc 取消"
        guard height > 0 else { return }
        let targetWidth = max(1, panel.frame.width - 24)
        let scale = targetWidth / CGFloat(width)
        previewCanvas.zoom = scale; previewCanvas.pieces = pieces
        previewCanvas.setFrameSize(CGSize(width: targetWidth, height: max(preview.contentSize.height, CGFloat(height) * scale)))
        previewCanvas.needsDisplay = true
        if followsTail {
            let upward = history.last?.upward == true
            preview.contentView.scroll(to: CGPoint(x: 0, y: upward ? 0 : max(0, previewCanvas.frame.height - preview.contentSize.height)))
            preview.reflectScrolledClipView(preview.contentView)
        }
    }
    private func pause(_ message: String, automatically: Bool = false) {
        let entering = !paused
        paused = true; automaticRecovery = automatically; stream?.setPaused(!automatically)
        if entering { updatePreview() }
        showStatus((automatically ? "等待接续（仍在识别）：" : "已暂停：") + message)
    }
    @objc func resume() {
        guard !stopped, !finishing else { return }
        guard !layoutInvalid else { showStatus("显示器布局已变化，请完成已有部分或取消后重新框选。"); return }
        lifecycle.invalidateProcessing()
        var checkpoint = history.last?.checkpoint ?? ScrollCaptureTracker()
        checkpoint.retry(); processor = ScrollProcessor(checkpoint: checkpoint)
        pending = !pieces.isEmpty; confirmPartial = false; paused = false; automaticRecovery = false
        showStatus(nil)
        if let stream { stream.setPaused(false) } else { launchStream() }
    }
    @objc func undo() {
        guard !stopped, !finishing else { return }
        guard pieces.count > 1 else { showStatus("已是第一段。"); return }
        lifecycle.invalidateProcessing()
        let previous = history.removeLast()
        let removed = previous.upward ? pieces.removeFirst() : pieces.removeLast()
        memoryBytes -= retainedBytes(removed)
        pending = true; confirmPartial = false
        updatePreview()
        resume()
    }
    @objc func finishCapture() { finish(action: .copy) }
    @objc private func finishForEditing() { finish(action: .edit) }
    @objc private func finishForSaving() { finish(action: .save) }
    private func finish(action: ScrollOutputAction) {
        guard !stopped, !finishing else { return }
        guard !pieces.isEmpty else { showStatus("尚未取得首帧，请稍候；Esc 可取消。"); return }
        guard let finishGeneration = lifecycle.beginFinish() else { return }
        showStatus(nil)
        // 先停止生产，再排空最多两帧的队列，避免回车时丢掉尚在处理的末段。
        let source = stream
        let captureTask = task
        finishTask = Task { [weak self] in
            guard let self else { return }
            await source?.stop()
            await captureTask?.value
            guard !self.stopped else { return }
            if self.pending && !self.confirmPartial {
                self.confirmPartial = true; self.lifecycle.resumeCapture()
                self.pause("末尾仍有未能接续的画面。再次按回车仅导出已确认部分，或回滚后重试。")
                return
            }
            let retained = self.pieces
            let image = await self.composeImage(retained)
            guard !self.stopped else { return }
            guard let image else {
                self.lifecycle.resumeCapture()
                self.pause("暂时无法生成长图，已有内容仍保留。可撤销一段或取消。")
                return
            }
            guard self.lifecycle.authorizeCommit(generation: finishGeneration) else { return }
            if action != .edit {
                do { try image.copyPNG(to: self.clipboard) }
                catch { self.lifecycle.outputFailed(); self.pause("复制失败：\(error.localizedDescription)。可再次完成或选择编辑。"); return }
            }
            self.stop(); self.completion?(image, action)
        }
    }
    @objc func cancelCapture() { guard !stopped else { return }; stop(); completion?(nil, .copy) }
    private func stop() {
        lifecycle.stop()
        task?.cancel(); task = nil
        watchdog?.cancel(); watchdog = nil
        finishTask?.cancel(); finishTask = nil
        let source = stream; stream = nil
        Task { await source?.stop() }
        hotkeys.unregister("session.finish"); hotkeys.unregister("session.cancel")
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver); self.screenObserver = nil }
        boundary.close(); notice.orderOut(nil); notice.close(); panel.orderOut(nil); panel.close(); pieces.removeAll(); history.removeAll(); previewCanvas.pieces.removeAll(); memoryBytes = 0
        processor = ScrollProcessor()
    }
    private func retainedBytes(_ piece: StitchPiece) -> Int {
        // 检查点两端均引用已保存片段的亮度数组（写时复制），不再次复制整幅 RGBA。
        piece.image.bytesPerRow * piece.image.height + piece.frame.pixels.count
    }
}
