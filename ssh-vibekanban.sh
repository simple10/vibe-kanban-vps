#!/usr/bin/env bash
# SSH into vibe-kanban container
# Usage: bash ssh-vibekanban.sh

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

SUDO=""
if [[ "${SSH_USER}" != "root" ]]; then
    SUDO="sudo"
fi

printf "\033[32mSSH'ing into vibe-kanban container on ${VPS_IP}\033[0m\n"
TERM=xterm-256color ssh -t -i "${SSH_KEY_PATH}" -p "${SSH_PORT}" "${SSH_USER}@${VPS_IP}" \
    "${SUDO} docker exec -it -u vkuser -e HOME=/home/vkuser -e TERM=xterm-256color vibe-kanban bash"
