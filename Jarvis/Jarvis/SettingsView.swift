import SwiftUI

/// Tabbed settings panel.
///
/// Tab 1 — Agents: list of configured agents, add/edit/delete, plus the
///                 per-agent intervals and quiet hours for the currently
///                 selected agent.
/// Tab 2 — Telegram: shared credentials (api id/hash/phone in Keychain)
///                  + Ductor "main bot" username for the wizard's
///                  "spawn new agent" path.
struct SettingsView: View {
    weak var controller: DuctorAppController?
    @ObservedObject private var config: Config = .shared

    var body: some View {
        TabView {
            AgentsTab(controller: controller)
                .tabItem { Label("Agents", systemImage: "person.crop.circle") }

            TelegramTab()
                .tabItem { Label("Telegram", systemImage: "key.fill") }
        }
        .padding(12)
        .frame(width: 540, height: 580)
    }
}

// MARK: - Agents tab

private struct AgentsTab: View {
    weak var controller: DuctorAppController?
    @ObservedObject private var config: Config = .shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Configured agents").font(.headline)
                Spacer()
                Button {
                    controller?.presentSetupWizard()
                } label: {
                    Label("Add agent…", systemImage: "plus.circle")
                }
            }

            List(selection: Binding(
                get: { config.selectedAgentID },
                set: { id in
                    if let id { controller?.switchAgent(id: id) }
                }
            )) {
                ForEach(config.agents) { agent in
                    HStack {
                        Image(systemName: agent.id == config.selectedAgentID
                                ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(agent.id == config.selectedAgentID
                                                ? Color.accentColor : .secondary)
                        VStack(alignment: .leading) {
                            Text(agent.displayName).font(.body)
                            Text("@\(agent.botUsername)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            config.removeAgent(id: agent.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                    .tag(agent.id)
                    .contentShape(Rectangle())
                }
            }
            .frame(maxHeight: 180)

            if let selected = config.selectedAgent {
                Divider()
                Text("Settings for \(selected.displayName)").font(.headline)
                AgentEditor(agent: bindingForSelected(selected))
            } else {
                Text("No agent selected — pick one above or add a new one.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(8)
    }

    private func bindingForSelected(_ agent: AgentProfile) -> Binding<AgentProfile> {
        Binding(
            get: { config.selectedAgent ?? agent },
            set: { config.updateAgent($0) }
        )
    }
}

private struct AgentEditor: View {
    @Binding var agent: AgentProfile

    var body: some View {
        Form {
            TextField("Display name", text: $agent.displayName)
            TextField("Bot username", text: $agent.botUsername)
            TextField("Sprite path", text: $agent.spritePath)
            Toggle("Periodic screenshots", isOn: $agent.screenshotsEnabled)
            Stepper(value: $agent.heartbeatInterval, in: 30...3600, step: 30) {
                Text("Heartbeat every \(Int(agent.heartbeatInterval)) sec")
            }
            Stepper(value: $agent.screenshotInterval, in: 60...3600, step: 60) {
                Text("Screenshot every \(Int(agent.screenshotInterval)) sec")
            }
            HStack {
                Stepper(value: $agent.quietHoursStart, in: 0...23) {
                    Text("Quiet from \(agent.quietHoursStart):00")
                }
                Spacer()
                Stepper(value: $agent.quietHoursEnd, in: 0...23) {
                    Text("to \(agent.quietHoursEnd):00")
                }
            }
        }
    }
}

// MARK: - Telegram tab

private struct TelegramTab: View {
    @ObservedObject private var config: Config = .shared
    @State private var phone: String = Config.shared.telegramPhone
    @State private var apiID: String = Config.shared.telegramAPIID
    @State private var apiHash: String = Config.shared.telegramAPIHash

    var body: some View {
        Form {
            Section("Account") {
                TextField("Phone (+15551234567)", text: $phone)
                TextField("API id", text: $apiID)
                TextField("API hash", text: $apiHash)
                Link("Get a free api_id / api_hash →",
                     destination: URL(string: "https://my.telegram.org/apps")!)
                    .font(.footnote)
                HStack {
                    Spacer()
                    Button("Save to Keychain") {
                        config.telegramPhone = phone
                        config.telegramAPIID = apiID
                        config.telegramAPIHash = apiHash
                    }
                }
            }
            Section("Ductor main bot") {
                TextField("Main bot username (used for spawning new agents)",
                          text: $config.ductorMainBotUsername)
                Text("The wizard's \"create new agent\" path opens this bot's "
                     + "chat so Ductor can mint a fresh sub-agent for you.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
    }
}
