#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STATE_FILE="${PLOW_CHAT_STATE_FILE:-${HOME}/.hermes/plow_chat_state.json}"
DISPLAY_NAME="${PLOW_CHAT_DISPLAY_NAME:-Hermes user}"
LINE_ID="${PLOW_CHAT_LINE_ID:-}"
PLOW_CHAT_SEED_DIR="${PLOW_CHAT_SEED_DIR:-${HOME}/.cache/seed-plow-chat}"
PLOW_CHAT_SEED_URL="${PLOW_CHAT_SEED_URL:-https://github.com/plow-pbc/seed-plow-chat.git}"

usage() {
  cat <<'EOF'
Usage: ref/scripts/bootstrap_fresh_hermes.sh [--state PATH] [--line-id ln_...] [--display-name NAME] [--skip-create]

Installs this SEED as a Hermes plugin from the repo root, ensures the
seed-plow-chat dep is cloned, creates a Plow chat via that dep's
ref/examples/create_chat.py (unless --skip-create), writes the resulting
state into Hermes' .env, and prints the gateway start command.

Environment overrides:
  PLOW_CHAT_STATE_FILE   default ~/.hermes/plow_chat_state.json
  PLOW_CHAT_DISPLAY_NAME default "Hermes user"
  PLOW_CHAT_LINE_ID      default first available line from /v1/lines
  PLOW_CHAT_SEED_DIR     default ~/.cache/seed-plow-chat
  PLOW_CHAT_SEED_URL     default https://github.com/plow-pbc/seed-plow-chat.git
EOF
}

SKIP_CREATE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --state) STATE_FILE="$2"; shift 2 ;;
    --line-id) LINE_ID="$2"; shift 2 ;;
    --display-name) DISPLAY_NAME="$2"; shift 2 ;;
    --skip-create) SKIP_CREATE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

command -v hermes >/dev/null || { echo "hermes command not found" >&2; exit 1; }
command -v git >/dev/null || { echo "git command not found; hermes plugins install needs git" >&2; exit 1; }
python3 - <<'PY'
try:
    import aiohttp  # noqa: F401
except ImportError:
    raise SystemExit("Python package aiohttp is required. Install it in Hermes' Python env before running the gateway.")
PY

# Git plugin installs clone the repository root. Because this SEED has root
# plugin.yaml + __init__.py, a fresh Hermes can point directly at the SEED.
hermes plugins install "file://${ROOT}" --force --enable

# Ensure the seed-plow-chat dep is available; bootstrap clones it on demand so
# this script also works when invoked outside a SEED-aware agent.
if [[ ! -d "${PLOW_CHAT_SEED_DIR}/.git" ]]; then
  mkdir -p "$(dirname "${PLOW_CHAT_SEED_DIR}")"
  git clone --depth 1 "${PLOW_CHAT_SEED_URL}" "${PLOW_CHAT_SEED_DIR}"
fi

if [[ "$SKIP_CREATE" != "1" ]]; then
  CREATE_ARGS=("${PLOW_CHAT_SEED_DIR}/ref/examples/create_chat.py" --display-name "$DISPLAY_NAME" --state "$STATE_FILE")
  if [[ -n "$LINE_ID" ]]; then
    CREATE_ARGS+=(--line-id "$LINE_ID")
  fi
  python3 "${CREATE_ARGS[@]}"
  echo
  echo "Text the VERIFY code above to the displayed Plow line."
  echo "This script will configure Hermes now; the gateway can connect while the chat is pending."
  echo "When Plow emits chat_active after verification, Hermes will send the welcome message automatically."
fi

python3 "${ROOT}/ref/scripts/configure_hermes_env.py" "$STATE_FILE"

echo
echo "Plow Chat plugin is installed and env is configured. Start or restart the gateway now:"
echo "  hermes gateway restart"
echo "or foreground for logs:"
echo "  hermes gateway run"
echo
echo "If you want to inspect activation manually:"
echo "  python3 ${PLOW_CHAT_SEED_DIR}/ref/examples/check_chat.py ${STATE_FILE}"
