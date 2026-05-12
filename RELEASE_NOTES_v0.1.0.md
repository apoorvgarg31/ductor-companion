# Ductor Companion v0.1.0

First public release. Download the DMG below, drag to Applications,
right-click → Open → Open the first time, and the wizard takes it
from there.

## What's in this release

* **Drag-to-install DMG.** A self-contained `.app` ad-hoc signed for
  Apple Silicon — no Apple Developer ID, no notarization, no Homebrew
  tap. Just download and drag.
* **No Python required on the user's machine.** The Telethon bridge is
  bundled with PyInstaller (`bridge_bundled/bridge_app/bridge`) and
  launched as a subprocess from the Swift host. Resources/bridge/.venv
  remains the dev fallback.
* **In-app Telegram login.** First-run wizard step 5 spawns the bridge
  in `--login-only` mode and surfaces an SMS-code sheet (+ a 2FA
  password sheet, if needed) over a local websocket. The terminal step
  that used to be required is gone. Telethon `StringSession` cached in
  macOS Keychain after success.
* **Five-step setup wizard.** Locate Ductor → pick/create agent →
  configure pet → Telegram credentials → in-app login. The "Create
  agent" path writes `agents.json` natively from Swift and waits for
  the Ductor `AgentSupervisor` to flip the agent's `MAINMEMORY.md`
  marker before continuing.
* **Always-on-top pet** with hatch-pet sprite support, speech bubble,
  per-display position memory, menu-bar agent switcher, and per-agent
  heartbeat / screenshot intervals + quiet hours.
* **GitHub Actions release pipeline.** Tag `v*` → macos-14 runner →
  PyInstaller + xcodebuild + create-dmg → uploaded to the matching
  Release.

## Install

1. Download `Ductor-Companion-v0.1.0.dmg` from the
   [Releases page](https://github.com/apoorvgarg31/ductor-companion/releases/tag/v0.1.0).
2. Open the DMG, drag **Ductor Companion** into Applications.
3. First launch: right-click → **Open** → **Open** anyway
   (Gatekeeper warning, expected for an unsigned app).
4. The first-run wizard handles everything else.

## Known limitations

* **Apple Silicon only.** The bundled PyInstaller binary targets the
  macos-14 runner's arch (arm64). Intel Macs need to build from source
  for now — `./scripts/install_bridge_deps.sh ./Jarvis/Jarvis/Resources`
  + Xcode ⌘R. A universal2 build is on the roadmap.
* **Ad-hoc signed, not notarized.** The right-click → Open dance is a
  one-time cost. Subsequent launches are silent. We don't have an
  Apple Developer ID; a future release with proper notarization will
  remove this step.
* **Single Telegram account.** Multiple Ductor sub-agents on one
  Telegram account work fine (sessions are scoped per slug in
  Keychain). Multi-account isn't supported in v0.1.0.
* **Matrix transport not supported.** The Telethon bridge handles only
  Telegram-transport entries in `agents.json`.
* **Sprite generation is separate.** The pet shows a placeholder blue
  hexagon until you run OpenAI's
  [hatch-pet](https://github.com/openai/skills) skill from Codex CLI
  to generate `~/.codex/pets/<agent-slug>/spritesheet.webp` +
  `pet.json`. The companion picks it up on the next app launch or
  agent switch.
* **Pet click → Telegram chat** requires the agent's `botUsername` to
  be set (Settings → Agents). The wizard doesn't currently ask for
  it — the bridge addresses the bot via the BotFather token on the
  Ductor side, so this only affects the click-to-open shortcut.

## Upgrading

This is the first release — nothing to upgrade from.

## Acknowledgements

Sprite art from the [hatch-pet](https://github.com/openai/skills)
skill (openai/skills repo). Bridge built on
[Telethon](https://github.com/LonamiWebs/Telethon).
