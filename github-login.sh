#!/bin/bash
set -euo pipefail

# =============================================================================
# GitHub CLI Login Helper
# SSHs into the VPS, docker execs into the vibe-kanban container, runs
# gh auth login (with SSH key generation), then configures git identity.
#
# Usage: bash github-login.sh
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

SSH_CMD="ssh -t -i ${SSH_KEY_PATH} -p ${SSH_PORT} -o StrictHostKeyChecking=accept-new ${SSH_USER}@${VPS_IP}"
DOCKER_EXEC="${SUDO} docker exec -i -u vkuser -e HOME=/home/vkuser vibe-kanban"
DOCKER_EXEC_IT="${SUDO} docker exec -it -u vkuser -e HOME=/home/vkuser vibe-kanban"

YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# --- Run gh auth login inside the container ---------------------------------
echo -e "${YELLOW}Connecting to ${VPS_IP} and running GitHub CLI login inside the vibe-kanban container...${NC}"
echo ""
echo "This script creates a new ssh-key (if needed) securely in the vibe-kanban container."
echo "It adds the key to your github account. The key is persisted in the data/home/.ssh/ bind mount."
echo ""
echo -e "${CYAN}IMPORTANT: When prompted for a passphrase, leave it EMPTY (just press Enter).${NC}"
echo -e "${CYAN}           Agents cannot enter passphrases interactively.${NC}"
echo -e "${CYAN}           Ignore any errors about browser unable to open on the VPS.${NC}"
echo ""

$SSH_CMD "${DOCKER_EXEC_IT} gh auth login --web --git-protocol ssh"

# --- Configure SSH for github.com -------------------------------------------
echo ""
echo "Configuring SSH for GitHub..."

# Find the key gh generated (it uses id_ed25519 by default)
$SSH_CMD "${DOCKER_EXEC} bash -c 'cat > /home/vkuser/.ssh/config << EOF
Host github.com
    IdentityFile /home/vkuser/.ssh/id_ed25519
    StrictHostKeyChecking accept-new
EOF
chmod 600 /home/vkuser/.ssh/config'"

# Configure git to use SSH for GitHub URLs
$SSH_CMD "${DOCKER_EXEC} git config --global url.git@github.com:.insteadOf https://github.com/"

# --- Configure git identity from GitHub profile -----------------------------
echo "Configuring git author identity from GitHub profile..."

# Get name from gh api user
GIT_NAME=$($SSH_CMD "${DOCKER_EXEC} gh api user --jq '.name // .login'" 2>/dev/null | tr -d '\r')

# Get email: first try gh api user, if null fall back to user/emails
GIT_EMAIL=$($SSH_CMD "${DOCKER_EXEC} gh api user --jq '.email // empty'" 2>/dev/null | tr -d '\r')

if [[ -z "${GIT_EMAIL}" ]]; then
    # Fetch from user/emails: prefer noreply address, fall back to primary
    GIT_EMAIL=$($SSH_CMD "${DOCKER_EXEC} gh api user/emails --jq '
        (map(select(.email | test(\"noreply\\.github\\.com\"))) | first // empty) //
        (map(select(.primary)) | first // empty) |
        .email
    '" 2>/dev/null | tr -d '\r')
fi

if [[ -n "${GIT_NAME}" ]]; then
    $SSH_CMD "${DOCKER_EXEC} git config --global user.name '${GIT_NAME}'"
    echo "  git user.name = ${GIT_NAME}"
else
    echo "  WARNING: Could not determine git user.name from GitHub profile"
fi

if [[ -n "${GIT_EMAIL}" ]]; then
    $SSH_CMD "${DOCKER_EXEC} git config --global user.email '${GIT_EMAIL}'"
    echo "  git user.email = ${GIT_EMAIL}"
else
    echo "  WARNING: Could not determine git user.email from GitHub profile"
fi

echo ""
echo "Done. GitHub CLI authenticated, SSH key configured, git identity set."
