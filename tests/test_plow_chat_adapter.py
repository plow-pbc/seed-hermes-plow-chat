import asyncio
import importlib.util
import sys
import types
from pathlib import Path


class Platform(str):
    pass


class SendResult:
    def __init__(self, success=False, message_id=None, error=None):
        self.success = success
        self.message_id = message_id
        self.error = error


class MessageType:
    TEXT = "text"


class MessageEvent:
    def __init__(self, **kwargs):
        self.__dict__.update(kwargs)


class BasePlatformAdapter:
    def __init__(self, config, platform):
        self.config = config
        self.platform = platform
        self.is_connected = False

    def build_source(self, **kwargs):
        return types.SimpleNamespace(**kwargs, platform=self.platform)

    def truncate_message(self, body):
        return [body]

    def _mark_connected(self):
        self.is_connected = True

    def _mark_disconnected(self):
        self.is_connected = False

    def _set_fatal_error(self, *args, **kwargs):
        self.fatal_error = (args, kwargs)

    async def _notify_fatal_error(self):
        self.fatal_notified = True


sys.modules.setdefault("gateway", types.ModuleType("gateway"))
config_mod = types.ModuleType("gateway.config")
config_mod.Platform = Platform
sys.modules["gateway.config"] = config_mod
platforms_mod = types.ModuleType("gateway.platforms")
sys.modules["gateway.platforms"] = platforms_mod
base_mod = types.ModuleType("gateway.platforms.base")
base_mod.BasePlatformAdapter = BasePlatformAdapter
base_mod.MessageEvent = MessageEvent
base_mod.MessageType = MessageType
base_mod.SendResult = SendResult
sys.modules["gateway.platforms.base"] = base_mod

ADAPTER_PATH = Path(__file__).resolve().parents[1] / "ref" / "hermes-plugin" / "plow_chat" / "adapter.py"
spec = importlib.util.spec_from_file_location("plow_chat_adapter_under_test", ADAPTER_PATH)
adapter_mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(adapter_mod)


class DummyConfig:
    extra = {"chat_uid": "cht_test", "secret_key": "sk_test"}


class RecordingAdapter(adapter_mod.PlowChatAdapter):
    def __init__(self, monkeypatch):
        monkeypatch.delenv("PLOW_CHAT_CHAT_UID", raising=False)
        monkeypatch.delenv("PLOW_CHAT_SECRET_KEY", raising=False)
        super().__init__(DummyConfig())
        self.sent = []
        self.handled = []

    async def send(self, chat_id, content, reply_to=None, metadata=None):
        self.sent.append((chat_id, content))
        return SendResult(success=True, message_id="msg_welcome")

    async def handle_message(self, event):
        self.handled.append(event)


def test_chat_active_sends_default_welcome(monkeypatch):
    monkeypatch.delenv("PLOW_CHAT_WELCOME_MESSAGE", raising=False)
    adapter = RecordingAdapter(monkeypatch)

    asyncio.run(adapter._handle_ws_frame({"type": "chat_active"}))

    assert adapter.sent == [
        (
            "cht_test",
            "Hi — Plow Chat is connected to Hermes now. Reply here to start chatting.",
        )
    ]


def test_chat_active_welcome_is_sent_once(monkeypatch):
    monkeypatch.setenv("PLOW_CHAT_WELCOME_MESSAGE", "ready!")
    adapter = RecordingAdapter(monkeypatch)

    asyncio.run(adapter._handle_ws_frame({"type": "chat_active"}))
    asyncio.run(adapter._handle_ws_frame({"type": "chat_active"}))

    assert adapter.sent == [("cht_test", "ready!")]


def test_inbound_message_auto_approves_verified_sender(monkeypatch):
    approved = []

    class FakeStore:
        _lock = None

        def approve_user(self, platform, user_id, user_name=""):
            approved.append((platform, user_id, user_name))

    class Lock:
        def __enter__(self):
            return None

        def __exit__(self, *args):
            return False

    FakeStore._lock = Lock()

    pairing_mod = types.ModuleType("gateway.pairing")
    pairing_mod.PairingStore = FakeStore
    monkeypatch.setitem(sys.modules, "gateway.pairing", pairing_mod)

    adapter = RecordingAdapter(monkeypatch)
    frame = {
        "type": "message_received",
        "message": {
            "uid": "msg_1",
            "direction": "inbound",
            "body": "hello",
            "sender": {"uid": "cp_member", "display_name": "Patrick"},
        },
    }

    asyncio.run(adapter._handle_ws_frame(frame))

    assert approved == [("plow_chat", "cp_member", "Patrick")]
    assert adapter.handled[0].source.user_id == "cp_member"
