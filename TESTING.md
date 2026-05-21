# Testing

## Maintainer checks

```bash
ref/verify.sh
pytest -q
```

These checks prove the direct-mounted file set is complete, `config.yaml`
enables `plow-chat-platform`, host helper scripts are syntax-valid, the adapter
shape is intact, and committed files do not contain literal Plow secrets or
real verification codes.

## Container plugin-load check

From a disposable Hermes host folder:

```bash
mkdir -p data
ref/scripts/install_direct_mount.sh --data-dir ./data --source-dir /path/to/seed-hermes-plow-chat
cat >> data/.env <<'EOF'
PLOW_CHAT_BASE_URL=https://chat.plow.co
PLOW_CHAT_CHAT_UID=cht_dummy_for_load_check
PLOW_CHAT_SECRET_KEY=dummy_for_load_check
PLOW_CHAT_HOME_CHANNEL=cht_dummy_for_load_check
EOF
docker compose up
```

Expected evidence:

- Hermes discovers and enables manifest `plow-chat-platform`.
- Gateway logs show platform `plow_chat` registered.
- No `ImportError` references `ref/hermes-plugin/plow_chat/adapter.py`.

The dummy secret is only for import/load verification. The WebSocket ticket
request may fail later because the chat credentials are not real.

## Live Plow verification run

```bash
mkdir -p data
ref/scripts/install_direct_mount.sh --data-dir ./data --source-dir .
ref/scripts/create_plow_chat_curl.sh --data-dir ./data
```

The script auto-discovers a line. For demo hygiene, pin one with
`--line ln_YOUR_DEMO_LINE` or `PLOW_CHAT_LINE=ln_YOUR_DEMO_LINE`.

In a second terminal, start Hermes before texting the code:

```bash
docker compose up
```

Then text the printed `VERIFY-XXXXXX` code from iMessage to the printed Plow
line. The host script should report:

```text
Status: pending
Status: active
Verified: chat is active.
```

Expected Hermes evidence:

- The adapter receives `chat_active`.
- Hermes sends exactly one welcome message to the iMessage thread.
- A normal reply from iMessage is delivered to Hermes as a `plow_chat` inbound
  message.

If the poll times out, recreate the chat. Common causes are Hermes not running
before verification, the code expiring, texting from the wrong messaging
identity, or using a shared/noisy demo line.
