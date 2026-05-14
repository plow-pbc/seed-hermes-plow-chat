"""
Reference Plow Chat platform adapter for Hermes Agent.

This is intentionally a small, readable seed implementation. It documents the
shape of a Hermes platform adapter backed by the Plow Chat API. Production
installs should add durable cursor persistence, richer setup UX, and tests
against the exact Hermes version they run.
"""

from __future__ import annotations

import asyncio
import logging
import os
import time
from typing import Any, Optional
from urllib.parse import urlparse

logger = logging.getLogger(__name__)

from gateway.config import Platform
from gateway.platforms.base import BasePlatformAdapter, MessageEvent, MessageType, SendResult

DEFAULT_BASE_URL = "https://chat.plow.co"
MAX_MESSAGE_LENGTH = 4_000


def _truthy(value: str | None) -> bool:
    return str(value or "").strip().lower() in {"1", "true", "yes", "on"}


def _base_url_from_env_or_config(config) -> str:
    extra = getattr(config, "extra", {}) or {}
    return (os.getenv("PLOW_CHAT_BASE_URL") or extra.get("base_url") or DEFAULT_BASE_URL).rstrip("/")


def _chat_uid_from_env_or_config(config) -> str:
    extra = getattr(config, "extra", {}) or {}
    return (os.getenv("PLOW_CHAT_CHAT_UID") or extra.get("chat_uid") or "").strip()


def _secret_from_env_or_config(config) -> str:
    # Prefer env. Keeping secret in config.extra works for local experiments but
    # is not recommended because config files are easier to accidentally commit.
    extra = getattr(config, "extra", {}) or {}
    return (os.getenv("PLOW_CHAT_SECRET_KEY") or extra.get("secret_key") or "").strip()


def _ws_url_for(base_url: str, ticket: str) -> str:
    parsed = urlparse(base_url)
    scheme = "wss" if parsed.scheme == "https" else "ws"
    return f"{scheme}://{parsed.netloc}/v1/ws?ticket={ticket}"


def _flatten_message(content: str) -> str:
    # Keep this deliberately conservative. iMessage/SMS render Markdown as text.
    return str(content or "").strip()


class PlowChatAdapter(BasePlatformAdapter):
    """Plow Chat <-> Hermes gateway adapter."""

    MAX_MESSAGE_LENGTH = MAX_MESSAGE_LENGTH

    def __init__(self, config, **kwargs):
        super().__init__(config=config, platform=Platform("plow_chat"))
        self.base_url = _base_url_from_env_or_config(config)
        self.chat_uid = _chat_uid_from_env_or_config(config)
        self.secret_key = _secret_from_env_or_config(config)
        self._http_session = None
        self._ws_task: Optional[asyncio.Task] = None
        self._seen_message_uids: set[str] = set()
        self._stop_event = asyncio.Event()

    @property
    def name(self) -> str:
        return "Plow Chat"

    async def connect(self) -> bool:
        import aiohttp

        if not self.chat_uid or not self.secret_key:
            msg = "PLOW_CHAT_CHAT_UID and PLOW_CHAT_SECRET_KEY are required"
            logger.error("[plow_chat] %s", msg)
            self._set_fatal_error("config_missing", msg, retryable=False)
            return False

        self._http_session = aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=30))
        self._stop_event.clear()
        self._ws_task = asyncio.create_task(self._websocket_loop())
        return True

    async def disconnect(self) -> None:
        self._stop_event.set()
        if self._ws_task and not self._ws_task.done():
            self._ws_task.cancel()
            try:
                await self._ws_task
            except asyncio.CancelledError:
                pass
        self._ws_task = None
        if self._http_session:
            await self._http_session.close()
            self._http_session = None
        self._mark_disconnected()

    async def send(
        self,
        chat_id: str,
        content: str,
        reply_to: Optional[str] = None,
        metadata: Optional[dict[str, Any]] = None,
    ) -> SendResult:
        import aiohttp

        target_chat = chat_id or self.chat_uid
        if target_chat != self.chat_uid:
            return SendResult(success=False, error="This seed adapter is configured for one Plow chat")

        body = _flatten_message(content)
        if not body:
            return SendResult(success=False, error="empty message")

        chunks = self.truncate_message(body)
        session = self._http_session or aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=30))
        close_session = self._http_session is None
        last_message_id = None
        try:
            for chunk in chunks:
                async with session.post(
                    f"{self.base_url}/v1/chats/{self.chat_uid}/messages",
                    json={"body": chunk},
                    headers={"X-Chat-Secret-Key": self.secret_key},
                ) as resp:
                    data = await resp.json(content_type=None)
                    if resp.status >= 400:
                        err = data.get("error", {}) if isinstance(data, dict) else {}
                        code = err.get("code") or resp.status
                        msg = err.get("message") or str(data)
                        return SendResult(success=False, error=f"Plow Chat {code}: {msg}")
                    last_message_id = data.get("uid") if isinstance(data, dict) else None
            return SendResult(success=True, message_id=last_message_id)
        except Exception as exc:
            logger.warning("[plow_chat] send failed: %s", exc)
            return SendResult(success=False, error=str(exc))
        finally:
            if close_session:
                await session.close()

    async def send_typing(self, chat_id: str, metadata=None) -> None:
        # Plow Chat currently exposes no typing endpoint.
        return None

    async def get_chat_info(self, chat_id: str) -> dict[str, Any]:
        return {"name": "Plow Chat", "type": "dm"}

    async def _mint_ws_ticket(self) -> str:
        async with self._http_session.post(
            f"{self.base_url}/v1/ws/ticket",
            headers={"X-Chat-Secret-Key": self.secret_key},
        ) as resp:
            data = await resp.json(content_type=None)
            if resp.status >= 400:
                err = data.get("error", {}) if isinstance(data, dict) else {}
                raise RuntimeError(err.get("message") or f"ticket mint failed: {resp.status}")
            return data["ticket"]

    async def _websocket_loop(self) -> None:
        import aiohttp

        backoff = 1.0
        while not self._stop_event.is_set():
            try:
                ticket = await self._mint_ws_ticket()
                ws_url = _ws_url_for(self.base_url, ticket)
                async with self._http_session.ws_connect(ws_url, heartbeat=30) as ws:
                    backoff = 1.0
                    async for msg in ws:
                        if self._stop_event.is_set():
                            break
                        if msg.type == aiohttp.WSMsgType.TEXT:
                            await self._handle_ws_frame(msg.json())
                        elif msg.type in (aiohttp.WSMsgType.CLOSED, aiohttp.WSMsgType.ERROR):
                            break
            except asyncio.CancelledError:
                raise
            except Exception as exc:
                logger.warning("[plow_chat] websocket loop error: %s", exc)
                if self.is_connected:
                    self._mark_disconnected()

            await asyncio.sleep(backoff)
            backoff = min(backoff * 2, 30.0)

    async def _handle_ws_frame(self, frame: dict[str, Any]) -> None:
        frame_type = frame.get("type")
        if frame_type == "connected":
            self._mark_connected()
            logger.info("[plow_chat] websocket subscribed")
            return
        if frame_type == "chat_active":
            logger.info("[plow_chat] chat active")
            return
        if frame_type == "chat_activation_failed":
            reason = frame.get("reason", "activation_failed")
            message = frame.get("message") or reason
            self._set_fatal_error("chat_activation_failed", message, retryable=False)
            await self._notify_fatal_error()
            return
        if frame_type == "message_status_updated":
            logger.debug("[plow_chat] status update: %s", frame.get("message"))
            return
        if frame_type != "message_received":
            return

        message = frame.get("message") or {}
        if message.get("direction") != "inbound":
            return
        msg_uid = message.get("uid") or str(int(time.time() * 1000))
        if msg_uid in self._seen_message_uids:
            return
        self._seen_message_uids.add(msg_uid)

        sender = message.get("sender") or {}
        user_id = sender.get("uid") or sender.get("provider_key") or "member"
        user_name = sender.get("display_name") or user_id
        text = message.get("body") or ""
        if not text.strip():
            return

        source = self.build_source(
            chat_id=self.chat_uid,
            chat_name="Plow Chat",
            chat_type="dm",
            user_id=user_id,
            user_name=user_name,
        )
        event = MessageEvent(
            text=text,
            message_type=MessageType.TEXT,
            source=source,
            raw_message=frame,
            message_id=msg_uid,
        )
        await self.handle_message(event)


def check_requirements() -> bool:
    try:
        import aiohttp  # noqa: F401
    except ImportError:
        return False
    return bool(os.getenv("PLOW_CHAT_CHAT_UID") and os.getenv("PLOW_CHAT_SECRET_KEY"))


def validate_config(config) -> bool:
    try:
        import aiohttp  # noqa: F401
    except ImportError:
        return False
    return bool(_chat_uid_from_env_or_config(config) and _secret_from_env_or_config(config))


def is_connected(config) -> bool:
    return validate_config(config)


def _env_enablement() -> dict | None:
    chat_uid = os.getenv("PLOW_CHAT_CHAT_UID", "").strip()
    secret = os.getenv("PLOW_CHAT_SECRET_KEY", "").strip()
    if not (chat_uid and secret):
        return None
    seed = {
        "base_url": os.getenv("PLOW_CHAT_BASE_URL", DEFAULT_BASE_URL).strip() or DEFAULT_BASE_URL,
        "chat_uid": chat_uid,
    }
    home = os.getenv("PLOW_CHAT_HOME_CHANNEL", "").strip() or chat_uid
    seed["home_channel"] = {"chat_id": home, "name": "Plow Chat"}
    return seed


async def _standalone_send(pconfig, chat_id: str, message: str, *, thread_id=None, media_files=None, force_document=False) -> dict:
    adapter = PlowChatAdapter(pconfig)
    target_chat = chat_id or adapter.chat_uid
    result = await adapter.send(target_chat, message)
    if result.success:
        return {"success": True, "message_id": result.message_id}
    return {"error": result.error or "send failed"}


def register(ctx):
    """Plugin entry point: called by the Hermes plugin system."""
    ctx.register_platform(
        name="plow_chat",
        label="Plow Chat",
        adapter_factory=lambda cfg: PlowChatAdapter(cfg),
        check_fn=check_requirements,
        validate_config=validate_config,
        is_connected=is_connected,
        required_env=["PLOW_CHAT_CHAT_UID", "PLOW_CHAT_SECRET_KEY"],
        install_hint="pip install aiohttp; create and verify a Plow chat first",
        env_enablement_fn=_env_enablement,
        cron_deliver_env_var="PLOW_CHAT_HOME_CHANNEL",
        standalone_sender_fn=_standalone_send,
        max_message_length=MAX_MESSAGE_LENGTH,
        pii_safe=True,
        emoji="💬",
        allow_update_command=True,
        platform_hint=(
            "You are chatting via Plow Chat over an iMessage/SMS-style thread. "
            "Use concise plain text. Avoid relying on rich markdown rendering."
        ),
    )
