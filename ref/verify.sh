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

python3 -m py_compile \
  __init__.py \
  ref/hermes-plugin/plow_chat/adapter.py \
  ref/scripts/create_chat.py \
  ref/scripts/check_chat.py \
  ref/scripts/configure_hermes_env.py

python3 - <<'PY'
import pathlib
root=pathlib.Path('.')
manifest=(root/'plugin.yaml').read_text()
if 'kind: platform' not in manifest:
    raise SystemExit('root plugin.yaml kind is not platform')
if 'name: plow-chat-platform' not in manifest:
    raise SystemExit('root plugin.yaml has unexpected plugin name')
if not (root/'__init__.py').exists():
    raise SystemExit('missing root __init__.py')
text=(root/'__init__.py').read_text()
if 'register' not in text or 'adapter.py' not in text:
    raise SystemExit('root __init__.py does not expose adapter register(ctx)')
PY

python3 - <<'PY'
import json, pathlib, subprocess, tempfile
with tempfile.TemporaryDirectory() as td:
    root=pathlib.Path(td)
    state=root/'state.json'
    env=root/'.env'
    state.write_text(json.dumps({
        'base_url':'https://chat.plow.co',
        'chat_uid':'cht_dummy',
        'chat_secret_key':'dummy_secret_for_verify_only',
    }))
    result=subprocess.run([
        'python3','ref/scripts/configure_hermes_env.py',str(state),'--env-file',str(env)
    ], capture_output=True, text=True, check=True)
    if 'dummy_secret_for_verify_only' in result.stdout:
        raise SystemExit('configure_hermes_env.py printed the secret')
    content=env.read_text()
    required=['PLOW_CHAT_BASE_URL=https://chat.plow.co','PLOW_CHAT_CHAT_UID=cht_dummy','PLOW_CHAT_SECRET_KEY=dummy_secret_for_verify_only','PLOW_CHAT_HOME_CHANNEL=cht_dummy']
    missing=[item for item in required if item not in content]
    if missing:
        raise SystemExit('env writer missing: '+', '.join(missing))
PY

python3 - <<'PY'
import pathlib, re, sys
bad=[]
for path in [pathlib.Path('README.md'), pathlib.Path('SEED.md'), pathlib.Path('plugin.yaml'), pathlib.Path('__init__.py'), pathlib.Path('after-install.md'), pathlib.Path('ref')]:
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
