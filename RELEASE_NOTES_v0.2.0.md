# Ductor Companion v0.2.0

The DMG now ships with a working pet **out of the box** — no Codex CLI
detour needed before the app feels alive. Download, drag, and the
bundled Zen Robot starts animating on first launch.

## New

* **Bundled "Zen Robot" sprite.** A hatch-pet-generated atlas
  (`Resources/pets/zen-robot/`, 1536×1872 spritesheet + `pet.json` +
  thumbnail) ships inside the `.app`. First launch shows the animated
  pet immediately — no need to install Codex CLI or run the hatch-pet
  skill just to see something on screen.
* **Inline sprite preview in Settings.** The Agents tab renders the
  bundled thumbnail next to the *Custom sprite path* field so users can
  see at a glance what the default looks like.
* **Browse + Reset-to-default affordances.** Both the wizard's Step 4
  and Settings → Agents now have a "Browse…" picker for selecting a
  custom hatch-pet directory and a "Reset to default" button that
  clears the field back to the bundled atlas.

## Changed

* **`AgentProfile.spritePath` is now optional.** An empty / unset value
  means "use the bundled default"; a non-empty value still points at a
  hatch-pet directory you minted yourself (typically
  `~/.codex/pets/<slug>/`). Existing v0.1.0 users with a stored
  spritePath are unaffected — the migration silently collapses empty
  strings to nil so the default kicks in.
* **`SpriteAtlas` resolution order** is now documented and explicit:
  1. The user's custom sprite directory (`AgentProfile.spritePath`).
  2. The bundled `Resources/pets/zen-robot/` atlas.
  3. The gradient hexagon placeholder (last resort, only when the
     bundle is broken).

## Known limitations

* **Ad-hoc signed, not notarized.** First launch still needs the
  right-click → **Open** → **Open** dance (or
  `xattr -d com.apple.quarantine "/Applications/Ductor Companion.app"`).
  No Apple Developer ID yet; subsequent launches are silent.
* **Single Telegram account per Mac.** Multiple Ductor sub-agents on
  one Telegram account work fine (sessions are scoped per slug in
  Keychain); multi-account is not supported.
* **arm64-only DMG.** The bundled PyInstaller binary targets the
  macos-14 runner's arch (Apple Silicon). Intel Macs need a
  from-source build (`./scripts/install_bridge_deps.sh
  ./Jarvis/Jarvis/Resources` + Xcode ⌘R). A universal2 build is still
  on the roadmap.

## Upgrading

Just download `Ductor-Companion-v0.2.0.dmg`, drag over the old app,
and relaunch. UserDefaults migrate automatically — your existing
agents, sprite paths, and Telegram session are preserved.

## Acknowledgements

Sprite art from the [hatch-pet](https://github.com/openai/skills)
skill (openai/skills repo). Bridge built on
[Telethon](https://github.com/LonamiWebs/Telethon).
