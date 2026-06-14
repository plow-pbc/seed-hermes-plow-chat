#!/usr/bin/env python3
"""Plow connectors helper for Hermes.

A thin, generic wrapper over the Plow connector REST API
(``https://api.plow.co/v1/connectors/<connector>/<action>``). It lets a Hermes
agent use the owner's Plow-connected Google (Gmail + Google Calendar) and Slack
accounts with the **same** user Bearer token the ``plow_chat`` gateway already
holds — so adding Google/Slack is zero new credentials.

The Plow connector surface is uniform: ``status`` is a GET, and every other
action is a POST whose JSON body is the request. This wrapper is therefore a
single generic call rather than one function per endpoint.

Usage::

    plow_connector.py <connector> <action> [json_body]

    plow_connector.py gmail status
    plow_connector.py gmail messages.list '{"query":"is:unread","max_results":5}'
    plow_connector.py gmail messages.send '{"to":["a@b.com"],"subject":"Hi","body":"...","account":"me@example.com"}'
    plow_connector.py gmail calendar.events.list '{"time_min":"2026-06-14T00:00:00Z","max_results":10}'
    plow_connector.py slack channels.list '{"account":"T0123"}'
    plow_connector.py slack messages.send '{"account":"T0123","channel_id":"C0123","text":"hello"}'

Auth/env (reuses the plow_chat gateway settings; define nothing new):

    PLOW_CONNECTOR_TOKEN or PLOW_CHAT_TOKEN        user Bearer token (required)
    PLOW_CONNECTOR_BASE_URL or PLOW_CHAT_BASE_URL  API base (default https://api.plow.co)

Prints the JSON response to stdout. A non-2xx response is fatal: the status and
body go to stderr and the process exits non-zero (no silent failures).
"""
from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.request

CONNECTORS = ("gmail", "slack")
GET_ACTIONS = {"status"}


def _env(*names: str, default: str | None = None) -> str | None:
    for name in names:
        value = os.environ.get(name)
        if value:
            return value
    return default


def call(connector: str, action: str, body: str = "") -> str:
    if connector not in CONNECTORS:
        raise SystemExit(f"unknown connector {connector!r}; expected one of {', '.join(CONNECTORS)}")

    token = _env("PLOW_CONNECTOR_TOKEN", "PLOW_CHAT_TOKEN")
    if not token:
        raise SystemExit("PLOW_CONNECTOR_TOKEN or PLOW_CHAT_TOKEN is required")
    base = _env("PLOW_CONNECTOR_BASE_URL", "PLOW_CHAT_BASE_URL", default="https://api.plow.co").rstrip("/")

    method = "GET" if action in GET_ACTIONS else "POST"
    headers = {"Authorization": f"Bearer {token}"}
    data = None
    if method == "POST":
        payload = json.loads(body) if body.strip() else {}
        data = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json"

    url = f"{base}/v1/connectors/{connector}/{action}"
    request = urllib.request.Request(url, data=data, headers=headers, method=method)
    with urllib.request.urlopen(request, timeout=60) as resp:
        return resp.read().decode("utf-8")


def main(argv: list[str]) -> None:
    if len(argv) < 2:
        raise SystemExit(__doc__)
    connector, action = argv[0], argv[1]
    body = argv[2] if len(argv) > 2 else ""
    try:
        sys.stdout.write(call(connector, action, body))
        if not body.endswith("\n"):
            sys.stdout.write("\n")
    except urllib.error.HTTPError as exc:  # fail loud — surface the API error verbatim
        detail = exc.read().decode("utf-8", "replace")[:1000]
        sys.stderr.write(f"HTTP {exc.code} {exc.reason}: {detail}\n")
        raise SystemExit(1)


if __name__ == "__main__":
    main(sys.argv[1:])
