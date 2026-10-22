import AppKit
import Carbon

struct Shortcut: Codable, Equatable {
    var key: UInt32
    var modifiers: UInt32
    var label: String
    static let normal = Shortcut(key: 19, modifiers: UInt32(cmdKey | shiftKey), label: "⌘⇧2")
    static let scroll = Shortcut(key: 26, modifiers: UInt32(cmdKey | shiftKey), label: "⌘⇧7")
}

/// 工具通过稳定 ID 注册动作，宿主可以扩展计时器、取色等模块。
@MainActor final class HotkeyRegistry {
    private var refs: [String: EventHotKeyRef] = [:]
    private var actions: [UInt32: () -> Void] = [:]
    private var ids: [String: UInt32] = [:]
    private var shortcuts: [String: Shortcut] = [:]
    private var serial: UInt32 = 0
    private var handler: EventHandlerRef?
    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, pointer in
            guard let event, let pointer else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let registry = Unmanaged<HotkeyRegistry>.fromOpaque(pointer).takeUnretainedValue()
            MainActor.assumeIsolated { registry.actions[id.id]?() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
    @discardableResult func register(_ name: String, shortcut: Shortcut, action: @escaping () -> Void) -> Bool {
        if shortcuts[name] == shortcut, let id = ids[name] { actions[id] = action; return true }
        serial += 1
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.key, shortcut.modifiers,
                                        EventHotKeyID(signature: 0x4B49524B, id: serial), GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        unregister(name)
        refs[name] = ref; ids[name] = serial; actions[serial] = action; shortcuts[name] = shortcut
        return true
    }
    func unregister(_ name: String) {
        shortcuts.removeValue(forKey: name)
        if let ref = refs.removeValue(forKey: name) { UnregisterEventHotKey(ref) }
        if let id = ids.removeValue(forKey: name) { actions.removeValue(forKey: id) }
    }
    deinit {
        refs.values.forEach { UnregisterEventHotKey($0) }
        if let handler { RemoveEventHandler(handler) }
    }
}

final class ShortcutRecorder: NSTextField {
    var onRecord: ((Shortcut) -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); stringValue = "按组合键（Esc 退出）" }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { window?.makeFirstResponder(nil); return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) || flags.contains(.control) || flags.contains(.option) else { stringValue = "需包含 ⌘ / ⌃ / ⌥"; return }
        var mods: UInt32 = 0, label = ""
        if flags.contains(.control) { mods |= UInt32(controlKey); label += "⌃" }
        if flags.contains(.option) { mods |= UInt32(optionKey); label += "⌥" }
        if flags.contains(.shift) { mods |= UInt32(shiftKey); label += "⇧" }
        if flags.contains(.command) { mods |= UInt32(cmdKey); label += "⌘" }
        guard let key = event.charactersIgnoringModifiers, !key.isEmpty else { return }
        label += key.uppercased()
        onRecord?(Shortcut(key: UInt32(event.keyCode), modifiers: mods, label: label))
        window?.makeFirstResponder(nil)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self { keyDown(with: event); return true }; return false
    }
}
