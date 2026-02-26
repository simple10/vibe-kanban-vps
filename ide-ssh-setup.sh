#!/bin/bash
set -euo pipefail

# =============================================================================
# IDE SSH Setup Helper
# Injects your SSH public key into the vibe-kanban container so VS Code / Cursor
# can connect via Remote-SSH. Optionally adds a Host entry to ~/.ssh/config.
#
# Usage: bash ide-ssh-setup.sh [--key <path>] [--no-config]
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Parse flags -------------------------------------------------------------
PUB_KEY_PATH=""
SKIP_CONFIG=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --key)
            PUB_KEY_PATH="$2"
            shift 2
            ;;
        --no-config)
            SKIP_CONFIG=true
            shift
            ;;
        *)
            echo "Unknown option: $1" >&2
            echo "Usage: bash ide-ssh-setup.sh [--key <path-to-public-key>] [--no-config]" >&2
            exit 1
            ;;
    esac
done

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
INSTALL_DIR="${INSTALL_DIR:-/home/vibe-kanban}"
VK_SSH_PORT="${VK_SSH_PORT:-2222}"

SUDO=""
if [[ "${SSH_USER}" != "root" ]]; then
    SUDO="sudo"
fi

SSH_CMD="ssh -i ${SSH_KEY_PATH} -p ${SSH_PORT} -o StrictHostKeyChecking=accept-new ${SSH_USER}@${VPS_IP}"

# --- Colors ------------------------------------------------------------------
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# --- Derive public key -------------------------------------------------------
if [[ -z "$PUB_KEY_PATH" ]]; then
    # Expand ~ in SSH_KEY_PATH
    EXPANDED_KEY_PATH="${SSH_KEY_PATH/#\~/$HOME}"
    PUB_KEY_PATH="${EXPANDED_KEY_PATH}.pub"
fi

if [[ ! -f "$PUB_KEY_PATH" ]]; then
    echo "ERROR: Public key not found at ${PUB_KEY_PATH}" >&2
    echo "Specify a public key with: bash ide-ssh-setup.sh --key /path/to/key.pub" >&2
    exit 1
fi

PUB_KEY=$(cat "$PUB_KEY_PATH")
echo -e "${GREEN}Using public key:${NC} ${PUB_KEY_PATH}"

# --- Inject public key into container ----------------------------------------
echo -e "${YELLOW}Injecting SSH public key into vibe-kanban container...${NC}"

AUTH_KEYS_DIR="${INSTALL_DIR}/data/vk-ssh"
AUTH_KEYS_FILE="${AUTH_KEYS_DIR}/authorized_keys"

# Create authorized_keys if missing, append key if not already present
$SSH_CMD "${SUDO} bash -c '
    mkdir -p ${AUTH_KEYS_DIR}
    touch ${AUTH_KEYS_FILE}
    chmod 600 ${AUTH_KEYS_FILE}
    if grep -qF \"${PUB_KEY}\" ${AUTH_KEYS_FILE} 2>/dev/null; then
        echo \"Key already present in authorized_keys\"
    else
        echo \"${PUB_KEY}\" >> ${AUTH_KEYS_FILE}
        echo \"Key added to authorized_keys\"
    fi
'"

echo -e "${GREEN}SSH key injected successfully.${NC}"

# --- Add Host entry to local ~/.ssh/config -----------------------------------
if [[ "$SKIP_CONFIG" == "true" ]]; then
    echo -e "${YELLOW}Skipping ~/.ssh/config update (--no-config).${NC}"
else
    SSH_CONFIG="$HOME/.ssh/config"
    mkdir -p "$HOME/.ssh"
    touch "$SSH_CONFIG"

    if grep -q "^Host vibe-kanban$" "$SSH_CONFIG" 2>/dev/null; then
        echo -e "${YELLOW}Host 'vibe-kanban' already exists in ${SSH_CONFIG} — skipping.${NC}"
        echo "  To update it, edit ${SSH_CONFIG} manually or remove the existing entry and re-run."
    else
        EXPANDED_KEY_PATH="${SSH_KEY_PATH/#\~/$HOME}"
        cat >> "$SSH_CONFIG" <<EOF

Host vibe-kanban
    HostName ${VPS_IP}
    Port ${VK_SSH_PORT}
    User vkuser
    IdentityFile ${EXPANDED_KEY_PATH}
    StrictHostKeyChecking accept-new
EOF
        echo -e "${GREEN}Added 'vibe-kanban' to ${SSH_CONFIG}${NC}"
    fi
fi

# --- Print instructions ------------------------------------------------------
echo ""
echo -e "${CYAN}=== IDE SSH Setup Complete ===${NC}"
echo ""
echo "  Connect via terminal:"
echo "    ssh vibe-kanban"
echo ""
echo "  VS Code / Cursor:"
echo "    1. Install the Remote-SSH extension"
echo "    2. Cmd+Shift+P → 'Remote-SSH: Connect to Host' → select 'vibe-kanban'"
echo "    3. Open folders like /repos/ or /var/tmp/vibe-kanban/worktrees/"
echo ""
echo "  vibe-kanban UI (Remote SSH Host setting):"
echo "    Set Host to 'vibe-kanban' and User to 'vkuser'"
echo ""
echo -e "${YELLOW}NOTE: Ensure VK_IDE_SSH=true is set in .env and the container has been"
echo -e "redeployed. Also ensure port ${VK_SSH_PORT} is open in your VPS firewall.${NC}"
