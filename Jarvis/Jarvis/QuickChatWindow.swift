import AppKit

/// Floating one-shot input that pops at the middle-top of the active
/// screen when the global hotkey fires. Return sends as `user_text` to
/// the bridge; the reply arrives via the normal speech-bubble path so
/// there's no inline reply UI. Escape — or 30 s idle — dismisses.
final class QuickChatWindowController: NSObject, NSTextFieldDelegate {
    private var panel: NSPanel?
    private var textField: NSTextField?
    private var idleDismiss: DispatchWorkItem?
    private let send: (String) -> Void
    private let idleTimeout: TimeInterval = 30

    init(send: @escaping (String) -> Void) {
        self.send = send
    }

    func toggle() {
        if panel != nil { dismiss() } else { present() }
    }

    func present() {
        let size = NSSize(width: 520, height: 56)
        let screen = screenUnderMouse()
        let v = screen.visibleFrame
        let origin = NSPoint(x: v.midX - size.width / 2,
                             y: v.maxY - size.height - 80)

        let p = NSPanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.title = "Ask Jarvis"
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isFloatingPanel = true
        p.level = .modalPanel
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.isMovableByWindowBackground = true
        p.isReleasedWhenClosed = false

        let tf = NSTextField(frame: NSRect(x: 16, y: 14,
                                            width: size.width - 32,
                                            height: 28))
        tf.placeholderString = "Ask Jarvis…"
        tf.font = NSFont.systemFont(ofSize: 16, weight: .regular)
        tf.bezelStyle = .roundedBezel
        tf.focusRingType = .none
        tf.isBordered = false
        tf.drawsBackground = false
        tf.delegate = self
        tf.target = self
        tf.action = #selector(submitFromField(_:))

        let content = NSView(frame: NSRect(origin: .zero, size: size))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        content.layer?.cornerRadius = 10
        content.addSubview(tf)
        p.contentView = content

        p.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        p.makeFirstResponder(tf)
        panel = p
        textField = tf
        kickIdleTimer()
    }

    func dismiss() {
        idleDismiss?.cancel()
        idleDismiss = nil
        panel?.orderOut(nil)
        panel = nil
        textField = nil
    }

    @objc private func submitFromField(_ sender: NSTextField) {
        submit(sender.stringValue)
    }

    private func submit(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        send(trimmed)
        dismiss()
    }

    func control(_ control: NSControl,
                 textView: NSTextView,
                 doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            dismiss(); return true
        }
        if selector == #selector(NSResponder.insertNewline(_:)) {
            submit(textField?.stringValue ?? ""); return true
        }
        return false
    }

    func controlTextDidChange(_ obj: Notification) {
        kickIdleTimer()
    }

    private func kickIdleTimer() {
        idleDismiss?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        idleDismiss = work
        DispatchQueue.main.asyncAfter(deadline: .now() + idleTimeout, execute: work)
    }

    /// Best signal for "where the user is right now" is the screen the
    /// mouse is currently on; the key window may be on a different
    /// monitor, or there may be no key window at all.
    private func screenUnderMouse() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        for screen in NSScreen.screens where screen.frame.contains(mouse) {
            return screen
        }
        return NSScreen.main ?? NSScreen.screens.first!
    }
}
