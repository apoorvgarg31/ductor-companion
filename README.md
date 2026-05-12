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

## Install (easy path)

1. Go to **[github.com/apoorvgarg31/ductor-companion/releases/latest](https://github.com/apoorvgarg31/ductor-companion/releases/latest)**
2. Download **`Ductor-Companion-v*.dmg`**
3. Open it, drag **Ductor Companion** into Applications
4. **First launch only:** right-click the app in Applications → **Open** → **Open** anyway.
   The app is ad-hoc signed (no Apple Developer ID), so macOS shows a
   Gatekeeper warning the first time. After this once, double-click works
   normally. Equivalent shortcut from Terminal:
   ```bash
   xattr -d com.apple.quarantine "/Applications/Ductor Companion.app"
   ```
5. The first-run wizard walks you through:
   - Finding `~/.ductor/agents.json` (with a "View Ductor on GitHub" link if it's not installed yet)
   - Picking an existing agent or creating a new one (BotFather token + allowed user IDs)
   - Configuring the pet (sprite path, heartbeat / screenshot intervals, quiet hours)
   - **Signing in to Telegram** — the wizard now collects the SMS code (and 2FA password if you have one) directly in the app. No terminal required.

The shipping DMG contains a self-contained Python bridge built with
PyInstaller, so end users do **not** need to install Python.

---

## Prerequisites

* **macOS 13 Ventura or later** on Apple Silicon (arm64).
* **[Ductor](https://github.com/PleasePrompto/ductor)** running on the same Mac — the Companion talks to its `agents.json` to discover sub-agents.
* A regular **Telegram account** and an `api_id` / `api_hash` from [my.telegram.org/apps](https://my.telegram.org/apps).
* On first launch macOS will prompt for **Accessibility** (needed for
  window-title heartbeats) and **Screen Recording** (only if you opt in
  to periodic screenshots). Grant both in
  System Settings → Privacy & Security.

---

## The first-run wizard

The first time the app starts, a sheet walks you through five steps. The
Companion integrates directly with Ductor's local `agents.json` —
there's no separate scripting to run.

### Step 1 — Locate Ductor

The Companion looks for `agents.json` in this order:

1. The path saved from a previous run (Settings → Agents → Ductor home).
2. `$DUCTOR_HOME/agents.json`.
3. `~/.ductor/agents.json`.

On success, you see "✓ Ductor detected at &lt;path&gt;" and Next is
enabled. If nothing is found, you get a "View Ductor on GitHub" link
([ductor repo](https://github.com/PleasePrompto/ductor)), a "Choose
Ductor home folder…" picker for non-default installs, and an "I'll
install it later" button that quits the app.

### Step 2 — Pick or create an agent

The wizard reads every Telegram-transport entry out of `agents.json`
and renders them as a radio list. Pick one to skip ahead to Step 4, or
choose **➕ Create new agent** to open the form in Step 3.

Matrix-transport agents are filtered out — they're out of scope for the
Telethon-based bridge.

### Step 3 — Create a new agent (only if you chose to)

This step writes a new entry into `agents.json` *natively from Swift*
— the Companion does not shell out to `create_agent.py`. The
AgentSupervisor file-watches that file and boots the agent within
seconds.

Form fields:

| Field | Notes |
| --- | --- |
| Slug | Lowercase, no spaces, not `main`. Validated inline. |
| Description | Multi-line, written into the new agent's `JOIN_NOTIFICATION.md`. |
| Provider | `claude` / `openai` / `gemini`. |
| Model | `opus`/`sonnet`/`haiku` for Claude; e.g. `gpt-5.3-codex` for OpenAI; `gemini-2.5-pro` for Gemini. |
| BotFather token | `SecureField`. There's an "Open @BotFather" button — run `/newbot` in the chat and paste the token here. |
| Allowed Telegram user IDs | Comma-separated integers. Find yours via @userinfobot. |

When you click **Create & continue**, the Companion:

1. Validates fields.
2. Reads `agents.json`, appends the new entry, and writes the file
   atomically (`tmp → rename`) so the supervisor never sees a partial
   file.
3. Writes `<DUCTOR_HOME>/agents/<slug>/workspace/JOIN_NOTIFICATION.md`
   with the description.
4. Polls for `<DUCTOR_HOME>/agents/<slug>/workspace/MAINMEMORY.md`
   (up to 30 s) — that's the marker the supervisor drops when the
   agent has started. On success → Step 4. On timeout it logs a
   warning and continues anyway; the agent often starts shortly after.

### Step 4 — Pet details

Defaults derived from the slug:

* Display name: capitalized slug.
* Sprite path: `~/.codex/pets/<slug>/`.
* Heartbeat every 2 min, screenshots off, screenshot interval 5 min,
  quiet hours 22:00 – 08:00.

All editable here and later in Settings.

### Step 5 — Telegram credentials + in-app login

Only shown when the Keychain doesn't already have phone / api_id /
api_hash. These are the *user-account* credentials the Telethon bridge
needs to log in and listen to the bot's chat — distinct from the
BotFather token (which the bridge never sees; that lives in
`agents.json` for the Ductor side).

* https://my.telegram.org/apps gives you a free api_id / api_hash.
* Phone is your Telegram-account phone number.

When you click **Finish**, the wizard launches the bridge in
`--login-only` mode and a sheet appears that asks for the SMS code
Telegram just sent you. If your account has 2FA enabled, it'll then ask
for the password. On success the Telethon `StringSession` is cached in
macOS Keychain under service `ductor-companion`, the sheet dismisses,
and the pet drops into the bottom-right corner of your screen.

**Re-opening the wizard.** Tray → "Add agent…" or Settings → "Add
agent…" reopens the wizard starting at Step 2 (Ductor is already
detected, credentials are already cached).

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

Login handshake (wizard ↔ bridge `--login-only`):

```json
bridge -> swift   {"kind":"needs_sms_code","phone":"+15..."}
swift  -> bridge  {"kind":"sms_code","value":"12345"}
bridge -> swift   {"kind":"needs_2fa_password"}
swift  -> bridge  {"kind":"2fa_password","value":"..."}
bridge -> swift   {"kind":"login_complete"}
```

Heartbeats arrive in the bot chat as plain-text `[heartbeat] {...}`;
screenshots arrive as photos with the same caption format.

---

## Troubleshooting

* **"Ductor Companion can't be opened because Apple cannot check it for malicious software."** — expected for unsigned apps. Right-click the app → **Open** → **Open** anyway; or run `xattr -d com.apple.quarantine "/Applications/Ductor Companion.app"`.
* **No sprite, blue hexagon** → run the **hatch-pet** skill from OpenAI's
  [skills repo](https://github.com/openai/skills) in Codex CLI to
  generate `~/.codex/pets/<agent-slug>/spritesheet.webp` + `pet.json`.
  The companion picks it up on next agent switch or app restart.
* **Pet doesn't appear** → tray menu → "Show Pet". If the saved
  position is off-screen, run
  `defaults delete com.apoorvgarg.ductor-companion`.
* **Bridge stuck "disconnected"** → Console.app, filter `[ductor]`
  or `[bridge]`. Common causes: missing API id/hash, session expired
  (`keyring delete ductor-companion <agent-slug>` then re-run the
  wizard), bot username typo.
* **Empty window titles** → grant Accessibility in System Settings →
  Privacy & Security → Accessibility.
* **Screenshots never send** → Settings → enable per-agent. If still
  nothing, quiet hours may be active.
* **Wizard "agents.json malformed"** → open it manually, fix the JSON,
  or back it up and let the wizard write a fresh entry. The Companion
  refuses to overwrite a file it can't parse.
* **Supervisor didn't write MAINMEMORY.md within 30 s** → look at the
  Ductor logs; the most common cause is the BotFather token being
  rejected or a model name the provider doesn't recognize.

---

## Open Decisions / Assumptions

1. **pet.json schema** — inferred from the hatch-pet skill's atlas spec
   (1536×1872, 8×9 cells of 192×208 px). Loader accepts either a
   top-level `rows: ["idle","waving",...]` array or a list of
   `animations[].name` objects, falling back to a default ordering when
   absent.
2. **Telegram API id/hash storage** — macOS Keychain, service
   `ductor-companion`, accounts `telegram.api_id` / `telegram.api_hash`
   / `telegram.phone`.
3. **Ductor home resolution** — checked in this order: saved
   `ductor.homePath` UserDefault, `DUCTOR_HOME` env, `~/.ductor`. The
   wizard's Step 1 falls back to an `NSOpenPanel` if none contain
   `agents.json`. Picked path is persisted for re-entry.
4. **Native `agents.json` writes** — the wizard's "Create agent" path
   does **not** shell out to `create_agent.py`. It reads, mutates, and
   atomically rewrites `agents.json` from Swift to match Ductor's
   AgentSupervisor file-watcher contract.
5. **Supervisor readiness signal** — we wait for
   `<DUCTOR_HOME>/agents/<slug>/workspace/MAINMEMORY.md` (up to 30 s)
   as the "agent has started" marker.
6. **Matrix transport is out of scope** — Step 2 filters `agents.json`
   to Telegram entries only.
7. **In-app SMS-code login** — the bridge gains a `--login-only` mode
   that prompts the wizard over the websocket instead of stdin. The
   stdin path is preserved when `bridge.py` is run from a terminal
   (dev / `bridge/README.md` workflow).
8. **Heartbeat schema** always includes `frontmost_app`, `window_title`
   (best-effort), `idle_seconds`, `quiet_hour`.
9. **WebP** via built-in `NSImage(contentsOf:)` (macOS 11+) — no
   third-party image library.
10. **One Telegram account** — the bridge keys Telethon sessions by
    agent slug, but the same `api_id`/`api_hash`/`phone` are used
    across all agents on a given Mac.
11. **arm64-only DMG** — the shipping PyInstaller bundle targets the
    host architecture of the macos-14 runner (Apple Silicon). Intel
    Macs can still run the app under Rosetta from a from-source build
    (see below). True universal2 builds are tracked for a future
    release.
12. **Ad-hoc signed, not notarized** — no Apple Developer ID. First
    launch needs the right-click → Open dance once; subsequent launches
    are silent.

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

* **Apple Developer ID + notarization** — silent first launch.
* **Sparkle auto-update** — DMG releases push themselves.
* **Homebrew tap** — `brew install --cask ductor-companion`.
* **Universal binary** — arm64 + x86_64 PyInstaller output.
* **Multi-agent rotation** — schedule a different agent to be active by
  time-of-day (e.g. coach in the morning, code reviewer in the
  afternoon).
* **Native Telegram client** via TDLib bindings instead of a Python
  Telethon subprocess — drops the bundled-Python footprint.

---

<details>
<summary><b>Build from source (developer workflow)</b></summary>

### Prerequisites

* **Xcode 15+** — install from the App Store, then open it once to accept the license.
* **Python 3.11+** — `brew install python@3.11`.

### Build & run

```bash
# 1. clone
git clone https://github.com/apoorvgarg31/ductor-companion.git
cd ductor-companion

# 2. install the Python bridge into a venv next to the source
./scripts/install_bridge_deps.sh ./Jarvis/Jarvis/Resources

# 3. open in Xcode
open Jarvis/Jarvis.xcodeproj
```

In Xcode: **Signing & Capabilities** → pick your team (a free Apple ID "Personal Team" is fine). Build & run with ⌘R.

At runtime the Swift host prefers a PyInstaller bundle at
`Resources/bridge_bundled/bridge_app/bridge` (populated by the release
CI) and falls back to the venv at `Resources/bridge/.venv/` when the
bundled binary isn't there — which is the normal dev case.

### Build the standalone PyInstaller bundle locally

```bash
python3 -m pip install pyinstaller telethon==1.36.0 websockets==12.0 keyring==25.2.1 Pillow==10.4.0
bash bridge/build_standalone.sh
./scripts/install_bridge_deps.sh --standalone ./Jarvis/Jarvis/Resources
```

After that, Swift will pick up the bundled binary and the venv is no
longer consulted.

### Build a distributable .app + DMG from the command line

```bash
./scripts/package_app.sh --configuration Release
# → build/Jarvis.zip
```

For a tagged DMG release, push a `v*` tag and let
`.github/workflows/release.yml` build it on macos-14.

### Telethon dev login from a terminal

If you'd rather not use the in-app login sheet (e.g. while iterating on
the bridge without rebuilding the app), the standalone bridge keeps the
stdin fallback:

```bash
cd bridge && source .venv/bin/activate
export DUCTOR_AGENT_CONFIG_JSON='{"agent_name":"jarvis","bot_username":"<your-bot>","api_id":12345,"api_hash":"<hash>","phone":"+15551234567"}'
python bridge.py
# paste the SMS code (and 2FA password if applicable)
# Ctrl-C once you see "watching @<bot>"
```

### Repository layout

```
ductor-companion/
├── README.md, LICENSE, .gitignore
├── .github/workflows/                ← CI + release pipelines
├── Jarvis/                           ← Xcode project
│   ├── Jarvis.xcodeproj/project.pbxproj
│   └── Jarvis/
│       ├── Info.plist
│       ├── JarvisApp.swift           ← @main + BridgeLauncher
│       ├── AgentProfile.swift        ← Codable agent record
│       ├── Config.swift              ← UserDefaults + Keychain glue
│       ├── Keychain.swift            ← SecItem wrapper
│       ├── PetWindow.swift           ← floating borderless NSPanel
│       ├── PetView.swift             ← sprite animation view
│       ├── SpriteAtlas.swift         ← hatch-pet atlas loader
│       ├── SpeechBubbleView.swift    ← bubble + tap-for-thread affordance
│       ├── SetupWizardView.swift     ← five-step wizard
│       ├── TelegramLoginView.swift   ← in-app SMS-code modal
│       ├── SettingsView.swift        ← TabView (Agents + Telegram)
│       ├── TrayMenu.swift            ← NSStatusItem menu w/ agent switcher
│       ├── BridgeClient.swift        ← URLSession websocket client
│       ├── ScreenshotService.swift   ← periodic display capture
│       ├── HeartbeatService.swift    ← frontmost app + window title + idle
│       └── Resources/
│           ├── Assets.xcassets/
│           ├── bridge/               ← bundled Python source + dev venv
│           └── bridge_bundled/       ← PyInstaller output (release only)
├── bridge/                           ← standalone bridge source
│   ├── bridge.py
│   ├── requirements.txt
│   ├── build_standalone.spec         ← PyInstaller spec
│   └── build_standalone.sh           ← wrapper for pyinstaller
└── scripts/
    ├── install_bridge_deps.sh        ← venv mode OR --standalone mode
    └── package_app.sh                ← xcodebuild + zip
```

</details>

---

## License

MIT. See `LICENSE`.
