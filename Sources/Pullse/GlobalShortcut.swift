import AppKit
import Carbon.HIToolbox
import Observation
import PullseCore

/// The shortcut that opens and closes the menu from any app. It is registered through
/// Carbon's hot key API, which delivers just this one key combination and so needs no
/// Accessibility permission, unlike watching every key press.
@MainActor
@Observable
final class GlobalShortcut {
    /// Set when macOS wouldn't register the shortcut, in words for the user.
    private(set) var registrationError: String?

    @ObservationIgnored private var hotKey: HotKey?
    @ObservationIgnored private var hotKeyRef: EventHotKeyRef?
    @ObservationIgnored private var handler: EventHandlerRef?
    @ObservationIgnored private var suspended = false

    /// Registers `hotKey` in place of the current one; nil removes it.
    func apply(_ hotKey: HotKey?) {
        guard hotKey != self.hotKey || (hotKey != nil && hotKeyRef == nil && !suspended) else { return }
        self.hotKey = hotKey
        register()
    }

    /// While a new shortcut is being recorded, so pressing the current one records it
    /// instead of toggling the menu.
    func suspend() {
        suspended = true
        register()
    }

    func resume() {
        suspended = false
        register()
    }

    private func register() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        registrationError = nil
        guard !suspended, let hotKey, hotKey.isValid else { return }
        installHandler()
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x5055_4C53), id: 1)  // "PULS"
        let status = RegisterEventHotKey(
            UInt32(hotKey.keyCode), Self.carbonModifiers(hotKey.modifiers), id,
            GetApplicationEventTarget(), 0, &ref
        )
        if status == noErr {
            hotKeyRef = ref
        } else {
            registrationError = "macOS didn't accept \(hotKey.display) (error \(status)). Another app may already use it; try a different one."
        }
    }

    private func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            // Carbon calls this on the main thread.
            MainActor.assumeIsolated { MenuToggle.toggle() }
            return noErr
        }, 1, &spec, nil, &handler)
    }

    private static func carbonModifiers(_ modifiers: Set<HotKey.Modifier>) -> UInt32 {
        var flags = 0
        if modifiers.contains(.command) { flags |= cmdKey }
        if modifiers.contains(.option) { flags |= optionKey }
        if modifiers.contains(.control) { flags |= controlKey }
        if modifiers.contains(.shift) { flags |= shiftKey }
        return UInt32(flags)
    }
}

/// Opens or closes the menu from code. `MenuBarExtra` has no API for that, so this clicks
/// Pullse's status bar button, which opens and closes its window exactly as a real click
/// does.
@MainActor
enum MenuToggle {
    static func toggle() {
        guard let button = StatusItemMenu.statusButton() else { return }
        // Make Pullse active first, so the menu window takes the keyboard when it opens.
        NSApp.activate(ignoringOtherApps: true)
        button.performClick(nil)
    }
}
