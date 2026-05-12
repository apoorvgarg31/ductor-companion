import SwiftUI
import AppKit

/// SwiftUI view that renders the currently-active row of the sprite atlas
/// as a frame-by-frame animation. Wraps a tiny state machine for the
/// pet's mood (idle / waving / running / celebrating).
struct PetView: View {
    enum Mood: String {
        case idle, waving, running, celebrating
    }

    @ObservedObject var state: PetViewState
    let atlas: SpriteAtlas
    let onClick: () -> Void

    var body: some View {
        Image(nsImage: state.currentFrame ?? fallbackImage())
            .resizable()
            .interpolation(.high)
            .frame(width: 192, height: 208)
            .opacity(0.98)
            .scaleEffect(state.bounce ? 1.03 : 1.0)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                       value: state.bounce)
            .contentShape(Rectangle())
            .onTapGesture(perform: onClick)
            .onAppear {
                state.start(with: atlas)
            }
    }

    private func fallbackImage() -> NSImage {
        if let first = atlas.frames.first?.first { return first }
        return NSImage(size: NSSize(width: 192, height: 208))
    }
}

/// Drives the per-frame timer and lets external services switch the active mood.
final class PetViewState: ObservableObject {
    @Published var currentFrame: NSImage?
    @Published var bounce: Bool = false

    private var atlas: SpriteAtlas?
    private var frames: [NSImage] = []
    private var frameIndex: Int = 0
    private var timer: Timer?
    private(set) var mood: PetView.Mood = .idle
    private var moodResetWork: DispatchWorkItem?

    func start(with atlas: SpriteAtlas) {
        self.atlas = atlas
        setMood(.idle, transient: false)
        bounce = true
    }

    /// Switches the active mood. Pass `transient: true` to auto-revert to idle
    /// after `duration` seconds (used while a speech bubble is on screen).
    func setMood(_ mood: PetView.Mood, transient: Bool, duration: TimeInterval = 4.0) {
        guard let atlas = atlas else { return }
        self.mood = mood
        self.frames = atlas.frames(for: mood.rawValue)
        self.frameIndex = 0
        self.currentFrame = frames.first

        moodResetWork?.cancel()
        timer?.invalidate()

        // Idle plays at ~5 fps (slow breathing); active moods at ~10 fps.
        let fps: Double = mood == .idle ? 5.0 : 10.0
        let t = Timer.scheduledTimer(withTimeInterval: 1.0 / fps, repeats: true) { [weak self] _ in
            guard let self, !self.frames.isEmpty else { return }
            self.frameIndex = (self.frameIndex + 1) % self.frames.count
            self.currentFrame = self.frames[self.frameIndex]
        }
        RunLoop.main.add(t, forMode: .common)
        self.timer = t

        if transient {
            let work = DispatchWorkItem { [weak self] in
                self?.setMood(.idle, transient: false)
            }
            moodResetWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
        }
    }

    deinit {
        timer?.invalidate()
        moodResetWork?.cancel()
    }
}
