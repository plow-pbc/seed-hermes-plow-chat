# Purpose

> See [[README#Purpose]].

## Normative Language

The key words MUST, MUST NOT, REQUIRED, SHALL, SHALL NOT, SHOULD, SHOULD NOT, RECOMMENDED, MAY, and OPTIONAL in this document are to be interpreted as described in RFC 2119.

`Implementation-defined` means the behavior is part of the implementation contract; this specification does not prescribe a single policy.

Sub-folder SEEDs in this tree inherit the RFC 2119 declaration. They MUST NOT re-declare it.

## Dependencies

### API

- The Plow Chat API MUST be reachable at `https://chat.plow.co`. ^dep-api
- The API schema is published at `https://chat.plow.co/v1/openapi.json`. ^dep-openapi
- No caller-wide API key is required by the current pre-1.0 API surface. A per-chat `secret_key` returned by `POST /v1/chats` is REQUIRED for all subsequent chat operations and MUST be stored as a secret. ^dep-secret-key
- A human member MUST verify the chat by texting the one-time `VERIFY-XXXXXX` code returned by chat creation to the selected Plow Chat line. ^dep-verification

### Software

- Hermes Agent MUST be installed with gateway/plugin support. The target Hermes tree SHOULD contain `gateway/platforms/base.py`, `gateway/platform_registry.py`, and `plugins/platforms/` support. ^dep-hermes
- Python MUST have `aiohttp` available for the reference adapter's REST and WebSocket client. ^dep-aiohttp
- A fresh Hermes SHOULD install this SEED directly as a Git plugin from the repository root: `hermes plugins install <git-url-or-file-url> --enable`. The root `plugin.yaml` and `__init__.py` load the reference adapter from `ref/hermes-plugin/plow_chat/`. ^dep-plugin-install
- The sample code in `ref/hermes-plugin/plow_chat/` MAY also be copied into a Hermes plugin location such as `$HERMES_HOME/plugins/platforms/plow_chat/` or an equivalent plugin-discovery path for the installed Hermes version. ^dep-plugin-copy

## Objects

### Plow Chat API

- The HTTP and WebSocket API at `https://chat.plow.co/v1`. ^obj-api
- It exposes lines, chats, messages, invitation resend, and WebSocket ticket endpoints.

### Plow line

- A provisioned messaging line returned by `GET /v1/lines`. ^obj-line
- The line's `uid` is supplied as the synthetic agent participant's `line_id` when creating a chat.
- The line's `provider_key` is the phone number users text for verification and later see as the sender for Hermes replies.

### Plow chat

- A Plow Chat conversation returned by `POST /v1/chats`. ^obj-chat
- It starts as `status='pending'`, becomes `status='active'` after every member verifies, and may become `status='failed'` if activation fails.
- It has a stable `uid` used as the Hermes `chat_id` for this platform.
- Its one-time `secret_key` authenticates future API calls through the `X-Chat-Secret-Key` header and MUST NOT be logged or committed.

### Plow member

- A human participant in a Plow chat. ^obj-member
- The API caller supplies only `display_name`; Plow binds the member's messaging identity from the first inbound text containing that member's verification code.
- Once active, inbound `message_received` WebSocket frames identify the member in `message.sender` with `type='member'`, `uid`, `display_name`, and `provider_key`.

### plow_chat Hermes platform

- A Hermes gateway platform named `plow_chat`. ^obj-platform
- It maps a Plow chat to a Hermes session source with `platform='plow_chat'`, `chat_id=<chat.uid>`, `chat_type='dm'`, and member sender metadata as the user identity.
- It sends plain text responses through Plow's message creation endpoint.
- It receives user messages by minting short-lived WebSocket tickets and subscribing to `wss://chat.plow.co/v1/ws?ticket=<ticket>`.

### Reference plugin

- The repository root is an installable Hermes plugin because it contains `plugin.yaml` and `__init__.py`. ^obj-root-plugin
- Root `__init__.py` loads and re-exports `register(ctx)` from `ref/hermes-plugin/plow_chat/adapter.py`, so `hermes plugins install <this repo> --enable` registers platform `plow_chat`. ^obj-root-entrypoint
- The folder `ref/hermes-plugin/plow_chat/` contains the readable Hermes plugin files for `plow_chat`. ^obj-ref-plugin
- The sample prioritizes the shape of the adapter contract over exhaustive production hardening.

### Reference helper scripts

- `ref/scripts/create_chat.py` creates a Plow chat and prints the verification instructions while writing the per-chat secret to a local state file. ^obj-create-script
- `ref/scripts/check_chat.py` reads a local state file and reports whether the chat is pending, active, or failed without printing the chat secret. ^obj-check-script
- `ref/scripts/configure_hermes_env.py` writes `PLOW_CHAT_*` values from a local state file into Hermes' `.env` without printing the secret. ^obj-configure-env-script
- `ref/scripts/bootstrap_fresh_hermes.sh` installs the SEED into Hermes, optionally creates a chat, and configures Hermes env from a verified state file. ^obj-bootstrap-script

## Actions

### Plow chat is created

- The installer chooses a Plow line from `GET /v1/lines`. ^act-create-chat
- The installer calls `POST /v1/chats` with exactly one `agent` participant containing `line_id` and at least one `member` participant containing a display name.
- The installer MUST store the returned `chat.uid` and one-time `secret_key` outside committed files.
- The installer MUST show the user the returned `verification_code` and the selected line's `provider_key` so the user can text the code to the line.

### Plow chat is verified

- The user texts the returned `VERIFY-XXXXXX` code to the selected Plow line from the messaging identity they want bound to Hermes. ^act-verify-chat
- Plow transitions that member from `pending_verification` to `active` and emits `participant_verified` on the WebSocket stream.
- Once every member is verified, Plow transitions the chat to `active` and emits `chat_active` with the bound `provider_key`.

### plow_chat sends a Hermes response

- The platform adapter sends outbound text with `POST /v1/chats/{chat_uid}/messages`, JSON body `{"body": "..."}`, and header `X-Chat-Secret-Key: <secret>`. ^act-send
- The adapter SHOULD strip or flatten rich markdown because the current backing channel is iMessage/SMS-style chat.
- The adapter MUST treat 409 `chat_not_ready` as a setup/verification problem, not a successful send.

### plow_chat receives a user message

- The platform adapter mints a WebSocket ticket with `POST /v1/ws/ticket` using the chat secret. ^act-receive
- The adapter connects to `wss://chat.plow.co/v1/ws?ticket=<ticket>` before the ticket expires.
- The adapter treats `{ "type": "connected" }` as subscribed.
- The adapter handles `message_received` frames and MUST ignore outbound echo frames where `message.direction == 'outbound'`.
- For inbound frames, the adapter constructs a Hermes `MessageEvent` with the message body, Plow message uid, chat uid, and member sender uid/name.
- On disconnect, the adapter SHOULD reconnect by minting a fresh ticket and SHOULD backfill missed messages with `GET /v1/chats/{chat_uid}/messages`.

### plow_chat handles status and activation frames

- The adapter MAY log `message_status_updated` frames for outbound delivery transitions. ^act-status
- The adapter SHOULD surface `chat_activation_failed` as a fatal setup error, because recovery is delete and recreate.
- The adapter SHOULD mark the platform connected only after the WebSocket's initial `connected` frame.

### plow_chat is configured in Hermes

- A fresh Hermes MAY install this SEED directly with `hermes plugins install <git-url-or-file-url> --enable`; plugin discovery MUST call root `register(ctx)` and register platform `plow_chat`. ^act-install-plugin
- A Hermes install SHOULD configure the platform with these non-secret values in `config.yaml` or equivalent plugin config: `base_url`, `chat_uid`, and optionally `home_channel`. ^act-config
- The chat secret MUST be configured through an environment variable such as `PLOW_CHAT_SECRET_KEY`, not committed config.
- A reasonable env-only setup is: `PLOW_CHAT_BASE_URL=https://chat.plow.co`, `PLOW_CHAT_CHAT_UID=<cht_...>`, `PLOW_CHAT_SECRET_KEY=<sk_...>`, and `PLOW_CHAT_HOME_CHANNEL=<cht_...>`.
- When `PLOW_CHAT_CHAT_UID` and `PLOW_CHAT_SECRET_KEY` are present, the plugin's `env_enablement_fn` SHOULD auto-enable `gateway.platforms.plow_chat` and set its home channel to the Plow chat uid. ^act-env-auto-enable

## Verify

1. **API schema check.** Fetch `https://chat.plow.co/v1/openapi.json`. Does it define `POST /v1/chats`, `POST /v1/chats/{chat_uid}/messages`, and `POST /v1/ws/ticket`? Expected: yes. ^v-schema

2. **Line discovery check.** Fetch `GET https://chat.plow.co/v1/lines`. Does the response contain at least one `LineResource` with a `uid` matching `ln_...` and a `provider_key`? Expected: yes. ^v-lines

3. **Hermes adapter-shape check.** Inspect `ref/hermes-plugin/plow_chat/adapter.py`. Does it define a `PlowChatAdapter` implementing `connect`, `disconnect`, and `send`, and a `register(ctx)` function that registers platform name `plow_chat`? Expected: yes. ^v-adapter-shape

4. **Root plugin installability check.** Inspect repository root. Does it contain `plugin.yaml` with `kind: platform` and `__init__.py` exporting `register(ctx)`? Expected: yes. ^v-root-plugin

5. **Env writer check.** Run `python3 -m py_compile ref/scripts/configure_hermes_env.py` and test it against a dummy state file. Does it write `PLOW_CHAT_BASE_URL`, `PLOW_CHAT_CHAT_UID`, `PLOW_CHAT_SECRET_KEY`, and `PLOW_CHAT_HOME_CHANNEL` without printing the secret? Expected: yes. ^v-env-writer

6. **Secret hygiene check.** Search committed files. Do they avoid literal `sk_` chat secrets and one-time verification codes? Expected: yes. ^v-secret-hygiene

7. **Optional live chat check.** If the installer has created a local state file containing a Plow chat uid and secret, run `ref/scripts/check_chat.py <state-file>`. Does it report `active` after the user texts the verification code, or `pending` before verification? Expected: active for a completed install. ^v-live-chat

## Open

- The sample plugin does not implement media attachments, streaming draft edits, delete-message, or native button UI for clarify prompts. ^o-media
- The sample plugin does not yet include production-grade reconnect backfill cursor persistence; it documents the expected behavior and includes a simple reconnect loop. ^o-backfill
- User-installed Hermes platform plugins must be enabled (`hermes plugins install ... --enable` or `hermes plugins enable plow-chat-platform`) before gateway plugin discovery will load them. ^o-plugin-enable
- The Plow Chat API is pre-1.0 and may change without backwards compatibility guarantees. ^o-api-stability

## Non-Goals

- This SEED does not define the Plow Chat service itself.
- This SEED does not store or publish chat secrets, verification codes, phone numbers, or provider identities.
- This SEED does not require modifying Hermes core; a plugin-based adapter is the preferred shape when supported.
