import SwiftUI
import AppKit

/// Tabbed settings panel.
///
/// Tab 1 — Agents: list of configured pet profiles, the active agent's
///                 per-agent settings, and the Ductor home path with a
///                 "Reveal agents.json" button.
/// Tab 2 — Telegram: shared credentials (api id/hash/phone in Keychain).
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
        .frame(width: 560, height: 600)
    }
}

// MARK: - Agents tab

private struct AgentsTab: View {
    weak var controller: DuctorAppController?
    @ObservedObject private var config: Config = .shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Pet profiles").font(.headline)
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
                            Text(agent.botUsername.isEmpty
                                 ? "(no bot username)"
                                 : "@\(agent.botUsername)")
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
            .frame(maxHeight: 160)

            DuctorHomeRow()

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

private struct DuctorHomeRow: View {
    @ObservedObject private var config: Config = .shared
    @State private var resolved: URL? = Config.shared.resolveDuctorHome()

    var body: some View {
        GroupBox(label: Label("Ductor home", systemImage: "folder")) {
            HStack {
                Text(resolved?.path ?? "(not detected)")
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Reveal agents.json") {
                    guard let home = resolved else { return }
                    let url = home.appendingPathComponent("agents.json")
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                .disabled(resolved == nil)
                Button("Refresh") {
                    resolved = config.resolveDuctorHome()
                }
            }
        }
    }
}

private struct AgentEditor: View {
    @Binding var agent: AgentProfile

    /// `agent.spritePath` is `String?` (nil → bundled default); SwiftUI's
    /// TextField wants a non-optional binding, so collapse nil → "" both ways.
    private var spritePathBinding: Binding<String> {
        Binding(
            get: { agent.spritePath ?? "" },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespaces)
                agent.spritePath = trimmed.isEmpty ? nil : trimmed
            }
        )
    }

    var body: some View {
        Form {
            TextField("Display name", text: $agent.displayName)
            TextField("Bot username (optional, for the tap-to-open deep link)",
                      text: $agent.botUsername)
            BundledSpriteRow(spritePath: spritePathBinding)
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

// MARK: - Sprite row (bundled default thumbnail + custom path field)

/// Shows the bundled Zen Robot thumbnail next to a textfield for an optional
/// override path. Empty path → bundled default is used.
private struct BundledSpriteRow: View {
    @Binding var spritePath: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            thumbnail
                .frame(width: 56, height: 56)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 4) {
                TextField(
                    "Custom sprite path (optional, defaults to bundled Zen Robot)",
                    text: $spritePath
                )
                HStack {
                    Button("Browse…") { browse() }
                    Button("Reset to default") { spritePath = "" }
                        .disabled(spritePath.isEmpty)
                    Spacer()
                }
                .font(.footnote)
            }
        }
    }

    @ViewBuilder private var thumbnail: some View {
        if let url = Bundle.main.url(forResource: "pets/zen-robot/thumbnail",
                                     withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            Image(nsImage: img).resizable().scaledToFit()
        } else {
            Image(systemName: "circle.hexagongrid.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.secondary)
                .padding(8)
        }
    }

    private func browse() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Pick a hatch-pet directory containing spritesheet.webp + pet.json"
        panel.prompt = "Use this folder"
        if panel.runModal() == .OK, let url = panel.url {
            spritePath = url.path
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
            Section {
                Text("These credentials are used by the Telethon bridge to "
                     + "log into Telegram as your user account and listen to "
                     + "the agent's bot chat. They're stored in macOS Keychain "
                     + "under service `ductor-companion`.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
    }
}
