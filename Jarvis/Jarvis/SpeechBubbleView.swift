import SwiftUI

/// Rounded chat-style bubble that pops next to the pet.
///
/// Renders up to ~5 lines inline; if the original text is longer it shows
/// a "tap for full thread" affordance that opens Telegram.
struct SpeechBubbleView: View {
    let text: String
    let hasMedia: Bool
    let mediaCaption: String?
    let onOpenTelegram: () -> Void
    let onDismiss: () -> Void

    private let maxLines: Int = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if hasMedia {
                HStack(spacing: 6) {
                    Image(systemName: "paperclip.circle.fill")
                        .foregroundStyle(.secondary)
                    Text(mediaCaption?.isEmpty == false ? mediaCaption! : "Attachment")
                        .font(.system(.callout, design: .rounded).weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }

            Text(displayText)
                .font(.system(.body, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(maxLines)
                .fixedSize(horizontal: false, vertical: true)

            if needsTapAffordance {
                Button(action: onOpenTelegram) {
                    HStack(spacing: 4) {
                        Image(systemName: "envelope.fill")
                        Text("tap for full thread")
                            .font(.system(.footnote, design: .rounded).weight(.medium))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 320, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.thinMaterial)
                .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.25), lineWidth: 0.5)
        )
        .onTapGesture { onDismiss() }
        .accessibilityElement(children: .combine)
    }

    private var displayText: String {
        let lines = text.split(whereSeparator: \.isNewline)
        if lines.count <= maxLines { return text }
        return lines.prefix(maxLines).joined(separator: "\n") + "…"
    }

    private var needsTapAffordance: Bool {
        let lines = text.split(whereSeparator: \.isNewline)
        return lines.count > maxLines || text.count > 280
    }
}

/// Estimated reading time used to auto-dismiss the bubble.
/// 3 seconds floor + 50 ms per character, capped at 30 s.
func bubbleReadingTime(for text: String) -> TimeInterval {
    let base: TimeInterval = 3.0
    let perChar: TimeInterval = 0.05
    return min(30.0, base + perChar * Double(text.count))
}
