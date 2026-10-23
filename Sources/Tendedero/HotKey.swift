import AppKit
import Carbon

/// A single global shortcut through the Carbon hot key API. Unlike a global
/// key monitor, it needs no Accessibility permission.
///
/// One handler serves every hot key in the app, and the Carbon event carries
/// which one fired, so showing the line and deleting the hovered photo can
/// have separate shortcuts without stealing each other's callback.
final class HotKey {
    private var ref: EventHotKeyRef?
    private static var actions: [UInt32: () -> Void] = [:]
    private static var handlerInstalled = false
    private let id: UInt32

    /// Nil when the combination cannot be registered, for example because
    /// another app already took it.
    init?(_ shortcut: Shortcut, id: UInt32, action: @escaping () -> Void) {
        self.id = id
        HotKey.actions[id] = action
        // One handler for the app, however many times the shortcuts change.
        if !HotKey.handlerInstalled {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                guard let event else { return noErr }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID)
                guard status == noErr else { return status }
                DispatchQueue.main.async { HotKey.actions[hotKeyID.id]?() }
                return noErr
            }, 1, &spec, nil, nil)
            HotKey.handlerInstalled = true
        }
        let hotKeyID = EventHotKeyID(signature: OSType(0x5445_4E44), id: id) // "TEND"
        let status = RegisterEventHotKey(UInt32(shortcut.keyCode), UInt32(shortcut.carbonModifiers), hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, ref != nil else {
            HotKey.actions[id] = nil
            return nil
        }
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        HotKey.actions[id] = nil
    }
}

/// Which global shortcut a value belongs to. The two are stored separately so
/// changing one never changes the other.
enum ShortcutSlot {
    case showLine
    case deleteHovered

    var defaultsKey: String {
        switch self {
        case .showLine: "shortcut"
        case .deleteHovered: "deleteShortcut"
        }
    }

    var fallback: Shortcut? {
        switch self {
        case .showLine: Shortcut.standard
        case .deleteHovered: Shortcut.deleteHoveredStandard
        }
    }

    var changeTitle: String {
        switch self {
        case .showLine: L("Change Shortcut")
        case .deleteHovered: L("Change Delete Shortcut")
        }
    }
}

/// A global shortcut made of a key and its modifiers.
struct Shortcut: Equatable {
    var keyCode: Int
    var modifiers: NSEvent.ModifierFlags
    /// The key as typed, for the menu: "t", " ", "1", "⌫".
    var key: String

    static let standard = Shortcut(keyCode: kVK_ANSI_T, modifiers: [.control, .option], key: "t")
    /// Delete the photo under the pointer while the line is down.
    static let deleteHoveredStandard = Shortcut(keyCode: kVK_Delete, modifiers: [.control, .option], key: "⌫")

    /// The shortcut that shows and hides the line. Nil means none.
    static var current: Shortcut? {
        get { current(for: .showLine) }
        set { set(newValue, for: .showLine) }
    }

    /// The shortcut that deletes the photo under the pointer. Nil means none.
    static var deleteHovered: Shortcut? {
        get { current(for: .deleteHovered) }
        set { set(newValue, for: .deleteHovered) }
    }

    static func current(for slot: ShortcutSlot) -> Shortcut? {
        guard let saved = UserDefaults.standard.dictionary(forKey: slot.defaultsKey) else { return slot.fallback }
        guard let code = saved["keyCode"] as? Int, let flags = saved["modifiers"] as? UInt,
              let key = saved["key"] as? String else { return nil }
        return Shortcut(keyCode: code, modifiers: NSEvent.ModifierFlags(rawValue: flags), key: key)
    }

    static func set(_ shortcut: Shortcut?, for slot: ShortcutSlot) {
        UserDefaults.standard.set(shortcut.map {
            ["keyCode": $0.keyCode, "modifiers": $0.modifiers.rawValue, "key": $0.key] as [String: Any]
        } ?? [:], forKey: slot.defaultsKey)
    }

    /// From a key press, if it makes a usable global shortcut: it needs
    /// Command, Control or Option, so typing alone never triggers it.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard !flags.intersection([.command, .control, .option]).isEmpty else { return nil }
        let key: String
        switch Int(event.keyCode) {
        case kVK_Delete: key = "⌫"
        case kVK_ForwardDelete: key = "⌦"
        case kVK_Return: key = "↩"
        case kVK_Tab: key = "⇥"
        case kVK_Escape: key = "⎋"
        default: key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        }
        guard !key.isEmpty else { return nil }
        self.init(keyCode: Int(event.keyCode), modifiers: flags, key: key)
    }

    init(keyCode: Int, modifiers: NSEvent.ModifierFlags, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    var carbonModifiers: Int {
        var carbon = 0
        if modifiers.contains(.command) { carbon |= cmdKey }
        if modifiers.contains(.control) { carbon |= controlKey }
        if modifiers.contains(.option) { carbon |= optionKey }
        if modifiers.contains(.shift) { carbon |= shiftKey }
        return carbon
    }

    /// As macOS writes it in menus: ⌃⌥⇧⌘ and the key.
    var display: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + (key == " " ? L("Space") : key.uppercased())
    }
}

/// Asks for a new shortcut in a small window: the next key press with
/// Command, Control or Option becomes it. Escape cancels and Delete leaves
/// the slot without a shortcut.
@MainActor
final class ShortcutRecorder: NSObject, NSWindowDelegate {
    static let shared = ShortcutRecorder()

    private var window: NSWindow?
    private var monitor: Any?
    private var done: ((Shortcut??) -> Void)?

    /// Calls back with the new shortcut, `.some(nil)` for none, or nil if
    /// cancelled.
    func record(for slot: ShortcutSlot, _ done: @escaping (Shortcut??) -> Void) {
        finish(nil)
        self.done = done

        let title = NSTextField(labelWithString: L("Press the new shortcut"))
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        let hint = NSTextField(labelWithString: L("Escape cancels. Delete removes the shortcut."))
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [title, hint])
        stack.orientation = .vertical
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 28, bottom: 22, right: 28)

        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = slot.changeTitle
        window.contentView = stack
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            let plain = event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
            if event.keyCode == UInt16(kVK_Escape) && plain {
                self.finish(nil)
            } else if (event.keyCode == UInt16(kVK_Delete) || event.keyCode == UInt16(kVK_ForwardDelete)) && plain {
                self.finish(.some(nil))
            } else if let shortcut = Shortcut(event: event) {
                self.finish(.some(shortcut))
            } else {
                NSSound.beep()
            }
            return nil
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else { return }
        window = nil
        finish(nil)
    }

    private func finish(_ result: Shortcut??) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        let done = self.done
        self.done = nil
        window?.close()
        window = nil
        done?(result)
    }
}
