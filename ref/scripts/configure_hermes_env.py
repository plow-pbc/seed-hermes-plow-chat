#!/usr/bin/env python3
"""Write Plow Chat state into Hermes' .env file.

Usage:
  python ref/scripts/configure_hermes_env.py ~/.hermes/plow_chat_state.json
  python ref/scripts/configure_hermes_env.py state.json --env-file ~/.hermes/.env

The input state file is created by create_chat.py. This script writes only the
runtime values Hermes needs; it never prints the chat secret.
"""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import re
import stat
import subprocess
import sys
from collections import OrderedDict

REQUIRED_STATE_KEYS = ["base_url", "chat_uid", "chat_secret_key"]
ENV_KEYS = [
    "PLOW_CHAT_BASE_URL",
    "PLOW_CHAT_CHAT_UID",
    "PLOW_CHAT_SECRET_KEY",
    "PLOW_CHAT_HOME_CHANNEL",
]


def default_env_file() -> pathlib.Path:
    env = os.getenv("HERMES_ENV_FILE")
    if env:
        return pathlib.Path(env).expanduser()
    try:
        result = subprocess.run(
            ["hermes", "config", "env-path"],
            capture_output=True,
            text=True,
            timeout=10,
        )
        if result.returncode == 0 and result.stdout.strip():
            return pathlib.Path(result.stdout.strip()).expanduser()
    except Exception:
        pass
    hermes_home = pathlib.Path(os.getenv("HERMES_HOME", pathlib.Path.home() / ".hermes")).expanduser()
    return hermes_home / ".env"


def parse_env(path: pathlib.Path) -> tuple[list[str], OrderedDict[str, str]]:
    lines: list[str] = []
    values: OrderedDict[str, str] = OrderedDict()
    if not path.exists():
        return lines, values
    for raw in path.read_text().splitlines():
        lines.append(raw)
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip()
        if key:
            values[key] = value
    return lines, values


def quote_env(value: str) -> str:
    if re.fullmatch(r"[A-Za-z0-9_./:@%+=,-]*", value):
        return value
    return json.dumps(value)


def update_env_file(path: pathlib.Path, updates: dict[str, str]) -> None:
    lines, existing = parse_env(path)
    remaining = dict(updates)
    out: list[str] = []
    for raw in lines:
        stripped = raw.strip()
        if stripped and not stripped.startswith("#") and "=" in stripped:
            key = stripped.split("=", 1)[0].strip()
            if key in remaining:
                out.append(f"{key}={quote_env(remaining.pop(key))}")
                continue
        out.append(raw)
    if out and out[-1] != "":
        out.append("")
    for key in ENV_KEYS:
        if key in remaining:
            out.append(f"{key}={quote_env(remaining.pop(key))}")
    for key, value in remaining.items():
        out.append(f"{key}={quote_env(value)}")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(out).rstrip() + "\n")
    try:
        path.chmod(stat.S_IRUSR | stat.S_IWUSR)
    except Exception:
        pass


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("state_file", help="State JSON written by create_chat.py")
    parser.add_argument("--env-file", default="", help="Hermes .env path; default: hermes config env-path or ~/.hermes/.env")
    parser.add_argument("--home-channel", default="", help="Override PLOW_CHAT_HOME_CHANNEL; defaults to chat uid")
    args = parser.parse_args()

    state_path = pathlib.Path(args.state_file).expanduser()
    state = json.loads(state_path.read_text())
    missing = [key for key in REQUIRED_STATE_KEYS if not state.get(key)]
    if missing:
        raise SystemExit(f"State file is missing required keys: {', '.join(missing)}")

    env_file = pathlib.Path(args.env_file).expanduser() if args.env_file else default_env_file()
    updates = {
        "PLOW_CHAT_BASE_URL": str(state.get("base_url") or "https://chat.plow.co").rstrip("/"),
        "PLOW_CHAT_CHAT_UID": str(state["chat_uid"]),
        "PLOW_CHAT_SECRET_KEY": str(state["chat_secret_key"]),
        "PLOW_CHAT_HOME_CHANNEL": args.home_channel or str(state["chat_uid"]),
    }
    update_env_file(env_file, updates)
    print(f"Wrote Plow Chat Hermes env to {env_file}")
    print(f"PLOW_CHAT_CHAT_UID={updates['PLOW_CHAT_CHAT_UID']}")
    print(f"PLOW_CHAT_HOME_CHANNEL={updates['PLOW_CHAT_HOME_CHANNEL']}")
    print("PLOW_CHAT_SECRET_KEY=<written, not printed>")
    print("Restart Hermes or run `hermes gateway restart` for changes to take effect.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
