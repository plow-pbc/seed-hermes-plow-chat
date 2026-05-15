# Hermes Plow Chat Platform Adapter SEED

## Purpose

This SEED installs a Hermes Agent custom gateway platform named `plow_chat` that wires Hermes into the [Plow Chat](https://github.com/plow-pbc/seed-plow-chat) API — sending Hermes responses through `POST /v1/chats/{chat_uid}/messages` and receiving user replies over the Plow Chat WebSocket stream at `/v1/ws`.

The repository root is also an installable Hermes plugin. A fresh Hermes can point directly at this SEED with `hermes plugins install <git-url-or-file-url> --enable`; the root `plugin.yaml` and `__init__.py` load the reference adapter from `ref/hermes-plugin/plow_chat/`.

## Dependencies

- [`seed-plow-chat`](https://github.com/plow-pbc/seed-plow-chat) — the API surface (endpoints, frame types, auth model) is defined there, not restated here. The bootstrap script clones it on demand to `~/.cache/seed-plow-chat/` and uses its example scripts for chat creation and status checks.
- Hermes Agent with gateway/plugin support.
- Python `aiohttp` available to Hermes' runtime.

## Quick start: fresh Hermes -> Plow Chat

From a fresh Hermes install with this SEED checked out:

```bash
cd seed-hermes-plow-chat
ref/scripts/bootstrap_fresh_hermes.sh --line-id ln_YOUR_PLOW_LINE_ID
```

Find an available `--line-id` with `curl -s https://chat.plow.co/v1/lines | jq '.data[].uid'` — pick the line you want Hermes to message users through.

The script installs this repo as a Hermes plugin, clones [`seed-plow-chat`](https://github.com/plow-pbc/seed-plow-chat) to `~/.cache/seed-plow-chat/` if it's not already there, creates a Plow chat, writes the Hermes env vars, and prints a `VERIFY-XXXXXX` code plus the Plow line. Text that code to the line from the phone/iMessage account that should talk to Hermes.

Then start or restart the gateway immediately, even before verification:

```bash
hermes gateway restart
```

The adapter can connect to Plow's WebSocket while the chat is still pending. When the user texts the verification code, Plow emits `chat_active`; Hermes sends a welcome message automatically and auto-approves the verified Plow member in Hermes' DM pairing store. The user's first normal reply should go straight to Hermes instead of receiving a generic pairing-code prompt.

Manual install path:

```bash
hermes plugins install "file://$(pwd)" --force --enable
git clone https://github.com/plow-pbc/seed-plow-chat.git ~/.cache/seed-plow-chat
python3 ~/.cache/seed-plow-chat/ref/examples/create_chat.py --state ~/.hermes/plow_chat_state.json
python3 ref/scripts/configure_hermes_env.py ~/.hermes/plow_chat_state.json
hermes gateway restart
# text the VERIFY code; Hermes will send the welcome message on chat_active
```

## Important behavior

- The chat secret is written only to the local state file and Hermes `.env`; it is not printed by the setup helper.
- The adapter is one-chat-per-plugin-instance: `PLOW_CHAT_CHAT_UID` is the Hermes chat id and home channel.
- The adapter subscribes to the WebSocket before activation, sends one welcome message on `chat_active`, and can be customized with `PLOW_CHAT_WELCOME_MESSAGE` or disabled with `PLOW_CHAT_AUTO_WELCOME=false`.
- The adapter best-effort approves verified Plow member ids in Hermes' `plow_chat` pairing store so the first inbound message does not trigger a second pairing flow. Disable with `PLOW_CHAT_AUTO_APPROVE_PAIRING=false`.
- Inbound WebSocket frames with `direction=outbound` are ignored so Hermes does not answer itself.
- Rich Markdown is flattened to plain text because the backing channel is iMessage/SMS-style.

## License

MIT.
