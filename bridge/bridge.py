#!/usr/bin/env python3
"""Telegram <-> Ductor Companion bridge. See bridge/README.md."""

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
from typing import Optional, Set

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


class LoginCoordinator:
    """Bridges Telethon prompts to websocket messages."""

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


async def _connect_authorized(
    config: dict[str, str],
    coordinator: Optional[LoginCoordinator] = None,
) -> Optional[TelegramClient]:
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


async def login_only(config: dict[str, str]) -> int:
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
