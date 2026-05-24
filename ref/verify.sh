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
mkdir -p "$tmpdir/hermes-agent"
PLOW_CHAT_PLUGIN_LOCAL_DIR=. ref/scripts/install_direct_mount.sh --scaffold "$tmpdir/hermes-agent" >/tmp/seed-hermes-plow-chat-install.out

for path in \
  "$tmpdir/hermes-agent/data/plugins/plow-chat-platform/plugin.yaml" \
  "$tmpdir/hermes-agent/data/plugins/plow-chat-platform/__init__.py" \
  "$tmpdir/hermes-agent/data/plugins/plow-chat-platform/ref/hermes-plugin/plow_chat/adapter.py"
do
  [[ -f "$path" ]] || { echo "missing direct-mounted file: $path" >&2; exit 1; }
done

grep -q 'plow-chat-platform' "$tmpdir/hermes-agent/data/config.yaml" || {
  echo 'config.yaml does not enable plow-chat-platform' >&2
  exit 1
}
cat >"$tmpdir/hermes-agent/data/config.yaml" <<'YAML'
plugins:
  enabled: [other-plugin]
  disabled:
    - plow-chat-platform
    - keep-disabled
terminal:
  cwd: /opt/data/workspace
YAML
PLOW_CHAT_PLUGIN_LOCAL_DIR=. ref/scripts/install_direct_mount.sh --scaffold "$tmpdir/hermes-agent" >/tmp/seed-hermes-plow-chat-install-existing.out
grep -q 'enabled: \[other-plugin, plow-chat-platform\]' "$tmpdir/hermes-agent/data/config.yaml" || {
  echo 'config.yaml inline enabled list was not preserved and extended' >&2
  exit 1
}
if awk '/disabled:/{in_disabled=1; next} in_disabled && /^  [^ ]/{in_disabled=0} in_disabled && /plow-chat-platform/{found=1} END{exit found ? 0 : 1}' "$tmpdir/hermes-agent/data/config.yaml"; then
  echo 'config.yaml still disables plow-chat-platform after install' >&2
  exit 1
fi

# 3. Host shell helpers are syntax-valid and contain no Python/git/Hermes CLI dependency.
bash -n ref/scripts/install_direct_mount.sh ref/scripts/create_plow_chat_curl.sh
if [[ -e after-install.md || -e ref/scripts/bootstrap_fresh_hermes.sh || -e ref/scripts/configure_hermes_env.py ]]; then
  echo 'old host installer artifact still exists' >&2
  exit 1
fi
if grep -rnE 'python3|git clone|hermes plugins|hermes gateway|GH[_]TOKEN|PLOW_CHAT_LINE|--line' ref/scripts; then
  echo 'host scripts still reference Python/git/Hermes installer artifacts' >&2
  exit 1
fi

# 4. jq-less curl orchestration check. The host path guarantees curl, not jq;
# keep jq out of PATH and verify optional missing fields do not abort parsing.
mockdir="$(mktemp -d)"
mkdir -p "$mockdir/bin" "$mockdir/hermes-agent"
for cmd in bash tr grep head sed mktemp mkdir awk mv chmod date sleep dirname cat cp; do
  target="$(command -v "$cmd")"
  ln -s "$target" "$mockdir/bin/$cmd"
done
cat >"$mockdir/bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
url="${@: -1}"
case "$url" in
  */v1/auth/activate)
    printf '{"display_code":"ABCDE","activation_secret":"act_test","send_to":"+15551234567","line_id":"ln_test"}\n'
    ;;
  */v1/auth/activate/redeem)
    count_file="${PLOW_FAKE_COUNT_FILE:?}"
    count=0
    [[ -f "$count_file" ]] && count="$(cat "$count_file")"
    count=$((count + 1))
    printf '%s' "$count" >"$count_file"
    if [[ "$count" -lt 2 ]]; then
      printf '{"status":"pending"}\n'
    else
      printf '{"status":"verified","token":"token_test","chat":{"uid":"cht_test","status":"active","participants":[{"type":"member","status":"active"}]}}\n'
    fi
    ;;
  *)
    echo "unexpected url: $url" >&2
    exit 2
    ;;
esac
SH
chmod +x "$mockdir/bin/curl"
PATH="$mockdir/bin" PLOW_FAKE_COUNT_FILE="$mockdir/count" \
  bash ref/scripts/create_plow_chat_curl.sh \
    --scaffold "$mockdir/hermes-agent" \
    --base-url https://chat.plow.test \
    --interval 0 \
    --timeout 3 >"$mockdir/out.txt"
grep -q 'Verified: chat is active.' "$mockdir/out.txt" || {
  echo 'jq-less curl orchestration did not poll to active' >&2
  exit 1
}
grep -q 'PLOW_CHAT_CHAT_UID=cht_test' "$mockdir/hermes-agent/data/.env" || {
  echo 'jq-less curl orchestration wrote wrong chat uid' >&2
  exit 1
}
grep -q 'PLOW_CHAT_TOKEN=token_test' "$mockdir/hermes-agent/data/.env" || {
  echo 'jq-less curl orchestration wrote wrong token' >&2
  exit 1
}
grep -q 'Text Plow Activate: ABCDE from iMessage to +15551234567' "$mockdir/out.txt" || {
  echo 'jq-less curl orchestration did not surface the selected line phone number' >&2
  exit 1
}
if [[ -e "$mockdir/hermes-agent/data/plow_chat_state.json" ]]; then
  echo 'curl orchestration wrote secret-bearing sidecar state' >&2
  exit 1
fi
if grep -q 'Code expires at:' "$mockdir/out.txt"; then
  echo 'jq-less curl orchestration surfaced missing optional expiry' >&2
  exit 1
fi

# 5. Root plugin installability check.
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

# 6. Secret hygiene check.
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
        if re.search(r'plow_[A-Za-z0-9-]{16,}', text):
            bad.append(f'{file}: literal-looking session token')
        for m in re.finditer(r'Plow Activate: ([A-Z0-9]{5,})', text):
            if m.group(1) != 'ABCDE':
                bad.append(f'{file}: literal-looking activation code')
if bad:
    raise SystemExit('\n'.join(bad))
PY

echo "ok"
