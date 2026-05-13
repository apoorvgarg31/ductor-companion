import Foundation
import AppKit
import ApplicationServices
import CoreGraphics

/// Collects a lightweight activity snapshot (frontmost app, window title,
/// idle seconds, optional terminal cwd) and sends it through the bridge.
final class HeartbeatService {
    var onHeartbeat: (([String: Any]) -> Void)?

    private var timer: Timer?
    private var interval: TimeInterval = 120
    private var isQuiet: () -> Bool = { false }
    private var configured: Bool = false

    func configure(interval: TimeInterval, isQuiet: @escaping () -> Bool) {
        self.interval = max(30, interval)
        self.isQuiet = isQuiet
        self.configured = true
        // If the timer is already running with a stale interval, restart it.
        if timer != nil { start() }
    }

    func start() {
        stop()
        guard configured else {
            NSLog("[ductor] heartbeat.start() called before configure(); skipping")
            return
        }
        guard !Config.shared.sensorsPaused else { return }
        // Use the non-scheduling Timer initializer + explicit RunLoop.main /
        // .common modes so the timer fires even while menus / popovers are
        // open, and is guaranteed to live on the main runloop regardless of
        // which thread `start()` was invoked from.
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        self.timer = t
        NSLog("[ductor] heartbeat timer scheduled every \(interval)s")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func snapshot() -> [String: Any] {
        var out: [String: Any] = [
            "ts": Date().timeIntervalSince1970,
            "idle_seconds": currentIdleSeconds(),
            "quiet_hour": isQuiet(),
        ]
        if let app = NSWorkspace.shared.frontmostApplication {
            out["frontmost_app"] = app.localizedName ?? app.bundleIdentifier ?? "unknown"
            if let bundle = app.bundleIdentifier { out["frontmost_bundle"] = bundle }
            if let title = frontmostWindowTitle(for: app) { out["window_title"] = title }
            if let cwd = terminalCwdIfApplicable(for: app) { out["terminal_cwd"] = cwd }
        }
        return out
    }

    private func tick() {
        guard !Config.shared.sensorsPaused else { return }
        onHeartbeat?(snapshot())
    }

    private func currentIdleSeconds() -> Double {
        let secs = CGEventSource.secondsSinceLastEventType(.combinedSessionState,
                                                            eventType: .mouseMoved)
        return max(0, secs)
    }

    private func frontmostWindowTitle(for app: NSRunningApplication) -> String? {
        let pid = app.processIdentifier
        let element = AXUIElementCreateApplication(pid)

        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXFocusedWindowAttribute as CFString, &windowRef
        ) == .success, let win = windowRef else { return nil }

        // swiftlint:disable:next force_cast
        let window = win as! AXUIElement
        var titleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            window, kAXTitleAttribute as CFString, &titleRef
        ) == .success, let title = titleRef as? String else { return nil }
        return title.isEmpty ? nil : title
    }

    private func terminalCwdIfApplicable(for app: NSRunningApplication) -> String? {
        guard let bundle = app.bundleIdentifier else { return nil }
        switch bundle {
        case "com.apple.Terminal":
            return runAppleScript("""
                tell application "Terminal"
                    if (count of windows) > 0 then
                        try
                            return (do shell script "pwd")
                        end try
                    end if
                end tell
                """)
        case "com.googlecode.iterm2":
            return runAppleScript("""
                tell application "iTerm"
                    try
                        return (current session of current window)'s variable "session.path"
                    end try
                end tell
                """)
        default:
            return nil
        }
    }

    private func runAppleScript(_ source: String) -> String? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let output = script.executeAndReturnError(&error)
        if error != nil { return nil }
        let s = output.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (s?.isEmpty ?? true) ? nil : s
    }
}
