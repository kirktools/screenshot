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
final class ColorSwatchButton: EditorIconButton {
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
    private var newTextFontSize: CGFloat = 28
    private var newTextRotation: CGFloat = 0
    private var newTextOpacity: CGFloat = 1
    var textFontSize: CGFloat = 28
    var textRotation: CGFloat = 0
    var textOpacity: CGFloat = 1
    private(set) var selectedText: Int?
    private var editingText: Int?
    private var textTransform: TextTransformGesture?
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
        if let selectedText, state.annotations.indices.contains(selectedText), editingText == nil, tool == .text {
            let a = state.annotations[selectedText]
            NSGraphicsContext.saveGraphicsState()
            let transform = NSAffineTransform(); transform.translateX(by: a.start.x, yBy: a.start.y); transform.rotate(byDegrees: a.rotation); transform.concat()
            NSColor.systemTeal.setStroke()
            let border = NSBezierPath(rect: CGRect(origin: .zero, size: a.textSize).insetBy(dx: -4, dy: -4)); border.lineWidth = 1 / zoom; border.stroke()
            let gap = 24 / zoom, size = a.textSize
            let stem = NSBezierPath(); stem.move(to: CGPoint(x: size.width/2, y: -4)); stem.line(to: CGPoint(x: size.width/2, y: -gap)); stem.lineWidth = 1/zoom; stem.stroke()
            let local = [CGPoint(x: -4, y: -4), CGPoint(x: size.width+4, y: -4), CGPoint(x: -4, y: size.height+4), CGPoint(x: size.width+4, y: size.height+4), CGPoint(x: size.width/2, y: -gap)]
            for point in local {
                let handle = NSBezierPath(ovalIn: CGRect(x: point.x-4/zoom, y: point.y-4/zoom, width: 8/zoom, height: 8/zoom))
                NSColor.white.setFill(); handle.fill(); NSColor.systemTeal.setStroke(); handle.lineWidth = 1/zoom; handle.stroke()
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        NSGraphicsContext.restoreGraphicsState()
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { if textTransform != nil { endTextTransform(cancel: true) } else { cancelRequested?() } }
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
            if beginTextTransform(at: p) { return }
            selectText(at: p)
            if let index = selectedText, event.clickCount < 2 {
                movingText = (p, state.annotations[index]); update(); return
            }
            editingText = selectedText
            textOrigin = p; textColor = selectedColor; textLineWidth = strokeWidth / zoom
            let field = NSTextField()
            if let editingText {
                let a = state.annotations[editingText]; textOrigin = a.start; textColor = a.color
                textFontSize = a.fontSize; textRotation = a.rotation; textOpacity = a.opacity
                field.stringValue = a.text
            }
            configureTextInput(field, at: textOrigin)
            field.textColor = textColor.value; field.delegate = self
            field.target = self; field.action = #selector(finishText)
            textField = field; addSubview(field); window?.makeFirstResponder(field)
        } else { drag = Annotation(tool: tool, start: p, end: p, color: selectedColor, lineWidth: strokeWidth / zoom) }
    }
    /// 输入控件独立于标注原点：靠边时移动编辑框，不改变最终文字位置。
    func configureTextInput(_ field: NSTextField, at origin: CGPoint) {
        let visible = visibleRect.intersection(bounds).insetBy(dx: 4, dy: 4)
        let area = visible.width > 0 && visible.height > 0 ? visible : bounds
        let requested = max(10, textFontSize * zoom)
        let value = field.currentEditor()?.string ?? field.stringValue
        let fitted = value.isEmpty ? min(13, requested) : min(requested, max(10, (area.height - 14) / 1.3))
        let font = NSFont.systemFont(ofSize: fitted, weight: .semibold)
        field.font = font
        if let editor = field.currentEditor() as? NSTextView {
            let selection = editor.selectedRange(); editor.font = font; editor.setSelectedRange(selection)
        }
        field.placeholderAttributedString = NSAttributedString(string: "输入文字，回车确认", attributes: [.font: NSFont.systemFont(ofSize: min(13, fitted)), .foregroundColor: NSColor.placeholderTextColor])
        field.cell?.usesSingleLineMode = true; field.cell?.isScrollable = true; field.cell?.wraps = false
        let lineHeight = ceil(font.ascender - font.descender + font.leading) + 12
        let textWidth = (value as NSString).size(withAttributes: [.font: font]).width + 20
        let width = min(area.width, max(180, min(480, textWidth)))
        let height = min(area.height, max(30, lineHeight))
        let x = min(max(area.minX, origin.x * zoom), area.maxX - width)
        let y = min(max(area.minY, origin.y * zoom), area.maxY - height)
        field.frame = CGRect(x: x, y: y, width: width, height: height)
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
    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, field === textField else { return }
        configureTextInput(field, at: textOrigin)
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            textField?.removeFromSuperview(); textField = nil; editingText = nil; update(); window?.makeFirstResponder(self); return true
        }
        return false
    }
    override func mouseDragged(with event: NSEvent) {
        if textTransform != nil { updateTextTransform(at: point(event)); return }
        if let movingText, let selectedText {
            let p = point(event), delta = CGPoint(x: p.x-movingText.point.x, y: p.y-movingText.point.y)
            var a = movingText.original; a.start.x += delta.x; a.start.y += delta.y; a.end.x += delta.x; a.end.y += delta.y
            state.annotations[selectedText] = a; update(); return
        }
        guard let a = drag else { return }; drag = Annotation(tool: a.tool, start: a.start, end: point(event), color: a.color, lineWidth: a.lineWidth); needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        if textTransform != nil { updateTextTransform(at: point(event)); endTextTransform(); return }
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
    @discardableResult func beginTextTransform(at point: CGPoint) -> Bool {
        guard let selectedText, state.annotations.indices.contains(selectedText) else { return false }
        let a = state.annotations[selectedText]
        guard let index = a.textHandlePoints(zoom: zoom).firstIndex(where: { hypot($0.x-point.x, $0.y-point.y) <= 9 / zoom }) else { return false }
        textTransform = TextTransformGesture(original: a, pointer: point, mode: index == 4 ? .rotate : .scale)
        return true
    }
    func updateTextTransform(at point: CGPoint) {
        guard let textTransform, let selectedText else { return }
        let a = textTransform.annotation(at: point); state.annotations[selectedText] = a
        textFontSize = a.fontSize; textRotation = a.rotation; update()
    }
    func endTextTransform(cancel: Bool = false) {
        guard let gesture = textTransform, let selectedText else { return }
        let result = state.annotations[selectedText]; state.annotations[selectedText] = gesture.original
        textTransform = nil
        if !cancel && (abs(result.fontSize - gesture.original.fontSize) > 0.001 || abs(result.rotation - gesture.original.rotation) > 0.001) {
            checkpoint(); state.annotations[selectedText] = result
        }
        textFontSize = state.annotations[selectedText].fontSize; textRotation = state.annotations[selectedText].rotation
        update()
    }
    func selectText(at point: CGPoint) {
        selectedText = state.annotations.indices.reversed().first { state.annotations[$0].tool == .text && state.annotations[$0].containsText(point) }
        if let selectedText {
            let a = state.annotations[selectedText]; textFontSize = a.fontSize; textRotation = a.rotation; textOpacity = a.opacity; selectedColor = a.color
        } else {
            textFontSize = newTextFontSize; textRotation = newTextRotation; textOpacity = newTextOpacity
        }
        update()
    }
    func styleSelectedText(fontSize: CGFloat, rotation: CGFloat, opacity: CGFloat) {
        commitText(); textFontSize = fontSize; textRotation = rotation; textOpacity = opacity
        newTextFontSize = fontSize; newTextRotation = rotation; newTextOpacity = opacity
        if let selectedText, state.annotations.indices.contains(selectedText) {
            let current = state.annotations[selectedText]
            guard current.fontSize != fontSize || current.rotation != rotation || current.opacity != opacity || current.color != selectedColor else { update(); return }
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

/// 编辑参数需要键盘焦点；滚动采集控件继续使用不抢焦点的 PassivePanel。
final class EditorToolbarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor final class EditorController: NSWindowController, NSTextFieldDelegate {
    let canvas: EditorCanvas
    private let info = NSTextField(labelWithString: "")
    private let toolbar: NSPanel
    private var toolbarOriginOverride: CGPoint?
    private var toolbarDragOrigin = CGPoint.zero
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
    private let styleRow = NSStackView()
    private let textRow = NSStackView()
    private let widthOptions = NSStackView()
    private var stylesExpanded = false
    private var advancedExpanded = false
    private var toolButtons: [NSButton] = []
    private let textPresets = NSStackView()
    private let advancedButton = EditorIconButton()
    private let shapeGroup = EditorShapeGroup()
    private var shapeButton: NSButton?
    private var lastShape: EditTool = .rectangle
    let shapeMenu = NSMenu()
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
        toolbar = EditorToolbarPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Screenshot · 原位标注"
        window.isReleasedWhenClosed = false; window.level = .screenSaver
        window.backgroundColor = .clear; window.isOpaque = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        toolbar.isReleasedWhenClosed = false; toolbar.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        toolbar.hidesOnDeactivate = false; toolbar.becomesKeyOnlyIfNeeded = true
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
        let tools = NSStackView(); tools.spacing = 6; tools.distribution = .fill; tools.alignment = .centerY
        for tool in [EditTool.rectangle, .arrow, .text, .redact] {
            if tool == .rectangle {
                let button = icon("rectangle", "矩形 / 圆形", target: self, action: #selector(activateShape))
                button.setButtonType(.toggle); shapeButton = button
                shapeGroup.spacing = 0; shapeGroup.addArrangedSubview(button)
                let arrow = icon("chevron.down", "选择矩形或圆形", target: self, action: #selector(showShapes(_:)), minimumWidth: 14)
                arrow.widthAnchor.constraint(equalToConstant: 14).isActive = true
                shapeGroup.addArrangedSubview(arrow); tools.addArrangedSubview(shapeGroup)
                for shape in [EditTool.rectangle, .ellipse] {
                    let item = NSMenuItem(title: shape.rawValue, action: #selector(selectShape(_:)), keyEquivalent: "")
                    item.target = self; item.tag = EditTool.allCases.firstIndex(of: shape)!
                    item.image = CaptureIcons.toolbar(shape == .rectangle ? "rectangle" : "circle")
                    shapeMenu.addItem(item)
                }
            } else {
                let symbols: [EditTool: String] = [.arrow: "arrow.up.right", .text: "textbox", .redact: "square.grid.3x3.fill"]
                let button = icon(symbols[tool]!, tool == .redact ? "打码（实心遮挡）" : tool.rawValue, target: self, action: #selector(selectToolButton(_:)))

                button.tag = EditTool.allCases.firstIndex(of: tool)!; button.setButtonType(.toggle)
                button.state = tool == .arrow ? .on : .off; button.contentTintColor = tool == .arrow ? .systemTeal : .labelColor; toolButtons.append(button); tools.addArrangedSubview(button)
            }
        }
        let undo = icon("arrow.uturn.backward", "撤销 ⌘Z", target: canvas, action: #selector(EditorCanvas.undo(_:)))
        let redo = icon("arrow.uturn.forward", "重做 ⇧⌘Z", target: canvas, action: #selector(EditorCanvas.redo(_:)))
        let save = icon("square.and.arrow.down", "保存 PNG ⌘S", target: self, action: #selector(saveEditing))
        let cancel = icon("xmark", "取消 Esc", target: self, action: #selector(cancelEditing))
        let done = icon("checkmark", "复制并完成 ↩", target: self, action: #selector(completeEditing))
        done.contentTintColor = .systemGreen; cancel.contentTintColor = .systemRed
        let handle = EditorToolbarDragHandle()
        handle.isBordered = false; handle.toolTip = "拖动工具栏；双击恢复自动位置"
        handle.widthAnchor.constraint(equalToConstant: 16).isActive = true
        handle.heightAnchor.constraint(equalToConstant: 28).isActive = true
        handle.began = { [weak self] in self?.toolbarDragOrigin = self?.toolbar.frame.origin ?? .zero }
        handle.moved = { [weak self] delta in
            guard let self else { return }
            self.moveToolbar(to: CGPoint(x: self.toolbarDragOrigin.x+delta.x, y: self.toolbarDragOrigin.y+delta.y))
        }
        handle.reset = { [weak self] in self?.toolbarOriginOverride = nil; self?.layoutCapture() }
        var controls: [NSView] = [handle, info, tools, undo, redo]
        if allowScroll {
            let button = icon("arrow.up.and.down", "滚动长截图（重新采集选区）", target: self, action: #selector(beginScroll))
            button.image = CaptureIcons.toolbar("arrow.up.and.down")
            controls.append(button)
        }
        let pin = icon("pin", "钉到屏幕", target: self, action: #selector(pinEditing))
        let more = icon("ellipsis", "更多：裁剪", target: self, action: #selector(showMore(_:)))
        controls += [more, save, pin, cancel, done]
        let mainRow = NSStackView(views: controls); mainRow.spacing = 8
        mainRow.distribution = .fill; mainRow.alignment = .centerY; mainRow.identifier = NSUserInterfaceItemIdentifier("editor.main")
        for (index, size) in [20.0, 28.0, 44.0].enumerated() {
            let button = EditorIconButton(title: ["小", "中", "大"][index], target: self, action: #selector(selectTextPreset(_:)))
            button.tag = Int(size); button.isBordered = false; button.toolTip = "文字字号 \(Int(size))"
            textPresets.addArrangedSubview(button)
        }
        textPresets.spacing = 4
        let leftStyles = NSStackView(views: [textPresets]); leftStyles.spacing = 6
        leftStyles.identifier = NSUserInterfaceItemIdentifier("editor.styles.left")
        leftStyles.distribution = .fill; leftStyles.alignment = .centerY
        let rightStyles = NSStackView(); rightStyles.spacing = 6
        rightStyles.identifier = NSUserInterfaceItemIdentifier("editor.styles.right")
        rightStyles.distribution = .fill; rightStyles.alignment = .centerY
        for (index, color) in AnnotationColor.allCases.enumerated() {
            let button = ColorSwatchButton(title: color.rawValue, target: self, action: #selector(selectColor(_:)))
            button.swatchColor = color.value; button.isBordered = false
            button.tag = index; button.toolTip = color.rawValue
            button.bezelStyle = .texturedRounded; button.setButtonType(.toggle)
            button.state = index == 0 ? .on : .off
            colorButtons.append(button); rightStyles.addArrangedSubview(button)
        }
        let widths = NSSegmentedControl(labels: ["·", "●", "⬤"], trackingMode: .selectOne, target: self, action: #selector(selectWidth(_:)))
        widths.setToolTip("细", forSegment: 0); widths.setToolTip("中", forSegment: 1); widths.setToolTip("粗", forSegment: 2)
        widths.selectedSegment = 1; widthOptions.addArrangedSubview(widths); widthOptions.spacing = 6; leftStyles.addArrangedSubview(widthOptions)
        advancedButton.image = CaptureIcons.toolbar("ellipsis")
        advancedButton.toolTip = "精确调整字号、旋转和不透明度"; advancedButton.isBordered = false
        advancedButton.target = self; advancedButton.action = #selector(toggleAdvanced)
        rightStyles.addArrangedSubview(advancedButton)
        let gap = NSView(); gap.setContentHuggingPriority(.init(1), for: .horizontal)
        gap.widthAnchor.constraint(greaterThanOrEqualToConstant: 16).isActive = true
        for group in [leftStyles, rightStyles] {
            group.setContentHuggingPriority(.required, for: .horizontal)
            group.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        [leftStyles, gap, rightStyles].forEach { styleRow.addArrangedSubview($0) }; styleRow.spacing = 6; styleRow.distribution = .fill; styleRow.alignment = .centerY
        styleRow.identifier = NSUserInterfaceItemIdentifier("editor.styles")
        var textStyles: [NSView] = []
        for (label, field) in [("字号", fontSizeField), ("旋转°", rotationField), ("不透明度%", opacityField)] {
            field.widthAnchor.constraint(equalToConstant: 52).isActive = true
            field.target = self; field.action = #selector(changeTextStyle); field.delegate = self
            field.identifier = NSUserInterfaceItemIdentifier(label); field.toolTip = label
            textStyles += [NSTextField(labelWithString: label), field]
        }
        let textHelp = NSTextField(labelWithString: "文字工具：单击选中拖动，双击改文字")
        textHelp.font = .systemFont(ofSize: 11); textHelp.toolTip = "拖动文字角点缩放，上方手柄旋转；双击修改文字"
        textStyles.forEach { textRow.addArrangedSubview($0) }; textRow.spacing = 6; textRow.distribution = .fill; textRow.alignment = .centerY
        textRow.identifier = NSUserInterfaceItemIdentifier("editor.precision")
        styleRow.isHidden = true; textRow.isHidden = true
        let rows = NSStackView(views: [mainRow, styleRow, textRow]); rows.orientation = .vertical; rows.alignment = .leading; rows.spacing = 8; rows.distribution = .fill
        styleRow.widthAnchor.constraint(equalTo: mainRow.widthAnchor).isActive = true
        for row in [mainRow, textRow] {
            row.setContentHuggingPriority(.required, for: .horizontal)
            row.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        toolbar.contentView = captureToolbar(views: [rows])
        canvas.changed = { [weak self] in
            guard let self else { return }; self.layoutCapture()
            for button in self.colorButtons {
                button.state = AnnotationColor.allCases[button.tag] == self.canvas.selectedColor ? .on : .off
                button.needsDisplay = true
            }
            if self.fontSizeField.currentEditor() == nil { self.fontSizeField.doubleValue = self.canvas.textFontSize }
            if self.rotationField.currentEditor() == nil { self.rotationField.doubleValue = self.canvas.textRotation }
            if self.opacityField.currentEditor() == nil { self.opacityField.doubleValue = self.canvas.textOpacity * 100 }
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
    private func icon(_ name: String, _ title: String, target: AnyObject, action: Selector, minimumWidth: CGFloat = 28) -> NSButton {
        let button = EditorIconButton(image: CaptureIcons.toolbar(name) ?? NSImage(systemSymbolName: name, accessibilityDescription: title) ?? NSImage(), target: target, action: action)
        button.toolTip = title; button.isBordered = false
        button.setAccessibilityLabel(title)
        button.imageScaling = .scaleNone
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: minimumWidth).isActive = true
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true
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
        info.font = .systemFont(ofSize: 11, weight: .regular); info.textColor = .secondaryLabelColor
        info.stringValue = "\(canvas.state.image.width) × \(canvas.state.image.height)"
        if frozenCapture?.limitsExpansion == true { info.toolTip = "显示器组合超过快照内存上限，仅能在已冻结范围内调整。" }
        toolbar.contentView?.layoutSubtreeIfNeeded()
        let size = toolbar.contentView!.fittingSize
        let placement = NSScreen.screens.max { left, right in
            let a = left.frame.intersection(frame), b = right.frame.intersection(frame)
            return a.width * a.height < b.width * b.height
        }?.visibleFrame ?? visibleFrame
        if let origin = toolbarOriginOverride {
            let bounds = NSScreen.screens.first { $0.frame.contains(origin) }?.visibleFrame ?? placement
            let x = min(max(origin.x, bounds.minX), max(bounds.minX, bounds.maxX-size.width))
            let y = min(max(origin.y, bounds.minY), max(bounds.minY, bounds.maxY-size.height))
            toolbarOriginOverride = CGPoint(x: x, y: y)
            toolbar.setFrame(CGRect(x: x, y: y, width: size.width, height: size.height), display: true)
        } else { toolbar.setFrame(CaptureLayout.toolbar(near: frame, size: size, within: placement), display: true) }
    }
    func moveToolbar(to origin: CGPoint) {
        toolbarOriginOverride = origin; layoutCapture()
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
        EditorHoverHelp.hide()
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
    @objc private func saveEditing() {
        toolbar.makeFirstResponder(nil); canvas.saveDocument(nil)
    }
    @objc private func completeEditing() {
        toolbar.makeFirstResponder(nil)
        if canvas.copyImage() { close(); dismissed?() }
    }
    @objc private func cancelEditing() { close(); dismissed?() }
    @objc private func beginScroll() { close(); requestScroll?() }
    private func refreshStyleVisibility() {
        let supportsStyle = canvas.tool != .crop && canvas.tool != .redact
        styleRow.isHidden = !stylesExpanded || !supportsStyle
        textRow.isHidden = !stylesExpanded || canvas.tool != .text || !advancedExpanded
        textPresets.isHidden = canvas.tool != .text; advancedButton.isHidden = canvas.tool != .text
        widthOptions.isHidden = canvas.tool == .text
        layoutCapture()
    }
    func controlTextDidEndEditing(_ notification: Notification) { changeTextStyle() }
    @objc private func changeTextStyle() {
        let size = min(300, max(8, fontSizeField.doubleValue))
        let rotation = min(360, max(-360, rotationField.doubleValue))
        let opacity = min(100, max(5, opacityField.doubleValue))
        fontSizeField.doubleValue = size; rotationField.doubleValue = rotation; opacityField.doubleValue = opacity
        canvas.styleSelectedText(fontSize: size, rotation: rotation, opacity: opacity / 100)
    }
    @objc private func selectColor(_ sender: NSButton) {
        toolbar.makeFirstResponder(nil)
        canvas.commitText(); canvas.selectedColor = AnnotationColor.allCases[sender.tag]
        if canvas.tool == .text { canvas.styleSelectedText(fontSize: canvas.textFontSize, rotation: canvas.textRotation, opacity: canvas.textOpacity) }
        for button in colorButtons { button.state = button === sender ? .on : .off; button.needsDisplay = true }
        window?.makeKeyAndOrderFront(nil); window?.makeFirstResponder(canvas)
    }
    @objc private func selectWidth(_ sender: NSSegmentedControl) {
        toolbar.makeFirstResponder(nil)
        canvas.commitText(); canvas.strokeWidth = [1.5, 3.0, 6.0][sender.selectedSegment]
        window?.makeKeyAndOrderFront(nil); window?.makeFirstResponder(canvas)
    }
    @objc private func toggleAdvanced() { toolbar.makeFirstResponder(nil); advancedExpanded.toggle(); refreshStyleVisibility() }
    @objc private func selectTextPreset(_ sender: NSButton) {
        toolbar.makeFirstResponder(nil)
        canvas.styleSelectedText(fontSize: CGFloat(sender.tag), rotation: canvas.textRotation, opacity: canvas.textOpacity)
    }
    @objc private func pinEditing() {
        toolbar.makeFirstResponder(nil); canvas.commitText()
        guard let image = render(canvas.state) else { return }
        do { try PinnedImage.show(image, near: captureRegion); close(); dismissed?() }
        catch { showError(error) }
    }
    @objc private func showMore(_ sender: NSButton) {
        EditorHoverHelp.hide()
        let menu = NSMenu()
        let crop = NSMenuItem(title: "裁剪（适合长图收尾）", action: #selector(selectCrop), keyEquivalent: "")
        crop.target = self; crop.image = NSImage(systemSymbolName: "crop", accessibilityDescription: "裁剪"); menu.addItem(crop)
        menu.popUp(positioning: nil, at: CGPoint(x: 0, y: sender.bounds.minY), in: sender)
    }
    @objc private func selectCrop() { chooseTool(.crop) }
    @objc private func activateShape() {
        chooseTool(lastShape)
    }
    @objc private func showShapes(_ sender: NSButton) {
        EditorHoverHelp.hide(); shapeMenu.popUp(positioning: nil, at: CGPoint(x: 0, y: sender.bounds.minY), in: sender)
    }
    @objc private func selectShape(_ sender: NSMenuItem) { chooseTool(EditTool.allCases[sender.tag]) }
    @objc private func selectToolButton(_ sender: NSButton) { chooseTool(EditTool.allCases[sender.tag]) }
    func chooseTool(_ tool: EditTool) {
        toolbar.makeFirstResponder(nil); canvas.commitText(); canvas.tool = tool
        stylesExpanded = tool != .crop && tool != .redact; advancedExpanded = false
        for button in toolButtons { button.state = EditTool.allCases[button.tag] == tool ? .on : .off; button.contentTintColor = button.state == .on ? .systemTeal : .labelColor }
        if tool == .rectangle || tool == .ellipse {
            lastShape = tool
            shapeButton?.image = CaptureIcons.toolbar(tool == .ellipse ? "circle" : "rectangle")
        }
        shapeGroup.selected = tool == .rectangle || tool == .ellipse
        shapeButton?.state = shapeGroup.selected ? .on : .off
        shapeButton?.contentTintColor = tool == .rectangle || tool == .ellipse ? .systemTeal : .labelColor
        for item in shapeMenu.items { item.state = EditTool.allCases[item.tag] == lastShape ? .on : .off }
        refreshStyleVisibility(); window?.makeKeyAndOrderFront(nil); window?.makeFirstResponder(canvas)
    }
}
