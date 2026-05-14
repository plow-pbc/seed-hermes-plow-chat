#!/usr/bin/env python3
"""Check a Plow Chat state file without printing the chat secret."""

from __future__ import annotations

import argparse
import json
import pathlib
import urllib.request


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("state_file")
    args = parser.parse_args()

    state = json.loads(pathlib.Path(args.state_file).expanduser().read_text())
    base = state.get("base_url", "https://chat.plow.co").rstrip("/")
    chat_uid = state["chat_uid"]
    secret = state["chat_secret_key"]
    req = urllib.request.Request(
        f"{base}/v1/chats/{chat_uid}",
        method="GET",
        headers={"X-Chat-Secret-Key": secret},
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        chat = json.loads(resp.read().decode("utf-8"))

    print(json.dumps({
        "chat_uid": chat.get("uid"),
        "status": chat.get("status"),
        "provider_key": chat.get("provider_key"),
        "failure_reason": chat.get("failure_reason"),
        "participants": [
            {
                "type": p.get("type"),
                "uid": p.get("uid"),
                "status": p.get("status"),
                "display_name": p.get("display_name"),
                "provider_key_bound": bool(p.get("provider_key")),
            }
            for p in chat.get("participants", [])
        ],
    }, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
