#!/usr/bin/env bash
# Clone a git repo into the vibe-kanban container's repos directory.
# Usage: bash clone-repo-remote.sh [<repo-url>]

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

# --- Get repo URL ------------------------------------------------------------
REPO_URL="${1:-}"
if [[ -z "$REPO_URL" ]]; then
    read -r -p "Git repo URL: " REPO_URL
fi

if [[ -z "$REPO_URL" ]]; then
    echo "ERROR: No repo URL provided." >&2
    exit 1
fi

# --- Clone inside the container ----------------------------------------------
REPOS_DIR="${REPOS_DIR:-/home/repos}"
echo "Cloning ${REPO_URL} into ${REPOS_DIR} on vibe-kanban container..."

ssh -t -i "${SSH_KEY_PATH}" -p "${SSH_PORT}" -o StrictHostKeyChecking=accept-new "${SSH_USER}@${VPS_IP}" \
    "${SUDO} docker exec -it -u vkuser -e HOME=/home/vkuser vibe-kanban git clone ${REPO_URL} ${REPOS_DIR}/\$(basename ${REPO_URL} .git)"
