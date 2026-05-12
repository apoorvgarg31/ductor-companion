#!/usr/bin/env python3
"""Telegram <-> Ductor Companion bridge.

Logs into Telegram as the user (not a bot — bots cannot read each other's
messages), watches a single configured bot chat, and exposes a local
websocket on 127.0.0.1:<auto-picked-port> for the Swift host app.

Inbound from Telegram bot chat -> websocket clients:
    {"kind": "jarvis_message", "text": "...", "has_media": false,
     "media_caption": null, "timestamp": 1234567890.0}

Outbound from websocket clients -> Telegram bot chat:
    {"kind": "user_text", "text": "..."}
    {"kind": "heartbeat", "data": {...}}     # serialized to "[heartbeat] {...}"
    {"kind": "screenshot", "png_base64": "...", "caption": "..."}

Login-flow messages (in-app wizard, see TelegramLoginView.swift):
    bridge -> swift   {"kind": "needs_sms_code", "phone": "+15..."}
                      {"kind": "needs_2fa_password"}
                      {"kind": "login_complete"}
                      {"kind": "login_failed", "reason": "..."}
    swift -> bridge   {"kind": "sms_code", "value": "12345"}
                      {"kind": "2fa_password", "value": "..."}

If stdin is a TTY (standalone CLI run), the bridge falls back to
prompting via input() so the dev workflow still works without Swift.

Configuration
-------------
Preferred (set by the Swift host on launch):
    DUCTOR_AGENT_CONFIG_JSON   - JSON blob with the keys
        bot_username, agent_name, api_id, api_hash, phone

Legacy / standalone fallback envs (used by `bridge/README.md` instructions):
    JARVIS_BOT_USERNAME, JARVIS_PHONE, JARVIS_API_ID, JARVIS_API_HASH

Other envs:
    JARVIS_PORT_FILE   - if set, the bridge writes its chosen port here
                          right after binding (handshake for the parent).

The Telethon StringSession is cached via the `keyring` package
(service `ductor-companion`, account = agent_name). Sessions are scoped
per-agent so multiple sub-agents on the same Telegram account each get
their own cached login state.

CLI flags
---------
    --dry-run       Authenticate + resolve the configured bot username,
                    then exit 0 on success / non-zero on failure. Used by
                    the in-app setup wizard's "Test" button.
    --login-only    Bring up the websocket, perform Telegram auth
                    (prompting Swift for the SMS code / 2FA over the
                    websocket), cache the session, then exit. Used by
                    the first-run wizard before the main app launches
                    the bridge for real.
"""

from __future__ import annotations

import argparse
import asyncio
import base64
import contextlib
import json
import os
import socket
import sys
import time
from io import BytesIO
from pathlib import Path
from typing import Any, Awaitable, Callable, Optional, Set

try:
    import keyring  # type: ignore
except Exception:  # pragma: no cover - keyring optional
    keyring = None  # type: ignore

import websockets
from telethon import TelegramClient, events
from telethon.errors import SessionPasswordNeededError
from telethon.sessions import StringSession

KEYRING_SERVICE = "ductor-companion"
LOCAL_SESSION_DIR = Path(__file__).with_name(".sessions")


def _config_from_env() -> dict[str, str]:
    """Resolve agent config from either the JSON blob env or the legacy
    JARVIS_* envs. JSON blob wins when present."""
    blob = os.environ.get("DUCTOR_AGENT_CONFIG_JSON", "").strip()
    if blob:
        try:
            data = json.loads(blob)
            return {
                "agent_name": str(data.get("agent_name", "default")).strip() or "default",
                "bot_username": str(data.get("bot_username", "")).lstrip("@").strip(),
                "api_id": str(data.get("api_id", "")).strip(),
                "api_hash": str(data.get("api_hash", "")).strip(),
                "phone": str(data.get("phone", "")).strip(),
            }
        except json.JSONDecodeError as exc:
            print(f"[bridge] bad DUCTOR_AGENT_CONFIG_JSON: {exc}", file=sys.stderr)
    return {
        "agent_name": os.environ.get("JARVIS_BOT_USERNAME", "default").lstrip("@") or "default",
        "bot_username": os.environ.get("JARVIS_BOT_USERNAME", "").lstrip("@").strip(),
        "api_id": os.environ.get("JARVIS_API_ID", "").strip(),
        "api_hash": os.environ.get("JARVIS_API_HASH", "").strip(),
        "phone": os.environ.get("JARVIS_PHONE", "").strip(),
    }


# --------------------------------------------------------------------------- #
# Session persistence (scoped per-agent)
# --------------------------------------------------------------------------- #

def load_session(agent_name: str) -> str:
    if keyring is not None:
        try:
            stored = keyring.get_password(KEYRING_SERVICE, agent_name)
            if stored:
                return stored
        except Exception as exc:  # pragma: no cover - depends on backend
            print(f"[bridge] keyring read failed: {exc}", file=sys.stderr)
    fallback = LOCAL_SESSION_DIR / f"{agent_name}.session"
    if fallback.exists():
        return fallback.read_text(encoding="utf-8").strip()
    return ""


def save_session(agent_name: str, session: str) -> None:
    if keyring is not None:
        try:
            keyring.set_password(KEYRING_SERVICE, agent_name, session)
            return
        except Exception as exc:
            print(f"[bridge] keyring write failed: {exc}", file=sys.stderr)
    LOCAL_SESSION_DIR.mkdir(parents=True, exist_ok=True)
    fallback = LOCAL_SESSION_DIR / f"{agent_name}.session"
    fallback.write_text(session, encoding="utf-8")
    try:
        os.chmod(fallback, 0o600)
    except OSError:
        pass


# --------------------------------------------------------------------------- #
# Local websocket fan-out
# --------------------------------------------------------------------------- #

class Hub:
    def __init__(self) -> None:
        self.clients: Set[websockets.WebSocketServerProtocol] = set()

    async def register(self, ws: websockets.WebSocketServerProtocol) -> None:
        self.clients.add(ws)

    async def unregister(self, ws: websockets.WebSocketServerProtocol) -> None:
        self.clients.discard(ws)

    async def broadcast(self, payload: dict) -> None:
        if not self.clients:
            return
        msg = json.dumps(payload)
        await asyncio.gather(
            *(client.send(msg) for client in list(self.clients)),
            return_exceptions=True,
        )


# --------------------------------------------------------------------------- #
# Login coordinator — pumps SMS-code / 2FA prompts over the websocket
# instead of stdin so the in-app wizard can present a sheet.
# --------------------------------------------------------------------------- #

class LoginCoordinator:
    """Bridges Telethon's blocking auth prompts to async websocket messages.

    `request_code` / `request_password` broadcast a `needs_*` message and
    await a future that the websocket handler resolves when Swift replies.
    """

    def __init__(self, hub: Hub) -> None:
        self.hub = hub
        self._code_future: Optional[asyncio.Future] = None
        self._pwd_future: Optional[asyncio.Future] = None

    async def request_code(self, phone: str) -> str:
        loop = asyncio.get_event_loop()
        self._code_future = loop.create_future()
        await self.hub.broadcast({"kind": "needs_sms_code", "phone": phone})
        return await self._code_future

    async def request_password(self) -> str:
        loop = asyncio.get_event_loop()
        self._pwd_future = loop.create_future()
        await self.hub.broadcast({"kind": "needs_2fa_password"})
        return await self._pwd_future

    def deliver_code(self, value: str) -> None:
        if self._code_future is not None and not self._code_future.done():
            self._code_future.set_result(value)

    def deliver_password(self, value: str) -> None:
        if self._pwd_future is not None and not self._pwd_future.done():
            self._pwd_future.set_result(value)


def _stdin_is_tty() -> bool:
    try:
        return bool(sys.stdin and sys.stdin.isatty())
    except Exception:
        return False


# --------------------------------------------------------------------------- #
# Telegram auth
# --------------------------------------------------------------------------- #

async def _connect_authorized(
    config: dict[str, str],
    coordinator: Optional[LoginCoordinator] = None,
) -> Optional[TelegramClient]:
    """Connect + authenticate. Returns a logged-in TelegramClient or None.

    When `coordinator` is supplied AND stdin is not a TTY, SMS-code and
    2FA-password prompts are pushed over the websocket. Otherwise they
    fall back to stdin (legacy / dev path).
    """
    try:
        api_id = int(config["api_id"])
    except (TypeError, ValueError):
        print("[bridge] api_id missing or non-numeric", file=sys.stderr)
        return None
    api_hash = config["api_hash"]
    phone = config["phone"]
    agent_name = config["agent_name"]
    if not api_hash:
        print("[bridge] api_hash missing", file=sys.stderr)
        return None

    session = StringSession(load_session(agent_name))
    client = TelegramClient(session, api_id, api_hash)
    await client.connect()

    if not await client.is_user_authorized():
        if not phone:
            print("[bridge] phone missing — cannot start interactive login",
                  file=sys.stderr)
            return None
        await client.send_code_request(phone)
        use_ws = coordinator is not None and not _stdin_is_tty()
        if use_ws:
            code = (await coordinator.request_code(phone)).strip()
        else:
            code = input(f"Enter the Telegram code sent to {phone}: ").strip()
        try:
            await client.sign_in(phone=phone, code=code)
        except SessionPasswordNeededError:
            if use_ws:
                pwd = await coordinator.request_password()
            else:
                pwd = input("Enter your 2FA password: ")
            await client.sign_in(password=pwd)
        save_session(agent_name, client.session.save())
        print("[bridge] logged in; session cached.", file=sys.stderr)

    return client


# --------------------------------------------------------------------------- #
# Telegram <-> hub plumbing
# --------------------------------------------------------------------------- #

async def telegram_main(
    hub: Hub,
    inbound: asyncio.Queue,
    config: dict[str, str],
    coordinator: Optional[LoginCoordinator] = None,
) -> None:
    bot_username = config["bot_username"]
    if not bot_username:
        print("[bridge] bot_username missing — bridge idle.", file=sys.stderr)
        return

    client = await _connect_authorized(config, coordinator=coordinator)
    if client is None:
        return

    try:
        target = await client.get_entity(bot_username)
    except Exception as exc:
        print(f"[bridge] cannot resolve bot @{bot_username}: {exc}", file=sys.stderr)
        return

    target_id = target.id

    @client.on(events.NewMessage(from_users=target_id))
    async def on_message(event):  # type: ignore[no-redef]
        msg = event.message
        text = msg.message or ""
        has_media = msg.media is not None
        caption = msg.message if has_media else None
        await hub.broadcast({
            "kind": "jarvis_message",
            "text": text,
            "has_media": has_media,
            "media_caption": caption,
            "timestamp": time.time(),
        })

    async def outbound_loop() -> None:
        while True:
            item = await inbound.get()
            try:
                kind = item.get("kind")
                if kind == "user_text":
                    text = item.get("text") or ""
                    if text:
                        await client.send_message(target_id, text)
                elif kind == "heartbeat":
                    payload = item.get("data") or {}
                    await client.send_message(
                        target_id,
                        "[heartbeat] " + json.dumps(payload, separators=(",", ":")),
                    )
                elif kind == "screenshot":
                    b64 = item.get("png_base64") or ""
                    caption = item.get("caption") or "[screenshot]"
                    if not b64:
                        continue
                    raw = base64.b64decode(b64)
                    bio = BytesIO(raw)
                    bio.name = "screenshot.png"
                    await client.send_file(target_id, file=bio, caption=caption)
                else:
                    print(f"[bridge] ignoring unknown kind={kind}", file=sys.stderr)
            except Exception as exc:
                print(f"[bridge] outbound failed: {exc}", file=sys.stderr)

    print(f"[bridge] watching @{bot_username} ({target_id})", file=sys.stderr)
    await asyncio.gather(client.run_until_disconnected(), outbound_loop())


# --------------------------------------------------------------------------- #
# Websocket server
# --------------------------------------------------------------------------- #

async def ws_main(
    hub: Hub,
    inbound: asyncio.Queue,
    port_holder: list[int],
    coordinator: Optional[LoginCoordinator] = None,
) -> None:
    async def handler(ws: websockets.WebSocketServerProtocol) -> None:
        await hub.register(ws)
        try:
            async for raw in ws:
                try:
                    payload = json.loads(raw)
                except json.JSONDecodeError:
                    continue
                kind = payload.get("kind")
                # Login replies short-circuit straight to the coordinator;
                # they never appear in the outbound queue.
                if coordinator is not None and kind == "sms_code":
                    coordinator.deliver_code(str(payload.get("value", "")))
                    continue
                if coordinator is not None and kind == "2fa_password":
                    coordinator.deliver_password(str(payload.get("value", "")))
                    continue
                await inbound.put(payload)
        except websockets.ConnectionClosed:
            pass
        finally:
            await hub.unregister(ws)

    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    sock.listen(8)
    sock.setblocking(False)
    port_holder.append(port)

    port_file = os.environ.get("JARVIS_PORT_FILE", "")
    if port_file:
        try:
            Path(port_file).write_text(str(port), encoding="utf-8")
        except OSError as exc:
            print(f"[bridge] cannot write port file: {exc}", file=sys.stderr)

    print(f"[bridge] websocket listening on 127.0.0.1:{port}", file=sys.stderr)
    async with websockets.serve(handler, sock=sock):
        await asyncio.Future()


# --------------------------------------------------------------------------- #
# Dry-run mode
# --------------------------------------------------------------------------- #

async def dry_run(config: dict[str, str]) -> int:
    if not config["bot_username"]:
        print("[bridge] dry-run: bot_username missing", file=sys.stderr)
        return 2
    client = await _connect_authorized(config)
    if client is None:
        return 3
    try:
        target = await client.get_entity(config["bot_username"])
        print(f"[bridge] dry-run: resolved @{config['bot_username']} -> {target.id}",
              file=sys.stderr)
        return 0
    except Exception as exc:
        print(f"[bridge] dry-run: cannot resolve bot: {exc}", file=sys.stderr)
        return 4
    finally:
        await client.disconnect()


# --------------------------------------------------------------------------- #
# Login-only mode — wizard handshake
# --------------------------------------------------------------------------- #

async def login_only(config: dict[str, str]) -> int:
    """Bring up the websocket, authenticate (prompting Swift over WS),
    save the session, and exit.

    Used by the first-run wizard before the main app launches the
    long-lived bridge. Does NOT require bot_username to be set.
    """
    hub = Hub()
    inbound: asyncio.Queue = asyncio.Queue()
    coordinator = LoginCoordinator(hub)
    port_holder: list[int] = []

    ws_task = asyncio.create_task(ws_main(hub, inbound, port_holder, coordinator))

    # Wait for the wizard to connect before kicking off Telegram auth.
    deadline = time.time() + 60
    while time.time() < deadline and not hub.clients:
        await asyncio.sleep(0.1)
    if not hub.clients and not _stdin_is_tty():
        print("[bridge] no client connected within 60s; aborting login-only",
              file=sys.stderr)
        ws_task.cancel()
        with contextlib.suppress(Exception):
            await ws_task
        return 5

    client: Optional[TelegramClient] = None
    try:
        client = await _connect_authorized(config, coordinator=coordinator)
    except Exception as exc:
        print(f"[bridge] login-only auth crashed: {exc}", file=sys.stderr)
        await hub.broadcast({"kind": "login_failed", "reason": str(exc)})
        await asyncio.sleep(0.5)
        ws_task.cancel()
        with contextlib.suppress(Exception):
            await ws_task
        return 3

    if client is None:
        await hub.broadcast({"kind": "login_failed", "reason": "bad config"})
        await asyncio.sleep(0.5)
        ws_task.cancel()
        with contextlib.suppress(Exception):
            await ws_task
        return 3

    await hub.broadcast({"kind": "login_complete"})
    # Give the wizard a moment to receive the success message before we
    # tear everything down.
    await asyncio.sleep(0.5)
    with contextlib.suppress(Exception):
        await client.disconnect()
    ws_task.cancel()
    with contextlib.suppress(Exception):
        await ws_task
    return 0


# --------------------------------------------------------------------------- #
# Entry point
# --------------------------------------------------------------------------- #

async def amain(args: argparse.Namespace) -> int:
    config = _config_from_env()

    if args.dry_run:
        return await dry_run(config)
    if args.login_only:
        return await login_only(config)

    hub = Hub()
    inbound: asyncio.Queue = asyncio.Queue()
    coordinator = LoginCoordinator(hub)
    port_holder: list[int] = []

    ws_task = asyncio.create_task(ws_main(hub, inbound, port_holder, coordinator))
    tg_task = asyncio.create_task(telegram_main(hub, inbound, config, coordinator))

    done, pending = await asyncio.wait(
        {ws_task, tg_task},
        return_when=asyncio.FIRST_COMPLETED,
    )
    for task in pending:
        task.cancel()
        with contextlib.suppress(Exception):
            await task
    return 0


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dry-run", action="store_true",
                        help="Authenticate + resolve bot, then exit.")
    parser.add_argument("--login-only", action="store_true",
                        help="Authenticate (prompting via websocket), cache "
                             "the session, then exit. Used by the wizard.")
    args = parser.parse_args()
    try:
        rc = asyncio.run(amain(args))
        sys.exit(rc)
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
