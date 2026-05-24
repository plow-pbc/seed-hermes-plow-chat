#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${PLOW_CHAT_BASE_URL:-https://api.plow.co}"
SCAFFOLD_DIR="${HERMES_SCAFFOLD_DIR:-./hermes-agent}"
DATA_DIR="${HERMES_DATA_DIR:-}"
DISPLAY_NAME="${PLOW_CHAT_DISPLAY_NAME:-Hermes user}"
TIMEOUT_SECONDS="${PLOW_CHAT_VERIFY_TIMEOUT:-900}"
POLL_INTERVAL="${PLOW_CHAT_VERIFY_POLL_INTERVAL:-5}"
POLL=1

usage() {
  cat <<'EOF'
Usage: ref/scripts/create_plow_chat_curl.sh [options]

Starts Plow activation with provision_chat=true, prints the activation message,
polls activation redeem until verified, then writes PLOW_CHAT_* to the target
scaffold's data/.env.

Options:
  --scaffold PATH        seed-hermes scaffold directory, default ./hermes-agent
  --data-dir PATH        Explicit Hermes data directory override
  --base-url URL         Plow API base URL, default https://api.plow.co
  --display-name NAME   Session display name, default "Hermes user"
  --timeout SECONDS     Poll timeout, default 900
  --interval SECONDS    Poll interval, default 5
  --no-poll             Start activation, print instructions, then exit

Environment overrides:
  HERMES_SCAFFOLD_DIR
  HERMES_DATA_DIR
  PLOW_CHAT_BASE_URL
  PLOW_CHAT_DISPLAY_NAME
  PLOW_CHAT_VERIFY_TIMEOUT
  PLOW_CHAT_VERIFY_POLL_INTERVAL
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scaffold) SCAFFOLD_DIR="$2"; shift 2 ;;
    --data-dir) DATA_DIR="$2"; shift 2 ;;
    --base-url) BASE_URL="$2"; shift 2 ;;
    --display-name) DISPLAY_NAME="$2"; shift 2 ;;
    --timeout) TIMEOUT_SECONDS="$2"; shift 2 ;;
    --interval) POLL_INTERVAL="$2"; shift 2 ;;
    --no-poll) POLL=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

BASE_URL="${BASE_URL%/}"
if [[ -z "$DATA_DIR" ]]; then
  DATA_DIR="${SCAFFOLD_DIR%/}/data"
fi
ENV_FILE="${DATA_DIR%/}/.env"

command -v curl >/dev/null 2>&1 || {
  echo "Missing required command: curl" >&2
  exit 1
}

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

json_object_value() {
  local json="$1"
  local key="$2"
  printf '%s' "$json" |
    tr '\n' ' ' |
    grep -oE "\"${key}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" |
    head -n 1 |
    sed -nE "s/\"${key}\"[[:space:]]*:[[:space:]]*\"([^\"]*)\"/\1/p" ||
    true
}

json_chat_value() {
  local json="$1"
  local key="$2"
  local chat
  chat="$(
    printf '%s' "$json" |
      tr '\n' ' ' |
      sed -nE 's/.*"chat"[[:space:]]*:[[:space:]]*(\{.*\}).*/\1/p' |
      sed -E 's/"participants"[[:space:]]*:[[:space:]]*\[[^][]*\]//g' ||
      true
  )"
  json_object_value "$chat" "$key"
}

json_value() {
  local json="$1"
  local jq_expr="$2"
  local key="$3"
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$json" | jq -r "$jq_expr // empty" 2>/dev/null || true
    return
  fi
  case "$jq_expr" in
    '.chat.uid')
      json_chat_value "$json" "$key"
      ;;
    *)
      json_object_value "$json" "$key"
      ;;
  esac
}

write_env_var() {
  local key="$1"
  local value="$2"
  local tmp
  mkdir -p "$(dirname "$ENV_FILE")"
  tmp="$(mktemp)"
  if [[ -f "$ENV_FILE" ]]; then
    awk -F= -v key="$key" '$1 != key { print }' "$ENV_FILE" >"$tmp"
  fi
  printf '%s=%s\n' "$key" "$value" >>"$tmp"
  mv "$tmp" "$ENV_FILE"
  chmod 600 "$ENV_FILE" 2>/dev/null || true
}

PAYLOAD="$(printf '{"name":"%s","provision_chat":true}' "$(json_escape "$DISPLAY_NAME")")"

echo "Starting Plow activation..."
ACTIVATION_JSON="$(curl -fsSL \
  -H 'Content-Type: application/json' \
  -d "$PAYLOAD" \
  "${BASE_URL}/v1/auth/activate")"

DISPLAY_CODE="$(json_value "$ACTIVATION_JSON" '.display_code' 'display_code')"
ACTIVATION_SECRET="$(json_value "$ACTIVATION_JSON" '.activation_secret' 'activation_secret')"
SEND_TO="$(json_value "$ACTIVATION_JSON" '.send_to' 'send_to')"
LINE_ID="$(json_value "$ACTIVATION_JSON" '.line_id' 'line_id')"

if [[ -z "$DISPLAY_CODE" || -z "$ACTIVATION_SECRET" || -z "$SEND_TO" ]]; then
  echo "Could not parse display code, activation secret, or send_to from Plow activation response." >&2
  echo "Response was saved nowhere to avoid leaking activation credentials." >&2
  exit 1
fi

echo
echo "Plow activation started."
if [[ -n "$LINE_ID" ]]; then
  echo "Line uid: ${LINE_ID}"
fi
echo "Text Plow Activate: ${DISPLAY_CODE} from iMessage to ${SEND_TO}"
echo

if [[ "$POLL" != "1" ]]; then
  echo "Activation is not complete yet; rerun with polling to write PLOW_CHAT_* after the text is sent."
  exit 0
fi

echo "Polling activation redeem until verified..."
deadline=$(( $(date +%s) + TIMEOUT_SECONDS ))
last_status=""
while [[ "$(date +%s)" -lt "$deadline" ]]; do
  REDEEM_JSON="$(curl -fsSL \
    -H 'Content-Type: application/json' \
    -d "$(printf '{"activation_secret":"%s"}' "$(json_escape "$ACTIVATION_SECRET")")" \
    "${BASE_URL}/v1/auth/activate/redeem")"
  STATUS="$(json_value "$REDEEM_JSON" '.status' 'status')"
  if [[ "$STATUS" != "$last_status" ]]; then
    echo "Status: ${STATUS:-unknown}"
    last_status="$STATUS"
  fi
  if [[ "$STATUS" == "verified" ]]; then
    TOKEN="$(json_value "$REDEEM_JSON" '.token' 'token')"
    CHAT_UID="$(json_value "$REDEEM_JSON" '.chat.uid' 'uid')"
    if [[ -z "$TOKEN" || -z "$CHAT_UID" ]]; then
      echo "Activation verified, but redeem did not include both token and chat uid." >&2
      exit 1
    fi
    mkdir -p "$DATA_DIR"
    write_env_var "PLOW_CHAT_BASE_URL" "$BASE_URL"
    write_env_var "PLOW_CHAT_CHAT_UID" "$CHAT_UID"
    write_env_var "PLOW_CHAT_TOKEN" "$TOKEN"
    write_env_var "PLOW_CHAT_HOME_CHANNEL" "$CHAT_UID"
    echo "Verified: chat is active."
    echo "Chat uid: ${CHAT_UID}"
    echo "Wrote PLOW_CHAT_* to ${ENV_FILE}"
    exit 0
  fi
  sleep "$POLL_INTERVAL"
done

echo "Timed out waiting for activation after ${TIMEOUT_SECONDS}s." >&2
echo "If the activation code expired, start activation again for a new code." >&2
exit 124
