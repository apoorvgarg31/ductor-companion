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
Telethon-based bridge (see Open Decisions below).

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

### Step 5 — Telegram user-account credentials

Only shown when the Keychain doesn't already have phone / api_id /
api_hash. These are the *user-account* credentials the Telethon bridge
needs to log in and listen to the bot's chat — distinct from the
BotFather token (which the bridge never sees; that lives in
`agents.json` for the Ductor side).

* https://my.telegram.org/apps gives you a free api_id / api_hash.
* Phone is your Telegram-account phone number.

Stored in macOS Keychain under service `ductor-companion`.

The wizard closes, the pet drops into the bottom-right corner of your
screen, and the bridge starts.

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
* **First SMS-code login** has to happen in a real terminal (Telethon
  reads it from stdin):
  ```bash
  cd bridge && source .venv/bin/activate
  export JARVIS_BOT_USERNAME=<your-bot-handle>
  export JARVIS_PHONE=+15551234567 JARVIS_API_ID=… JARVIS_API_HASH=…
  python bridge.py
  # paste code, ctrl-C once you see "watching @<bot>"
  ```
  The StringSession is then cached in Keychain (service
  `ductor-companion`, account = agent slug) and subsequent launches are
  silent.
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
   AgentSupervisor file-watcher contract. The schema mirror is in
   `DuctorRegistry` (Telegram-only). This keeps the Companion
   self-contained — no Python on PATH required, no need to find the
   user's Ductor source tree.
5. **Supervisor readiness signal** — we wait for
   `<DUCTOR_HOME>/agents/<slug>/workspace/MAINMEMORY.md` (up to 30 s)
   as the "agent has started" marker. On timeout we log a warning and
   proceed; the agent often appears moments later.
6. **Matrix transport is out of scope** — Step 2 filters
   `agents.json` to entries where `transport` is missing (Telegram is
   the default) or equals `"telegram"`. The Telethon bridge has no
   Matrix support today.
7. **First-run SMS-code prompt** is still on stdin in the standalone
   `bridge/` flow. For the in-app bridge, you'll need to run the
   bridge once from a terminal to enter the code; the StringSession is
   then cached in Keychain and the in-app launch is silent.
8. **Heartbeat schema** always includes `frontmost_app`, `window_title`
   (best-effort), `idle_seconds`, `quiet_hour`.
9. **WebP** via built-in `NSImage(contentsOf:)` (macOS 11+) — no
   third-party image library.
10. **One Telegram account** — the bridge keys Telethon sessions by
    agent slug, but the same `api_id`/`api_hash`/`phone` are used
    across all agents on a given Mac. Multi-account would need
    per-agent credential storage.
11. **Bot username on AgentProfile is optional.** The Companion knows
    which agent to talk to via the BotFather token in `agents.json`
    (server-side), but the tap-to-open deep link
    (`tg://resolve?domain=…`) needs the human-facing @handle. The
    wizard doesn't ask for it; fill it in from Settings if you want
    the click-to-open shortcut to work.

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
