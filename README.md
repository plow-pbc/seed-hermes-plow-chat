# Plow Chat Hermes Platform Adapter SEED

## Purpose

This SEED captures the capability of installing a Hermes Agent custom gateway platform named `plow_chat`. The platform uses the Plow Chat API to create and bind an inbound-first chat, send Hermes responses through `POST /v1/chats/{chat_uid}/messages`, and receive user replies through the Plow Chat WebSocket stream at `/v1/ws`.

The repository root is also an installable Hermes plugin. A fresh Hermes can point directly at this SEED with `hermes plugins install <git-url-or-file-url> --enable`; the root `plugin.yaml` and `__init__.py` load the reference adapter from `ref/hermes-plugin/plow_chat/`.

## Quick start: fresh Hermes -> Plow Chat

From a fresh Hermes install with this SEED checked out:

```bash
cd seed-plow-chat
ref/scripts/bootstrap_fresh_hermes.sh --line-id ln_JakRCMmHRfQBAkG6f6X6FQ
```

The script installs this repo as a Hermes plugin, creates a Plow chat, and prints a `VERIFY-XXXXXX` code plus the Plow line returned by the API. Text that code to the line from the phone/iMessage account that should talk to Hermes.

After verification:

```bash
python3 ref/scripts/check_chat.py ~/.hermes/plow_chat_state.json
ref/scripts/bootstrap_fresh_hermes.sh --skip-create
hermes gateway restart
```

Then send a normal message in the verified Plow Chat thread. Hermes should receive it through the `plow_chat` gateway adapter and reply through the same thread.

Manual install path:

```bash
hermes plugins install "file://$(pwd)" --force --enable
python3 ref/scripts/create_chat.py --state ~/.hermes/plow_chat_state.json
# text the VERIFY code, then:
python3 ref/scripts/configure_hermes_env.py ~/.hermes/plow_chat_state.json
hermes gateway restart
```

## Important behavior

- The chat secret is written only to the local state file and Hermes `.env`; it is not printed by the setup helper.
- The adapter is one-chat-per-plugin-instance: `PLOW_CHAT_CHAT_UID` is the Hermes chat id and home channel.
- Inbound WebSocket frames with `direction=outbound` are ignored so Hermes does not answer itself.
- Rich Markdown is flattened to plain text because the backing channel is iMessage/SMS-style.

## License

MIT.
