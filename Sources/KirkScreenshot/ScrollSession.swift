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
    private var stopped = false
    private var memoryBytes = 0
    private let panel: PassivePanel
    private let status = NSTextField(wrappingLabelWithString: "准备捕获…")
    private let preview = NSImageView()
    private let count = NSTextField(labelWithString: "")
    var diagnosticSnapshot: (height: Int, count: Int, paused: Bool, pending: Bool, bytes: Int) {
        (pieces.reduce(0) { $0 + $1.addedRows }, pieces.count, paused, pending, memoryBytes)
    }
    var completion: ((CGImage?) -> Void)?
    init(provider: RegionCaptureProvider, region: CGRect, hotkeys: HotkeyRegistry) {
        self.provider = provider; self.region = region; self.hotkeys = hotkeys
        panel = PassivePanel(contentRect: CGRect(x: 0, y: 0, width: 310, height: 370),
                             styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "滚动捕获"; panel.level = .floating; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        status.font = .systemFont(ofSize: 13); status.maximumNumberOfLines = 4
        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.wantsLayer = true; preview.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        preview.heightAnchor.constraint(equalToConstant: 165).isActive = true
        let retry = NSButton(title: "重试", target: self, action: #selector(resume))
        let undo = NSButton(title: "撤销上一段", target: self, action: #selector(undo))
        let finish = NSButton(title: "完成 ↩", target: self, action: #selector(finishCapture))
        let cancel = NSButton(title: "取消 Esc", target: self, action: #selector(cancelCapture))
        let row = NSStackView(views: [retry, undo]); row.orientation = .horizontal
        let bottom = NSStackView(views: [finish, cancel]); bottom.orientation = .horizontal
        let stack = NSStackView(views: [status, count, preview, row, bottom]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false; panel.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor, constant: 16), stack.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor, constant: -16), stack.topAnchor.constraint(equalTo: panel.contentView!.topAnchor, constant: 16), preview.widthAnchor.constraint(equalTo: stack.widthAnchor)])
        // 尽量放在选区外；即使覆盖选区，也通过 ScreenCaptureKit 排除整个本应用。
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(region) }) {
            let x = region.maxX + 12 + 310 <= screen.visibleFrame.maxX ? region.maxX + 12 : screen.visibleFrame.minX + 12
            panel.setFrameOrigin(CGPoint(x: x, y: max(screen.visibleFrame.minY, min(region.maxY - 400, screen.visibleFrame.maxY - 400))))
        }
    }
    func start(registerHotkeys: Bool = true, showPanel: Bool = true) -> Bool {
        if registerHotkeys {
            guard hotkeys.register("session.finish", shortcut: Shortcut(key: 36, modifiers: 0, label: "↩"), action: { [weak self] in self?.finishCapture() }) else { return false }
            guard hotkeys.register("session.cancel", shortcut: Shortcut(key: 53, modifiers: 0, label: "Esc"), action: { [weak self] in self?.cancelCapture() }) else { hotkeys.unregister("session.finish"); return false }
        }
        if showPanel { panel.orderFrontRegardless() }
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
                if case .paused(let reason) = timeout { self.pause(self.message(reason)) }
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
                let source = try self.provider.makeStream(self.region)
                retainedSource = source; self.stream = source
                try await source.start()
                if self.stopped || Task.isCancelled { await source.stop(); return }
                for try await frame in source.frames {
                    guard !self.stopped, !Task.isCancelled else { break }
                    guard !self.paused else { continue }
                    let activeProcessor = self.processor
                    let frameEpoch = self.generation
                    let output = await activeProcessor.process(frame)
                    guard frameEpoch == self.generation, !self.stopped, !self.paused else { continue }
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
            pending = false; confirmPartial = false
            append(piece)
        case .duplicate:
            pending = false
            status.stringValue = "捕获中 · 可连续向下滚动，无需逐次停顿。回车完成，Esc 取消。"
        case .recovering:
            pending = true; confirmPartial = false
            status.stringValue = "正在恢复接缝…可稍停或回滚一点；已确认的内容已保留。"
        case .paused(let reason): pending = true; pause(message(reason))
        }
    }
    private func message(_ reason: MatchResult) -> String {
        switch reason {
        case .reverse: return "持续向上滚动。请回到预览末尾附近后重试；需要删除内容时用撤销。"
        case .ambiguous: return "重复内容无法唯一定位接缝。请回到预览末尾附近重试，或扩大选区以包含更多特征。"
        case .incompatibleSize: return "像素尺寸或缩放发生变化，请取消并重新框选。"
        case .changedContent: return "内容持续变化。请避开固定栏、动画或新消息，再回到预览末尾附近重试。"
        default: return "持续无法找到可靠重叠，可能滚动过快或内容重排。请回到预览末尾附近重试；可撤销上一段。"
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
        // 缩略图直接绘制片段，避免每帧分配完整长图。
        let h = pieces.reduce(0) { $0 + $1.addedRows }, w = pieces.first?.image.width ?? 1
        let scale = min(250 / Double(w), 165 / Double(h))
        let size = NSSize(width: max(1, Double(w) * scale), height: max(1, Double(h) * scale))
        let thumb = NSImage(size: size)
        thumb.lockFocus()
        var top = 0.0
        for p in pieces {
            let dh = Double(p.addedRows) / Double(h) * size.height
            if let strip = p.image.cropping(to: CGRect(x: 0, y: p.image.height - p.addedRows, width: p.image.width, height: p.addedRows)) {
                strip.nsImage.draw(in: CGRect(x: 0, y: size.height - top - dh, width: size.width, height: dh))
            }
            top += dh
        }
        thumb.unlockFocus(); preview.image = thumb
        count.stringValue = "\(pieces.count) 段 · \(w) × \(h) 像素"
    }
    private func pause(_ message: String) {
        paused = true; stream?.setPaused(true)
        updatePreview()
        status.stringValue = "已暂停：" + message
    }
    @objc func resume() {
        guard !stopped, !finishing else { return }
        guard !layoutInvalid else { status.stringValue = "显示器布局已变化，请完成已有部分或取消后重新框选。"; return }
        generation += 1
        processor = ScrollProcessor(anchor: pieces.last?.frame)
        pending = !pieces.isEmpty; confirmPartial = false; paused = false
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
        pending = false; confirmPartial = false
        pause("已撤销。请回滚至保留片段附近后重试。")
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
        panel.orderOut(nil); panel.close(); pieces.removeAll(); memoryBytes = 0
        processor = ScrollProcessor()
    }
}
