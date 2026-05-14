#!/usr/bin/env python3
"""Create a Plow Chat and print verification instructions.

Usage:
  python ref/scripts/create_chat.py --display-name "Your Name" --state ~/.config/hermes/plow_chat_state.json

The state file contains the one-time chat secret. Do not commit it.
"""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import sys
import urllib.request

BASE_URL = "https://chat.plow.co"


def request_json(method: str, url: str, body: dict | None = None, headers: dict | None = None) -> dict:
    data = None if body is None else json.dumps(body).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=data,
        method=method,
        headers={"Content-Type": "application/json", **(headers or {})},
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.loads(resp.read().decode("utf-8"))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-url", default=os.getenv("PLOW_CHAT_BASE_URL", BASE_URL))
    parser.add_argument("--line-id", default="", help="Line uid from GET /v1/lines; defaults to first line")
    parser.add_argument("--display-name", default="Hermes user")
    parser.add_argument("--state", default=str(pathlib.Path.home() / ".config/hermes/plow_chat_state.json"))
    args = parser.parse_args()

    base = args.base_url.rstrip("/")
    lines = request_json("GET", f"{base}/v1/lines")
    data = lines.get("data") or []
    if not data:
        raise SystemExit("No Plow Chat lines returned by /v1/lines")
    line = next((item for item in data if item.get("uid") == args.line_id), data[0])

    payload = {
        "participants": [
            {"type": "agent", "line_id": line["uid"]},
            {"type": "member", "display_name": args.display_name},
        ]
    }
    chat = request_json("POST", f"{base}/v1/chats", payload)
    member = next(p for p in chat["participants"] if p.get("type") == "member")
    state = {
        "base_url": base,
        "line_uid": line["uid"],
        "line_provider_key": line.get("provider_key"),
        "chat_uid": chat["uid"],
        "chat_secret_key": chat.get("secret_key"),
        "member_uid": member["uid"],
        "verification_code": member.get("verification_code"),
        "verification_code_expires_at": member.get("verification_code_expires_at"),
    }

    state_path = pathlib.Path(args.state).expanduser()
    state_path.parent.mkdir(parents=True, exist_ok=True)
    state_path.write_text(json.dumps(state, indent=2))
    os.chmod(state_path, 0o600)

    print("Plow Chat created.")
    print(f"State file: {state_path}")
    print(f"Chat uid: {state['chat_uid']}")
    print(f"Text this code: {state['verification_code']}")
    print(f"To this Plow line: {state['line_provider_key']}")
    print(f"Code expires at: {state['verification_code_expires_at']}")
    print("For Hermes env after verification:")
    print(f"  PLOW_CHAT_BASE_URL={base}")
    print(f"  PLOW_CHAT_CHAT_UID={state['chat_uid']}")
    print("  PLOW_CHAT_SECRET_KEY=<copy from state file; do not commit>")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
