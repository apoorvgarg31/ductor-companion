import SwiftUI
import AppKit

/// Five-step setup sheet.
///
///   1. Locate Ductor — find `<DUCTOR_HOME>/agents.json`.
///   2. Pick existing agent OR create a new one.
///   3. New-agent form — written natively to `agents.json` so the
///      Ductor AgentSupervisor picks it up via its file watcher.
///   4. Sprite / intervals / quiet hours for the chosen agent.
///   5. Telegram user-account credentials for the Telethon bridge
///      (skipped if already in Keychain).
///
/// When the user re-enters from the tray ("Add agent…") the wizard
/// starts at step 2 — Ductor is already detected and credentials are
/// almost always already cached.
struct SetupWizardView: View {
    enum Step: Int, CaseIterable {
        case locateDuctor
        case pickAgent
        case createAgent
        case agentDetails
        case telegramCreds
    }

    @ObservedObject private var config = Config.shared
    @State private var step: Step
    private let firstRun: Bool

    // Step 1 — Ductor detection
    @State private var ductorHome: URL?
    @State private var manualHomeError: String?

    // Step 2 — Agent list
    @State private var registry: [DuctorAgent] = []
    @State private var loadError: String?
    @State private var selection: Selection = .none

    // Step 3 — Create new agent form
    @State private var newSlug: String = ""
    @State private var newDescription: String = ""
    @State private var newProvider: String = "claude"
    @State private var newModel: String = "sonnet"
    @State private var newToken: String = ""
    @State private var newUserIDs: String = ""
    @State private var createState: CreateState = .idle

    // Step 4 — Sprite/intervals
    @State private var slug: String = ""
    @State private var displayName: String = ""
    @State private var spritePath: String = ""
    @State private var heartbeatMinutes: Double = 2
    @State private var screenshotMinutes: Double = 5
    @State private var screenshotsEnabled: Bool = false
    @State private var quietStart: Int = 22
    @State private var quietEnd: Int = 8

    // Step 5 — Telegram credentials
    @State private var phone: String = Config.shared.telegramPhone
    @State private var apiID: String = Config.shared.telegramAPIID
    @State private var apiHash: String = Config.shared.telegramAPIHash
    @State private var credsError: String?
    @State private var showLoginSheet: Bool = false

    var onCancel: () -> Void = {}
    var onFinish: (AgentProfile) -> Void = { _ in }

    enum Selection: Equatable {
        case none
        case existing(String) // agent name
        case createNew
    }

    enum CreateState: Equatable {
        case idle
        case validating(String)
        case writing
        case waitingForSupervisor
        case ready
        case failed(String)
    }

    init(firstRun: Bool = true,
         onCancel: @escaping () -> Void = {},
         onFinish: @escaping (AgentProfile) -> Void = { _ in }) {
        self.firstRun = firstRun
        self.onCancel = onCancel
        self.onFinish = onFinish
        _step = State(initialValue: firstRun ? .locateDuctor : .pickAgent)
    }

    // MARK: - Layout

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            footer
        }
        .padding(20)
        .frame(width: 580, height: 580)
        .onAppear { onAppear() }
        .sheet(isPresented: $showLoginSheet) {
            TelegramLoginView(
                agentSlug: slug.isEmpty ? "default" : slug,
                phone: phone.trimmingCharacters(in: .whitespaces),
                apiID: apiID.trimmingCharacters(in: .whitespaces),
                apiHash: apiHash.trimmingCharacters(in: .whitespaces),
                onComplete: {
                    showLoginSheet = false
                    let profile = pendingProfile ?? makeProfile()
                    onFinish(profile)
                },
                onCancel: {
                    showLoginSheet = false
                }
            )
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(headerTitle).font(.title2.bold())
            Text(headerSubtitle).font(.callout).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach(visibleSteps, id: \.rawValue) { s in
                    Circle()
                        .fill(s.rawValue <= step.rawValue
                              ? Color.accentColor
                              : Color.secondary.opacity(0.25))
                        .frame(width: 8, height: 8)
                }
            }
            .padding(.top, 4)
        }
    }

    private var headerTitle: String {
        switch step {
        case .locateDuctor: return "1. Locate Ductor"
        case .pickAgent: return "2. Pick a Ductor agent"
        case .createAgent: return "3. Create a new agent"
        case .agentDetails: return "4. Pet details"
        case .telegramCreds: return "5. Telegram credentials"
        }
    }

    private var headerSubtitle: String {
        switch step {
        case .locateDuctor:
            return "Ductor stores its sub-agents in agents.json. The Companion "
            + "talks to that file directly — no separate bot scripting needed."
        case .pickAgent:
            return "Choose an existing agent for the pet to represent, or "
            + "spin up a brand-new one. New agents auto-start within a few "
            + "seconds once written to agents.json."
        case .createAgent:
            return "These fields are written natively into agents.json. The "
            + "Ductor AgentSupervisor file-watches that file and boots the "
            + "agent for you."
        case .agentDetails:
            return "How the pet looks and how often it pings. All editable "
            + "later in Settings."
        case .telegramCreds:
            return "The bridge logs in as your Telegram **user** so it can "
            + "watch bot chats. Get a free api_id / api_hash from "
            + "my.telegram.org/apps."
        }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .locateDuctor: stepLocate
        case .pickAgent: stepPick
        case .createAgent: stepCreate
        case .agentDetails: stepDetails
        case .telegramCreds: stepCreds
        }
    }

    private var footer: some View {
        HStack {
            Button("Cancel", role: .cancel) { onCancel() }
            Spacer()
            if step != firstStep {
                Button("Back") { goBack() }
                    .disabled(!canGoBack)
            }
            Button(advanceButtonLabel) { advance() }
                .keyboardShortcut(.defaultAction)
                .disabled(!canAdvance)
        }
    }

    private var firstStep: Step { firstRun ? .locateDuctor : .pickAgent }

    private var visibleSteps: [Step] {
        // The progress dots reflect the flow length the user will see.
        var s: [Step] = firstRun ? [.locateDuctor, .pickAgent] : [.pickAgent]
        if selection == .createNew { s.append(.createAgent) }
        s.append(.agentDetails)
        if !config.hasTelegramCredentials { s.append(.telegramCreds) }
        return s
    }

    private var advanceButtonLabel: String {
        if step == .telegramCreds { return "Finish" }
        if step == .agentDetails && config.hasTelegramCredentials { return "Finish" }
        if step == .createAgent { return "Create & continue" }
        return "Next"
    }

    private func onAppear() {
        if firstRun || ductorHome == nil {
            detectDuctor()
        }
        // Pre-load registry when we land on step 2.
        if step == .pickAgent { loadRegistry() }
    }

    // MARK: - Step 1 — locate Ductor

    private var stepLocate: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let home = ductorHome {
                Label("Ductor detected at \(home.path)",
                      systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("agents.json: \(home.appendingPathComponent("agents.json").path)")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                Label("Ductor is not installed on this Mac",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Ductor is the local agent orchestrator that the Companion "
                     + "talks to. Install it, or point to a non-default location.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                HStack {
                    Link("View Ductor on GitHub",
                         destination: URL(string: "https://github.com/PleasePrompto/ductor")!)
                    Spacer()
                    Button("Choose Ductor home folder…") { pickHomeFolder() }
                    Button("I'll install it later") { onCancel() }
                }
                if let err = manualHomeError {
                    Text(err).font(.footnote).foregroundStyle(.red)
                }
            }
        }
    }

    private func detectDuctor() {
        if let url = config.resolveDuctorHome() {
            ductorHome = url
            if config.ductorHomePath.isEmpty {
                config.ductorHomePath = url.path
            }
        } else {
            ductorHome = nil
        }
    }

    private func pickHomeFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Pick the directory that contains agents.json (typically ~/.ductor)"
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            let target = url.appendingPathComponent("agents.json")
            if FileManager.default.fileExists(atPath: target.path) {
                config.ductorHomePath = url.path
                ductorHome = url
                manualHomeError = nil
            } else {
                manualHomeError = "agents.json not found in \(url.path)."
            }
        }
    }

    // MARK: - Step 2 — pick an agent

    private var stepPick: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let err = loadError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }

            List {
                ForEach(registry, id: \.name) { agent in
                    pickRow(
                        title: agent.name,
                        subtitle: agent.subtitle,
                        selected: selection == .existing(agent.name)
                    ) {
                        selection = .existing(agent.name)
                    }
                }
                pickRow(title: "Create new agent",
                        subtitle: "Writes a new entry into agents.json",
                        systemImage: "plus.circle",
                        selected: selection == .createNew) {
                    selection = .createNew
                }
            }
            .frame(minHeight: 260)
        }
    }

    @ViewBuilder
    private func pickRow(title: String,
                         subtitle: String,
                         systemImage: String = "person.crop.circle",
                         selected: Bool,
                         action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(selected ? Color.accentColor : .secondary)
            Image(systemName: systemImage).foregroundStyle(.secondary)
            VStack(alignment: .leading) {
                Text(title).font(.body)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
    }

    private func loadRegistry() {
        guard let home = ductorHome ?? config.resolveDuctorHome() else {
            loadError = "Ductor home not set."
            return
        }
        ductorHome = home
        do {
            registry = try DuctorRegistry.loadTelegramAgents(at: home)
            loadError = nil
        } catch {
            loadError = "Could not read agents.json: \(error.localizedDescription)"
            registry = []
        }
    }

    // MARK: - Step 3 — create a new agent

    private var stepCreate: some View {
        Form {
            Section("Identity") {
                TextField("Slug (lowercase, no spaces, not 'main')", text: $newSlug)
                Text("Description (saved to the agent's JOIN_NOTIFICATION.md)")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $newDescription)
                    .frame(height: 64)
                    .border(Color.secondary.opacity(0.2))
            }
            Section("Model") {
                Picker("Provider", selection: $newProvider) {
                    Text("Claude").tag("claude")
                    Text("OpenAI / Codex").tag("openai")
                    Text("Gemini").tag("gemini")
                }
                TextField(modelPlaceholder, text: $newModel)
            }
            Section("Telegram") {
                SecureField("BotFather token", text: $newToken)
                HStack {
                    Button("Open @BotFather") {
                        if let url = URL(string: "tg://resolve?domain=BotFather") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    Text("Run /newbot, copy the token.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                TextField("Allowed Telegram user IDs (comma-separated)", text: $newUserIDs)
                Text("Get your own ID by chatting with @userinfobot.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                switch createState {
                case .idle, .validating, .failed:
                    EmptyView()
                case .writing:
                    HStack { ProgressView().controlSize(.small); Text("Writing agents.json…") }
                case .waitingForSupervisor:
                    HStack { ProgressView().controlSize(.small); Text("Waiting for AgentSupervisor to start \(newSlug)…") }
                case .ready:
                    Label("Agent \(newSlug) is running.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                if case let .failed(msg) = createState {
                    Label(msg, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
                if case let .validating(msg) = createState {
                    Label(msg, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.footnote)
                }
            }
        }
    }

    private var modelPlaceholder: String {
        switch newProvider {
        case "claude": return "opus / sonnet / haiku"
        case "openai": return "gpt-5.3-codex / o4-mini / …"
        case "gemini": return "gemini-2.5-pro / …"
        default: return ""
        }
    }

    private func createAgentEntry(completion: @escaping (Bool) -> Void) {
        guard let home = ductorHome else {
            createState = .failed("Ductor home not set.")
            completion(false); return
        }
        // Inline validation
        let slug = newSlug.lowercased().trimmingCharacters(in: .whitespaces)
        if slug.isEmpty || slug.contains(" ") || slug == "main" {
            createState = .validating("Slug must be lowercase, no spaces, not 'main'.")
            completion(false); return
        }
        if newToken.trimmingCharacters(in: .whitespaces).isEmpty {
            createState = .validating("BotFather token is required.")
            completion(false); return
        }
        let ids: [Int]
        do {
            ids = try parseUserIDs(newUserIDs)
        } catch {
            createState = .validating(error.localizedDescription)
            completion(false); return
        }
        if ids.isEmpty {
            createState = .validating("At least one Telegram user ID is required.")
            completion(false); return
        }

        createState = .writing
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try DuctorRegistry.appendTelegramAgent(
                    home: home,
                    name: slug,
                    token: self.newToken.trimmingCharacters(in: .whitespaces),
                    allowedUserIDs: ids,
                    provider: self.newProvider,
                    model: self.newModel.trimmingCharacters(in: .whitespaces),
                    description: self.newDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            } catch {
                DispatchQueue.main.async {
                    createState = .failed("Write failed: \(error.localizedDescription)")
                    completion(false)
                }
                return
            }
            DispatchQueue.main.async { createState = .waitingForSupervisor }

            // Poll for the agent's workspace MAINMEMORY.md (up to 30 s).
            let marker = home.appendingPathComponent("agents/\(slug)/workspace/MAINMEMORY.md")
            let deadline = Date().addingTimeInterval(30)
            var supervisorStarted = false
            while Date() < deadline {
                if FileManager.default.fileExists(atPath: marker.path) {
                    supervisorStarted = true
                    break
                }
                Thread.sleep(forTimeInterval: 0.5)
            }
            DispatchQueue.main.async {
                if supervisorStarted {
                    createState = .ready
                } else {
                    createState = .failed("Supervisor didn't write MAINMEMORY.md within 30s. "
                                          + "Continuing anyway — it may still start.")
                }
                completion(true)
            }
        }
    }

    private func parseUserIDs(_ text: String) throws -> [Int] {
        var out: [Int] = []
        for token in text.split(separator: ",") {
            let trimmed = token.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            guard let n = Int(trimmed) else {
                throw NSError(domain: "wizard", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "User ID '\(trimmed)' is not a number."
                ])
            }
            out.append(n)
        }
        return out
    }

    // MARK: - Step 4 — pet details

    private var stepDetails: some View {
        Form {
            TextField("Slug (used for paths)", text: $slug)
            TextField("Display name", text: $displayName)
            TextField("Sprite path", text: $spritePath)
            Toggle("Periodic screenshots", isOn: $screenshotsEnabled)
            HStack {
                Text("Heartbeat every")
                Slider(value: $heartbeatMinutes, in: 1...30, step: 1)
                Text("\(Int(heartbeatMinutes)) min").frame(width: 60, alignment: .trailing)
            }
            HStack {
                Text("Screenshot every")
                Slider(value: $screenshotMinutes, in: 1...60, step: 1)
                Text("\(Int(screenshotMinutes)) min").frame(width: 60, alignment: .trailing)
            }
            HStack {
                Stepper(value: $quietStart, in: 0...23) { Text("Quiet from \(quietStart):00") }
                Spacer()
                Stepper(value: $quietEnd, in: 0...23) { Text("to \(quietEnd):00") }
            }
        }
    }

    // MARK: - Step 5 — Telegram user credentials

    private var stepCreds: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Phone (e.g. +15551234567)", text: $phone)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 10) {
                TextField("API id", text: $apiID)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 160)
                TextField("API hash", text: $apiHash)
                    .textFieldStyle(.roundedBorder)
            }
            Link("Get a free api_id / api_hash from my.telegram.org/apps →",
                 destination: URL(string: "https://my.telegram.org/apps")!)
                .font(.footnote)
            if let err = credsError {
                Text(err).font(.footnote).foregroundStyle(.red)
            }
        }
    }

    // MARK: - Step transitions

    private var canGoBack: Bool {
        if createState == .writing || createState == .waitingForSupervisor { return false }
        return step != firstStep
    }

    private var canAdvance: Bool {
        switch step {
        case .locateDuctor:
            return ductorHome != nil
        case .pickAgent:
            switch selection {
            case .none: return false
            default: return true
            }
        case .createAgent:
            return createState != .writing && createState != .waitingForSupervisor
        case .agentDetails:
            return !slug.trimmingCharacters(in: .whitespaces).isEmpty
                && !displayName.trimmingCharacters(in: .whitespaces).isEmpty
        case .telegramCreds:
            return !phone.trimmingCharacters(in: .whitespaces).isEmpty
                && Int(apiID.trimmingCharacters(in: .whitespaces)) != nil
                && !apiHash.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private func advance() {
        switch step {
        case .locateDuctor:
            step = .pickAgent
            loadRegistry()
        case .pickAgent:
            switch selection {
            case .existing(let name):
                primeDetailsFromExisting(name)
                step = .agentDetails
            case .createNew:
                step = .createAgent
            case .none:
                return
            }
        case .createAgent:
            // The "Next" button on this step kicks off the write if not yet done.
            switch createState {
            case .ready:
                primeDetailsFromCreated()
                step = .agentDetails
            case .idle, .failed, .validating:
                createAgentEntry { ok in
                    if ok {
                        primeDetailsFromCreated()
                        step = .agentDetails
                    }
                }
            default:
                return
            }
        case .agentDetails:
            let profile = makeProfile()
            if !config.hasTelegramCredentials {
                slug = profile.name
                step = .telegramCreds
                // Stash a pending profile for finishCreds() to retrieve.
                pendingProfile = profile
            } else {
                onFinish(profile)
            }
        case .telegramCreds:
            credsError = nil
            guard Int(apiID.trimmingCharacters(in: .whitespaces)) != nil else {
                credsError = "API id must be numeric."
                return
            }
            config.telegramPhone = phone.trimmingCharacters(in: .whitespaces)
            config.telegramAPIID = apiID.trimmingCharacters(in: .whitespaces)
            config.telegramAPIHash = apiHash.trimmingCharacters(in: .whitespaces)
            // Hand off to the in-app login sheet — it spawns the bridge
            // in --login-only mode, handles the SMS-code + 2FA prompts
            // over the websocket, and only then calls onFinish.
            showLoginSheet = true
        }
    }

    @State private var pendingProfile: AgentProfile?

    private func goBack() {
        let order: [Step] = visibleSteps
        guard let idx = order.firstIndex(of: step), idx > 0 else { return }
        step = order[idx - 1]
    }

    private func primeDetailsFromExisting(_ name: String) {
        slug = name
        displayName = name.prefix(1).uppercased() + name.dropFirst()
        spritePath = AgentProfile.defaultSpritePath(forName: name)
    }

    private func primeDetailsFromCreated() {
        let s = newSlug.lowercased().trimmingCharacters(in: .whitespaces)
        slug = s
        displayName = s.prefix(1).uppercased() + s.dropFirst()
        spritePath = AgentProfile.defaultSpritePath(forName: s)
    }

    private func makeProfile() -> AgentProfile {
        // Bot username: derive from BotFather token if creating, else leave
        // empty (the deep link is via tg://resolve?domain=<botUsername> and
        // can be filled in later from Settings if the user knows the @handle;
        // the bridge itself addresses the bot via the saved token on the
        // Ductor side, not via Telethon).
        AgentProfile(
            name: slug,
            displayName: displayName,
            botUsername: "",
            spritePath: spritePath,
            screenshotInterval: screenshotMinutes * 60,
            heartbeatInterval: heartbeatMinutes * 60,
            screenshotsEnabled: screenshotsEnabled,
            quietHoursStart: quietStart,
            quietHoursEnd: quietEnd
        )
    }
}

// MARK: - DuctorAgent + registry helpers

struct DuctorAgent: Equatable {
    let name: String
    let provider: String?
    let model: String?
    let transport: String          // "telegram" or "matrix"

    var subtitle: String {
        let p = provider ?? "(inherited)"
        let m = model ?? "(inherited)"
        return "\(transport) · \(p) / \(m)"
    }
}

/// Reads + writes Ductor's `agents.json`. Schema mirrors
/// `tools/agent_tools/create_agent.py` in the Ductor source.
enum DuctorRegistry {
    enum Error: Swift.Error, LocalizedError {
        case notFound(URL)
        case malformedJSON
        case duplicate(String)

        var errorDescription: String? {
            switch self {
            case .notFound(let url): return "No agents.json at \(url.path)"
            case .malformedJSON: return "agents.json could not be parsed."
            case .duplicate(let name): return "An agent named '\(name)' already exists."
            }
        }
    }

    static func agentsJSON(at home: URL) -> URL {
        home.appendingPathComponent("agents.json")
    }

    static func loadTelegramAgents(at home: URL) throws -> [DuctorAgent] {
        let url = agentsJSON(at: home)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw Error.notFound(url)
        }
        let data = try Data(contentsOf: url)
        guard let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw Error.malformedJSON
        }
        return arr.compactMap { dict in
            guard let name = dict["name"] as? String else { return nil }
            // Telegram entries omit `transport` (default). Matrix entries
            // set `transport: "matrix"` — those are out of scope.
            let transport = (dict["transport"] as? String) ?? "telegram"
            if transport != "telegram" { return nil }
            return DuctorAgent(
                name: name,
                provider: dict["provider"] as? String,
                model: dict["model"] as? String,
                transport: transport
            )
        }
    }

    /// Append a new Telegram-transport agent to agents.json, write the
    /// JOIN_NOTIFICATION.md, and fsync via atomic rename.
    static func appendTelegramAgent(
        home: URL,
        name: String,
        token: String,
        allowedUserIDs: [Int],
        provider: String?,
        model: String?,
        description: String?
    ) throws {
        let url = agentsJSON(at: home)
        var arr: [[String: Any]] = []
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            arr = (try JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
        }
        if arr.contains(where: { ($0["name"] as? String) == name }) {
            throw Error.duplicate(name)
        }

        var entry: [String: Any] = [
            "name": name,
            "telegram_token": token,
            "allowed_user_ids": allowedUserIDs,
        ]
        let normalizedProvider = (provider == "codex") ? "openai" : provider
        if let p = normalizedProvider, !p.isEmpty { entry["provider"] = p }
        if let m = model, !m.isEmpty { entry["model"] = m }
        arr.append(entry)

        let outData = try JSONSerialization.data(
            withJSONObject: arr,
            options: [.prettyPrinted, .withoutEscapingSlashes]
        )

        // Atomic write: tmpfile → rename.
        try FileManager.default.createDirectory(at: home,
                                                withIntermediateDirectories: true)
        let tmp = url.appendingPathExtension("tmp-\(UUID().uuidString)")
        try outData.write(to: tmp, options: [.atomic])
        // Add a trailing newline to match the Python tool's output.
        if let fh = try? FileHandle(forWritingTo: tmp) {
            try? fh.seekToEnd()
            try? fh.write(contentsOf: Data("\n".utf8))
            try? fh.close()
        }
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: url)
        }

        // JOIN_NOTIFICATION.md
        if let desc = description, !desc.isEmpty {
            let ws = home.appendingPathComponent("agents/\(name)/workspace",
                                                 isDirectory: true)
            try FileManager.default.createDirectory(at: ws,
                                                    withIntermediateDirectories: true)
            let notif = ws.appendingPathComponent("JOIN_NOTIFICATION.md")
            try (desc + "\n").write(to: notif, atomically: true, encoding: .utf8)
        }
    }
}
