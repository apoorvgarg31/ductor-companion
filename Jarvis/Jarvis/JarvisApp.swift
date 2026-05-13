import SwiftUI
import AppKit
import UserNotifications
import os.log

/// Resolves the bridge entry point (bundled Mach-O > dev venv > system
/// python3) and builds a Process ready to launch.
struct BridgeLauncher {
    let resources: URL?

    init(resources: URL? = Bundle.main.resourceURL) {
        self.resources = resources
    }

    var bundledBinary: URL? {
        guard let r = resources else { return nil }
        let url = r.appendingPathComponent("bridge_bundled/bridge_app/bridge")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    var venvPython: URL? {
        guard let r = resources else { return nil }
        let url = r.appendingPathComponent("bridge/.venv/bin/python3")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    var bridgeScript: URL? {
        guard let r = resources else { return nil }
        let url = r.appendingPathComponent("bridge/bridge.py")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func makeProcess(extraArgs: [String] = []) -> Process? {
        let proc = Process()
        if let bundled = bundledBinary {
            proc.executableURL = bundled
            proc.arguments = extraArgs
        } else if let venv = venvPython, let script = bridgeScript {
            proc.executableURL = venv
            proc.arguments = [script.path] + extraArgs
        } else if let script = bridgeScript {
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            proc.arguments = ["python3", script.path] + extraArgs
        } else {
            return nil
        }
        return proc
    }
}

@main
struct DuctorCompanionApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsView(controller: appDelegate.controller)
        }
    }
}

/// AppDelegate owns the long-lived controller and is responsible for
/// presenting the setup wizard on first launch (and any time the user
/// triggers "Add agent…" from the tray).
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var controller: DuctorAppController?
    private var wizardWindow: NSWindow?
    private var hotKey: GlobalHotKey?
    private var quickChat: QuickChatWindowController?
    private var shortcutObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let c = DuctorAppController()
        c.requestWizard = { [weak self] firstRun in
            self?.presentWizard(firstRun: firstRun)
        }
        self.controller = c

        // The quick-chat input is available regardless of wizard state —
        // it just no-ops until a bridge connection exists. Re-register
        // whenever the user changes the shortcut from Settings.
        let qc = QuickChatWindowController { [weak self] text in
            self?.controller?.sendQuickChat(text)
        }
        self.quickChat = qc
        installHotKey()
        shortcutObserver = NotificationCenter.default.addObserver(
            forName: .quickChatShortcutChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.installHotKey() }

        if Config.shared.selectedAgent == nil || !Config.shared.hasTelegramCredentials {
            presentWizard(firstRun: true)
        } else {
            c.start()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.stop()
        if let token = shortcutObserver {
            NotificationCenter.default.removeObserver(token)
        }
        hotKey = nil
    }

    private func installHotKey() {
        let shortcut = Config.shared.quickChatShortcut
        let carbonMods = GlobalHotKey.carbonModifiers(from: shortcut.modifiers)
        // Releasing the old binding before creating the new one — Carbon
        // refuses to register two hotkeys with overlapping signatures
        // until the previous EventHotKeyRef has been unregistered.
        self.hotKey = nil
        self.hotKey = GlobalHotKey(
            keyCode: UInt16(shortcut.keyCode),
            carbonModifiers: carbonMods
        ) { [weak self] in
            self?.quickChat?.toggle()
        }
    }

    // MARK: - Wizard

    func presentWizard(firstRun: Bool) {
        let wizard = SetupWizardView(
            firstRun: firstRun,
            onCancel: { [weak self] in
                self?.dismissWizard()
                if firstRun { NSApp.terminate(nil) }
            },
            onFinish: { [weak self] profile in
                Config.shared.addAgent(profile, makeSelected: true)
                self?.dismissWizard()
                self?.controller?.refreshForActiveAgent()
                self?.controller?.start()
                if firstRun { AppDelegate.notifyFirstLaunch() }
            }
        )
        let host = NSHostingController(rootView: wizard)
        let win = NSWindow(contentViewController: host)
        win.title = "Ductor Companion — Setup"
        win.styleMask = [.titled, .closable]
        win.setContentSize(NSSize(width: 580, height: 580))
        win.center()
        win.isReleasedWhenClosed = false
        wizardWindow = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func dismissWizard() {
        wizardWindow?.orderOut(nil)
        wizardWindow = nil
    }

    /// One-shot user notification pointing the user at the menu bar icon
    /// after they finish the setup wizard for the first time. The app is
    /// LSUIElement so there's otherwise no visible "we're running" cue.
    static func notifyFirstLaunch() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Ductor Companion is running"
            content.body = "Your pet sits at the bottom-right of the screen. "
                + "Click the menu bar icon for settings."
            let req = UNNotificationRequest(identifier: "ductor.firstLaunch",
                                            content: content, trigger: nil)
            center.add(req)
        }
    }
}

/// Glue between the various pieces (pet window, tray, services, bridge).
/// Rebuilds the pet window + sensors whenever the active agent changes.
final class DuctorAppController: NSObject {

    private var atlas: SpriteAtlas
    private var petWindow: PetWindowController
    private let tray = TrayMenu()
    private let bridge = BridgeClient()
    private let screenshots = ScreenshotService()
    private let heartbeat = HeartbeatService()
    private var bridgeProcess: Process?
    private var bridgeStderrPipe: Pipe?
    private var bridgeStdoutPipe: Pipe?
    private var bridgeStderrBuffer = Data()
    private var bridgeStdoutBuffer = Data()
    private var settingsWindow: NSWindow?
    private(set) var bridgeStatus: String = "starting…"

    var requestWizard: ((Bool) -> Void)?

    override init() {
        let atlas = SpriteAtlas.load(
            customSpritePath: Config.shared.selectedAgent?.spritePath
        )
        self.atlas = atlas

        var openTelegramRef: () -> Void = {}
        self.petWindow = PetWindowController(atlas: atlas, onPetClick: { openTelegramRef() })

        super.init()
        openTelegramRef = { [weak self] in self?.openTelegramChat() }
        tray.controller = self
    }

    func start() {
        guard Config.shared.selectedAgent != nil else {
            bridgeStatus = "no agent configured"
            return
        }

        if Config.shared.petVisible {
            petWindow.showWindow(nil)
        }

        wireBridge()
        wireSensors()

        let port = launchBridgeProcess()
        Config.shared.bridgePort = port
        bridge.start(port: port)
        screenshots.start()
        heartbeat.start()
        tray.rebuild()
    }

    func stop() {
        petWindow.window.flatMap { ($0 as? PetWindow)?.persistPosition() }
        screenshots.stop()
        heartbeat.stop()
        bridge.stop()
        bridgeStderrPipe?.fileHandleForReading.readabilityHandler = nil
        bridgeStdoutPipe?.fileHandleForReading.readabilityHandler = nil
        bridgeStderrPipe = nil
        bridgeStdoutPipe = nil
        bridgeProcess?.terminate()
        bridgeProcess = nil
    }

    /// Tear down and rebuild everything that depends on the active agent.
    func refreshForActiveAgent() {
        stop()
        guard let agent = Config.shared.selectedAgent else { return }

        // Reload the atlas + pet window for the new sprite path.
        let newAtlas = SpriteAtlas.load(customSpritePath: agent.spritePath)
        self.atlas = newAtlas

        var openTelegramRef: () -> Void = {}
        let newWindow = PetWindowController(atlas: newAtlas,
                                            onPetClick: { openTelegramRef() })
        openTelegramRef = { [weak self] in self?.openTelegramChat() }

        if let oldWindow = petWindow.window { oldWindow.orderOut(nil) }
        self.petWindow = newWindow
    }

    // MARK: - Wiring

    private func wireBridge() {
        bridge.onMessage = { [weak self] message in
            guard let self else { return }
            guard message.kind == "jarvis_message" else { return }
            let text = message.text ?? ""
            self.petWindow.showBubble(
                text: text,
                hasMedia: message.hasMedia ?? false,
                mediaCaption: message.mediaCaption
            )
        }
        bridge.onStateChange = { [weak self] connected in
            self?.bridgeStatus = connected ? "connected" : "disconnected"
        }
    }

    private func wireSensors() {
        guard let agent = Config.shared.selectedAgent else { return }
        bridge.agentSlug = agent.name
        screenshots.configure(
            enabled: agent.screenshotsEnabled,
            interval: agent.screenshotInterval,
            agent: agent.name,
            isQuiet: { agent.isQuietHour }
        )
        heartbeat.configure(
            interval: agent.heartbeatInterval,
            agent: agent.name,
            isQuiet: { agent.isQuietHour }
        )
        heartbeat.onHeartbeat = { [weak self] data in
            self?.bridge.sendHeartbeat(data)
        }
        screenshots.captionProvider = { [weak self] in
            guard let snap = self?.heartbeat.snapshot() else { return "[screenshot]" }
            let app = snap["frontmost_app"] as? String ?? "?"
            let title = (snap["window_title"] as? String) ?? ""
            let idle = snap["idle_seconds"] as? Double ?? 0
            return String(format: "[screenshot] frontmost=%@ title='%@' idle=%.0fs",
                          app, title, idle)
        }
        screenshots.onCapture = { [weak self] b64, caption in
            self?.bridge.sendScreenshot(pngBase64: b64, caption: caption)
        }
    }

    // MARK: - Bridge subprocess

    private func launchBridgeProcess() -> Int {
        let agent = Config.shared.selectedAgent?.name ?? Trace.unknownAgent
        let portFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("ductor-companion.port")
        try? FileManager.default.removeItem(at: portFile)

        guard let proc = BridgeLauncher().makeProcess() else {
            Trace.log(Trace.bridge, .error, agent: agent,
                      "no bridge launcher found "
                      + "(neither bridge_bundled/ nor bridge/bridge.py)")
            return 0
        }

        var env = ProcessInfo.processInfo.environment
        if let blob = Config.shared.bridgeConfigJSON() {
            env["DUCTOR_AGENT_CONFIG_JSON"] = blob
        }
        env["JARVIS_PORT_FILE"] = portFile.path
        // Tell Python to flush stdout/stderr immediately so the lines we
        // pipe to os_log show up in Console.app in real time.
        env["PYTHONUNBUFFERED"] = "1"
        proc.environment = env

        attachOutputPipes(to: proc, agent: agent)

        do {
            try proc.run()
            self.bridgeProcess = proc
            Trace.log(Trace.bridge, agent: agent,
                      "subprocess launched pid=\(proc.processIdentifier) "
                      + "exe=\(proc.executableURL?.lastPathComponent ?? "?")")
        } catch {
            Trace.log(Trace.bridge, .error, agent: agent,
                      "failed to launch bridge: \(error.localizedDescription)")
            return 0
        }

        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if let data = try? Data(contentsOf: portFile),
               let str = String(data: data, encoding: .utf8),
               let port = Int(str.trimmingCharacters(in: .whitespacesAndNewlines)),
               port > 0 {
                Trace.log(Trace.bridge, agent: agent,
                          "subprocess announced port=\(port)")
                return port
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        Trace.log(Trace.bridge, .error, agent: agent,
                  "bridge did not announce a port within 8s — outbound will be dropped")
        return 0
    }

    /// Pipe the bridge subprocess's stdout/stderr to the `bridge-py`
    /// os_log category so Python-side errors show up in Console.app under
    /// the same subsystem as the Swift traces. Previously these streams
    /// inherited the launching process's tty, which means they were
    /// silently swallowed for a `.app` launched from Finder.
    private func attachOutputPipes(to proc: Process, agent: String) {
        let errPipe = Pipe()
        let outPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = outPipe
        bridgeStderrPipe = errPipe
        bridgeStdoutPipe = outPipe
        bridgeStderrBuffer.removeAll()
        bridgeStdoutBuffer.removeAll()

        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            self?.consumeBridgeOutput(chunk, isStderr: true, agent: agent)
        }
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            self?.consumeBridgeOutput(chunk, isStderr: false, agent: agent)
        }
    }

    private func consumeBridgeOutput(_ chunk: Data, isStderr: Bool, agent: String) {
        // Split on newlines without losing partial trailing lines between
        // reads — handlers fire whenever the pipe has data, often mid-line.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if isStderr {
                self.bridgeStderrBuffer.append(chunk)
                self.flushLines(buffer: &self.bridgeStderrBuffer,
                                stream: "stderr", agent: agent)
            } else {
                self.bridgeStdoutBuffer.append(chunk)
                self.flushLines(buffer: &self.bridgeStdoutBuffer,
                                stream: "stdout", agent: agent)
            }
        }
    }

    private func flushLines(buffer: inout Data, stream: String, agent: String) {
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            let line = String(data: lineData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if line.isEmpty { continue }
            let level: OSLogType = stream == "stderr" ? .info : .info
            Trace.log(Trace.bridgePy, level, agent: agent,
                      "\(stream): \(line)")
        }
    }

    // MARK: - Actions

    func openTelegramChat() {
        if let url = Config.shared.telegramDeepLink() {
            NSWorkspace.shared.open(url)
        }
    }

    /// Send a one-shot message from the global quick-chat window. Replies
    /// arrive via the regular Telegram → bridge → speech-bubble path, so
    /// there's no separate response UI to wire up.
    func sendQuickChat(_ text: String) {
        bridge.sendText(text)
    }

    func toggleVisibility() {
        Config.shared.petVisible.toggle()
        if Config.shared.petVisible {
            petWindow.showWindow(nil)
        } else {
            petWindow.window?.orderOut(nil)
        }
    }

    func toggleSensorsPaused() {
        Config.shared.sensorsPaused.toggle()
        if Config.shared.sensorsPaused {
            screenshots.stop(); heartbeat.stop()
        } else {
            screenshots.start(); heartbeat.start()
        }
    }

    func switchAgent(id: UUID) {
        Config.shared.selectedAgentID = id
        refreshForActiveAgent()
        start()
    }

    func presentSetupWizard() {
        requestWizard?(false)
    }

    func openSettings() {
        if let win = settingsWindow {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = SettingsView(controller: self)
        let host = NSHostingController(rootView: view)
        let win = NSWindow(contentViewController: host)
        win.title = "Ductor Companion — Settings"
        win.styleMask = [.titled, .closable]
        win.setContentSize(NSSize(width: 540, height: 580))
        win.center()
        settingsWindow = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
