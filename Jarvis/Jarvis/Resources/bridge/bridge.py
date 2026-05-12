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
    --dry-run    Authenticate + resolve the configured bot username,
                 then exit 0 on success / non-zero on failure. Used by
                 the in-app setup wizard's "Test" button.
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
from typing import Any, Optional, Set

try:
    import keyring  # type: ignore
except Exception:  # pragma: no cover - keyring optional
    keyring = None  # type: ignore

import websockets
from telethon import TelegramClient, events
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


async def _connect_authorized(config: dict[str, str]) -> Optional[TelegramClient]:
    """Connect + authenticate. Returns a logged-in TelegramClient or None."""
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
        code = input(f"Enter the Telegram code sent to {phone}: ").strip()
        try:
            await client.sign_in(phone=phone, code=code)
        except Exception as exc:
            from telethon.errors import SessionPasswordNeededError
            if isinstance(exc, SessionPasswordNeededError):
                pwd = input("Enter your 2FA password: ")
                await client.sign_in(password=pwd)
            else:
                raise
        save_session(agent_name, client.session.save())
        print("[bridge] logged in; session cached.", file=sys.stderr)

    return client


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
# Telegram <-> hub plumbing
# --------------------------------------------------------------------------- #

async def telegram_main(hub: Hub, inbound: asyncio.Queue, config: dict[str, str]) -> None:
    bot_username = config["bot_username"]
    if not bot_username:
        print("[bridge] bot_username missing — bridge idle.", file=sys.stderr)
        return

    client = await _connect_authorized(config)
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

async def ws_main(hub: Hub, inbound: asyncio.Queue, port_holder: list[int]) -> None:
    async def handler(ws: websockets.WebSocketServerProtocol) -> None:
        await hub.register(ws)
        try:
            async for raw in ws:
                try:
                    payload = json.loads(raw)
                except json.JSONDecodeError:
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
# Entry point
# --------------------------------------------------------------------------- #

async def amain(args: argparse.Namespace) -> int:
    config = _config_from_env()

    if args.dry_run:
        return await dry_run(config)

    hub = Hub()
    inbound: asyncio.Queue = asyncio.Queue()
    port_holder: list[int] = []

    ws_task = asyncio.create_task(ws_main(hub, inbound, port_holder))
    tg_task = asyncio.create_task(telegram_main(hub, inbound, config))

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
    args = parser.parse_args()
    try:
        rc = asyncio.run(amain(args))
        sys.exit(rc)
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
