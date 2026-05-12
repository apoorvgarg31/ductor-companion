import AppKit
import SwiftUI

/// NSStatusItem-based menu bar entry.
///
/// Top section: visibility, pause sensors. Middle: agent switcher
/// (one item per configured agent + "Add agent…"). Bottom: open
/// chat / settings / quit.
final class TrayMenu: NSObject {
    private let statusItem: NSStatusItem
    weak var controller: DuctorAppController?

    override init() {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "circle.hexagongrid.fill",
                                   accessibilityDescription: "Ductor Companion")
            button.image?.isTemplate = true
            button.toolTip = "Ductor Companion"
        }
        rebuild()
    }

    func rebuild() {
        let menu = NSMenu()
        let cfg = Config.shared

        if let active = cfg.selectedAgent {
            let header = NSMenuItem(title: "Active: \(active.displayName)",
                                    action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            menu.addItem(.separator())
        }

        let visibility = NSMenuItem(
            title: cfg.petVisible ? "Hide Pet" : "Show Pet",
            action: #selector(toggleVisibility(_:)),
            keyEquivalent: ""
        )
        visibility.target = self
        menu.addItem(visibility)

        let pause = NSMenuItem(
            title: cfg.sensorsPaused ? "Resume Sensors" : "Pause Sensors",
            action: #selector(togglePaused(_:)),
            keyEquivalent: ""
        )
        pause.target = self
        menu.addItem(pause)

        menu.addItem(.separator())

        // Agent switcher
        let agentsHeader = NSMenuItem(title: "Agents", action: nil, keyEquivalent: "")
        agentsHeader.isEnabled = false
        menu.addItem(agentsHeader)
        for agent in cfg.agents {
            let item = NSMenuItem(title: "  \(agent.displayName)",
                                  action: #selector(selectAgent(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = agent.id.uuidString
            item.state = (agent.id == cfg.selectedAgentID) ? .on : .off
            menu.addItem(item)
        }
        let addAgent = NSMenuItem(title: "  Add agent…",
                                  action: #selector(addAgent(_:)),
                                  keyEquivalent: "")
        addAgent.target = self
        menu.addItem(addAgent)

        menu.addItem(.separator())

        let openTG = NSMenuItem(title: "Open Telegram Chat",
                                action: #selector(openTelegram(_:)),
                                keyEquivalent: "t")
        openTG.target = self
        menu.addItem(openTG)

        let settings = NSMenuItem(title: "Settings…",
                                  action: #selector(openSettings(_:)),
                                  keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Ductor Companion",
                              action: #selector(quit(_:)),
                              keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    @objc private func toggleVisibility(_ sender: Any?) {
        controller?.toggleVisibility(); rebuild()
    }
    @objc private func togglePaused(_ sender: Any?) {
        controller?.toggleSensorsPaused(); rebuild()
    }
    @objc private func openTelegram(_ sender: Any?) {
        controller?.openTelegramChat()
    }
    @objc private func openSettings(_ sender: Any?) {
        controller?.openSettings()
    }
    @objc private func quit(_ sender: Any?) {
        NSApp.terminate(nil)
    }
    @objc private func selectAgent(_ sender: NSMenuItem) {
        guard let str = sender.representedObject as? String,
              let id = UUID(uuidString: str) else { return }
        controller?.switchAgent(id: id); rebuild()
    }
    @objc private func addAgent(_ sender: Any?) {
        controller?.presentSetupWizard()
    }
}
