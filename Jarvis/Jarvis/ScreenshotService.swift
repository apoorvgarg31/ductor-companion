import Foundation
import AppKit
import CoreGraphics

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

    func configure(enabled: Bool, interval: TimeInterval, isQuiet: @escaping () -> Bool) {
        self.enabled = enabled
        self.interval = max(30, interval)
        self.isQuiet = isQuiet
    }

    func start() {
        stop()
        guard enabled, !Config.shared.sensorsPaused else { return }
        let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        self.timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func captureOnce() { tick() }

    private func tick() {
        if Config.shared.sensorsPaused || isQuiet() || !enabled { return }
        guard let png = captureMainDisplayPNG() else { return }
        let b64 = png.base64EncodedString()
        let caption = captionProvider?() ?? "[screenshot]"
        onCapture?(b64, caption)
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
