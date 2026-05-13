import Foundation
import AppKit
import CoreGraphics
import os.log

/// Periodic full-display capture using CGWindowList (works back to macOS 10).
///
/// Captures are gated by user opt-in + a per-agent quiet-hour predicate +
/// the global "sensors paused" toggle. The controller calls `configure(...)`
/// whenever the active agent changes.
final class ScreenshotService {
    var onCapture: ((String, String) -> Void)?
    var captionProvider: (() -> String)?

    private var timer: Timer?
    private var enabled: Bool = false
    private var interval: TimeInterval = 300
    private var isQuiet: () -> Bool = { false }
    private var agentSlug: String = Trace.unknownAgent

    func configure(enabled: Bool,
                   interval: TimeInterval,
                   agent: String,
                   isQuiet: @escaping () -> Bool) {
        let clamped = max(30, interval)
        let timerAlreadyArmed = (timer != nil)
        self.enabled = enabled
        self.interval = clamped
        self.isQuiet = isQuiet
        self.agentSlug = agent
        Trace.log(Trace.screenshot,
                  agent: agent,
                  "configure enabled=\(enabled) interval=\(clamped)s armed=\(timerAlreadyArmed)")
        if timerAlreadyArmed { start() }
    }

    func start() {
        stop()
        guard enabled else {
            Trace.log(Trace.screenshot, agent: agentSlug, "start() skipped — disabled")
            return
        }
        if Config.shared.sensorsPaused {
            Trace.log(Trace.screenshot, agent: agentSlug, "start() skipped — sensors paused")
            return
        }
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        self.timer = t
        Trace.log(Trace.screenshot,
                  agent: agentSlug,
                  "started — first fire in \(Int(interval))s, repeats=\(Int(interval))s")
    }

    func stop() {
        if timer != nil {
            Trace.log(Trace.screenshot, agent: agentSlug, "stop()")
        }
        timer?.invalidate()
        timer = nil
    }

    func captureOnce() { tick() }

    private func tick() {
        let quiet = isQuiet()
        Trace.log(Trace.screenshot,
                  agent: agentSlug,
                  "tick enabled=\(enabled) quiet=\(quiet) paused=\(Config.shared.sensorsPaused)")
        if Config.shared.sensorsPaused {
            Trace.log(Trace.screenshot, agent: agentSlug, "suppressed — sensors paused")
            return
        }
        if quiet {
            Trace.log(Trace.screenshot, agent: agentSlug, "suppressed — quiet hours")
            return
        }
        if !enabled {
            Trace.log(Trace.screenshot, agent: agentSlug, "suppressed — disabled")
            return
        }
        guard let png = captureMainDisplayPNG() else {
            Trace.log(Trace.screenshot, .error,
                      agent: agentSlug,
                      "captureMainDisplayPNG returned nil — Screen Recording permission?")
            return
        }
        let b64 = png.base64EncodedString()
        let caption = captionProvider?() ?? "[screenshot]"
        Trace.log(Trace.screenshot,
                  agent: agentSlug,
                  "send bytes=\(png.count) caption='\(caption)'")
        guard let cb = onCapture else {
            Trace.log(Trace.screenshot, .error,
                      agent: agentSlug,
                      "onCapture handler is nil — payload dropped")
            return
        }
        cb(b64, caption)
    }

    private func captureMainDisplayPNG() -> Data? {
        let displayID = CGMainDisplayID()
        guard let cg = CGDisplayCreateImage(displayID) else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: cg)

        let scale: CGFloat = {
            let longEdge = CGFloat(max(cg.width, cg.height))
            let cap: CGFloat = 1600
            return longEdge > cap ? cap / longEdge : 1.0
        }()

        let targetW = Int(CGFloat(cg.width) * scale)
        let targetH = Int(CGFloat(cg.height) * scale)

        guard scale < 1.0,
              let resized = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: targetW,
                pixelsHigh: targetH,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0)
        else {
            return bitmap.representation(using: .png, properties: [:])
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: resized)
        let dst = NSRect(x: 0, y: 0, width: targetW, height: targetH)
        bitmap.draw(in: dst)
        NSGraphicsContext.restoreGraphicsState()
        return resized.representation(using: .png, properties: [:])
    }
}
