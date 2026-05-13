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
    /// Optional override pointing at a hatch-pet sprite directory (typically
    /// `~/.codex/pets/<slug>/`). When nil — the common case — the pet falls
    /// back to the app-bundled `zen-robot` atlas. See `SpriteAtlas` for the
    /// full resolution order.
    var spritePath: String?
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
        spritePath: String? = nil,
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
        self.spritePath = AgentProfile.normalize(spritePath)
        self.screenshotInterval = screenshotInterval
        self.heartbeatInterval = heartbeatInterval
        self.screenshotsEnabled = screenshotsEnabled
        self.quietHoursStart = quietHoursStart
        self.quietHoursEnd = quietHoursEnd
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.displayName = try c.decode(String.self, forKey: .displayName)
        self.botUsername = try c.decode(String.self, forKey: .botUsername)
        // Pre-v0.2.0 stored spritePath as a non-optional empty string when
        // unset — collapse that into nil so the bundled default kicks in.
        self.spritePath = AgentProfile.normalize(
            try c.decodeIfPresent(String.self, forKey: .spritePath)
        )
        self.screenshotInterval = try c.decode(TimeInterval.self, forKey: .screenshotInterval)
        self.heartbeatInterval = try c.decode(TimeInterval.self, forKey: .heartbeatInterval)
        self.screenshotsEnabled = try c.decode(Bool.self, forKey: .screenshotsEnabled)
        self.quietHoursStart = try c.decode(Int.self, forKey: .quietHoursStart)
        self.quietHoursEnd = try c.decode(Int.self, forKey: .quietHoursEnd)
    }

    private static func normalize(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            return nil
        }
        return raw
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
