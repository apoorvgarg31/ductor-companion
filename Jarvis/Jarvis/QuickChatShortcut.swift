import Foundation
import AppKit
import Carbon.HIToolbox

/// User-configurable global hotkey for the quick-chat window. Persisted to
/// `UserDefaults` under `ductor.quickChatShortcut`. `keyCode` is a Carbon
/// virtual key code (the `NSEvent.keyCode` / `RegisterEventHotKey` domain);
/// `modifiers` is the `NSEvent.ModifierFlags.rawValue` mask. Carbon-side
/// translation happens in `GlobalHotKey`.
struct QuickChatShortcut: Codable, Equatable {
    var keyCode: Int
    var modifiers: UInt

    static let `default` = QuickChatShortcut(
        keyCode: Int(kVK_ANSI_J),
        modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue
    )

    /// "⌘⇧J"-style label for Settings.
    var displayString: String {
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        s += keyLabel
        return s
    }

    private var keyLabel: String {
        // Layout-aware lookup via the current keyboard input source —
        // falls back to a "key N" placeholder for non-printables we
        // don't bother naming (dead keys, fn keys we don't expose).
        if let c = Self.character(forKeyCode: UInt16(keyCode))?.uppercased(),
           !c.isEmpty {
            return c
        }
        return "key \(keyCode)"
    }

    static func character(forKeyCode keyCode: UInt16) -> String? {
        guard let layoutSource = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let rawPtr = TISGetInputSourceProperty(layoutSource,
                                                     kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        // TISGetInputSourceProperty returns `UnsafeMutableRawPointer`
        // that the runtime guarantees is a CFData when the property key
        // is kTISPropertyUnicodeKeyLayoutData. The canonical Carbon-Swift
        // pattern is unsafeBitCast — Unmanaged.fromOpaque type-mismatches
        // against the mutable pointer.
        let layoutData = unsafeBitCast(rawPtr, to: CFData.self)
        guard let bytes = CFDataGetBytePtr(layoutData) else { return nil }
        let layout = UnsafeRawPointer(bytes)
            .assumingMemoryBound(to: UCKeyboardLayout.self)
        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = UCKeyTranslate(
            layout, keyCode, UInt16(kUCKeyActionDisplay), 0,
            UInt32(LMGetKbdType()),
            OptionBits(kUCKeyTranslateNoDeadKeysBit),
            &deadKeyState, chars.count, &length, &chars
        )
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length)
    }
}

extension Config {
    var quickChatShortcut: QuickChatShortcut {
        get {
            if let data = UserDefaults.standard.data(forKey: "ductor.quickChatShortcut"),
               let s = try? JSONDecoder().decode(QuickChatShortcut.self, from: data) {
                return s
            }
            return .default
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: "ductor.quickChatShortcut")
            }
            NotificationCenter.default.post(name: .quickChatShortcutChanged,
                                            object: newValue)
        }
    }
}

extension Notification.Name {
    /// Posted when the user picks a new shortcut in Settings; the
    /// `AppDelegate` re-registers the Carbon hotkey on receipt.
    static let quickChatShortcutChanged = Notification.Name("ductor.quickChatShortcutChanged")
}
