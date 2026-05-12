# Ductor Companion — a Mac face for your Ductor agent

A tiny always-on-top macOS pet that bridges your desktop to a remote
**Ductor** sub-agent over Telegram. The pet sits on your screen, talks
to you in a soft speech bubble, and forwards screenshots + activity
heartbeats back to the agent so it can coach with context.

Ductor Companion is a **face**, not a brain. Persona, memory, project
awareness — all of that lives on the Ductor side. The Mac app only
renders messages, captures sensors, and pipes the conversation in both
directions.

```
┌────────────┐  ws://127.0.0.1:port  ┌────────────────┐  Telegram MTProto  ┌──────────────────┐
│ Companion  │ ◀───────────────────▶ │ Telethon       │ ◀────────────────▶ │ Ductor sub-agent │
│ (SwiftUI)  │                       │ bridge (py)    │                    │ (jarvis, coach…) │
└────────────┘                       └────────────────┘                    └──────────────────┘
       ▲                                                                              │
       │ pet click → tg://resolve?domain=<agent_bot>                                   │
       ▼                                                                              ▼
   Telegram chat                                                          (replies, screenshots,
                                                                            heartbeats, prompts)
```

One Mac, many sub-agents. Switch which agent the pet represents from
the tray menu.

---

## Quickstart

```bash
# 1. clone (or copy this folder onto the Mac)
git clone <wherever-you-host-this> ductor-companion
cd ductor-companion

# 2. install the Python bridge into a venv next to the source
./scripts/install_bridge_deps.sh ./Jarvis/Jarvis/Resources

# 3. open in Xcode (requires Xcode 15+, macOS 13+ SDK)
open Jarvis/Jarvis.xcodeproj

# 4. build & run (⌘R) — the first-run wizard kicks in.
```

On first launch macOS will ask for **Accessibility** (needed) and
**Screen Recording** (only if you opt in to periodic screenshots).

---

## The first-run wizard

The first time the app starts, a 3-step sheet walks you through setup.
There's nothing to configure manually beforehand.

### Step 1 — Telegram credentials

The companion authenticates as a **Telegram user account** (not a bot),
so it can listen to bot chats. That requires your own
`api_id` / `api_hash`:

* Go to https://my.telegram.org/apps and sign in with the phone you'll
  use here.
* Create a new application (any name).
* Paste the values into the wizard along with your phone number.

These three values are written to the macOS Keychain (service
`ductor-companion`). They never appear in UserDefaults or on disk.

### Step 2 — Connect a Ductor agent

Pick a path:

* **I have a bot username.** Paste it (without `@`) and click **Test**.
  The bridge spawns in dry-run mode, logs into Telegram, resolves the
  username, and reports success or failure inline.
* **Spin up a new agent.** Provide the username of the **Ductor main
  bot** (the one that mints sub-agents for you). The wizard opens that
  chat via `tg://resolve?domain=…`, you ask it to mint a new agent the
  usual way, then paste the resulting bot username back into the
  wizard.

If Test reports "Telegram session not yet authorized", run the bridge
once from a terminal (see [bridge/README.md](bridge/README.md)) so you
can type the SMS code. The session is then cached in the Keychain and
the wizard's Test will succeed on retry.

### Step 3 — Name the agent

The wizard pre-fills sensible defaults derived from the bot username
(`jarvis_apoorv_bot` → slug `jarvis`, display name "Jarvis", sprite path
`~/.codex/pets/jarvis/`). Adjust intervals + quiet hours, then **Finish**.

The wizard closes, the pet drops into the bottom-right corner of your
screen, and the bridge starts watching the bot chat.

---

## Daily use

* **Click the pet** → opens the active agent's Telegram chat.
* **Bubble appears** when the agent sends a message. Up to 5 lines
  render inline; for longer messages you'll see "📩 tap for full thread".
* **Drag the pet** anywhere — its position is remembered per-display.
* **Menu bar icon** → show/hide pet, pause sensors, switch agent, add
  agent, open settings, quit.
* **Quiet hours** silence sensor traffic; explicit messages still surface.

### Deep-linking

Anything on macOS can open the active agent's chat with:

```bash
open "tg://resolve?domain=<bot-username>"
```

---

## Adding more agents

One Mac, many sub-agents.

* **Tray → Add agent…** runs the wizard again.
* The tray menu shows all configured agents; click one to make it active.
* Settings → Agents tab lists everything and exposes per-agent
  intervals, sprite paths, and quiet hours.

When you switch agents, the companion tears down the current bridge
subprocess, reloads the sprite atlas from the new agent's sprite path,
and reconnects. Telegram credentials are shared — no second login.

The bridge scopes each agent's Telethon session by slug in the
Keychain, so multiple Telegram identities are technically possible
(you'd need to re-run the wizard with a different phone), but the
common case is one Telegram account fronting many Ductor sub-agents.

---

## Wire format

Outbound from agent → companion:

```json
{"kind":"jarvis_message","text":"...","has_media":false,"media_caption":null,"timestamp":1234567890.0}
```

Inbound from companion → agent (the bridge translates into Telegram):

```json
{"kind":"user_text","text":"..."}
{"kind":"heartbeat","data":{"frontmost_app":"Xcode","window_title":"App.swift","idle_seconds":3,"quiet_hour":false}}
{"kind":"screenshot","png_base64":"iVBOR...","caption":"[screenshot] frontmost=Xcode title='App.swift' idle=3s"}
```

Heartbeats arrive in the bot chat as plain-text `[heartbeat] {...}`;
screenshots arrive as photos with the same caption format.

---

## Repository layout

```
ductor-companion/
├── README.md, LICENSE, .gitignore
├── Jarvis/                            ← Xcode project (kept as-is to minimize churn)
│   ├── Jarvis.xcodeproj/project.pbxproj
│   └── Jarvis/
│       ├── Info.plist
│       ├── JarvisApp.swift            ← @main DuctorCompanionApp + AppDelegate
│       ├── AgentProfile.swift         ← Codable agent record
│       ├── Config.swift               ← UserDefaults + Keychain glue
│       ├── Keychain.swift             ← SecItem wrapper
│       ├── PetWindow.swift            ← floating borderless NSPanel
│       ├── PetView.swift              ← sprite animation view
│       ├── SpriteAtlas.swift          ← hatch-pet atlas loader + placeholder
│       ├── SpeechBubbleView.swift     ← bubble + tap-for-thread affordance
│       ├── SetupWizardView.swift      ← first-run + add-agent wizard
│       ├── SettingsView.swift         ← TabView (Agents + Telegram)
│       ├── TrayMenu.swift             ← NSStatusItem menu w/ agent switcher
│       ├── BridgeClient.swift         ← URLSession websocket client
│       ├── ScreenshotService.swift    ← periodic display capture
│       ├── HeartbeatService.swift     ← frontmost app + window title + idle
│       └── Resources/
│           ├── Assets.xcassets/       ← AppIcon + placeholder
│           └── bridge/                ← bundled Python bridge
├── bridge/                            ← standalone dev copy of the bridge
└── scripts/
    ├── install_bridge_deps.sh         ← venv into .app/Contents/Resources/bridge
    └── package_app.sh                 ← xcodebuild + zip
```

---

## Troubleshooting

* **No sprite, blue hexagon** → run the **hatch-pet** skill from OpenAI's
  [skills repo](https://github.com/openai/skills) in Codex CLI to
  generate `~/.codex/pets/<agent-slug>/spritesheet.webp` + `pet.json`.
  The companion picks it up on next agent switch or app restart.
* **Pet doesn't appear** → tray menu → "Show Pet". If the saved
  position is off-screen, run
  `defaults delete com.apoorvgarg.ductor-companion`.
* **Bridge stuck "disconnected"** → Console.app, filter `[ductor]`
  or `[bridge]`. Common causes: missing API id/hash, session expired
  (`keyring delete ductor-companion <agent-slug>`), bot username typo.
* **Empty window titles** → grant Accessibility in System Settings →
  Privacy & Security → Accessibility.
* **Screenshots never send** → Settings → enable per-agent. If still
  nothing, quiet hours may be active.
* **Wizard's Test always fails with "needs interactive login"** → the
  first SMS-code login has to happen in a real terminal:
  ```bash
  cd bridge && python bridge.py
  # paste code, ctrl-C once you see "watching @<bot>"
  ```
  After that the Keychain has a valid session and the wizard's Test
  succeeds without any prompt.

---

## Open Decisions / Assumptions

1. **pet.json schema** — inferred from the hatch-pet skill's atlas spec
   (1536×1872, 8×9 cells of 192×208 px). Loader accepts either a
   top-level `rows: ["idle","waving",...]` array or a list of
   `animations[].name` objects, falling back to a default ordering when
   absent.
2. **Telegram API id/hash storage** — Keychain, service
   `ductor-companion`, accounts `telegram.api_id` / `telegram.api_hash`
   / `telegram.phone`.
3. **Ductor "main bot"** — the wizard's "create new agent" path opens
   whatever username is stored at `Config.ductorMainBotUsername`.
   There's no built-in default; the wizard prompts on first use and
   re-uses the value thereafter. Stored in UserDefaults under
   `ductor.mainBotUsername`.
4. **"Ductor-ish" bot pattern** — we **do not** filter or validate
   usernames against a regex. The user types or pastes whatever they
   like; the wizard's Test step is the source of truth for "is this
   real."
5. **First-run SMS-code prompt** is on stdin, not in the GUI. The
   wizard's dry-run Test closes stdin so it fails fast rather than
   hanging on `input()`. Documented workaround: run the bridge once
   from a terminal for the initial login.
6. **Heartbeat schema** always includes `frontmost_app`, `window_title`
   (best-effort), `idle_seconds`, `quiet_hour`.
7. **WebP** via built-in `NSImage(contentsOf:)` (macOS 11+) — no
   third-party image library.
8. **One Telegram account** — the bridge keys sessions by agent slug,
   but the same `api_id`/`api_hash`/`phone` are used across agents.
   Multi-account would need per-agent credential storage.

---

## Building from the command line

```bash
./scripts/package_app.sh --configuration Release
# → build/Jarvis.zip
```

This runs `xcodebuild`, drops a Python venv into
`Jarvis.app/Contents/Resources/bridge/.venv`, and zips the result.

---

## Acknowledgements

* The desktop sprite comes from the **hatch-pet** skill in
  [openai/skills](https://github.com/openai/skills). Run it from Codex
  CLI to produce `~/.codex/pets/<slug>/`; the companion picks it up
  automatically.
* This is the Mac face for the Ductor agent system (an internal
  multi-agent orchestrator).

---

## Roadmap

* **Multi-agent rotation** — schedule a different agent to be active by
  time-of-day (e.g. coach in the morning, code reviewer in the
  afternoon).
* **Native Telegram client** via TDLib bindings instead of a Python
  Telethon subprocess — drops the venv requirement, simplifies
  packaging.
* **Proper packaged `.dmg`** with sandbox entitlements and
  notarization.

---

## License

MIT. See `LICENSE`.
