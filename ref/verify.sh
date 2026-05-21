#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$ROOT"

# 1. Adapter shape + compile. Python is a maintainer verification tool here;
# the documented host install/orchestration path is shell + curl only.
python3 -m py_compile \
  __init__.py \
  ref/hermes-plugin/plow_chat/adapter.py

python3 - <<'PY'
import pathlib
adapter = pathlib.Path('ref/hermes-plugin/plow_chat/adapter.py').read_text()
for needed in ['class PlowChatAdapter', 'def connect', 'def disconnect', 'def send', 'def register(']:
    if needed not in adapter:
        raise SystemExit(f'adapter.py missing: {needed}')
if '"plow_chat"' not in adapter and "'plow_chat'" not in adapter:
    raise SystemExit('adapter.py does not register platform name plow_chat')
PY

# 2. Direct-mount file-set + config enablement check.
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
ref/scripts/install_direct_mount.sh --data-dir "$tmpdir/data" --source-dir . >/tmp/seed-hermes-plow-chat-install.out

for path in \
  "$tmpdir/data/plugins/plow-chat-platform/plugin.yaml" \
  "$tmpdir/data/plugins/plow-chat-platform/__init__.py" \
  "$tmpdir/data/plugins/plow-chat-platform/ref/hermes-plugin/plow_chat/adapter.py"
do
  [[ -f "$path" ]] || { echo "missing direct-mounted file: $path" >&2; exit 1; }
done

grep -q 'plow-chat-platform' "$tmpdir/data/config.yaml" || {
  echo 'config.yaml does not enable plow-chat-platform' >&2
  exit 1
}

# 3. Host shell helpers are syntax-valid and contain no Python/git/Hermes CLI dependency.
bash -n ref/scripts/install_direct_mount.sh ref/scripts/create_plow_chat_curl.sh
if [[ -e after-install.md || -e ref/scripts/bootstrap_fresh_hermes.sh || -e ref/scripts/configure_hermes_env.py ]]; then
  echo 'old host installer artifact still exists' >&2
  exit 1
fi
if rg -n 'python3|git clone|hermes plugins|hermes gateway|GH_TOKEN' ref/scripts; then
  echo 'host scripts still reference Python/git/Hermes installer artifacts' >&2
  exit 1
fi

# 4. Root plugin installability check.
python3 - <<'PY'
import pathlib
root = pathlib.Path('.')
manifest = (root / 'plugin.yaml').read_text()
if 'kind: platform' not in manifest:
    raise SystemExit('root plugin.yaml kind is not platform')
if 'name: plow-chat-platform' not in manifest:
    raise SystemExit('root plugin.yaml has unexpected plugin name')
if not (root / '__init__.py').exists():
    raise SystemExit('missing root __init__.py')
text = (root / '__init__.py').read_text()
if 'register' not in text or 'adapter.py' not in text:
    raise SystemExit('root __init__.py does not expose adapter register(ctx)')
if 'raise ImportError' not in text:
    raise SystemExit('root __init__.py does not fail closed when adapter.py is missing')
PY

# 5. Secret hygiene check.
python3 - <<'PY'
import pathlib, re
bad = []
paths = [
    pathlib.Path('README.md'),
    pathlib.Path('SEED.md'),
    pathlib.Path('TESTING.md'),
    pathlib.Path('plugin.yaml'),
    pathlib.Path('__init__.py'),
    pathlib.Path('ref'),
]
for path in paths:
    if not path.exists():
        continue
    files = [path] if path.is_file() else [p for p in path.rglob('*') if p.is_file()]
    for file in files:
        text = file.read_text(errors='ignore')
        if re.search(r'sk_[A-Za-z0-9_-]{8,}', text):
            bad.append(f'{file}: literal-looking chat secret')
        for m in re.finditer(r'VERIFY-[A-Z0-9]{6}', text):
            if m.group(0) != 'VERIFY-XXXXXX':
                bad.append(f'{file}: literal-looking verification code')
if bad:
    raise SystemExit('\n'.join(bad))
PY

echo "ok"
