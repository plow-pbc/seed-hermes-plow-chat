#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STATE_FILE="${PLOW_CHAT_STATE_FILE:-${HOME}/.hermes/plow_chat_state.json}"
DISPLAY_NAME="${PLOW_CHAT_DISPLAY_NAME:-Hermes user}"
LINE_ID="${PLOW_CHAT_LINE_ID:-}"

usage() {
  cat <<'EOF'
Usage: ref/scripts/bootstrap_fresh_hermes.sh [--state PATH] [--line-id ln_...] [--display-name NAME] [--skip-create]

Installs this SEED as a Hermes plugin from the repo root, creates a Plow chat
unless --skip-create is supplied, writes the resulting state into Hermes' .env,
and prints the gateway start command.

Environment overrides:
  PLOW_CHAT_STATE_FILE
  PLOW_CHAT_DISPLAY_NAME
  PLOW_CHAT_LINE_ID
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

if [[ "$SKIP_CREATE" != "1" ]]; then
  CREATE_ARGS=("${ROOT}/ref/scripts/create_chat.py" --display-name "$DISPLAY_NAME" --state "$STATE_FILE")
  if [[ -n "$LINE_ID" ]]; then
    CREATE_ARGS+=(--line-id "$LINE_ID")
  fi
  python3 "${CREATE_ARGS[@]}"
  echo
  echo "Text the VERIFY code above to the displayed Plow line, then run:"
  echo "  python3 ${ROOT}/ref/scripts/check_chat.py ${STATE_FILE}"
  echo
  echo "After it reports status=active, run this bootstrap again with --skip-create:"
  echo "  ${ROOT}/ref/scripts/bootstrap_fresh_hermes.sh --state ${STATE_FILE} --skip-create"
  exit 0
fi

python3 "${ROOT}/ref/scripts/configure_hermes_env.py" "$STATE_FILE"

echo
echo "Plow Chat plugin is installed and env is configured. Start or restart the gateway:"
echo "  hermes gateway restart"
echo "or foreground for logs:"
echo "  hermes gateway run"
