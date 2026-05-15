# Purpose

> See [[README#Purpose]].

## Normative Language

The key words MUST, MUST NOT, REQUIRED, SHALL, SHALL NOT, SHOULD, SHOULD NOT, RECOMMENDED, MAY, and OPTIONAL in this document are to be interpreted as described in RFC 2119.

`Implementation-defined` means the behavior is part of the implementation contract; this specification does not prescribe a single policy.

Sub-folder SEEDs in this tree inherit the RFC 2119 declaration. They MUST NOT re-declare it.

## Dependencies

### API

- The Plow Chat API surface — endpoints, headers, WebSocket frame types, auth model — is defined by the external SEED at `https://github.com/plow-pbc/seed-plow-chat`. An installer MUST install that SEED first; this SEED depends on its `## Objects` and `## Actions` and does not restate them. ^dep-plow-chat-seed

### Software

- Hermes Agent MUST be installed with gateway/plugin support (`gateway/platforms/base.py`, `gateway/platform_registry.py`, plugin discovery under `~/.hermes/plugins/`). ^dep-hermes
- Python MUST have `aiohttp` available for the reference adapter's REST and WebSocket client. ^dep-aiohttp
- A fresh Hermes SHOULD install this SEED directly as a Git plugin from the repository root: `hermes plugins install <git-url-or-file-url> --enable`. The root `plugin.yaml` and `__init__.py` load the reference adapter from `ref/hermes-plugin/plow_chat/`. ^dep-plugin-install

## Objects

The named entities that exist on the Hermes side. For Plow Chat entities (chats, lines, members, messages, WebSocket frames), see [[https://github.com/plow-pbc/seed-plow-chat/blob/main/SEED.md#Objects]].

### plow_chat Hermes platform

- A Hermes gateway platform named `plow_chat`. ^obj-platform
- It maps a Plow chat to a Hermes session source with `platform='plow_chat'`, `chat_id=<chat.uid>`, `chat_type='dm'`, and member sender metadata as the user identity.
- It sends plain text responses through Plow's message creation endpoint.
- It receives user messages by minting short-lived WebSocket tickets and subscribing to `wss://chat.plow.co/v1/ws?ticket=<ticket>`.

### Reference plugin

- The repository root is an installable Hermes plugin because it contains `plugin.yaml` and `__init__.py`. ^obj-root-plugin
- Root `__init__.py` loads and re-exports `register(ctx)` from `ref/hermes-plugin/plow_chat/adapter.py`, so `hermes plugins install <this repo> --enable` registers platform `plow_chat`. ^obj-root-entrypoint
- The folder `ref/hermes-plugin/plow_chat/` contains the readable Hermes plugin files for `plow_chat`. ^obj-ref-plugin

### Reference helper scripts

- `ref/scripts/configure_hermes_env.py` writes `PLOW_CHAT_*` values from a local state file into Hermes' `.env` without printing the secret. ^obj-configure-env-script
- `ref/scripts/bootstrap_fresh_hermes.sh` installs this SEED into Hermes, optionally clones the [[seed-plow-chat]] dependency to create a chat via its `ref/examples/create_chat.py`, and configures Hermes env from the resulting state file. ^obj-bootstrap-script

## Actions

The verbs performed by the Hermes-side objects. For Plow Chat actions (chat is created, chat is verified, message is sent, WebSocket subscription is opened, message is received), see [[https://github.com/plow-pbc/seed-plow-chat/blob/main/SEED.md#Actions]].

### plow_chat sends a Hermes response

- The platform adapter implements the [[https://github.com/plow-pbc/seed-plow-chat/blob/main/SEED.md#Actions]] "Message is sent" action against the configured chat. ^act-send
- The adapter SHOULD strip or flatten rich markdown because the current backing channel is iMessage/SMS-style chat.
- The adapter MUST treat 409 `chat_not_ready` as a setup/verification problem, not a successful send.

### plow_chat receives a user message

- The platform adapter implements the [[https://github.com/plow-pbc/seed-plow-chat/blob/main/SEED.md#Actions]] "WebSocket subscription is opened" and "Message is received" actions. ^act-receive
- For inbound frames, the adapter constructs a Hermes `MessageEvent` with the message body, Plow message uid, chat uid, and member sender uid/name.
- On disconnect, the adapter SHOULD reconnect by minting a fresh ticket and SHOULD backfill missed messages with `GET /v1/chats/{chat_uid}/messages`.

### plow_chat handles status and activation frames

- The adapter MAY log `message_status_updated` frames for outbound delivery transitions. ^act-status
- The adapter SHOULD surface `chat_activation_failed` as a fatal setup error, because recovery is delete and recreate.
- The adapter SHOULD mark the platform connected only after the WebSocket's initial `connected` frame.

### plow_chat is configured in Hermes

- A fresh Hermes MAY install this SEED directly with `hermes plugins install <git-url-or-file-url> --enable`; plugin discovery MUST call root `register(ctx)` and register platform `plow_chat`. ^act-install-plugin
- A Hermes install SHOULD configure the platform with these non-secret values in `config.yaml` or equivalent plugin config: `base_url`, `chat_uid`, and optionally `home_channel`. ^act-config
- The chat secret MUST be configured through an environment variable (`PLOW_CHAT_SECRET_KEY`), not committed config.
- A reasonable env-only setup is: `PLOW_CHAT_BASE_URL=https://chat.plow.co`, `PLOW_CHAT_CHAT_UID=<cht_...>`, `PLOW_CHAT_SECRET_KEY=<sk_...>`, `PLOW_CHAT_HOME_CHANNEL=<cht_...>`.
- When `PLOW_CHAT_CHAT_UID` and `PLOW_CHAT_SECRET_KEY` are present, the plugin's `env_enablement_fn` SHOULD auto-enable `gateway.platforms.plow_chat` and set its home channel to the Plow chat uid. ^act-env-auto-enable

## Verify

1. **Hermes adapter-shape check.** Inspect `ref/hermes-plugin/plow_chat/adapter.py`. Does it define a `PlowChatAdapter` implementing `connect`, `disconnect`, and `send`, and a `register(ctx)` function that registers platform name `plow_chat`? Expected: yes. ^v-adapter-shape

2. **Root plugin installability check.** Inspect repository root. Does it contain `plugin.yaml` with `kind: platform` and `__init__.py` exporting `register(ctx)`? Expected: yes. ^v-root-plugin

3. **Env writer check.** Run `python3 -m py_compile ref/scripts/configure_hermes_env.py` and test it against a dummy state file. Does it write `PLOW_CHAT_BASE_URL`, `PLOW_CHAT_CHAT_UID`, `PLOW_CHAT_SECRET_KEY`, and `PLOW_CHAT_HOME_CHANNEL` without printing the secret? Expected: yes. ^v-env-writer

4. **Secret hygiene check.** Search committed files. Do they avoid literal `sk_` chat secrets and one-time verification codes? Expected: yes. ^v-secret-hygiene

5. **Optional live chat check.** If the installer has created a local state file containing a Plow chat uid and secret, run the [[seed-plow-chat]] dep's `ref/examples/check_chat.py <state-file>`. Does it report `active` after the user texts the verification code, or `pending` before verification? Expected: active for a completed install. ^v-live-chat

## Open

- The sample plugin does not implement media attachments, streaming draft edits, delete-message, or native button UI for clarify prompts. ^o-media
- The sample plugin does not yet include production-grade reconnect backfill cursor persistence; it documents the expected behavior and includes a simple reconnect loop. ^o-backfill
- User-installed Hermes platform plugins must be enabled (`hermes plugins install ... --enable` or `hermes plugins enable plow-chat-platform`) before gateway plugin discovery will load them. ^o-plugin-enable
- The Plow Chat API is pre-1.0 and may change without backwards compatibility guarantees; see [[seed-plow-chat#Open]]. ^o-api-stability

## Non-Goals

- This SEED does not document the Plow Chat API; see [[seed-plow-chat]]. ^ng-api
- This SEED does not store or publish chat secrets, verification codes, phone numbers, or provider identities.
- This SEED does not require modifying Hermes core; a plugin-based adapter is the preferred shape when supported.
