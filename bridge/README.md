# jarvis-bridge (standalone)

This is a development copy of the Python bridge that the Jarvis macOS app
launches as a child process. You can run it on its own from a terminal —
useful for first-time Telegram login (the interactive code + 2FA prompts)
and for debugging the websocket protocol.

## 1. Telegram API credentials

Telethon authenticates as a **user account** (not a bot), so you need
your own Telegram `api_id` / `api_hash`:

1. Open https://my.telegram.org/apps and log in with the same phone number
   you'll use with Jarvis.
2. Create a new application (any name; "Jarvis Pet" is fine).
3. Copy the `App api_id` and `App api_hash`.

## 2. Install dependencies

```bash
cd bridge
python3.11 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

## 3. Configure and run

```bash
export JARVIS_API_ID=1234567
export JARVIS_API_HASH=abcdef0123456789abcdef0123456789
export JARVIS_BOT_USERNAME=jarvis_yourname_bot
export JARVIS_PHONE=+15551234567
export JARVIS_PORT_FILE=/tmp/jarvis-bridge.port

python bridge.py
```

On first run Telethon will prompt for the SMS code (and 2FA password if
you have one). After a successful login the StringSession is stored in
macOS Keychain (service `jarvis-pet`, account = your phone number), so
subsequent launches are silent.

## 4. Talking to the bridge

After startup the bridge prints something like:

```
[bridge] websocket listening on 127.0.0.1:54931
[bridge] watching @jarvis_yourname_bot (123456789)
```

You can connect any websocket client to that URL (the Jarvis app does
this for you). Outbound messages from the bot will arrive as JSON:

```json
{"kind":"jarvis_message","text":"...","has_media":false,"timestamp":...}
```

You can send messages back:

```json
{"kind":"user_text","text":"hi jarvis"}
{"kind":"heartbeat","data":{"frontmost_app":"Xcode","idle_seconds":3}}
{"kind":"screenshot","png_base64":"iVBORw0KG...","caption":"[screenshot] frontmost=Xcode"}
```

## 5. Clearing the cached session

If you need to log out (e.g. switching accounts):

```bash
python -c "import keyring; keyring.delete_password('jarvis-pet', '+15551234567')"
# or, if you don't use keyring:
rm bridge/.jarvis-session
```
