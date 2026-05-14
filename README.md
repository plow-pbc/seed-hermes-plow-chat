# Plow Chat Hermes Platform Adapter SEED

## Purpose

This SEED captures the capability of installing a Hermes Agent custom gateway platform named `plow_chat`. The platform uses the Plow Chat API to create and bind an inbound-first chat, send Hermes responses through `POST /v1/chats/{chat_uid}/messages`, and receive user replies through the Plow Chat WebSocket stream at `/v1/ws`. It is intentionally adapter-seed documentation plus a lightweight reference implementation, not a promise that the sample code is the only correct Hermes implementation.

## License

MIT.
