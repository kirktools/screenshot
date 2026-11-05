import AppKit

enum EditTool: String, CaseIterable {
    case crop = "裁剪", arrow = "箭头", rectangle = "矩形", ellipse = "圆形", text = "文字", redact = "打码"
}
enum AnnotationColor: String, CaseIterable {
    case red = "红色", orange = "橙色", yellow = "黄色", green = "绿色", blue = "蓝色", white = "白色", black = "黑色"
    var value: NSColor {
        switch self {
        case .red: return NSColor(srgbRed: 0.98, green: 0.22, blue: 0.28, alpha: 1)
        case .orange: return NSColor(srgbRed: 1, green: 0.55, blue: 0.1, alpha: 1)
        case .yellow: return NSColor(srgbRed: 1, green: 0.83, blue: 0, alpha: 1)
        case .green: return NSColor(srgbRed: 0, green: 0.75, blue: 0.38, alpha: 1)
        case .blue: return NSColor(srgbRed: 0.1, green: 0.6, blue: 1, alpha: 1)
        case .white: return .white
        case .black: return .black
        }
    }
}

/// 不使用模板符号着色，避免系统主题把所有颜色统一染成强调色。
final class ColorSwatchButton: NSButton {
    var swatchColor: NSColor = .systemRed
    override var intrinsicContentSize: NSSize { NSSize(width: 26, height: 26) }
    override func draw(_ dirtyRect: NSRect) {
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 6, dy: 6))
        swatchColor.setFill(); circle.fill()
        NSColor.separatorColor.setStroke(); circle.lineWidth = 1; circle.stroke()
        if state == .on {
            NSColor.labelColor.setStroke()
            let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 2, dy: 2))
            ring.lineWidth = 2; ring.stroke()
        }
    }
}

/// 普通截图不接受滚轮，长图预览才允许实际滚动；两种模式都关闭弹性回弹。
final class CaptureScrollView: NSScrollView {
    var permitsScrolling = false
    override func scrollWheel(with event: NSEvent) {
        if permitsScrolling { super.scrollWheel(with: event) }
    }
}
struct Annotation {
    let tool: EditTool
    var start: CGPoint
    var end: CGPoint
    var text: String = ""
    var color: AnnotationColor = .red
    var lineWidth: CGFloat = 0
    var fontSize: CGFloat = 28
    var rotation: CGFloat = 0
    var opacity: CGFloat = 1
    var textSize: CGSize { (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: fontSize, weight: .semibold)]) }
    func containsText(_ point: CGPoint) -> Bool {
        let angle = -rotation * .pi / 180
        let dx = point.x - start.x, dy = point.y - start.y
        return CGRect(origin: .zero, size: textSize).insetBy(dx: -6, dy: -6).contains(CGPoint(x: dx*cos(angle)-dy*sin(angle), y: dx*sin(angle)+dy*cos(angle)))
    }
    var rect: CGRect { CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y)) }
}
struct EditState {
    var image: CGImage
    var annotations: [Annotation] = []
    var captureRegion: CGRect?
}

/// 预览和导出共用此函数；所有几何数据均使用图片像素、左上原点。
@MainActor func paint(_ state: EditState, transient: Annotation? = nil) {
    state.image.nsImage.draw(in: CGRect(x: 0, y: 0, width: state.image.width, height: state.image.height), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    for a in state.annotations + (transient.map { [$0] } ?? []) {
        let line = a.lineWidth > 0 ? a.lineWidth : max(3, CGFloat(state.image.width) / 360)
        a.color.value.setStroke(); a.color.value.setFill()
        let path = NSBezierPath(); path.lineWidth = line; path.lineCapStyle = .round
        switch a.tool {
        case .redact:
            NSColor.black.setFill(); a.rect.integral.fill()
        case .rectangle:
            path.appendRect(a.rect); path.stroke()
        case .ellipse:
            path.appendOval(in: a.rect); path.stroke()
        case .arrow:
            path.move(to: a.start); path.line(to: a.end); path.stroke()
            let angle = atan2(a.end.y - a.start.y, a.end.x - a.start.x), length = max(14, line * 4)
            path.move(to: a.end)
            path.line(to: CGPoint(x: a.end.x - length * cos(angle - 0.5), y: a.end.y - length * sin(angle - 0.5)))
            path.move(to: a.end)
            path.line(to: CGPoint(x: a.end.x - length * cos(angle + 0.5), y: a.end.y - length * sin(angle + 0.5))); path.stroke()
        case .text:
            NSGraphicsContext.saveGraphicsState()
            let transform = NSAffineTransform(); transform.translateX(by: a.start.x, yBy: a.start.y); transform.rotate(byDegrees: a.rotation); transform.concat()
            (a.text as NSString).draw(at: .zero, withAttributes: [.font: NSFont.systemFont(ofSize: a.fontSize, weight: .semibold), .foregroundColor: a.color.value.withAlphaComponent(a.opacity)])
            NSGraphicsContext.restoreGraphicsState()
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

@MainActor final class EditorCanvas: NSView, NSTextFieldDelegate {
    var state: EditState
    var tool: EditTool = .arrow
    var selectedColor: AnnotationColor = .red
    var strokeWidth: CGFloat = 3
    var textFontSize: CGFloat = 28
    var textRotation: CGFloat = 0
    var textOpacity: CGFloat = 1
    private(set) var selectedText: Int?
    private var editingText: Int?
    private var movingText: (point: CGPoint, original: Annotation)?
    var zoom: CGFloat = 1
    var preferredWidth: CGFloat = 960
    var maximumZoom: CGFloat = 1
    var finishRequested: (() -> Void)?
    var cancelRequested: (() -> Void)?
    var changed: (() -> Void)?
    var feedback: ((String) -> Void)?
    var cropRequested: ((CGRect) -> Bool)?
    private var history: [EditState] = []
    private var future: [EditState] = []
    private var drag: Annotation?
    private var textField: NSTextField?
    private var textOrigin: CGPoint = .zero
    private var textColor: AnnotationColor = .red
    private var textLineWidth: CGFloat = 3
    init(image: CGImage) { state = EditState(image: image); super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    func layoutImage() {
        zoom = min(maximumZoom, preferredWidth / CGFloat(state.image.width))
        setFrameSize(CGSize(width: CGFloat(state.image.width) * zoom, height: CGFloat(state.image.height) * zoom))
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        NSAffineTransform.transformScale(zoom).concat()
        var visible = state
        if let editingText, visible.annotations.indices.contains(editingText) { visible.annotations.remove(at: editingText) }
        paint(visible, transient: drag)
        if let selectedText, state.annotations.indices.contains(selectedText), editingText == nil {
            let a = state.annotations[selectedText]
            NSGraphicsContext.saveGraphicsState()
            let transform = NSAffineTransform(); transform.translateX(by: a.start.x, yBy: a.start.y); transform.rotate(byDegrees: a.rotation); transform.concat()
            NSColor.systemTeal.setStroke()
            let border = NSBezierPath(rect: CGRect(origin: .zero, size: a.textSize).insetBy(dx: -4, dy: -4)); border.lineWidth = 1 / zoom; border.stroke()
            NSGraphicsContext.restoreGraphicsState()
        }
        NSGraphicsContext.restoreGraphicsState()
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { cancelRequested?() }
        else if event.keyCode == 36 || event.keyCode == 76 { finishRequested?() }
        else { super.keyDown(with: event) }
    }
    private func point(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: min(max(0, p.x / zoom), CGFloat(state.image.width)), y: min(max(0, p.y / zoom), CGFloat(state.image.height)))
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = point(event)
        commitText()
        if tool == .text {
            selectText(at: p)
            if let index = selectedText, event.clickCount < 2 {
                movingText = (p, state.annotations[index]); update(); return
            }
            editingText = selectedText
            textOrigin = p; textColor = selectedColor; textLineWidth = strokeWidth / zoom
            let field = NSTextField(frame: CGRect(x: p.x * zoom, y: p.y * zoom, width: max(80, min(320, bounds.width - p.x * zoom)), height: max(26, 35 * zoom)))
            if let editingText {
                let a = state.annotations[editingText]; textOrigin = a.start; textColor = a.color
                textFontSize = a.fontSize; textRotation = a.rotation; textOpacity = a.opacity
                field.frame.origin = CGPoint(x: a.start.x * zoom, y: a.start.y * zoom); field.stringValue = a.text
            }
            field.placeholderString = "输入文字，回车确认"
            field.font = .systemFont(ofSize: max(10, textFontSize * zoom), weight: .semibold)
            field.textColor = textColor.value; field.delegate = self
            field.target = self; field.action = #selector(finishText)
            textField = field; addSubview(field); window?.makeFirstResponder(field)
        } else { drag = Annotation(tool: tool, start: p, end: p, color: selectedColor, lineWidth: strokeWidth / zoom) }
    }
    @objc private func finishText() { commitText(); window?.makeFirstResponder(self) }
    func commitText() {
        guard let field = textField else { return }
        let value = field.currentEditor()?.string ?? field.stringValue
        textField = nil; field.removeFromSuperview()
        if !value.isEmpty {
            let a = Annotation(tool: .text, start: textOrigin, end: textOrigin, text: value, color: textColor, lineWidth: textLineWidth, fontSize: textFontSize, rotation: textRotation, opacity: textOpacity)
            if let index = editingText, state.annotations.indices.contains(index) { checkpoint(); state.annotations[index] = a }
            else { apply(a); selectedText = state.annotations.indices.last }
        }
        editingText = nil; update()
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            textField?.removeFromSuperview(); textField = nil; editingText = nil; update(); window?.makeFirstResponder(self); return true
        }
        return false
    }
    override func mouseDragged(with event: NSEvent) {
        if let movingText, let selectedText {
            let p = point(event), delta = CGPoint(x: p.x-movingText.point.x, y: p.y-movingText.point.y)
            var a = movingText.original; a.start.x += delta.x; a.start.y += delta.y; a.end.x += delta.x; a.end.y += delta.y
            state.annotations[selectedText] = a; update(); return
        }
        guard let a = drag else { return }; drag = Annotation(tool: a.tool, start: a.start, end: point(event), color: a.color, lineWidth: a.lineWidth); needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        if let movingText, let selectedText {
            let result = state.annotations[selectedText]
            state.annotations[selectedText] = movingText.original
            self.movingText = nil
            if result.start != movingText.original.start { checkpoint(); state.annotations[selectedText] = result }
            update(); return
        }
        guard let a = drag else { return }; drag = nil
        let final = Annotation(tool: a.tool, start: a.start, end: point(event), color: a.color, lineWidth: a.lineWidth)
        apply(final)
    }
    func apply(_ final: Annotation) {
        if final.tool == .crop {
            if let cropRequested { if !cropRequested(final.rect.integral) { update() }; return }
            if final.rect.width >= 8, final.rect.height >= 8, let flattened = render(state), let cropped = flattened.cropping(to: final.rect.integral) {
                checkpoint(); state = EditState(image: cropped); layoutImage()
            }
        } else if final.tool == .text || hypot(final.end.x - final.start.x, final.end.y - final.start.y) >= 4 {
            checkpoint(); state.annotations.append(final)
        }
        update()
    }
    func selectText(at point: CGPoint) {
        selectedText = state.annotations.indices.reversed().first { state.annotations[$0].tool == .text && state.annotations[$0].containsText(point) }
        if let selectedText {
            let a = state.annotations[selectedText]; textFontSize = a.fontSize; textRotation = a.rotation; textOpacity = a.opacity; selectedColor = a.color
        }
        update()
    }
    func styleSelectedText(fontSize: CGFloat, rotation: CGFloat, opacity: CGFloat) {
        commitText(); textFontSize = fontSize; textRotation = rotation; textOpacity = opacity
        if let selectedText, state.annotations.indices.contains(selectedText) {
            checkpoint(); state.annotations[selectedText].fontSize = fontSize
            state.annotations[selectedText].rotation = rotation; state.annotations[selectedText].opacity = opacity
            state.annotations[selectedText].color = selectedColor
        }
        update()
    }
    func reframe(image: CGImage, region: CGRect, scale: CGFloat, remember: Bool) {
        guard let previous = state.captureRegion else { return }
        if remember { checkpoint() }
        let delta = CGPoint(x: (previous.minX - region.minX) * scale, y: (region.maxY - previous.maxY) * scale)
        state.annotations = state.annotations.map { annotation in
            return Annotation(tool: annotation.tool, start: CGPoint(x: annotation.start.x + delta.x, y: annotation.start.y + delta.y),
                                 end: CGPoint(x: annotation.end.x + delta.x, y: annotation.end.y + delta.y), text: annotation.text,
                                 color: annotation.color, lineWidth: annotation.lineWidth, fontSize: annotation.fontSize, rotation: annotation.rotation, opacity: annotation.opacity)
        }
        state.image = image; state.captureRegion = region; update()
    }
    func releaseCaptureHistory() {
        if let compact = copiedStrip(state.image, rows: state.image.height) { state.image = compact }
        history.removeAll(); future.removeAll(); state.captureRegion = nil
    }
    private func checkpoint() {
        history.append(state)
        while history.count > 30 || (history.count > 1 && history.reduce(0, { $0 + $1.image.bytesPerRow * $1.image.height }) > 256_000_000) { history.removeFirst() }
        future.removeAll()
    }
    private func update() { needsDisplay = true; changed?() }
    @objc func undo(_ sender: Any?) { guard let previous = history.popLast() else { return }; future.append(state); state = previous; selectedText = nil; layoutImage(); update() }
    @objc func redo(_ sender: Any?) { guard let next = future.popLast() else { return }; history.append(state); state = next; selectedText = nil; layoutImage(); update() }
    @objc func copy(_ sender: Any?) { _ = copyImage() }
    @discardableResult func copyImage() -> Bool {
        commitText()
        do {
            guard let output = render(state) else { throw CaptureError.message("无法渲染图片") }
            try output.copyPNG()
            feedback?("已复制 PNG 到剪贴板"); return true
        } catch { showError(error); return false }
    }
    @objc func saveDocument(_ sender: Any?) {
        commitText()
        let panel = NSSavePanel(); panel.allowedContentTypes = [.png]
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 3)
        panel.nameFieldStringValue = "Screenshot-\(Date.now.formatted(.iso8601).replacingOccurrences(of: ":", with: "-" )).png"
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
    let alert = NSAlert(); alert.window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 3); alert.messageText = "Screenshot"; alert.informativeText = error.localizedDescription; alert.runModal()
}

@MainActor final class EditorController: NSWindowController {
    let canvas: EditorCanvas
    private let info = NSTextField(labelWithString: "")
    private let toolbar: NSPanel
    private var backdrops: [NSWindow] = []
    private var anchor: CGRect
    private var frozenCapture: FrozenCapture?
    private var displayObserver: NSObjectProtocol?
    private var displayLayoutChanged = false
    private let resizeHandles = ResizeHandles()
    private var resizeGesture: (region: CGRect, start: CGPoint, edges: CaptureEdges, checkpointed: Bool)?
    var captureRegion: CGRect? { canvas.state.captureRegion ?? window?.frame }
    var diagnosticResizeHandles: ResizeHandles { resizeHandles }
    var diagnosticFrozenCaptureRetained: Bool { frozenCapture != nil }
    private let visibleFrame: CGRect
    private let scrollView = CaptureScrollView()
    private let isLongImage: Bool
    private let fontSizeField = NSTextField(string: "28")
    private let rotationField = NSTextField(string: "0")
    private let opacityField = NSTextField(string: "100")
    private var colorButtons: [NSButton] = []
    var diagnosticGeometry: (image: CGRect, toolbar: CGRect, toolbarVisible: Bool, backdrops: Int, scrolling: Bool, elasticity: NSScrollView.Elasticity) {
        (window?.frame ?? .zero, toolbar.frame, toolbar.isVisible, backdrops.filter(\.isVisible).count, scrollView.permitsScrolling, scrollView.verticalScrollElasticity)
    }
    var diagnosticToolbarViews: [NSView] {
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        return toolbar.contentView.map(descendants) ?? []
    }
    var requestScroll: (() -> Void)?
    var dismissed: (() -> Void)?
    init(image: CGImage, region: CGRect? = nil, allowScroll: Bool = false, frozenCapture: FrozenCapture? = nil) {
        canvas = EditorCanvas(image: image)
        self.frozenCapture = frozenCapture
        if frozenCapture != nil { canvas.state.captureRegion = region }
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(region ?? .zero) }) ?? NSScreen.main!
        visibleFrame = screen.visibleFrame
        let width = min(CGFloat(image.width), min(860, visibleFrame.width - 48))
        let initial = region ?? CGRect(x: visibleFrame.midX - width / 2, y: visibleFrame.midY - 220, width: width, height: 440)
        anchor = initial
        isLongImage = CGFloat(image.height) * min(1, initial.width / CGFloat(image.width)) > initial.height + 0.5
        let window = EditorCaptureWindow(contentRect: initial, styleMask: [.borderless], backing: .buffered, defer: false)
        toolbar = PassivePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Screenshot · 原位标注"
        window.isReleasedWhenClosed = false; window.level = .screenSaver
        window.backgroundColor = .clear; window.isOpaque = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        toolbar.isReleasedWhenClosed = false; toolbar.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        toolbar.hidesOnDeactivate = false
        toolbar.backgroundColor = .clear; toolbar.isOpaque = false; toolbar.hasShadow = true
        toolbar.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        canvas.preferredWidth = initial.width
        canvas.maximumZoom = min(1, initial.width / CGFloat(image.width))
        scrollView.permitsScrolling = isLongImage
        scrollView.hasVerticalScroller = isLongImage; scrollView.hasHorizontalScroller = false
        scrollView.verticalScrollElasticity = .none; scrollView.horizontalScrollElasticity = .none
        scrollView.automaticallyAdjustsContentInsets = false; scrollView.contentInsets = .init()
        scrollView.autohidesScrollers = true; scrollView.scrollerStyle = .overlay; scrollView.borderType = .noBorder
        scrollView.wantsLayer = true
        scrollView.drawsBackground = true; scrollView.backgroundColor = .windowBackgroundColor
        scrollView.documentView = canvas
        let container = NSView(frame: CGRect(origin: .zero, size: initial.size))
        scrollView.frame = container.bounds; scrollView.autoresizingMask = [.width, .height]
        resizeHandles.frame = container.bounds; resizeHandles.autoresizingMask = [.width, .height]
        container.addSubview(scrollView); container.addSubview(resizeHandles); window.contentView = container
        resizeHandles.began = { [weak self] edges, point in
            guard let self, let region = self.canvas.state.captureRegion else { return }
            self.canvas.commitText()
            self.resizeGesture = (region, point, edges, false)
        }
        resizeHandles.moved = { [weak self] point in self?.resize(to: point) }
        resizeHandles.ended = { [weak self] in self?.resizeGesture = nil }
        if frozenCapture != nil {
            canvas.cropRequested = { [weak self] rect in
                guard let self, let source = self.frozenCapture, let previous = self.canvas.state.captureRegion,
                      rect.width >= 8, rect.height >= 8 else { return false }
                let next = CGRect(x: previous.minX + rect.minX / source.scale, y: previous.maxY - rect.maxY / source.scale,
                                  width: rect.width / source.scale, height: rect.height / source.scale)
                return self.reframe(to: next, remember: true)
            }
        }
        let tools = NSSegmentedControl(labels: EditTool.allCases.map(\.rawValue), trackingMode: .selectOne, target: self, action: #selector(selectTool(_:)))
        tools.selectedSegment = 1
        let undo = icon("arrow.uturn.backward", "撤销 ⌘Z", target: canvas, action: #selector(EditorCanvas.undo(_:)))
        let redo = icon("arrow.uturn.forward", "重做 ⇧⌘Z", target: canvas, action: #selector(EditorCanvas.redo(_:)))
        let save = icon("square.and.arrow.down", "保存 PNG ⌘S", target: canvas, action: #selector(EditorCanvas.saveDocument(_:)))
        let cancel = icon("xmark", "取消 Esc", target: self, action: #selector(cancelEditing))
        let done = icon("checkmark", "复制并完成 ↩", target: self, action: #selector(completeEditing))
        done.contentTintColor = .systemGreen; cancel.contentTintColor = .systemRed
        var controls: [NSView] = [info, tools, undo, redo]
        if allowScroll {
            let button = icon("arrow.up.and.down", "滚动长截图（重新采集选区）", target: self, action: #selector(beginScroll))
            button.image = CaptureIcons.scrollCapture
            controls.append(button)
        }
        controls += [save, cancel, done]
        let mainRow = NSStackView(views: controls); mainRow.spacing = 8
        var styles: [NSView] = [NSTextField(labelWithString: "颜色")]
        for (index, color) in AnnotationColor.allCases.enumerated() {
            let button = ColorSwatchButton(title: color.rawValue, target: self, action: #selector(selectColor(_:)))
            button.swatchColor = color.value; button.isBordered = false
            button.tag = index; button.toolTip = color.rawValue
            button.bezelStyle = .texturedRounded; button.setButtonType(.toggle)
            button.state = index == 0 ? .on : .off
            colorButtons.append(button); styles.append(button)
        }
        styles.append(NSTextField(labelWithString: "线宽"))
        let widths = NSSegmentedControl(labels: ["细", "中", "粗"], trackingMode: .selectOne, target: self, action: #selector(selectWidth(_:)))
        widths.selectedSegment = 1; styles.append(widths)
        let styleRow = NSStackView(views: styles); styleRow.spacing = 6
        var textStyles: [NSView] = []
        for (label, field) in [("字号", fontSizeField), ("旋转°", rotationField), ("不透明度%", opacityField)] {
            field.widthAnchor.constraint(equalToConstant: 52).isActive = true
            field.target = self; field.action = #selector(changeTextStyle)
            textStyles += [NSTextField(labelWithString: label), field]
        }
        let textHelp = NSTextField(labelWithString: "文字工具：单击选中拖动，双击改文字")
        textHelp.font = .systemFont(ofSize: 11); textStyles.append(textHelp)
        let textRow = NSStackView(views: textStyles); textRow.spacing = 6
        let rows = NSStackView(views: [mainRow, styleRow, textRow]); rows.orientation = .vertical; rows.alignment = .leading; rows.spacing = 8
        toolbar.contentView = captureToolbar(views: [rows])
        canvas.changed = { [weak self] in
            guard let self else { return }; self.layoutCapture()
            self.fontSizeField.doubleValue = self.canvas.textFontSize
            self.rotationField.doubleValue = self.canvas.textRotation
            self.opacityField.doubleValue = self.canvas.textOpacity * 100
        }
        canvas.feedback = { [weak self] message in self?.info.toolTip = message }
        canvas.finishRequested = { [weak self] in self?.completeEditing() }
        canvas.cancelRequested = { [weak self] in self?.cancelEditing() }
        if frozenCapture != nil {
            displayObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.displayLayoutChanged = true; self?.resizeGesture = nil; self?.resizeHandles.enabled = false
                    self?.info.toolTip = "显示器布局或缩放已改变，请完成现有截图或取消后重新框选。"
                }
            }
        }
        layoutCapture()
        window.makeFirstResponder(canvas)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func icon(_ name: String, _ title: String, target: AnyObject, action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: name, accessibilityDescription: title) ?? NSImage(), target: target, action: action)
        button.toolTip = title; button.bezelStyle = .texturedRounded
        return button
    }
    private func resize(to point: CGPoint) {
        guard !displayLayoutChanged, let source = frozenCapture, let gesture = resizeGesture else { return }
        let next = CaptureResizeGeometry.resized(gesture.region, edges: gesture.edges,
                                                delta: CGPoint(x: point.x - gesture.start.x, y: point.y - gesture.start.y), within: source.bounds, pixelScale: source.scale)
        if next != canvas.state.captureRegion && reframe(to: next, remember: !gesture.checkpointed) { resizeGesture?.checkpointed = true }
    }
    @discardableResult private func reframe(to region: CGRect, remember: Bool) -> Bool {
        guard !displayLayoutChanged, let source = frozenCapture, let image = source.crop(region) else { info.toolTip = "选区超出已冻结的屏幕范围或像素上限。"; return false }
        canvas.reframe(image: image, region: region, scale: source.scale, remember: remember)
        return true
    }
    private func layoutCapture() {
        if let region = canvas.state.captureRegion, let source = frozenCapture {
            canvas.preferredWidth = region.width; canvas.maximumZoom = 1 / source.scale
        }
        canvas.layoutImage()
        let reserve: CGFloat = canvas.frame.height > anchor.height ? 76 : 0
        let height = min(canvas.frame.height, max(80, anchor.maxY - visibleFrame.minY - reserve))
        let frame = canvas.state.captureRegion ?? CGRect(x: anchor.minX, y: anchor.maxY - height, width: min(anchor.width, canvas.frame.width), height: height)
        window?.setFrame(frame, display: true)
        resizeHandles.enabled = !displayLayoutChanged && frozenCapture != nil && canvas.state.captureRegion != nil && !isLongImage
        info.stringValue = "\(canvas.state.image.width) × \(canvas.state.image.height)"
        if frozenCapture?.limitsExpansion == true { info.toolTip = "显示器组合超过快照内存上限，仅能在已冻结范围内调整。" }
        let size = toolbar.contentView!.fittingSize
        let placement = NSScreen.screens.max { left, right in
            let a = left.frame.intersection(frame), b = right.frame.intersection(frame)
            return a.width * a.height < b.width * b.height
        }?.visibleFrame ?? visibleFrame
        toolbar.setFrame(CaptureLayout.toolbar(near: frame, size: size, within: placement), display: true)
    }
    override func showWindow(_ sender: Any?) {
        if backdrops.isEmpty {
            for screen in NSScreen.screens {
                let backdrop = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                backdrop.level = .screenSaver; backdrop.backgroundColor = .clear; backdrop.isOpaque = false; backdrop.hasShadow = false
                backdrop.isReleasedWhenClosed = false; backdrop.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                let background = EditorBackdrop(frame: CGRect(origin: .zero, size: screen.frame.size))
                background.frozenCapture = frozenCapture
                backdrop.contentView = background
                backdrops.append(backdrop)
            }
        }
        backdrops.forEach { $0.orderFrontRegardless() }
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(nil); toolbar.orderFrontRegardless()
    }
    override func close() {
        resizeGesture = nil
        if let displayObserver { NotificationCenter.default.removeObserver(displayObserver); self.displayObserver = nil }
        if frozenCapture != nil {
            anchor = canvas.state.captureRegion ?? anchor
            canvas.releaseCaptureHistory(); canvas.cropRequested = nil; frozenCapture = nil
            resizeHandles.enabled = false
        }
        toolbar.orderOut(nil); toolbar.close()
        backdrops.forEach { ($0.contentView as? EditorBackdrop)?.frozenCapture = nil; $0.orderOut(nil); $0.close() }; backdrops.removeAll()
        super.close()
    }
    @objc private func completeEditing() {
        if canvas.copyImage() { close(); dismissed?() }
    }
    @objc private func cancelEditing() { close(); dismissed?() }
    @objc private func beginScroll() { close(); requestScroll?() }
    @objc private func changeTextStyle() {
        let size = min(300, max(8, fontSizeField.doubleValue))
        let rotation = min(360, max(-360, rotationField.doubleValue))
        let opacity = min(100, max(5, opacityField.doubleValue))
        fontSizeField.doubleValue = size; rotationField.doubleValue = rotation; opacityField.doubleValue = opacity
        canvas.styleSelectedText(fontSize: size, rotation: rotation, opacity: opacity / 100)
    }
    @objc private func selectColor(_ sender: NSButton) {
        canvas.commitText(); canvas.selectedColor = AnnotationColor.allCases[sender.tag]
        if canvas.tool == .text { canvas.styleSelectedText(fontSize: canvas.textFontSize, rotation: canvas.textRotation, opacity: canvas.textOpacity) }
        for button in colorButtons { button.state = button === sender ? .on : .off; button.needsDisplay = true }
        window?.makeFirstResponder(canvas)
    }
    @objc private func selectWidth(_ sender: NSSegmentedControl) {
        canvas.commitText(); canvas.strokeWidth = [1.5, 3.0, 6.0][sender.selectedSegment]
        window?.makeFirstResponder(canvas)
    }
    @objc private func selectTool(_ sender: NSSegmentedControl) { canvas.commitText(); canvas.tool = EditTool.allCases[sender.selectedSegment]; window?.makeFirstResponder(canvas) }
}
