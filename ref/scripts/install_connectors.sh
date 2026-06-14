#!/usr/bin/env bash
set -euo pipefail

# Installs the `plow-connectors` Hermes skill (Gmail / Google Calendar / Slack)
# into a seed-hermes scaffold's data/skills/ directory. Like
# install_direct_mount.sh, this is a curl/shell installer: it does not call
# `hermes`, `git`, or any Python installer, and it does not start the container.
#
# The skill reuses the plow_chat gateway's PLOW_CHAT_TOKEN + PLOW_CHAT_BASE_URL
# (same account, same host), so there are no new credentials to configure.

SCAFFOLD_DIR="${HERMES_SCAFFOLD_DIR:-./hermes-agent}"
DATA_DIR="${HERMES_DATA_DIR:-}"
SKILL_NAME="plow-connectors"
SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_DIR="${SCRIPT_ROOT}/hermes-skill/${SKILL_NAME}"

usage() {
  cat <<EOF
Usage: ref/scripts/install_connectors.sh [--scaffold ./hermes-agent] [--data-dir DIR]

Installs the ${SKILL_NAME} Hermes skill into <scaffold>/data/skills/${SKILL_NAME}/.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scaffold) SCAFFOLD_DIR="$2"; shift 2 ;;
    --data-dir) DATA_DIR="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -z "$DATA_DIR" ]] && DATA_DIR="${SCAFFOLD_DIR%/}/data"
DEST="${DATA_DIR%/}/skills/${SKILL_NAME}"

[[ -f "${SOURCE_DIR}/SKILL.md" && -f "${SOURCE_DIR}/plow_connector.py" ]] || {
  echo "Source skill files missing under ${SOURCE_DIR}" >&2; exit 1; }

mkdir -p "$DEST"
cp "${SOURCE_DIR}/SKILL.md" "${SOURCE_DIR}/plow_connector.py" "$DEST/"
chmod +x "${DEST}/plow_connector.py"

echo "Installed ${SKILL_NAME} skill into ${DEST}"
echo "It uses the existing PLOW_CHAT_TOKEN/PLOW_CHAT_BASE_URL — no extra config needed."
