import AppKit

/// 系统 tooltip 的层级低于截图浮层，因此在同一浮层之上绘制提示。
@MainActor enum EditorHoverHelp {
    private static var panel: NSPanel?
    static var diagnosticWindow: NSWindow? { panel }
    private static var pending: DispatchWorkItem?
    static func hide() { pending?.cancel(); pending = nil; panel?.orderOut(nil) }
    static func show(for button: NSButton) {
        hide()
        guard let text = button.toolTip, !text.isEmpty else { return }
        let work = DispatchWorkItem { [weak button] in
            guard let button, let window = button.window, window.isVisible else { return }
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: 12); label.textColor = .labelColor
            let popup = panel ?? NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            popup.isReleasedWhenClosed = false; popup.ignoresMouseEvents = true; popup.hidesOnDeactivate = false
            popup.backgroundColor = .clear; popup.isOpaque = false
            popup.level = NSWindow.Level(rawValue: window.level.rawValue + 2)
            popup.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            popup.contentView = captureToolbar(views: [label])
            let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
            let size = popup.contentView!.fittingSize
            let screen = window.screen?.visibleFrame ?? NSScreen.main!.visibleFrame
            popup.setFrame(CaptureLayout.toolbar(near: rect, size: size, within: screen), display: true)
            panel = popup; popup.orderFrontRegardless()
        }
        pending = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }
}
class EditorIconButton: NSButton {
    private var hoverTracking: NSTrackingArea?
    override func updateTrackingAreas() {
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(tracking); hoverTracking = tracking; super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { EditorHoverHelp.show(for: self) }
    override func mouseExited(with event: NSEvent) { EditorHoverHelp.hide() }
    override func mouseDown(with event: NSEvent) { EditorHoverHelp.hide(); super.mouseDown(with: event) }
}

/// 形状主体和窄下拉区是一个控件：共享背景，内部不使用工具间距。
final class EditorShapeGroup: NSStackView {
    var selected = false { didSet { refreshBackground() } }
    private var hovering = false
    private var hoverTracking: NSTrackingArea?
    override func updateTrackingAreas() {
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(tracking); hoverTracking = tracking; super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; refreshBackground() }
    override func mouseExited(with event: NSEvent) { hovering = false; refreshBackground() }
    private func refreshBackground() {
        wantsLayer = true; layer?.cornerRadius = 5
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(selected ? 0.1 : hovering ? 0.06 : 0).cgColor
    }
}

final class EditorToolbarDragHandle: EditorIconButton {
    var began: (() -> Void)?
    var moved: ((CGPoint) -> Void)?
    var reset: (() -> Void)?
    private var start: CGPoint?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.secondaryLabelColor.setFill()
        for x in [5.0, 10.0] { for y in [8.0, 14.0, 20.0] {
            NSBezierPath(ovalIn: CGRect(x: x-1, y: y-1, width: 2, height: 2)).fill()
        } }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func mouseDown(with event: NSEvent) {
        EditorHoverHelp.hide()
        if event.clickCount == 2 { start = nil; reset?(); return }
        start = NSEvent.mouseLocation; began?(); NSCursor.closedHand.set()
    }
    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let p = NSEvent.mouseLocation; moved?(CGPoint(x: p.x-start.x, y: p.y-start.y))
    }
    override func mouseUp(with event: NSEvent) { start = nil; NSCursor.openHand.set() }
}

private final class EditorMenuButton: NSButton {
    private var hoverArea: NSTrackingArea?
    private var isHovering = false
    var isKeyboardSelected = false { didSet { updateBackground() } }

    override func updateTrackingAreas() {
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        hoverArea = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true; updateBackground() }
    override func mouseExited(with event: NSEvent) { isHovering = false; updateBackground() }

    private func updateBackground() {
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.backgroundColor = isEnabled && (isHovering || isKeyboardSelected) ? NSColor(white: 1, alpha: 0.16).cgColor : nil
    }
}

/// 菜单使用和工具栏相同的原生控件，窗口层级由截图编辑器决定。
@MainActor final class EditorToolbarMenu: NSWindowController, NSWindowDelegate {
    private var eventMonitor: Any?
    private weak var previousKeyWindow: NSWindow?
    private weak var trigger: NSView?
    private var rows: [(item: NSMenuItem, button: EditorMenuButton)] = []
    private var selection: Int?

    init() {
        let panel = EditorToolbarPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                       backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        super.init(window: panel)
        panel.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ menu: NSMenu, from anchor: NSView, in toolbar: NSWindow, alignToToolbar: Bool = false) {
        EditorHoverHelp.hide()
        if window?.isVisible == true {
            dismiss(restoreFocus: true)
            return
        }
        guard let panel = window, let screen = toolbar.screen else { return }
        menu.update()
        previousKeyWindow = NSApp.keyWindow
        trigger = anchor
        rows = menu.items.filter { !$0.isHidden && !$0.isSeparatorItem }.map { item in
            let button = EditorMenuButton(title: item.title, target: self, action: #selector(choose(_:)))
            button.image = item.image
            button.imagePosition = .imageLeading
            button.alignment = .left
            button.font = .systemFont(ofSize: 13)
            button.isBordered = false
            button.isEnabled = item.isEnabled
            button.setAccessibilityLabel(item.title)
            if item.state == .on { button.contentTintColor = .systemTeal }
            button.heightAnchor.constraint(equalToConstant: 28).isActive = true
            return (item, button)
        }
        let list = NSStackView(views: rows.map(\.button))
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 2
        for (_, button) in rows {
            button.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
        list.widthAnchor.constraint(greaterThanOrEqualToConstant: 112).isActive = true
        let background = captureToolbar(views: [list])
        panel.contentView = background
        panel.collectionBehavior = toolbar.collectionBehavior
        panel.level = NSWindow.Level(rawValue: toolbar.level.rawValue + 3)
        let size = background.fittingSize
        let anchorFrame = toolbar.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let anchorX = alignToToolbar ? toolbar.frame.minX : anchorFrame.minX
        let point = CaptureLayout.menuTopLeft(under: toolbar.frame, alignedTo: anchorX,
                                              size: size, within: screen.visibleFrame)
        panel.setFrame(CGRect(x: point.x, y: point.y - size.height, width: size.width, height: size.height), display: true)
        panel.makeKeyAndOrderFront(nil)
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        if event.type != .keyDown {
            guard event.window !== window else { return event }
            if let trigger, event.window === trigger.window,
               trigger.bounds.contains(trigger.convert(event.locationInWindow, from: nil)) {
                dismiss(restoreFocus: true)
                return nil
            }
            dismiss()
            return event
        }
        switch event.keyCode {
        case 53:
            dismiss(restoreFocus: true)
        case 125, 126, 48:
            let enabled = rows.indices.filter { rows[$0].button.isEnabled }
            guard !enabled.isEmpty else { return nil }
            let direction = event.keyCode == 126 || event.modifierFlags.contains(.shift) ? -1 : 1
            let position = selection.flatMap { enabled.firstIndex(of: $0) } ?? (direction > 0 ? -1 : 0)
            if let selection { rows[selection].button.isKeyboardSelected = false }
            let next = enabled[(position + direction + enabled.count) % enabled.count]
            selection = next
            rows[next].button.isKeyboardSelected = true
        case 36, 76, 49:
            if let index = selection ?? rows.firstIndex(where: { $0.button.isEnabled }) { choose(rows[index].button) }
        default:
            return event
        }
        return nil
    }

    @objc private func choose(_ sender: NSButton) {
        guard let item = rows.first(where: { $0.button === sender })?.item, let action = item.action else { return }
        dismiss(restoreFocus: true)
        NSApp.sendAction(action, to: item.target, from: item)
    }

    func dismiss(restoreFocus: Bool = false) {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor); self.eventMonitor = nil }
        let previous = previousKeyWindow
        previousKeyWindow = nil
        trigger = nil
        rows = []
        selection = nil
        window?.orderOut(nil)
        if restoreFocus { previous?.makeKey() }
    }

    func windowDidResignKey(_ notification: Notification) {
        if eventMonitor != nil { dismiss() }
    }
}
