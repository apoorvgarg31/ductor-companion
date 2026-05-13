import AppKit
import SwiftUI

/// Borderless, transparent, always-on-top panel that hosts the pet sprite.
/// Lets the user drag from anywhere inside the content view to reposition
/// the window. The speech bubble lives in a sibling panel (see
/// `BubbleWindow`) so it can be anchored to the pet's current screen
/// position rather than baked into this window's layout.
final class PetWindow: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        self.level = .floating
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.isMovableByWindowBackground = true
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        self.ignoresMouseEvents = false
        self.isReleasedWhenClosed = false
        self.hidesOnDeactivate = false
        self.titleVisibility = .hidden
        self.titlebarAppearsTransparent = true
        self.animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Stash the current frame origin into Config so we can restore it next launch.
    func persistPosition() {
        Config.shared.petPosition = self.frame.origin
    }
}

/// Sibling floating panel that hosts the speech bubble. Sized to fit its
/// SwiftUI content and re-positioned every time it's shown so the bubble
/// stays glued to the pet regardless of where the pet has been dragged.
final class BubbleWindow: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.level = .floating
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        self.ignoresMouseEvents = false
        self.isReleasedWhenClosed = false
        self.hidesOnDeactivate = false
        self.animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Top-level NSWindowController that wires the SwiftUI pet view into the
/// floating panel and drives the transient speech bubble panel.
final class PetWindowController: NSWindowController, NSWindowDelegate {
    let petState = PetViewState()
    private let atlas: SpriteAtlas
    private let onPetClick: () -> Void
    private let petSize = NSSize(width: 192, height: 208)
    private var bubblePanel: BubbleWindow?
    private var bubbleDismissWork: DispatchWorkItem?

    init(atlas: SpriteAtlas, onPetClick: @escaping () -> Void) {
        self.atlas = atlas
        self.onPetClick = onPetClick

        let origin = Config.shared.petPosition ?? PetWindowController.defaultOrigin(size: petSize)
        let frame = NSRect(origin: origin, size: petSize)
        let panel = PetWindow(contentRect: frame)

        let petView = PetView(state: petState, atlas: atlas, onClick: onPetClick)
        panel.contentView = NSHostingView(rootView: petView
            .frame(width: petSize.width, height: petSize.height))

        super.init(window: panel)
        panel.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported for PetWindowController")
    }

    private static func defaultOrigin(size: NSSize) -> NSPoint {
        guard let screen = NSScreen.main else { return .zero }
        let v = screen.visibleFrame
        return NSPoint(x: v.maxX - size.width - 40, y: v.minY + 40)
    }

    // MARK: - Bubble

    func showBubble(text: String, hasMedia: Bool, mediaCaption: String?) {
        guard let petWindow = window else { return }
        clearBubble()

        let openTelegram = self.onPetClick
        let bubble = SpeechBubbleView(
            text: text,
            hasMedia: hasMedia,
            mediaCaption: mediaCaption,
            onOpenTelegram: { [weak self] in
                openTelegram()
                self?.clearBubble()
            },
            onDismiss: { [weak self] in
                self?.clearBubble()
            }
        )

        let host = NSHostingView(rootView: bubble)
        // Ask the SwiftUI hierarchy for its preferred size at a fixed width.
        let fittingSize = host.fittingSize
        let width: CGFloat = max(220, min(fittingSize.width, 340))
        let height: CGFloat = max(60, fittingSize.height)
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)

        let panel = BubbleWindow()
        panel.setContentSize(NSSize(width: width, height: height))
        panel.contentView = host

        positionBubble(panel: panel, near: petWindow.frame)
        panel.orderFront(nil)
        bubblePanel = panel

        // Wave (or its closest mood) while talking.
        petState.setMood(.waving,
                        transient: true,
                        duration: bubbleReadingTime(for: text))

        let work = DispatchWorkItem { [weak self] in self?.clearBubble() }
        bubbleDismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + bubbleReadingTime(for: text),
                                      execute: work)
    }

    func clearBubble() {
        bubbleDismissWork?.cancel()
        bubbleDismissWork = nil
        bubblePanel?.orderOut(nil)
        bubblePanel = nil
    }

    /// Place the bubble panel above the pet by default, falling back to
    /// below when there's no room above. Always clamp to the active
    /// screen's visible frame so it doesn't get clipped by the menu bar
    /// or dock.
    private func positionBubble(panel: BubbleWindow, near petFrame: NSRect) {
        let size = panel.frame.size
        let gap: CGFloat = 8
        let screen = window?.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? petFrame

        let preferredY = petFrame.maxY + gap
        let aboveFits = preferredY + size.height <= visible.maxY
        let y: CGFloat = aboveFits
            ? preferredY
            : max(visible.minY, petFrame.minY - gap - size.height)

        // Center the bubble horizontally over the pet, then clamp into screen.
        let centeredX = petFrame.midX - size.width / 2
        let clampedX = min(max(centeredX, visible.minX + 4),
                           visible.maxX - size.width - 4)
        panel.setFrameOrigin(NSPoint(x: clampedX, y: y))
    }

    // MARK: - NSWindowDelegate

    func windowDidMove(_ notification: Notification) {
        (window as? PetWindow)?.persistPosition()
    }
}
