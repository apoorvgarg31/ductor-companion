import AppKit
import SwiftUI

/// Borderless, transparent, always-on-top panel that hosts the pet sprite
/// and (optionally) the speech bubble. Lets the user drag from anywhere
/// inside the content view to reposition the window.
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

/// Top-level NSWindowController that wires the SwiftUI hierarchy
/// (pet + transient speech bubble) into the floating panel.
final class PetWindowController: NSWindowController, NSWindowDelegate {
    let petState = PetViewState()
    private let atlas: SpriteAtlas
    private let onPetClick: () -> Void
    private var bubbleHostingView: NSHostingView<AnyView>?
    private var bubbleDismissWork: DispatchWorkItem?

    init(atlas: SpriteAtlas, onPetClick: @escaping () -> Void) {
        self.atlas = atlas
        self.onPetClick = onPetClick

        let petSize = NSSize(width: 192, height: 208)
        // Reserve extra height above the pet for the bubble.
        let totalSize = NSSize(width: 360, height: petSize.height + 220)
        let origin = Config.shared.petPosition ?? PetWindowController.defaultOrigin(size: totalSize)
        let frame = NSRect(origin: origin, size: totalSize)

        let panel = PetWindow(contentRect: frame)

        let petView = PetView(state: petState, atlas: atlas, onClick: onPetClick)

        // The container places the pet at the bottom and reserves space above
        // for the bubble (added later via a separate hosting view).
        let container = ZStack(alignment: .bottomLeading) {
            Color.clear
            petView
                .frame(width: petSize.width, height: petSize.height)
                .padding(.leading, 0)
        }
        .frame(width: totalSize.width, height: totalSize.height, alignment: .bottomLeading)

        panel.contentView = NSHostingView(rootView: container)
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
        guard let window = window, let contentView = window.contentView else { return }
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

        let host = NSHostingView(rootView: AnyView(bubble))
        host.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            host.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor,
                                           constant: -8),
            host.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
        ])
        bubbleHostingView = host

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
        bubbleHostingView?.removeFromSuperview()
        bubbleHostingView = nil
    }

    // MARK: - NSWindowDelegate

    func windowDidMove(_ notification: Notification) {
        (window as? PetWindow)?.persistPosition()
    }
}
