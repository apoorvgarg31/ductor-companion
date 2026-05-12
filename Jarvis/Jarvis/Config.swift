import Foundation
import AppKit

/// Process-wide configuration. Owns:
///   * the list of configured Ductor agents
///   * which one is currently active
///   * pet window position + visibility flags
///   * the resolved Ductor home path (containing agents.json)
///
/// Per-agent settings (intervals, sprite path, bot username, quiet hours)
/// live on `AgentProfile` and are mutated via `updateSelectedAgent(_:)`.
/// Telegram credentials (api id/hash/phone) live in the Keychain.
final class Config: ObservableObject {
    static let shared = Config()

    private let defaults = UserDefaults.standard

    private enum Key {
        static let agents = "ductor.agents.v1"
        static let selectedAgentID = "ductor.selectedAgentID"
        static let ductorHomePath = "ductor.homePath"
        static let petPositionX = "ductor.petPositionX"
        static let petPositionY = "ductor.petPositionY"
        static let bridgePort = "ductor.bridgePort"
        static let petVisible = "ductor.petVisible"
        static let sensorsPaused = "ductor.sensorsPaused"
    }

    @Published var agents: [AgentProfile] {
        didSet { saveAgents() }
    }
    @Published var selectedAgentID: UUID? {
        didSet {
            if let id = selectedAgentID {
                defaults.set(id.uuidString, forKey: Key.selectedAgentID)
            } else {
                defaults.removeObject(forKey: Key.selectedAgentID)
            }
        }
    }
    /// Path to the user's Ductor home directory (the one containing
    /// `agents.json`). Picked up by the wizard and persisted for re-entry.
    @Published var ductorHomePath: String {
        didSet { defaults.set(ductorHomePath, forKey: Key.ductorHomePath) }
    }
    @Published var bridgePort: Int {
        didSet { defaults.set(bridgePort, forKey: Key.bridgePort) }
    }
    @Published var petVisible: Bool {
        didSet { defaults.set(petVisible, forKey: Key.petVisible) }
    }
    @Published var sensorsPaused: Bool {
        didSet { defaults.set(sensorsPaused, forKey: Key.sensorsPaused) }
    }

    private init() {
        defaults.register(defaults: [
            Key.ductorHomePath: "",
            Key.bridgePort: 0,
            Key.petVisible: true,
            Key.sensorsPaused: false,
        ])

        let loaded: [AgentProfile] = {
            guard let data = defaults.data(forKey: Key.agents),
                  let arr = try? JSONDecoder().decode([AgentProfile].self, from: data)
            else { return [] }
            return arr
        }()
        self.agents = loaded

        if let raw = defaults.string(forKey: Key.selectedAgentID),
           let uuid = UUID(uuidString: raw),
           loaded.contains(where: { $0.id == uuid }) {
            self.selectedAgentID = uuid
        } else {
            self.selectedAgentID = loaded.first?.id
        }

        self.ductorHomePath = defaults.string(forKey: Key.ductorHomePath) ?? ""
        self.bridgePort = defaults.integer(forKey: Key.bridgePort)
        self.petVisible = defaults.bool(forKey: Key.petVisible)
        self.sensorsPaused = defaults.bool(forKey: Key.sensorsPaused)
    }

    // MARK: - Agents CRUD

    var selectedAgent: AgentProfile? {
        guard let id = selectedAgentID else { return nil }
        return agents.first(where: { $0.id == id })
    }

    func addAgent(_ profile: AgentProfile, makeSelected: Bool = true) {
        agents.append(profile)
        if makeSelected { selectedAgentID = profile.id }
    }

    func removeAgent(id: UUID) {
        agents.removeAll(where: { $0.id == id })
        if selectedAgentID == id {
            selectedAgentID = agents.first?.id
        }
    }

    func updateAgent(_ profile: AgentProfile) {
        if let idx = agents.firstIndex(where: { $0.id == profile.id }) {
            agents[idx] = profile
        }
    }

    /// Apply a mutation closure to the currently-selected agent.
    func updateSelectedAgent(_ mutate: (inout AgentProfile) -> Void) {
        guard var profile = selectedAgent else { return }
        mutate(&profile)
        updateAgent(profile)
    }

    private func saveAgents() {
        if let data = try? JSONEncoder().encode(agents) {
            defaults.set(data, forKey: Key.agents)
        }
    }

    // MARK: - Telegram credentials (Keychain-backed)

    var telegramAPIID: String {
        get { Keychain.get(TelegramCredential.apiID.account) ?? "" }
        set { Keychain.set(newValue, account: TelegramCredential.apiID.account) }
    }
    var telegramAPIHash: String {
        get { Keychain.get(TelegramCredential.apiHash.account) ?? "" }
        set { Keychain.set(newValue, account: TelegramCredential.apiHash.account) }
    }
    var telegramPhone: String {
        get { Keychain.get(TelegramCredential.phone.account) ?? "" }
        set { Keychain.set(newValue, account: TelegramCredential.phone.account) }
    }

    var hasTelegramCredentials: Bool {
        !telegramAPIID.isEmpty && !telegramAPIHash.isEmpty && !telegramPhone.isEmpty
    }

    // MARK: - Pet window position

    var petPosition: CGPoint? {
        get {
            guard defaults.object(forKey: Key.petPositionX) != nil,
                  defaults.object(forKey: Key.petPositionY) != nil else {
                return nil
            }
            return CGPoint(
                x: defaults.double(forKey: Key.petPositionX),
                y: defaults.double(forKey: Key.petPositionY)
            )
        }
        set {
            if let p = newValue {
                defaults.set(p.x, forKey: Key.petPositionX)
                defaults.set(p.y, forKey: Key.petPositionY)
            } else {
                defaults.removeObject(forKey: Key.petPositionX)
                defaults.removeObject(forKey: Key.petPositionY)
            }
        }
    }

    // MARK: - Helpers

    // MARK: - Ductor home resolution

    /// Resolve a usable Ductor home URL by checking, in order:
    ///   1. The saved `ductorHomePath` (if it exists on disk).
    ///   2. The `DUCTOR_HOME` env var.
    ///   3. `~/.ductor/`.
    /// Returns nil if none of those directories contain `agents.json`.
    func resolveDuctorHome() -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []
        if !ductorHomePath.isEmpty {
            candidates.append(URL(fileURLWithPath: (ductorHomePath as NSString).expandingTildeInPath,
                                  isDirectory: true))
        }
        if let env = ProcessInfo.processInfo.environment["DUCTOR_HOME"], !env.isEmpty {
            candidates.append(URL(fileURLWithPath: (env as NSString).expandingTildeInPath,
                                  isDirectory: true))
        }
        candidates.append(fm.homeDirectoryForCurrentUser.appendingPathComponent(".ductor",
                                                                                isDirectory: true))
        for url in candidates {
            let agentsJSON = url.appendingPathComponent("agents.json")
            if fm.fileExists(atPath: agentsJSON.path) {
                return url
            }
        }
        return nil
    }

    /// Deep link into the active agent's Telegram chat.
    func telegramDeepLink() -> URL? {
        guard let agent = selectedAgent else { return nil }
        let trimmed = agent.botUsername.trimmingCharacters(in: CharacterSet(charactersIn: "@ "))
        guard !trimmed.isEmpty else { return nil }
        return URL(string: "tg://resolve?domain=\(trimmed)")
    }

    /// Convenience: build the JSON config blob the Python bridge consumes
    /// at launch time (via the `DUCTOR_AGENT_CONFIG_JSON` env var).
    func bridgeConfigJSON() -> String? {
        guard let agent = selectedAgent else { return nil }
        let blob: [String: Any] = [
            "agent_name": agent.name,
            "bot_username": agent.botUsername,
            "api_id": telegramAPIID,
            "api_hash": telegramAPIHash,
            "phone": telegramPhone,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: blob, options: []) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
