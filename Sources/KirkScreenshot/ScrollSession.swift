import AppKit
import StitchCore

final class PassivePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor final class ScrollSession {
    private let provider: RegionCaptureProvider
    private let region: CGRect
    private let hotkeys: HotkeyRegistry
    private var task: Task<Void, Never>?
    private var pieces: [StitchPiece] = []
    private var candidate: GrayFrame?
    private var paused = false
    private var stopped = false
    private var unstableCount = 0
    private var memoryBytes = 0
    private let matcher = StitchMatcher()
    private let panel: PassivePanel
    private let status = NSTextField(wrappingLabelWithString: "准备捕获…")
    private let preview = NSImageView()
    private let count = NSTextField(labelWithString: "")
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
    func start() -> Bool {
        guard hotkeys.register("session.finish", shortcut: Shortcut(key: 36, modifiers: 0, label: "↩"), action: { [weak self] in self?.finishCapture() }) else { return false }
        guard hotkeys.register("session.cancel", shortcut: Shortcut(key: 53, modifiers: 0, label: "Esc"), action: { [weak self] in self?.cancelCapture() }) else { hotkeys.unregister("session.finish"); return false }
        panel.orderFrontRegardless()
        task = Task { [weak self] in
            while let self, !self.stopped, !Task.isCancelled {
                if !self.paused {
                    do {
                        let image = try await self.provider.capture(self.region)
                        guard !self.stopped else { break }
                        self.consume(image)
                    } catch { self.pause("捕获失败：\(error.localizedDescription)。请检查屏幕录制权限或重新框选。") }
                }
                try? await Task.sleep(for: .milliseconds(220))
            }
        }
        return true
    }
    private func consume(_ image: CGImage) {
        let frame = image.grayFrame()
        // 两次采样稳定才进行拼接，避免把滚动动画直接拼入结果。
        guard let candidate, matcher.difference(candidate, frame) < 0.8 else {
            self.candidate = frame
            unstableCount += 1
            if unstableCount >= 14 {
                pause("滚动过快或画面持续变化。请停止滚动和动画，回到上一段附近，再点击重试。")
            } else { status.stringValue = "等待画面稳定…请缓慢向下滚动，每次停顿半秒。" }
            return
        }
        unstableCount = 0
        self.candidate = frame
        if pieces.isEmpty { append(image, frame: frame, rows: image.height); return }
        switch matcher.match(previous: pieces.last!.frame, next: frame) {
        case .duplicate: status.stringValue = "捕获中 · 请向下滚动，每次不超过半屏。回车完成，Esc 取消。"
        case .append(let rows): append(image, frame: frame, rows: rows)
        case .reverse: pause("检测到向上滚动。请回到缩略图末尾对应位置，再点击重试。需要删除内容时用撤销。")
        case .ambiguous: pause("内容重复，无法唯一确定接缝。请缩小每次滚动幅度，或重新选择包含更多特征的区域。")
        case .incompatibleSize: pause("像素尺寸或缩放发生变化，请取消并重新框选。")
        case .changedContent: pause("内容发生局部变化，可能有固定栏、动画或新消息。请避开这些区域后重新框选。")
        case .insufficientOverlap: pause("重叠不足或内容已改变。请向上回滚至上一段附近，停稳后点击重试；也可撤销或完成已有部分。")
        }
    }
    private func append(_ image: CGImage, frame: GrayFrame, rows: Int) {
        let totalRows = pieces.reduce(rows) { $0 + $1.addedRows }
        let bytes = image.bytesPerRow * image.height
        guard totalRows <= 30_000, totalRows * image.width <= 32_000_000, memoryBytes + bytes <= 256_000_000 else {
            pause("达到本次捕获的尺寸或内存上限，请完成并另起一张。")
            return
        }
        pieces.append(StitchPiece(image: image, addedRows: rows, frame: frame)); memoryBytes += bytes
        updatePreview()
        status.stringValue = "已接入新片段 · 缓慢向下滚动，停稳后自动接图。"
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
    private func pause(_ message: String) { paused = true; status.stringValue = "已暂停：" + message }
    @objc private func resume() { paused = false; candidate = nil; unstableCount = 0; status.stringValue = "重新检查中…请回到上一段附近，保留至少半屏重叠。" }
    @objc private func undo() {
        guard pieces.count > 1 else { status.stringValue = "已是第一段。"; return }
        let removed = pieces.removeLast(); memoryBytes -= removed.image.bytesPerRow * removed.image.height
        updatePreview()
        pause("已撤销。请向上回滚至保留片段附近，再点击重试。")
    }
    @objc func finishCapture() {
        guard !stopped else { return }
        guard !pieces.isEmpty, let image = compose(pieces) else { pause("无法生成长图，请撤销一段后再试。尚未丢弃捕获内容。"); return }
        stop(); completion?(image)
    }
    @objc func cancelCapture() { guard !stopped else { return }; stop(); completion?(nil) }
    private func stop() {
        stopped = true; task?.cancel(); task = nil
        hotkeys.unregister("session.finish"); hotkeys.unregister("session.cancel")
        panel.orderOut(nil); panel.close(); pieces.removeAll(); candidate = nil
    }
}
