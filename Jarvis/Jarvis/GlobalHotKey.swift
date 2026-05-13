import Foundation
import AppKit
import Carbon.HIToolbox

/// Thin wrapper over Carbon's `RegisterEventHotKey` for desktop-wide key
/// bindings. The Carbon API is still the supported route for system-wide
/// hotkeys on macOS 13/14 — `NSEvent.addGlobalMonitorForEvents` cannot
/// intercept keystrokes destined for other apps without Accessibility
/// permission and is unreliable even then.
final class GlobalHotKey {
    private static var nextID: UInt32 = 1
    private static var handlerInstalled = false
    /// Holds the active hotkey wrappers keyed by their Carbon ID so the
    /// C-callback can find the Swift instance. Stored weakly so callers
    /// can release the wrapper without an explicit unregister step.
    private static var instances: [UInt32: Weak] = [:]

    private final class Weak {
        weak var value: GlobalHotKey?
        init(_ v: GlobalHotKey) { self.value = v }
    }

    private let id: UInt32
    private var ref: EventHotKeyRef?
    private let action: () -> Void

    init(keyCode: UInt16, carbonModifiers: UInt32, action: @escaping () -> Void) {
        let assigned = GlobalHotKey.nextID
        GlobalHotKey.nextID += 1
        self.id = assigned
        self.action = action

        GlobalHotKey.installHandlerIfNeeded()

        let hotKeyID = EventHotKeyID(signature: OSType(0x44545248 /* 'DTRH' */),
                                     id: assigned)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(keyCode),
            carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else {
            Trace.log(Trace.hotkey, .error, agent: Trace.unknownAgent,
                      "RegisterEventHotKey failed (status=\(status)) for "
                      + "keyCode=\(keyCode) mods=\(String(carbonModifiers, radix: 16))")
            return
        }
        self.ref = ref
        GlobalHotKey.instances[assigned] = Weak(self)
        Trace.log(Trace.hotkey, agent: Trace.unknownAgent,
                  "registered id=\(assigned) keyCode=\(keyCode) "
                  + "carbonMods=0x\(String(carbonModifiers, radix: 16))")
    }

    deinit {
        if let ref = ref {
            UnregisterEventHotKey(ref)
        }
        GlobalHotKey.instances.removeValue(forKey: id)
        Trace.log(Trace.hotkey, agent: Trace.unknownAgent,
                  "unregistered id=\(id)")
    }

    // MARK: - Carbon event handler

    private static func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(),
                            { (_, eventRef, _) -> OSStatus in
            guard let eventRef = eventRef else { return noErr }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                eventRef,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr else { return status }
            if let inst = GlobalHotKey.instances[hotKeyID.id]?.value {
                DispatchQueue.main.async { inst.action() }
            }
            return noErr
        }, 1, &eventType, nil, nil)
    }

    // MARK: - Modifier translation

    /// Map AppKit's `NSEvent.modifierFlags.rawValue` (what
    /// `QuickChatShortcut` persists) into the Carbon mask
    /// `RegisterEventHotKey` expects.
    static func carbonModifiers(from cocoaRawValue: UInt) -> UInt32 {
        let flags = NSEvent.ModifierFlags(rawValue: cocoaRawValue)
        var mask: UInt32 = 0
        if flags.contains(.command) { mask |= UInt32(cmdKey) }
        if flags.contains(.option) { mask |= UInt32(optionKey) }
        if flags.contains(.control) { mask |= UInt32(controlKey) }
        if flags.contains(.shift) { mask |= UInt32(shiftKey) }
        return mask
    }
}
