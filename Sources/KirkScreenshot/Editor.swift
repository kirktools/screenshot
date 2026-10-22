import AppKit

enum EditTool: String, CaseIterable {
    case crop = "裁剪", arrow = "箭头", rectangle = "矩形", text = "文字", redact = "打码"
}
struct Annotation {
    let tool: EditTool
    let start: CGPoint
    let end: CGPoint
    var text: String = ""
    var rect: CGRect { CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y)) }
}
struct EditState {
    var image: CGImage
    var annotations: [Annotation] = []
}

/// 预览和导出共用此函数；所有几何数据均使用图片像素、左上原点。
@MainActor func paint(_ state: EditState, transient: Annotation? = nil) {
    state.image.nsImage.draw(in: CGRect(x: 0, y: 0, width: state.image.width, height: state.image.height), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    for a in state.annotations + (transient.map { [$0] } ?? []) {
        let line = max(3, Double(state.image.width) / 360)
        NSColor.systemRed.setStroke(); NSColor.systemRed.setFill()
        let path = NSBezierPath(); path.lineWidth = line; path.lineCapStyle = .round
        switch a.tool {
        case .redact:
            NSColor.black.setFill(); a.rect.integral.fill()
        case .rectangle:
            path.appendRect(a.rect); path.stroke()
        case .arrow:
            path.move(to: a.start); path.line(to: a.end); path.stroke()
            let angle = atan2(a.end.y - a.start.y, a.end.x - a.start.x), length = max(14, line * 4)
            path.move(to: a.end)
            path.line(to: CGPoint(x: a.end.x - length * cos(angle - 0.5), y: a.end.y - length * sin(angle - 0.5)))
            path.move(to: a.end)
            path.line(to: CGPoint(x: a.end.x - length * cos(angle + 0.5), y: a.end.y - length * sin(angle + 0.5))); path.stroke()
        case .text:
            (a.text as NSString).draw(at: a.start, withAttributes: [.font: NSFont.systemFont(ofSize: max(22, line * 7), weight: .semibold), .foregroundColor: NSColor.systemRed])
        case .crop:
            NSColor.systemTeal.setStroke(); path.appendRect(a.rect); path.stroke()
        }
    }
}

@MainActor func render(_ state: EditState) -> CGImage? {
    guard let ctx = CGContext(data: nil, width: state.image.width, height: state.image.height, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.translateBy(x: 0, y: CGFloat(state.image.height)); ctx.scaleBy(x: 1, y: -1)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
    paint(state)
    NSGraphicsContext.restoreGraphicsState()
    return ctx.makeImage()
}

@MainActor final class EditorCanvas: NSView {
    var state: EditState
    var tool: EditTool = .arrow
    var zoom: CGFloat = 1
    var changed: (() -> Void)?
    var feedback: ((String) -> Void)?
    private var history: [EditState] = []
    private var future: [EditState] = []
    private var drag: Annotation?
    init(image: CGImage) { state = EditState(image: image); super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    func layoutImage() {
        zoom = min(1, 960 / CGFloat(state.image.width))
        setFrameSize(CGSize(width: CGFloat(state.image.width) * zoom, height: CGFloat(state.image.height) * zoom))
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        NSAffineTransform.transformScale(zoom).concat()
        paint(state, transient: drag)
        NSGraphicsContext.restoreGraphicsState()
    }
    private func point(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: min(max(0, p.x / zoom), CGFloat(state.image.width)), y: min(max(0, p.y / zoom), CGFloat(state.image.height)))
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = point(event)
        if tool == .text {
            let alert = NSAlert(); alert.messageText = "添加文字"; alert.addButton(withTitle: "添加"); alert.addButton(withTitle: "取消")
            let field = NSTextField(frame: CGRect(x: 0, y: 0, width: 320, height: 28)); field.placeholderString = "输入文字"
            alert.accessoryView = field; alert.window.initialFirstResponder = field
            if alert.runModal() == .alertFirstButtonReturn && !field.stringValue.isEmpty {
                apply(Annotation(tool: .text, start: p, end: p, text: field.stringValue))
            }
        } else { drag = Annotation(tool: tool, start: p, end: p) }
    }
    override func mouseDragged(with event: NSEvent) {
        guard let a = drag else { return }; drag = Annotation(tool: a.tool, start: a.start, end: point(event)); needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        guard let a = drag else { return }; drag = nil
        let final = Annotation(tool: a.tool, start: a.start, end: point(event))
        apply(final)
    }
    func apply(_ final: Annotation) {
        if final.tool == .crop {
            if final.rect.width >= 8, final.rect.height >= 8, let flattened = render(state), let cropped = flattened.cropping(to: final.rect.integral) {
                checkpoint(); state = EditState(image: cropped); layoutImage()
            }
        } else if final.tool == .text || hypot(final.end.x - final.start.x, final.end.y - final.start.y) >= 4 {
            checkpoint(); state.annotations.append(final)
        }
        update()
    }
    private func checkpoint() { history.append(state); if history.count > 30 { history.removeFirst() }; future.removeAll() }
    private func update() { needsDisplay = true; changed?() }
    @objc func undo(_ sender: Any?) { guard let previous = history.popLast() else { return }; future.append(state); state = previous; layoutImage(); update() }
    @objc func redo(_ sender: Any?) { guard let next = future.popLast() else { return }; history.append(state); state = next; layoutImage(); update() }
    @objc func copy(_ sender: Any?) {
        do {
            guard let output = render(state) else { throw CaptureError.message("无法渲染图片") }
            let data = try output.png()
            let board = NSPasteboard.general; board.clearContents()
            guard board.setData(data, forType: .png) else { throw CaptureError.message("写入剪贴板失败") }
            feedback?("已复制 PNG 到剪贴板")
        } catch { showError(error) }
    }
    @objc func saveDocument(_ sender: Any?) {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "Kirk-\(Date.now.formatted(.iso8601).replacingOccurrences(of: ":", with: "-" )).png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            guard let output = render(state) else { throw CaptureError.message("无法渲染图片") }
            try output.png().write(to: url, options: .atomic)
        } catch { showError(error) }
    }
}
extension NSAffineTransform {
    static func transformScale(_ factor: CGFloat) -> NSAffineTransform { let t = NSAffineTransform(); t.scale(by: factor); return t }
}
@MainActor func showError(_ error: Error) {
    let alert = NSAlert(); alert.messageText = "Kirk Screenshot"; alert.informativeText = error.localizedDescription; alert.runModal()
}

@MainActor final class EditorController: NSWindowController {
    let canvas: EditorCanvas
    private let info = NSTextField(labelWithString: "")
    init(image: CGImage) {
        canvas = EditorCanvas(image: image)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1040, height: 760), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.minSize = NSSize(width: 1040, height: 500)
        window.title = "Kirk Screenshot · 预览与编辑"; window.isReleasedWhenClosed = false; window.center()
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.drawsBackground = true; scroll.backgroundColor = .underPageBackgroundColor
        canvas.layoutImage(); scroll.documentView = canvas
        let tools = NSSegmentedControl(labels: EditTool.allCases.map(\.rawValue), trackingMode: .selectOne, target: self, action: #selector(selectTool(_:)))
        tools.selectedSegment = 1
        let undo = NSButton(title: "撤销", target: canvas, action: #selector(EditorCanvas.undo(_:)))
        let redo = NSButton(title: "重做", target: canvas, action: #selector(EditorCanvas.redo(_:)))
        let copy = NSButton(title: "复制 ⌘C", target: self, action: #selector(copyImage))
        let save = NSButton(title: "保存 PNG ⌘S", target: canvas, action: #selector(EditorCanvas.saveDocument(_:)))
        let row = NSStackView(views: [tools, undo, redo, copy, save]); row.spacing = 8
        let hint = NSTextField(labelWithString: "拖动添加标注或裁剪；文字工具点击输入。打码为不可逆实心覆盖。撤销/重做最多保留 30 步。")
        hint.font = .systemFont(ofSize: 12); hint.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [row, hint, scroll, info]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false; window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 16), stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -16), stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 16), stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -12), scroll.widthAnchor.constraint(equalTo: stack.widthAnchor)])
        canvas.changed = { [weak self] in self?.updateInfo() }
        canvas.feedback = { [weak self] message in self?.info.stringValue = message }; updateInfo()
        window.makeFirstResponder(canvas)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func copyImage() { canvas.copy(nil) }
    private func updateInfo() { info.stringValue = "\(canvas.state.image.width) × \(canvas.state.image.height) 像素 · 全程本机处理" }
    @objc private func selectTool(_ sender: NSSegmentedControl) { canvas.tool = EditTool.allCases[sender.selectedSegment] }
}
