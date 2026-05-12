import SwiftUI
import AppKit

/// Drives the first-run Telegram login as a sheet over the setup wizard.
///
/// On appear it spawns `bridge --login-only` with the credentials in
/// env, reads the websocket port the bridge writes to JARVIS_PORT_FILE,
/// and follows the WS handshake:
///
///     bridge -> needs_sms_code      → show code field
///     swift  -> sms_code            (user-entered)
///     bridge -> needs_2fa_password  → show password field (optional)
///     swift  -> 2fa_password        (user-entered)
///     bridge -> login_complete      → dismiss + onComplete
///     bridge -> login_failed        → surface the reason
///
/// On success the Telethon StringSession is cached in Keychain by the
/// bridge, so the long-lived runtime bridge launched immediately after
/// the wizard finishes never has to prompt again.
struct TelegramLoginView: View {
    @StateObject private var coordinator: TelegramLoginCoordinator
    @State private var codeInput: String = ""
    @State private var passwordInput: String = ""

    let onComplete: () -> Void
    let onCancel: () -> Void

    init(agentSlug: String,
         phone: String,
         apiID: String,
         apiHash: String,
         onComplete: @escaping () -> Void,
         onCancel: @escaping () -> Void) {
        _coordinator = StateObject(wrappedValue: TelegramLoginCoordinator(
            agentSlug: agentSlug,
            phone: phone,
            apiID: apiID,
            apiHash: apiHash
        ))
        self.onComplete = onComplete
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Sign in to Telegram").font(.title2.bold())
            Text(coordinator.statusLine)
                .font(.callout)
                .foregroundStyle(.secondary)
            Divider()
            content
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            footer
        }
        .padding(20)
        .frame(width: 460, height: 280)
        .onAppear {
            coordinator.onComplete = onComplete
            coordinator.start()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch coordinator.phase {
        case .starting, .sendingCode:
            HStack {
                ProgressView().controlSize(.small)
                Text("Contacting Telegram…")
            }
        case .needsCode(let phone):
            VStack(alignment: .leading, spacing: 8) {
                Text("Telegram sent a code to \(phone). Enter it below.")
                TextField("e.g. 12345", text: $codeInput)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
                Button("Submit code") {
                    let code = codeInput.trimmingCharacters(in: .whitespaces)
                    guard !code.isEmpty else { return }
                    coordinator.submitCode(code)
                    codeInput = ""
                }
                .keyboardShortcut(.defaultAction)
                .disabled(codeInput.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        case .verifying:
            HStack {
                ProgressView().controlSize(.small)
                Text("Verifying code…")
            }
        case .needs2FA:
            VStack(alignment: .leading, spacing: 8) {
                Text("Two-factor authentication is enabled on this account. "
                     + "Enter your Telegram password.")
                SecureField("2FA password", text: $passwordInput)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                Button("Submit password") {
                    guard !passwordInput.isEmpty else { return }
                    coordinator.submit2FA(passwordInput)
                    passwordInput = ""
                }
                .keyboardShortcut(.defaultAction)
                .disabled(passwordInput.isEmpty)
            }
        case .verifying2FA:
            HStack {
                ProgressView().controlSize(.small)
                Text("Verifying 2FA password…")
            }
        case .complete:
            Label("Logged in. Finishing setup…",
                  systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let reason):
            VStack(alignment: .leading, spacing: 4) {
                Label("Login failed", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(reason).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Cancel", role: .cancel) {
                coordinator.cancel()
                onCancel()
            }
            Spacer()
        }
    }
}

/// Owns the bridge subprocess + websocket for the wizard's login flow.
/// Lives only for the duration of the login sheet — once the bridge
/// reports `login_complete` (or fails), this coordinator is discarded
/// and the long-lived runtime bridge is launched separately by
/// `DuctorAppController.start()`.
final class TelegramLoginCoordinator: NSObject, ObservableObject,
                                       URLSessionDelegate,
                                       URLSessionWebSocketDelegate {
    enum Phase: Equatable {
        case starting
        case sendingCode(phone: String)
        case needsCode(phone: String)
        case verifying
        case needs2FA
        case verifying2FA
        case complete
        case failed(String)
    }

    @Published var phase: Phase = .starting
    @Published var statusLine: String = "Launching bridge…"

    let agentSlug: String
    let phone: String
    let apiID: String
    let apiHash: String

    var onComplete: () -> Void = {}

    private var process: Process?
    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private let portFile: URL

    init(agentSlug: String, phone: String, apiID: String, apiHash: String) {
        self.agentSlug = agentSlug
        self.phone = phone
        self.apiID = apiID
        self.apiHash = apiHash
        self.portFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("ductor-companion.login.port")
        super.init()
        let cfg = URLSessionConfiguration.default
        self.session = URLSession(configuration: cfg,
                                  delegate: self,
                                  delegateQueue: nil)
    }

    func start() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.launchBridge()
        }
    }

    func cancel() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        process?.terminate()
        process = nil
    }

    func submitCode(_ code: String) {
        DispatchQueue.main.async { [weak self] in
            self?.phase = .verifying
            self?.statusLine = "Verifying code…"
        }
        send(["kind": "sms_code", "value": code])
    }

    func submit2FA(_ password: String) {
        DispatchQueue.main.async { [weak self] in
            self?.phase = .verifying2FA
            self?.statusLine = "Verifying 2FA password…"
        }
        send(["kind": "2fa_password", "value": password])
    }

    // MARK: - Subprocess

    private func launchBridge() {
        try? FileManager.default.removeItem(at: portFile)

        guard let proc = BridgeLauncher().makeProcess(extraArgs: ["--login-only"]) else {
            DispatchQueue.main.async { [weak self] in
                self?.phase = .failed("Bridge binary not found inside the app bundle.")
                self?.statusLine = "Bridge missing"
            }
            return
        }

        let cfg: [String: Any] = [
            "agent_name": agentSlug,
            "bot_username": "",
            "api_id": apiID,
            "api_hash": apiHash,
            "phone": phone,
        ]
        var env = ProcessInfo.processInfo.environment
        if let blob = try? JSONSerialization.data(withJSONObject: cfg),
           let str = String(data: blob, encoding: .utf8) {
            env["DUCTOR_AGENT_CONFIG_JSON"] = str
        }
        env["JARVIS_PORT_FILE"] = portFile.path
        proc.environment = env

        do {
            try proc.run()
            self.process = proc
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.phase = .failed("Failed to launch bridge: \(error.localizedDescription)")
                self?.statusLine = "Launch failed"
            }
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.statusLine = "Waiting for bridge to come up…"
        }

        // Poll the port file the bridge writes after binding.
        let deadline = Date().addingTimeInterval(10)
        var port: Int = 0
        while Date() < deadline {
            if let data = try? Data(contentsOf: portFile),
               let str = String(data: data, encoding: .utf8),
               let p = Int(str.trimmingCharacters(in: .whitespacesAndNewlines)),
               p > 0 {
                port = p
                break
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        if port == 0 {
            DispatchQueue.main.async { [weak self] in
                self?.phase = .failed("Bridge didn't announce a port within 10s.")
                self?.statusLine = "Bridge timed out"
            }
            process?.terminate()
            return
        }

        proc.terminationHandler = { [weak self] p in
            guard let self else { return }
            DispatchQueue.main.async {
                if self.phase != .complete {
                    self.phase = .failed(
                        "Bridge exited (code \(p.terminationStatus)) before login finished."
                    )
                    self.statusLine = "Bridge exited"
                }
            }
        }

        connectWebSocket(port: port)
    }

    // MARK: - WebSocket

    private func connectWebSocket(port: Int) {
        guard let url = URL(string: "ws://127.0.0.1:\(port)/") else { return }
        let t = session.webSocketTask(with: url)
        self.task = t
        t.resume()
        DispatchQueue.main.async { [weak self] in
            self?.statusLine = "Sending login request to Telegram…"
            self?.phase = .sendingCode(phone: self?.phone ?? "")
        }
        listen()
    }

    private func listen() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                self.handle(message)
                self.listen()
            case .failure(let error):
                DispatchQueue.main.async {
                    if self.phase != .complete {
                        self.phase = .failed(
                            "Bridge connection dropped: \(error.localizedDescription)"
                        )
                        self.statusLine = "Connection lost"
                    }
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let raw: Data?
        switch message {
        case .data(let d): raw = d
        case .string(let s): raw = s.data(using: .utf8)
        @unknown default: raw = nil
        }
        guard let data = raw,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kind = obj["kind"] as? String else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch kind {
            case "needs_sms_code":
                let phone = (obj["phone"] as? String) ?? self.phone
                self.phase = .needsCode(phone: phone)
                self.statusLine = "Telegram sent a code to \(phone)."
            case "needs_2fa_password":
                self.phase = .needs2FA
                self.statusLine = "Two-factor password required."
            case "login_complete":
                self.phase = .complete
                self.statusLine = "Logged in."
                self.task?.cancel(with: .goingAway, reason: nil)
                self.task = nil
                self.onComplete()
            case "login_failed":
                let reason = (obj["reason"] as? String) ?? "unknown"
                self.phase = .failed(reason)
                self.statusLine = "Login failed: \(reason)"
            default:
                break
            }
        }
    }

    private func send(_ payload: [String: Any]) {
        guard let task = task else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let str = String(data: data, encoding: .utf8) else { return }
        task.send(.string(str)) { error in
            if let error = error {
                NSLog("[ductor] login send failed: \(error.localizedDescription)")
            }
        }
    }
}
