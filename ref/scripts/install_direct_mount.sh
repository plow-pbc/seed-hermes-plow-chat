#!/usr/bin/env bash
set -euo pipefail

DATA_DIR="${HERMES_DATA_DIR:-./data}"
PLUGIN_NAME="plow-chat-platform"
PLUGIN_DIR=""
SOURCE_DIR=""
RAW_BASE="${PLOW_CHAT_SEED_RAW_BASE:-https://raw.githubusercontent.com/plow-pbc/seed-hermes-plow-chat/main}"

usage() {
  cat <<'EOF'
Usage: ref/scripts/install_direct_mount.sh [--data-dir ./data] [--source-dir PATH]

Places the Plow Chat Hermes plugin directly into:

  <data-dir>/plugins/plow-chat-platform/

and ensures <data-dir>/config.yaml enables the manifest name
plow-chat-platform. This helper does not call `hermes`, `git`, or the Hermes
plugin installer. It uses local source files when --source-dir is supplied,
otherwise it downloads the required file set with curl.

Environment overrides:
  HERMES_DATA_DIR              default ./data
  PLOW_CHAT_SEED_RAW_BASE      default raw GitHub main URL
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --data-dir) DATA_DIR="$2"; shift 2 ;;
    --source-dir) SOURCE_DIR="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

PLUGIN_DIR="${DATA_DIR%/}/plugins/${PLUGIN_NAME}"
CONFIG_FILE="${DATA_DIR%/}/config.yaml"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

copy_or_fetch() {
  local rel="$1"
  local dest="${PLUGIN_DIR}/${rel}"
  mkdir -p "$(dirname "$dest")"
  if [[ -n "$SOURCE_DIR" ]]; then
    cp "${SOURCE_DIR%/}/${rel}" "$dest"
  else
    require_cmd curl
    curl -fsSL "${RAW_BASE%/}/${rel}" -o "$dest"
  fi
}

enable_plugin_in_config() {
  mkdir -p "$(dirname "$CONFIG_FILE")"
  if [[ ! -f "$CONFIG_FILE" ]]; then
    cat >"$CONFIG_FILE" <<'EOF'
plugins:
  enabled:
    - plow-chat-platform
  disabled: []
terminal:
  cwd: /opt/data/workspace
EOF
    return
  fi

  if grep -Eq '^[[:space:]]*-[[:space:]]*plow-chat-platform[[:space:]]*$|enabled:[[:space:]]*\[[^]]*plow-chat-platform' "$CONFIG_FILE"; then
    return
  fi

  local tmp
  tmp="$(mktemp)"
  awk '
    BEGIN { in_plugins = 0; inserted = 0; saw_plugins = 0 }
    /^plugins:[[:space:]]*$/ {
      saw_plugins = 1
      in_plugins = 1
      print
      next
    }
    in_plugins && /^[^[:space:]][^:]*:/ {
      if (!inserted) {
        print "  enabled:"
        print "    - plow-chat-platform"
        inserted = 1
      }
      in_plugins = 0
    }
    in_plugins && /^  enabled:[[:space:]]*\[[[:space:]]*\][[:space:]]*$/ {
      print "  enabled:"
      print "    - plow-chat-platform"
      inserted = 1
      next
    }
    in_plugins && /^  enabled:[[:space:]]*$/ {
      print
      print "    - plow-chat-platform"
      inserted = 1
      next
    }
    { print }
    END {
      if (in_plugins && !inserted) {
        print "  enabled:"
        print "    - plow-chat-platform"
      }
      if (!saw_plugins) {
        print ""
        print "plugins:"
        print "  enabled:"
        print "    - plow-chat-platform"
        print "  disabled: []"
      }
    }
  ' "$CONFIG_FILE" >"$tmp"
  mv "$tmp" "$CONFIG_FILE"
}

mkdir -p "$PLUGIN_DIR"
copy_or_fetch "plugin.yaml"
copy_or_fetch "__init__.py"
copy_or_fetch "ref/hermes-plugin/plow_chat/adapter.py"

mkdir -p "${DATA_DIR%/}/workspace"
enable_plugin_in_config

echo "Installed ${PLUGIN_NAME} into ${PLUGIN_DIR}"
echo "Enabled ${PLUGIN_NAME} in ${CONFIG_FILE}"
