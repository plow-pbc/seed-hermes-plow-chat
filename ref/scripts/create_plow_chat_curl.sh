#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${PLOW_CHAT_BASE_URL:-https://chat.plow.co}"
DATA_DIR="${HERMES_DATA_DIR:-./data}"
LINE_ID="${PLOW_CHAT_LINE_ID:-}"
DISPLAY_NAME="${PLOW_CHAT_DISPLAY_NAME:-Hermes user}"
TIMEOUT_SECONDS="${PLOW_CHAT_VERIFY_TIMEOUT:-900}"
POLL_INTERVAL="${PLOW_CHAT_VERIFY_POLL_INTERVAL:-5}"
POLL=1

usage() {
  cat <<'EOF'
Usage: ref/scripts/create_plow_chat_curl.sh [options]

Creates a Plow Chat using curl, writes PLOW_CHAT_* to ./data/.env, prints the
verification code, and polls GET /v1/chats/{uid} with X-Chat-Secret-Key until
the chat becomes active or the timeout expires.

Options:
  --data-dir PATH        Hermes data directory, default ./data
  --base-url URL         Plow Chat base URL, default https://chat.plow.co
  --line-id ln_...      Plow line uid; default first line from /v1/lines
  --display-name NAME   Member display name, default "Hermes user"
  --timeout SECONDS     Poll timeout, default 900
  --interval SECONDS    Poll interval, default 5
  --no-poll             Create the chat and write env, then exit

Environment overrides:
  HERMES_DATA_DIR
  PLOW_CHAT_BASE_URL
  PLOW_CHAT_LINE_ID
  PLOW_CHAT_DISPLAY_NAME
  PLOW_CHAT_VERIFY_TIMEOUT
  PLOW_CHAT_VERIFY_POLL_INTERVAL
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --data-dir) DATA_DIR="$2"; shift 2 ;;
    --base-url) BASE_URL="$2"; shift 2 ;;
    --line-id) LINE_ID="$2"; shift 2 ;;
    --display-name) DISPLAY_NAME="$2"; shift 2 ;;
    --timeout) TIMEOUT_SECONDS="$2"; shift 2 ;;
    --interval) POLL_INTERVAL="$2"; shift 2 ;;
    --no-poll) POLL=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

BASE_URL="${BASE_URL%/}"
ENV_FILE="${DATA_DIR%/}/.env"
STATE_FILE="${DATA_DIR%/}/plow_chat_state.json"

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

json_top_value() {
  local json="$1"
  local key="$2"
  local flat
  flat="$(printf '%s' "$json" | tr '\n' ' ')"
  # The fallback parser is intentionally narrow: strip participant arrays so
  # repeated keys like uid/status inside participants cannot be mistaken for
  # top-level chat fields.
  flat="$(printf '%s' "$flat" | sed -E 's/"participants"[[:space:]]*:[[:space:]]*\[[^][]*\]//g')"
  json_object_value "$flat" "$key"
}

json_member_value() {
  local json="$1"
  local key="$2"
  local member
  member="$(
    printf '%s' "$json" |
      tr '\n' ' ' |
      grep -oE '\{[^{}]*"type"[[:space:]]*:[[:space:]]*"member"[^{}]*\}' |
      head -n 1 ||
      true
  )"
  json_object_value "$member" "$key"
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
    '.uid // .chat.uid'|'.secret_key // .chat.secret_key'|'.status')
      json_top_value "$json" "$key"
      ;;
    '(.participants[]? | select(.type == "member") | .verification_code) // .verification_code'|\
    '(.participants[]? | select(.type == "member") | .verification_code_expires_at) // .verification_code_expires_at'|\
    '(.participants[]? | select(.type == "member") | .uid)')
      json_member_value "$json" "$key"
      ;;
    *)
      json_object_value "$json" "$key"
      ;;
  esac
}

line_object_by_uid() {
  local json="$1"
  local uid="$2"
  if [[ -z "$uid" ]]; then
    printf '%s' "$json"
    return
  fi
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$json" | jq -c --arg uid "$uid" '.data[]? | select(.uid == $uid)' 2>/dev/null || true
    return
  fi
  printf '%s' "$json" |
    tr '\n' ' ' |
    sed -nE "s/.*(\{[^{}]*\"uid\"[[:space:]]*:[[:space:]]*\"${uid}\"[^{}]*\}).*/\1/p" |
    head -n 1
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

echo "Fetching Plow Chat lines..."
LINES_JSON="$(curl -fsSL "${BASE_URL}/v1/lines")"
LINE_JSON="$(line_object_by_uid "$LINES_JSON" "$LINE_ID")"
if [[ -z "$LINE_JSON" ]]; then
  echo "Line ${LINE_ID} was not returned by ${BASE_URL}/v1/lines" >&2
  exit 1
fi

if [[ -z "$LINE_ID" ]]; then
  LINE_ID="$(json_value "$LINE_JSON" '.data[0].uid' 'uid')"
fi
LINE_PROVIDER_KEY="$(json_value "$LINE_JSON" '.provider_key // .data[0].provider_key' 'provider_key')"
if [[ -z "$LINE_ID" ]]; then
  echo "Could not read a Plow line uid from ${BASE_URL}/v1/lines" >&2
  exit 1
fi

PAYLOAD="$(printf '{"participants":[{"type":"agent","line_id":"%s"},{"type":"member","display_name":"%s"}]}' "$LINE_ID" "$(json_escape "$DISPLAY_NAME")")"

echo "Creating Plow Chat on line ${LINE_ID}..."
CHAT_JSON="$(curl -fsSL \
  -H 'Content-Type: application/json' \
  -d "$PAYLOAD" \
  "${BASE_URL}/v1/chats")"

CHAT_UID="$(json_value "$CHAT_JSON" '.uid // .chat.uid' 'uid')"
SECRET_KEY="$(json_value "$CHAT_JSON" '.secret_key // .chat.secret_key' 'secret_key')"
VERIFY_CODE="$(json_value "$CHAT_JSON" '(.participants[]? | select(.type == "member") | .verification_code) // .verification_code' 'verification_code')"
VERIFY_EXPIRES_AT="$(json_value "$CHAT_JSON" '(.participants[]? | select(.type == "member") | .verification_code_expires_at) // .verification_code_expires_at' 'verification_code_expires_at')"
MEMBER_UID="$(json_value "$CHAT_JSON" '(.participants[]? | select(.type == "member") | .uid)' 'uid')"

if [[ -z "$CHAT_UID" || -z "$SECRET_KEY" || -z "$VERIFY_CODE" ]]; then
  echo "Could not parse chat uid, secret key, or verification code from Plow Chat response." >&2
  echo "Response was saved nowhere to avoid leaking the chat secret." >&2
  exit 1
fi

mkdir -p "$DATA_DIR"
cat >"$STATE_FILE" <<EOF
{
  "base_url": "$BASE_URL",
  "line_uid": "$LINE_ID",
  "line_provider_key": "$LINE_PROVIDER_KEY",
  "chat_uid": "$CHAT_UID",
  "member_uid": "$MEMBER_UID",
  "verification_code": "$VERIFY_CODE",
  "verification_code_expires_at": "$VERIFY_EXPIRES_AT"
}
EOF
chmod 600 "$STATE_FILE" 2>/dev/null || true

write_env_var "PLOW_CHAT_BASE_URL" "$BASE_URL"
write_env_var "PLOW_CHAT_CHAT_UID" "$CHAT_UID"
write_env_var "PLOW_CHAT_SECRET_KEY" "$SECRET_KEY"
write_env_var "PLOW_CHAT_HOME_CHANNEL" "$CHAT_UID"

echo
echo "Plow Chat created."
echo "Chat uid: ${CHAT_UID}"
echo "Wrote PLOW_CHAT_* to ${ENV_FILE}"
echo "Text this code from iMessage: ${VERIFY_CODE}"
if [[ -n "$LINE_PROVIDER_KEY" ]]; then
  echo "To this Plow line: ${LINE_PROVIDER_KEY}"
else
  echo "To the Plow line with uid: ${LINE_ID}"
fi
if [[ -n "$VERIFY_EXPIRES_AT" ]]; then
  echo "Code expires at: ${VERIFY_EXPIRES_AT}"
fi
echo
echo "Start Hermes with docker compose before texting the code so the plugin can send the chat_active welcome."

if [[ "$POLL" != "1" ]]; then
  exit 0
fi

echo "Polling chat status until active..."
deadline=$(( $(date +%s) + TIMEOUT_SECONDS ))
last_status=""
while [[ "$(date +%s)" -lt "$deadline" ]]; do
  STATUS_JSON="$(curl -fsSL \
    -H "X-Chat-Secret-Key: ${SECRET_KEY}" \
    "${BASE_URL}/v1/chats/${CHAT_UID}")"
  STATUS="$(json_value "$STATUS_JSON" '.status' 'status')"
  if [[ "$STATUS" != "$last_status" ]]; then
    echo "Status: ${STATUS:-unknown}"
    last_status="$STATUS"
  fi
  case "$STATUS" in
    active)
      echo "Verified: chat is active."
      exit 0
      ;;
    failed)
      echo "Plow reported chat activation failed. Recreate the chat to get a new verification code." >&2
      exit 1
      ;;
  esac
  sleep "$POLL_INTERVAL"
done

echo "Timed out waiting for chat activation after ${TIMEOUT_SECONDS}s." >&2
echo "If the verification code expired or Hermes did not send the welcome, recreate the chat for a new code." >&2
exit 124
