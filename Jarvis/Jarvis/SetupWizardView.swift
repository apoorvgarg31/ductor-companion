import SwiftUI
import AppKit

/// 3-step modal wizard shown on first launch (and any time the user picks
/// "Add agent…" from the tray). Drives the user through:
///
///   1. Telegram API credentials (phone, api_id, api_hash) — written to Keychain.
///   2. Bot connection — paste an existing agent's username and test it,
///      OR open the Ductor "main bot" chat to spawn a new sub-agent and
///      paste the new bot's username back in.
///   3. Agent details — slug, display name, sprite path, intervals,
///      quiet hours — then persist the AgentProfile.
///
/// On `Cancel` from anywhere, the wizard reports cancellation via
/// `onCancel` (the host typically terminates the app on first run, or
/// just dismisses the sheet for subsequent invocations).
struct SetupWizardView: View {
    enum Step: Int, CaseIterable { case credentials, connect, details }

    @ObservedObject private var config = Config.shared
    @State private var step: Step = .credentials

    // Step 1 fields
    @State private var phone: String = Config.shared.telegramPhone
    @State private var apiID: String = Config.shared.telegramAPIID
    @State private var apiHash: String = Config.shared.telegramAPIHash
    @State private var step1Error: String?

    // Step 2 fields
    @State private var botUsername: String = ""
    @State private var mainBotInput: String = Config.shared.ductorMainBotUsername
    @State private var testStatus: TestStatus = .idle
    @State private var creatingNew: Bool = false

    // Step 3 fields
    @State private var slug: String = ""
    @State private var displayName: String = ""
    @State private var spritePath: String = ""
    @State private var heartbeatMinutes: Double = 2
    @State private var screenshotMinutes: Double = 5
    @State private var screenshotsEnabled: Bool = false
    @State private var quietStart: Int = 22
    @State private var quietEnd: Int = 8

    var onCancel: () -> Void = {}
    var onFinish: (AgentProfile) -> Void = { _ in }
    var bridgeRunner: BridgeDryRunRunner = .systemPython

    enum TestStatus: Equatable {
        case idle, running, ok(String), failed(String)
    }

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
        .frame(width: 560, height: 540)
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(headerTitle)
                .font(.title2.bold())
            Text(headerSubtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.rawValue) { s in
                    Circle()
                        .fill(s.rawValue <= step.rawValue ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(width: 8, height: 8)
                }
            }
            .padding(.top, 4)
        }
    }

    private var headerTitle: String {
        switch step {
        case .credentials: return "1. Telegram credentials"
        case .connect: return "2. Connect a Ductor agent"
        case .details: return "3. Name the agent"
        }
    }
    private var headerSubtitle: String {
        switch step {
        case .credentials:
            return "Ductor Companion logs into Telegram as your user account, "
            + "not a bot, so it can listen to bot chats."
        case .connect:
            return "Tell us which Telegram bot represents this agent. "
            + "You can paste an existing username, or open the Ductor main "
            + "chat to spin up a new sub-agent."
        case .details:
            return "Final details. You can change all of these later in Settings."
        }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .credentials: stepCredentials
        case .connect: stepConnect
        case .details: stepDetails
        }
    }

    private var footer: some View {
        HStack {
            Button("Cancel", role: .cancel) { onCancel() }
            Spacer()
            if step != .credentials {
                Button("Back") { goBack() }
            }
            Button(step == .details ? "Finish" : "Next") { advance() }
                .keyboardShortcut(.defaultAction)
                .disabled(!canAdvance)
        }
    }

    // MARK: - Step 1

    private var stepCredentials: some View {
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
            if let err = step1Error {
                Text(err).font(.footnote).foregroundStyle(.red)
            }
        }
    }

    // MARK: - Step 2

    private var stepConnect: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("", selection: $creatingNew) {
                Text("I have a bot username").tag(false)
                Text("Spin up a new agent in Ductor").tag(true)
            }
            .pickerStyle(.segmented)

            if creatingNew {
                VStack(alignment: .leading, spacing: 8) {
                    Text("First, the Ductor main bot username (the bot that "
                         + "creates sub-agents for you):")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    TextField("e.g. ductor_main_bot", text: $mainBotInput)
                        .textFieldStyle(.roundedBorder)
                    Button("Open Ductor main chat") {
                        let trimmed = mainBotInput.trimmingCharacters(in: CharacterSet(charactersIn: "@ "))
                        guard !trimmed.isEmpty else { return }
                        config.ductorMainBotUsername = trimmed
                        if let url = URL(string: "tg://resolve?domain=\(trimmed)") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .disabled(mainBotInput.trimmingCharacters(in: .whitespaces).isEmpty)

                    Divider().padding(.vertical, 4)

                    Text("Once Ductor has minted the new sub-agent, paste its "
                         + "bot username here:")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                TextField("bot username (e.g. jarvis_apoorv_bot)", text: $botUsername)
                    .textFieldStyle(.roundedBorder)
                Button("Test") { runTest() }
                    .disabled(botUsername.trimmingCharacters(in: .whitespaces).isEmpty
                              || testStatus == .running)
            }

            switch testStatus {
            case .idle:
                EmptyView()
            case .running:
                ProgressView("Connecting to Telegram…").controlSize(.small)
            case .ok(let msg):
                Label(msg, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.footnote)
            case .failed(let msg):
                Label(msg, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.footnote)
            }
        }
    }

    // MARK: - Step 3

    private var stepDetails: some View {
        Form {
            TextField("Slug (used for paths)", text: $slug)
                .textFieldStyle(.roundedBorder)
            TextField("Display name", text: $displayName)
                .textFieldStyle(.roundedBorder)
            TextField("Sprite path", text: $spritePath)
                .textFieldStyle(.roundedBorder)
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

    // MARK: - Step transitions

    private var canAdvance: Bool {
        switch step {
        case .credentials:
            return !phone.trimmingCharacters(in: .whitespaces).isEmpty
                && Int(apiID.trimmingCharacters(in: .whitespaces)) != nil
                && !apiHash.trimmingCharacters(in: .whitespaces).isEmpty
        case .connect:
            return !botUsername.trimmingCharacters(in: .whitespaces).isEmpty
        case .details:
            return !slug.trimmingCharacters(in: .whitespaces).isEmpty
                && !displayName.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private func advance() {
        switch step {
        case .credentials:
            guard Int(apiID.trimmingCharacters(in: .whitespaces)) != nil else {
                step1Error = "API id must be a number."
                return
            }
            config.telegramPhone = phone.trimmingCharacters(in: .whitespaces)
            config.telegramAPIID = apiID.trimmingCharacters(in: .whitespaces)
            config.telegramAPIHash = apiHash.trimmingCharacters(in: .whitespaces)
            step1Error = nil
            step = .connect
        case .connect:
            // Pre-fill step 3 from the username.
            let trimmed = botUsername.trimmingCharacters(in: CharacterSet(charactersIn: "@ "))
            let derived = AgentProfile.deriveSlug(from: trimmed)
            slug = derived
            displayName = derived.prefix(1).uppercased() + derived.dropFirst()
            spritePath = AgentProfile.defaultSpritePath(forName: derived)
            step = .details
        case .details:
            let profile = AgentProfile(
                name: slug,
                displayName: displayName,
                botUsername: botUsername.trimmingCharacters(in: CharacterSet(charactersIn: "@ ")),
                spritePath: spritePath,
                screenshotInterval: screenshotMinutes * 60,
                heartbeatInterval: heartbeatMinutes * 60,
                screenshotsEnabled: screenshotsEnabled,
                quietHoursStart: quietStart,
                quietHoursEnd: quietEnd
            )
            onFinish(profile)
        }
    }

    private func goBack() {
        guard let prev = Step(rawValue: step.rawValue - 1) else { return }
        step = prev
    }

    // MARK: - Dry-run test

    private func runTest() {
        let bot = botUsername.trimmingCharacters(in: CharacterSet(charactersIn: "@ "))
        guard !bot.isEmpty else { return }
        testStatus = .running

        let payload: [String: Any] = [
            "agent_name": AgentProfile.deriveSlug(from: bot),
            "bot_username": bot,
            "api_id": apiID.trimmingCharacters(in: .whitespaces),
            "api_hash": apiHash.trimmingCharacters(in: .whitespaces),
            "phone": phone.trimmingCharacters(in: .whitespaces),
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let jsonStr = String(data: json, encoding: .utf8) else {
            testStatus = .failed("Could not encode config")
            return
        }

        bridgeRunner.run(configJSON: jsonStr) { result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    testStatus = .ok("Connected. The bot is reachable.")
                case .needsInteractiveLogin:
                    testStatus = .failed("Telegram session not yet authorized — "
                                         + "run the bridge once from a terminal "
                                         + "to enter the SMS code, then try again.")
                case .failure(let msg):
                    testStatus = .failed(msg)
                }
            }
        }
    }
}

// MARK: - Bridge dry-run runner

/// Wraps the subprocess invocation for the bridge's `--dry-run` mode so
/// the wizard view can stay focused on UI. The default runner shells out
/// to `python3 <bundle>/Resources/bridge/bridge.py --dry-run`.
struct BridgeDryRunRunner {
    enum Outcome {
        case success
        case needsInteractiveLogin
        case failure(String)
    }

    var run: (String, @escaping (Outcome) -> Void) -> Void

    static let systemPython = BridgeDryRunRunner { configJSON, completion in
        DispatchQueue.global(qos: .userInitiated).async {
            guard let bridgeURL = Bundle.main.resourceURL?
                .appendingPathComponent("bridge")
                .appendingPathComponent("bridge.py"),
                  FileManager.default.fileExists(atPath: bridgeURL.path)
            else {
                completion(.failure("Could not find bridge.py in bundle."))
                return
            }

            let proc = Process()
            let venvPython = Bundle.main.resourceURL?
                .appendingPathComponent("bridge/.venv/bin/python3")
            if let v = venvPython, FileManager.default.fileExists(atPath: v.path) {
                proc.executableURL = v
                proc.arguments = [bridgeURL.path, "--dry-run"]
            } else {
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                proc.arguments = ["python3", bridgeURL.path, "--dry-run"]
            }

            var env = ProcessInfo.processInfo.environment
            env["DUCTOR_AGENT_CONFIG_JSON"] = configJSON
            proc.environment = env

            let pipe = Pipe()
            proc.standardError = pipe
            proc.standardOutput = pipe
            // The bridge will try input() if not yet authorized — close stdin
            // so it fails fast instead of hanging.
            proc.standardInput = FileHandle.nullDevice

            do {
                try proc.run()
            } catch {
                completion(.failure("Could not launch bridge: \(error.localizedDescription)"))
                return
            }
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let log = String(data: data, encoding: .utf8) ?? ""
            switch proc.terminationStatus {
            case 0:
                completion(.success)
            case 2, 3:
                if log.contains("send_code_request") || log.contains("not authorized") {
                    completion(.needsInteractiveLogin)
                } else {
                    completion(.failure(log.isEmpty ? "Bridge returned \(proc.terminationStatus)." : log))
                }
            default:
                completion(.failure(log.isEmpty ? "Bridge returned \(proc.terminationStatus)." : log))
            }
        }
    }
}
