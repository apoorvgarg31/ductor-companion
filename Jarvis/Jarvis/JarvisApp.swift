import SwiftUI
import AppKit

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

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let c = DuctorAppController()
        c.requestWizard = { [weak self] firstRun in
            self?.presentWizard(firstRun: firstRun)
        }
        self.controller = c

        if Config.shared.selectedAgent == nil || !Config.shared.hasTelegramCredentials {
            presentWizard(firstRun: true)
        } else {
            c.start()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.stop()
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
    private var settingsWindow: NSWindow?
    private(set) var bridgeStatus: String = "starting…"

    var requestWizard: ((Bool) -> Void)?

    override init() {
        let initialPath = Config.shared.selectedAgent?.spritePath
            ?? AgentProfile.defaultSpritePath(forName: "jarvis")
        let atlas = SpriteAtlas.load(spritePath: initialPath)
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
        bridgeProcess?.terminate()
        bridgeProcess = nil
    }

    /// Tear down and rebuild everything that depends on the active agent.
    func refreshForActiveAgent() {
        stop()
        guard let agent = Config.shared.selectedAgent else { return }

        // Reload the atlas + pet window for the new sprite path.
        let newAtlas = SpriteAtlas.load(spritePath: agent.spritePath)
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
        screenshots.configure(
            enabled: agent.screenshotsEnabled,
            interval: agent.screenshotInterval,
            isQuiet: { agent.isQuietHour }
        )
        heartbeat.configure(
            interval: agent.heartbeatInterval,
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
        let resources = Bundle.main.resourceURL?.appendingPathComponent("bridge")
        let bridgeScript = resources?.appendingPathComponent("bridge.py")
        let venvPython = resources?.appendingPathComponent(".venv/bin/python3")
        let portFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("ductor-companion.port")
        try? FileManager.default.removeItem(at: portFile)

        guard let script = bridgeScript, FileManager.default.fileExists(atPath: script.path) else {
            NSLog("[ductor] bridge.py not found in app Resources/")
            return 0
        }

        let proc = Process()
        if let venv = venvPython, FileManager.default.fileExists(atPath: venv.path) {
            proc.executableURL = venv
            proc.arguments = [script.path]
        } else {
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            proc.arguments = ["python3", script.path]
        }

        var env = ProcessInfo.processInfo.environment
        if let blob = Config.shared.bridgeConfigJSON() {
            env["DUCTOR_AGENT_CONFIG_JSON"] = blob
        }
        env["JARVIS_PORT_FILE"] = portFile.path
        proc.environment = env

        do {
            try proc.run()
            self.bridgeProcess = proc
        } catch {
            NSLog("[ductor] failed to launch bridge: \(error)")
            return 0
        }

        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if let data = try? Data(contentsOf: portFile),
               let str = String(data: data, encoding: .utf8),
               let port = Int(str.trimmingCharacters(in: .whitespacesAndNewlines)),
               port > 0 {
                return port
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        NSLog("[ductor] bridge did not announce a port within 8s")
        return 0
    }

    // MARK: - Actions

    func openTelegramChat() {
        if let url = Config.shared.telegramDeepLink() {
            NSWorkspace.shared.open(url)
        }
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
