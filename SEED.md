# Purpose

> See [[README#Purpose]].

## Normative Language

The key words MUST, MUST NOT, REQUIRED, SHALL, SHALL NOT, SHOULD, SHOULD NOT, RECOMMENDED, MAY, and OPTIONAL in this document are to be interpreted as described in RFC 2119.

`Implementation-defined` means the behavior is part of the implementation contract; this specification does not prescribe a single policy.

Sub-folder SEEDs in this tree inherit the RFC 2119 declaration. They MUST NOT re-declare it.

## Dependencies

### API

- The Plow Chat API surface — endpoints, headers, WebSocket frame types, auth model, chat creation, and verification semantics — is defined by the external SEED at `https://github.com/plow-pbc/seed-plow-chat`. A consumer MUST read that SEED first; this SEED depends on its `## Objects` and `## Actions` and does not restate them. ^dep-plow-chat-seed

### Runtime

- Hermes Agent MUST run in the Docker-backed `seed-hermes` shape: a host `compose.yaml`, whole `./data:/opt/data` mount, and `HERMES_HOME=/opt/data` inside the container. ^dep-hermes-docker
- Hermes' container runtime MUST have gateway/plugin support and Python `aiohttp`; the official Hermes image supplies the runtime dependencies for this plugin. ^dep-container-runtime
- The host setup path MUST NOT require host `hermes`, host Python, git, `hermes plugins install`, `GH_TOKEN`, or container-side network/plugin installation. ^dep-host-minimal
- The host setup path MAY use `curl` and standard shell tools. `gh` MAY be used by a higher-level seed as an accelerator, but it is not required by this SEED. ^dep-curl

## Objects

The named entities that exist on the Hermes side. For Plow Chat entities (chats, lines, members, messages, WebSocket frames), see [[https://github.com/plow-pbc/seed-plow-chat/blob/main/SEED.md#Objects]].

### plow_chat Hermes platform

- A Hermes gateway platform named `plow_chat`. ^obj-platform
- It maps a Plow chat to a Hermes session source with `platform='plow_chat'`, `chat_id=<chat.uid>`, `chat_type='dm'`, and member sender metadata as the user identity.
- It sends plain text responses through Plow's message creation endpoint.
- It receives user messages by minting short-lived WebSocket tickets and subscribing to `wss://chat.plow.co/v1/ws?ticket=<ticket>`.

### Direct-mounted plugin

- The plugin MUST be placed on the host at `./data/plugins/plow-chat-platform/`, which the Hermes container sees as `/opt/data/plugins/plow-chat-platform/`. ^obj-direct-plugin
- The mounted plugin directory MUST include `plugin.yaml`, `__init__.py`, and `ref/hermes-plugin/plow_chat/adapter.py`, preserving that layout. ^obj-required-files
- The root `__init__.py` MUST load and re-export `register(ctx)` from `ref/hermes-plugin/plow_chat/adapter.py`; if that adapter file is missing, it MUST raise `ImportError` at boot. ^obj-root-entrypoint
- Hermes config MUST enable the manifest name `plow-chat-platform` in `plugins.enabled`; the registered platform name remains `plow_chat`. ^obj-plugin-enable

### Host orchestration scripts

- `ref/scripts/install_direct_mount.sh` is a curl/shell helper that places the required plugin file set under `./data/plugins/plow-chat-platform/` and enables `plow-chat-platform` in `./data/config.yaml`. ^obj-direct-install-script
- `ref/scripts/create_plow_chat_curl.sh` is a curl/shell helper that creates a Plow chat, prints the one-time verification code, writes `PLOW_CHAT_*` to `./data/.env`, and polls `GET /v1/chats/{chat_uid}` until `active` or timeout. ^obj-curl-chat-script

## Actions

The verbs performed by the Hermes-side objects. For Plow Chat actions (chat is created, chat is verified, message is sent, WebSocket subscription is opened, message is received), see [[https://github.com/plow-pbc/seed-plow-chat/blob/main/SEED.md#Actions]].

### plow_chat is installed by direct mount

- A host agent MUST place the plugin files directly into `./data/plugins/plow-chat-platform/`; it MUST NOT call `hermes plugins install`, `hermes plugins enable`, `git clone`, or any Python installer on the host. ^act-direct-mount
- A host agent MUST ensure `./data/config.yaml` exists before first `docker compose up` and contains `plugins.enabled` with `plow-chat-platform`. ^act-enable-config
- A host agent SHOULD preserve any existing `config.yaml` values while adding this plugin. If no config exists, it MAY write the minimal plugin/terminal skeleton shown in the README. ^act-config-preserve

### plow_chat is configured with Plow chat credentials

- A host agent MUST create the Plow chat before first Hermes boot for this gateway and write these values into `./data/.env`: `PLOW_CHAT_BASE_URL`, `PLOW_CHAT_CHAT_UID`, `PLOW_CHAT_SECRET_KEY`, and `PLOW_CHAT_HOME_CHANNEL`. ^act-write-env
- The chat secret MUST be configured through `PLOW_CHAT_SECRET_KEY`; it MUST NOT be committed, printed in logs, or placed in `config.yaml`. ^act-secret-env
- When `PLOW_CHAT_CHAT_UID` and `PLOW_CHAT_SECRET_KEY` are present, the plugin's `env_enablement_fn` SHOULD auto-enable `gateway.platforms.plow_chat` and set its home channel to the Plow chat uid. ^act-env-auto-enable

### Host creates and polls Plow chat with curl

- The host flow MUST create a chat with unauthenticated `POST /v1/chats`, capture the response `uid`, one-time `secret_key`, and member `verification_code`, and surface the verification code plus line `provider_key` to the human. ^act-curl-create
- The host flow MUST poll `GET /v1/chats/{chat_uid}` with `X-Chat-Secret-Key: <secret>` until the chat status is `active`, `failed`, or a local timeout expires. ^act-curl-poll
- The timeout path MUST tell the operator that the verification may not have arrived, Hermes may not have been running to send the welcome, or the code may have expired; recovery is to recreate the chat. ^act-timeout

### plow_chat sends a Hermes response

- The platform adapter implements the [[https://github.com/plow-pbc/seed-plow-chat/blob/main/SEED.md#Actions]] "Message is sent" action against the configured chat. ^act-send
- The adapter SHOULD strip or flatten rich markdown because the current backing channel is iMessage/SMS-style chat.
- The adapter MUST treat 409 `chat_not_ready` as a setup/verification problem, not a successful send.

### plow_chat receives a user message

- The adapter implements the [[https://github.com/plow-pbc/seed-plow-chat/blob/main/SEED.md#Actions]] "WebSocket subscription is opened" and "Message is received" actions. ^act-receive
- For inbound frames, the adapter constructs a Hermes `MessageEvent` with the message body, Plow message uid, chat uid, and member sender uid/name.
- Before dispatching an inbound member message into Hermes, the adapter SHOULD best-effort approve that member uid in Hermes' `plow_chat` pairing store so the verified Plow participant does not hit a second generic DM pairing flow. ^act-auto-pair
- On disconnect, the adapter SHOULD reconnect by minting a fresh ticket and SHOULD backfill missed messages with `GET /v1/chats/{chat_uid}/messages`.

### plow_chat handles status and activation frames

- The adapter MAY log `message_status_updated` frames for outbound delivery transitions. ^act-status
- The adapter SHOULD subscribe while the Plow chat is still pending and, on `chat_active`, send exactly one setup-success welcome message through the normal Plow message endpoint. ^act-activation-welcome
- The adapter SHOULD surface `chat_activation_failed` as a fatal setup error, because recovery is delete and recreate.
- The adapter SHOULD mark the platform connected only after the WebSocket's initial `connected` frame.

## Verify

1. **Direct file-set check.** Run `ref/scripts/install_direct_mount.sh --data-dir "$(mktemp -d)/data" --source-dir .`. Does it create `plugins/plow-chat-platform/plugin.yaml`, `plugins/plow-chat-platform/__init__.py`, and `plugins/plow-chat-platform/ref/hermes-plugin/plow_chat/adapter.py`? Expected: yes. ^v-direct-files

2. **Config enablement check.** Inspect the generated `config.yaml`. Does `plugins.enabled` include `plow-chat-platform` before first boot? Expected: yes. ^v-config-enabled

3. **Hermes adapter-shape check.** Inspect `ref/hermes-plugin/plow_chat/adapter.py`. Does it define a `PlowChatAdapter` implementing `connect`, `disconnect`, and `send`, and a `register(ctx)` function that registers platform name `plow_chat`? Expected: yes. ^v-adapter-shape

4. **Host shell syntax check.** Run `bash -n ref/scripts/install_direct_mount.sh ref/scripts/create_plow_chat_curl.sh`. Does it exit 0? Expected: yes. ^v-shell-syntax

5. **Secret hygiene check.** Search committed files. Do they avoid literal `sk_` chat secrets and one-time verification codes? Expected: yes. ^v-secret-hygiene

6. **Container plugin-load check.** Prepare `./data` with the direct file set, `plugins.enabled: [plow-chat-platform]`, and dummy or real `PLOW_CHAT_*`; run `docker compose up`. Do logs show platform `plow_chat` registered and no `ImportError` from the plugin root? Expected: yes. ^v-container-load

7. **Optional live chat check.** With a real Plow line, run `ref/scripts/create_plow_chat_curl.sh --data-dir ./data --line-id <line>`, start Hermes, text the printed verification code from iMessage, and let the script poll. Does it report `active`, and does Hermes send one welcome message on `chat_active`? Expected: yes. ^v-live-chat

## Open

- The sample plugin does not implement media attachments, streaming draft edits, delete-message, or native button UI for clarify prompts. ^o-media
- The sample plugin does not yet include production-grade reconnect backfill cursor persistence; it documents the expected behavior and includes a simple reconnect loop. ^o-backfill
- The Plow Chat API is pre-1.0 and may change without backwards compatibility guarantees; see [[seed-plow-chat#Open]]. ^o-api-stability

## Non-Goals

- This SEED does not document the Plow Chat API; see [[seed-plow-chat]]. ^ng-api
- This SEED does not store or publish chat secrets, verification codes, phone numbers, or provider identities.
- This SEED does not require modifying Hermes core; a plugin-based adapter is the preferred shape when supported.
- This SEED does not install or enable Hermes plugins through the Hermes CLI on the target path.
