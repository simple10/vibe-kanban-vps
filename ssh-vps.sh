#!/usr/bin/env bash
# SSH into VPS (vibe-kanban)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Load .env --------------------------------------------------------------
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "${SCRIPT_DIR}/.env"
    set +a
else
    echo "ERROR: .env not found in ${SCRIPT_DIR}" >&2
    exit 1
fi

# --- Validate required vars -------------------------------------------------
: "${VPS_IP:?VPS_IP is required in .env}"
: "${SSH_KEY_PATH:?SSH_KEY_PATH is required in .env}"
SSH_USER="${SSH_USER:-root}"
SSH_PORT="${SSH_PORT:-22}"

printf "\033[32mSSH'ing into Vibe Kanban VPS as ${SSH_USER}@${VPS_IP} \033[0m\n"
# Set TERM to fix issues when running this script via ghostty
TERM=xterm-256color ssh -t -i "${SSH_KEY_PATH}" -p "${SSH_PORT}" "${SSH_USER}@${VPS_IP}"
