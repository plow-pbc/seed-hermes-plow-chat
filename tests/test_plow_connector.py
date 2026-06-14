"""Behavior tests for the plow-connectors helper.

The helper's observable contract is the HTTP request it issues to the Plow
connector API and the response it returns, so the tests assert on the request
(method, URL, auth header, JSON body) and on the failure behavior — not on
internal structure.
"""
import importlib.util
import io
import json
import urllib.error
from pathlib import Path

import pytest

MODULE_PATH = (
    Path(__file__).resolve().parent.parent
    / "ref/hermes-skill/plow-connectors/plow_connector.py"
)


def _load():
    spec = importlib.util.spec_from_file_location("plow_connector", MODULE_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@pytest.fixture
def mod():
    return _load()


@pytest.fixture
def captured(monkeypatch, mod):
    """Patch urlopen to capture the outgoing Request and return a canned body."""
    seen = {}

    class _Resp:
        def __init__(self, body):
            self._body = body.encode()

        def read(self):
            return self._body

        def __enter__(self):
            return self

        def __exit__(self, *a):
            return False

    def fake_urlopen(req, timeout=None):
        seen["method"] = req.method
        seen["url"] = req.full_url
        seen["headers"] = {k.lower(): v for k, v in req.header_items()}
        seen["body"] = req.data.decode() if req.data else None
        return _Resp('{"ok":true}')

    monkeypatch.setattr(mod.urllib.request, "urlopen", fake_urlopen)
    return seen


def test_status_is_a_get_with_no_body(monkeypatch, mod, captured):
    monkeypatch.setenv("PLOW_CHAT_TOKEN", "tok-abc")
    monkeypatch.delenv("PLOW_CONNECTOR_TOKEN", raising=False)
    monkeypatch.setenv("PLOW_CHAT_BASE_URL", "https://api.plow.co")

    out = mod.call("gmail", "status")

    assert json.loads(out) == {"ok": True}
    assert captured["method"] == "GET"
    assert captured["url"] == "https://api.plow.co/v1/connectors/gmail/status"
    assert captured["headers"]["authorization"] == "Bearer tok-abc"
    assert captured["body"] is None


def test_action_posts_json_body(monkeypatch, mod, captured):
    monkeypatch.setenv("PLOW_CHAT_TOKEN", "tok-abc")
    mod.call("slack", "messages.send", '{"account":"T1","channel_id":"C1","text":"hi"}')

    assert captured["method"] == "POST"
    assert captured["url"] == "https://api.plow.co/v1/connectors/slack/messages.send"
    assert json.loads(captured["body"]) == {"account": "T1", "channel_id": "C1", "text": "hi"}
    assert captured["headers"]["content-type"] == "application/json"


def test_connector_token_overrides_chat_token(monkeypatch, mod, captured):
    monkeypatch.setenv("PLOW_CHAT_TOKEN", "chat-tok")
    monkeypatch.setenv("PLOW_CONNECTOR_TOKEN", "conn-tok")
    mod.call("gmail", "status")
    assert captured["headers"]["authorization"] == "Bearer conn-tok"


def test_base_url_override_and_default(monkeypatch, mod, captured):
    monkeypatch.setenv("PLOW_CHAT_TOKEN", "t")
    monkeypatch.delenv("PLOW_CHAT_BASE_URL", raising=False)
    monkeypatch.delenv("PLOW_CONNECTOR_BASE_URL", raising=False)
    mod.call("gmail", "status")
    assert captured["url"].startswith("https://api.plow.co/")

    monkeypatch.setenv("PLOW_CONNECTOR_BASE_URL", "https://example.test/")
    mod.call("gmail", "status")
    assert captured["url"] == "https://example.test/v1/connectors/gmail/status"


def test_unknown_connector_is_fatal(monkeypatch, mod):
    monkeypatch.setenv("PLOW_CHAT_TOKEN", "t")
    with pytest.raises(SystemExit):
        mod.call("dropbox", "status")


def test_missing_token_is_fatal(monkeypatch, mod):
    monkeypatch.delenv("PLOW_CHAT_TOKEN", raising=False)
    monkeypatch.delenv("PLOW_CONNECTOR_TOKEN", raising=False)
    with pytest.raises(SystemExit):
        mod.call("gmail", "status")


def test_http_error_exits_nonzero(monkeypatch, mod):
    monkeypatch.setenv("PLOW_CHAT_TOKEN", "t")

    def boom(req, timeout=None):
        raise urllib.error.HTTPError(req.full_url, 401, "Unauthorized", {}, io.BytesIO(b'{"detail":"nope"}'))

    monkeypatch.setattr(mod.urllib.request, "urlopen", boom)
    with pytest.raises(SystemExit) as exc:
        mod.main(["gmail", "status"])
    assert exc.value.code == 1
