# Hermes Plow Chat Platform Adapter SEED

## Purpose

This SEED provides the Hermes gateway platform plugin named `plow_chat`. It
wires Hermes to the [Plow Chat](https://github.com/plow-pbc/seed-plow-chat)
API: Hermes sends replies through `POST /v1/chats/{chat_uid}/messages` and
receives user replies from Plow's WebSocket stream.

The target install model is direct mount into Docker-backed Hermes data. The
host places this repository's plugin files under
`./data/plugins/plow-chat-platform/`, pre-enables the manifest name in
`./data/config.yaml`, writes `PLOW_CHAT_*` to `./data/.env`, and then starts the
Hermes container. The host does not run `hermes plugins install`, clone git
repositories, or depend on Python.

## Required plugin files

The mounted plugin directory must contain this exact file set:

```text
data/plugins/plow-chat-platform/
  plugin.yaml
  __init__.py
  ref/hermes-plugin/plow_chat/adapter.py
```

`plugin.yaml` is the manifest Hermes discovers. `__init__.py` loads
`ref/hermes-plugin/plow_chat/adapter.py` and raises `ImportError` during boot if
the adapter is missing, so preserving that layout is required.

## Direct-mount install

From the host folder that contains `compose.yaml` and `data/`:

```bash
mkdir -p data
curl -fsSL https://raw.githubusercontent.com/plow-pbc/seed-hermes-plow-chat/main/ref/scripts/install_direct_mount.sh \
  -o /tmp/install_plow_chat.sh
bash /tmp/install_plow_chat.sh --data-dir ./data
```

When running from a local checkout, avoid network fetches by copying from the
checkout:

```bash
ref/scripts/install_direct_mount.sh --data-dir ./data --source-dir .
```

The resulting `data/config.yaml` must include the manifest name:

```yaml
plugins:
  enabled:
    - plow-chat-platform
  disabled: []
terminal:
  cwd: /opt/data/workspace
```

## Create and verify a Plow chat

Use the curl-only host helper to create the chat, capture the one-time verify
code, write `PLOW_CHAT_*` to `./data/.env`, and poll status:

```bash
ref/scripts/create_plow_chat_curl.sh \
  --data-dir ./data
```

The script auto-discovers an available line with unauthenticated
`GET /v1/lines`, uses the first returned line by default, and prints the
instruction the user needs: `Text VERIFY-XXXXXX from iMessage to +1...`. It
does not print the chat secret. Start Hermes with `docker compose up` before
texting the code so the plugin is subscribed when Plow emits `chat_active`.

For controlled demos, pin a specific line with `--line ln_...` or
`PLOW_CHAT_LINE=ln_...` to avoid shared-line collisions. This override is
optional; normal users should not supply or know a line uid.

The host poll uses:

```bash
curl -fsSL \
  -H "X-Chat-Secret-Key: <secret>" \
  "https://chat.plow.co/v1/chats/<chat_uid>"
```

When the chat becomes `active`, the adapter sends exactly one welcome message
from Hermes through the normal Plow message endpoint. Set
`PLOW_CHAT_WELCOME_MESSAGE` to customize it or
`PLOW_CHAT_AUTO_WELCOME=false` to disable it.

## Runtime behavior

- `PLOW_CHAT_CHAT_UID` is the single Plow chat handled by this plugin instance.
- `PLOW_CHAT_SECRET_KEY` stays in `./data/.env`; do not commit it or log it.
- The adapter subscribes while the chat is still pending and sends the welcome
  on the first `chat_active` frame only.
- Inbound WebSocket frames with `direction=outbound` are ignored so Hermes does
  not answer itself.
- The adapter best-effort approves verified Plow member ids in Hermes'
  `plow_chat` pairing store so the first inbound message reaches Hermes.
- Rich Markdown is flattened to plain text because the backing channel is
  iMessage/SMS-style.

## License

MIT.
