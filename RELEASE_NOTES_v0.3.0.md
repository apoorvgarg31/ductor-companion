# Ductor Companion v0.3.0

Heartbeats now actually fire, and you can talk to your pet from
anywhere on the desktop without switching to Telegram.

## New

* **Global quick-chat shortcut.** Hit **⌘⇧J** anywhere on macOS to pop
  a small floating input. Type a question, press Return — it goes to
  your agent over the same path Telegram messages use, and the reply
  lands in the pet's speech bubble. Escape (or 30 s of idleness)
  dismisses without sending. The shortcut is rebindable in
  Settings → General → *Quick chat shortcut* (click the field, press
  any chord with at least one of ⌘/⌥/⌃, Esc to abort).

  Implemented with Carbon's `RegisterEventHotKey` — no third-party
  Swift dependencies added.

## Fixed

* **Heartbeats now actually reach the bot chat.** Three behaviours
  conspired to drop outbound traffic silently while *inbound* (bot →
  Companion → speech bubble) appeared to work normally:

  1. `BridgeClient` marked itself "connected" the instant
     `task.resume()` was called, before the websocket handshake had
     actually completed. The tray said *connected* while the wire was
     still negotiating.
  2. Sends issued during that handshake window were buffered by
     URLSession and silently dropped if the handshake later failed.
  3. When the Python bridge took longer than 8 s to write its port
     file, the Swift side called `start(port: 0)` which silently
     no-op'd. The client looked alive but `task` was nil and every
     `sendHeartbeat()` quietly returned.

  v0.3.0 replaces the ad-hoc nil-checks with an explicit state
  machine (`idle` / `connecting` / `connected` / `disconnected`).
  "Connected" is now driven by the URLSession delegate's real
  `didOpenWithProtocol` callback. Sends made while `.connecting` are
  queued (cap 32) and flushed once the wire is live. Sends in `.idle`
  or `.disconnected` get a loud error trace instead of vanishing.
  `start(port: 0)` is now an explicit failure path that surfaces the
  dead state in the tray.

* **Bridge subprocess errors are no longer invisible.** Python
  exceptions from the Telethon bridge (target_id resolution failures,
  FloodWait, etc.) used to land on a tty no `.app` ever sees. The
  Companion now pipes the subprocess's stdout *and* stderr into the
  unified-logging subsystem under category `bridge-py`, with
  `PYTHONUNBUFFERED=1` so lines arrive in real time.

## Tracing

Every hop on the heartbeat / screenshot / bridge paths emits structured
`os_log` lines under subsystem `com.apoorvgarg.ductor-companion`. Each
line carries the active agent slug. To pull the last few minutes of
traffic:

```bash
log show --predicate 'subsystem == "com.apoorvgarg.ductor-companion"' \
    --info --last 5m
```

Useful category filters:

| category    | what it shows                                                |
| ----------- | ------------------------------------------------------------ |
| `heartbeat` | timer configure/start/tick, suppression reasons, send calls  |
| `screenshot`| same, plus disabled / quiet-hour / paused suppressions       |
| `bridge`    | ws connect, state transitions, send/recv kinds, reconnects   |
| `bridge-py` | the Python bridge subprocess's stdout/stderr, line-by-line   |
| `hotkey`    | `RegisterEventHotKey` results for the quick-chat shortcut    |

If heartbeats still go missing after upgrading, attach the output of
that `log show` command to a bug report and the path the message took
will be visible end-to-end.

## Known limitations

* **Ad-hoc signed, not notarized.** First launch still needs
  right-click → **Open** → **Open**, or
  `xattr -d com.apple.quarantine "/Applications/Ductor Companion.app"`.
* **arm64-only DMG.** Universal2 / Intel still on the roadmap.
* **Single Telegram account per Mac.** The bridge keys Telethon
  sessions by agent slug, but the `api_id` / `api_hash` / `phone`
  trio is shared across all agents on a given machine.
* **Matrix transport unsupported.** The wizard filters
  `agents.json` to Telegram entries; Matrix-transport agents are
  out of scope for the Telethon-based bridge.

## Upgrading

Drag the new `Ductor-Companion-v0.3.0.dmg` over the old install. Your
agents, sprite paths, Telegram session, and pet position migrate
automatically. The first launch will register the default ⌘⇧J
shortcut; no extra permission prompts compared to v0.2.x.
