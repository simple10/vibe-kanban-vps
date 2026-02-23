#!/bin/bash
set -euo pipefail

# =============================================================================
# Claude Code Login Helper
# SSHs into the VPS, docker execs into the vibe-kanban container, and runs
# the Claude Code login flow so agents can use OAuth instead of an API key.
#
# Usage: bash claude-login.sh
# =============================================================================

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

SSH_CMD="TERM=xterm-256color ssh -t -i ${SSH_KEY_PATH} -p ${SSH_PORT} -o StrictHostKeyChecking=accept-new ${SSH_USER}@${VPS_IP}"

# --- Run Claude Code login inside the container -----------------------------
echo "Connecting to ${VPS_IP} and running Claude Code login inside the vibe-kanban container..."
echo "A URL will be displayed — open it in your browser to complete the login."
echo ""

$SSH_CMD "${SUDO} docker exec -it vibe-kanban npx -y @anthropic-ai/claude-code@latest /login"
