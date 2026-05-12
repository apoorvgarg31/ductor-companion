import Foundation

/// One configured Ductor sub-agent. Multiple of these can live side by
/// side; the user picks which one is "active" via the tray menu.
///
/// Telegram authentication (api id/hash/phone, StringSession) is global
/// — shared across all agents — so it isn't stored here. Only per-agent
/// preferences live in this struct.
struct AgentProfile: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String                  // slug, e.g. "jarvis"
    var displayName: String           // human label, e.g. "Jarvis"
    var botUsername: String           // e.g. "jarvis_apoorv_bot"
    var spritePath: String            // default ~/.codex/pets/<name>/
    var screenshotInterval: TimeInterval
    var heartbeatInterval: TimeInterval
    var screenshotsEnabled: Bool
    var quietHoursStart: Int          // 0–23
    var quietHoursEnd: Int            // 0–23

    init(
        id: UUID = UUID(),
        name: String,
        displayName: String,
        botUsername: String,
        spritePath: String,
        screenshotInterval: TimeInterval = 300,
        heartbeatInterval: TimeInterval = 120,
        screenshotsEnabled: Bool = false,
        quietHoursStart: Int = 22,
        quietHoursEnd: Int = 8
    ) {
        self.id = id
        self.name = name
        self.displayName = displayName
        self.botUsername = botUsername
        self.spritePath = spritePath
        self.screenshotInterval = screenshotInterval
        self.heartbeatInterval = heartbeatInterval
        self.screenshotsEnabled = screenshotsEnabled
        self.quietHoursStart = quietHoursStart
        self.quietHoursEnd = quietHoursEnd
    }

    /// Returns true when the current local time falls inside the agent's
    /// configured quiet hours range (handles overnight wrap-around).
    var isQuietHour: Bool {
        let hour = Calendar.current.component(.hour, from: Date())
        if quietHoursStart == quietHoursEnd { return false }
        if quietHoursStart < quietHoursEnd {
            return hour >= quietHoursStart && hour < quietHoursEnd
        }
        return hour >= quietHoursStart || hour < quietHoursEnd
    }

    /// Default sprite path for an agent with the given slug.
    static func defaultSpritePath(forName name: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.codex/pets/\(name)"
    }

    /// Derive a slug from a Telegram bot username:
    /// `jarvis_apoorv_bot` → `jarvis`, `coach42_bot` → `coach42`.
    static func deriveSlug(from botUsername: String) -> String {
        var s = botUsername
            .trimmingCharacters(in: CharacterSet(charactersIn: "@ "))
            .lowercased()
        if let r = s.range(of: "_bot", options: [.backwards, .anchored]) {
            s.removeSubrange(r)
        }
        // Take the first underscore-delimited segment.
        if let first = s.split(separator: "_").first {
            return String(first)
        }
        return s
    }
}
