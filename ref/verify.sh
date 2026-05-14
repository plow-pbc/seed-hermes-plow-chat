#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$ROOT"

fail() { echo "FAIL: $*" >&2; exit 1; }

python3 - <<'PY'
import json, urllib.request
spec=json.load(urllib.request.urlopen('https://chat.plow.co/v1/openapi.json', timeout=30))
paths=spec.get('paths', {})
required=['/v1/chats','/v1/chats/{chat_uid}/messages','/v1/ws/ticket']
missing=[p for p in required if p not in paths]
if missing:
    raise SystemExit('missing OpenAPI paths: '+', '.join(missing))
PY

python3 - <<'PY'
import json, urllib.request
lines=json.load(urllib.request.urlopen('https://chat.plow.co/v1/lines', timeout=30))
data=lines.get('data') or []
if not any(str(item.get('uid','')).startswith('ln_') and item.get('provider_key') for item in data):
    raise SystemExit('no usable Plow line found')
PY

python3 -m py_compile ref/hermes-plugin/plow_chat/adapter.py ref/scripts/create_chat.py ref/scripts/check_chat.py

python3 - <<'PY'
import pathlib, re, sys
bad=[]
for path in [pathlib.Path('README.md'), pathlib.Path('SEED.md'), pathlib.Path('ref')]:
    files=[path] if path.is_file() else [p for p in path.rglob('*') if p.is_file()]
    for file in files:
        text=file.read_text(errors='ignore')
        if re.search(r'sk_[A-Za-z0-9_-]{8,}', text):
            bad.append(f'{file}: literal-looking chat secret')
        for m in re.finditer(r'VERIFY-[A-Z0-9]{6}', text):
            if m.group(0) != 'VERIFY-XXXXXX':
                bad.append(f'{file}: literal-looking verification code')
if bad:
    raise SystemExit('\n'.join(bad))
PY

echo "ok"
