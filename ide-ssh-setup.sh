#!/bin/bash
set -euo pipefail

# =============================================================================
# IDE SSH Setup Helper
# Injects your SSH public key into the vibe-kanban container so VS Code / Cursor
# can connect via Remote-SSH. Optionally adds a Host entry to ~/.ssh/config.
#
# Usage: bash ide-ssh-setup.sh [--key <path>] [--no-config] [--yes|-y]
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Parse flags -------------------------------------------------------------
PUB_KEY_PATH=""
SKIP_CONFIG=false
AUTO_YES=false

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
        --yes|-y)
            AUTO_YES=true
            shift
            ;;
        *)
            echo "Unknown option: $1" >&2
            echo "Usage: bash ide-ssh-setup.sh [--key <path-to-public-key>] [--no-config] [--yes|-y]" >&2
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

SSH_CMD="ssh -n -i ${SSH_KEY_PATH} -p ${SSH_PORT} -o StrictHostKeyChecking=accept-new ${SSH_USER}@${VPS_IP}"

# --- Colors ------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Track changes for the summary
CHANGES_LOCAL=()
CHANGES_VPS_HOST=()
CHANGES_CONTAINER=()

# Backup directory on the VPS for uninstall/rollback
UNINSTALL_DIR="${INSTALL_DIR}/.uninstall"

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

AUTH_KEYS_DIR="${INSTALL_DIR}/data/home/.ssh"
AUTH_KEYS_FILE="${AUTH_KEYS_DIR}/authorized_keys"

# Create authorized_keys if missing, append key if not already present
KEY_RESULT=$($SSH_CMD "${SUDO} bash -c '
    mkdir -p ${AUTH_KEYS_DIR}
    touch ${AUTH_KEYS_FILE}
    chmod 600 ${AUTH_KEYS_FILE}
    if grep -qF \"${PUB_KEY}\" ${AUTH_KEYS_FILE} 2>/dev/null; then
        echo \"already_present\"
    else
        echo \"${PUB_KEY}\" >> ${AUTH_KEYS_FILE}
        echo \"added\"
    fi
'")

# Fix ownership inside the container — sysbox remaps UIDs so host chown won't match.
# docker exec sees the container's UID namespace where vkuser is the correct owner.
$SSH_CMD "${SUDO} docker exec vibe-kanban chown vkuser:vkuser /home/vkuser/.ssh/authorized_keys"

if [[ "$KEY_RESULT" == "added" ]]; then
    echo -e "${GREEN}SSH key added to authorized_keys.${NC}"
    CHANGES_CONTAINER+=("Added SSH public key to container authorized_keys")
else
    echo -e "${GREEN}SSH key already present in authorized_keys.${NC}"
fi

# --- Ensure VPS sshd allows local TCP forwarding (required for ProxyJump) ----
echo -e "${YELLOW}Checking VPS sshd AllowTcpForwarding setting...${NC}"

TCP_FWD=$($SSH_CMD "${SUDO} bash -c '
    # Check all sshd config files for the effective AllowTcpForwarding value
    val=\$(${SUDO} sshd -T 2>/dev/null | grep -i \"^allowtcpforwarding \" | awk \"{print \\\$2}\")
    echo \"\${val:-unknown}\"
'")

if [[ "$TCP_FWD" == "yes" || "$TCP_FWD" == "local" ]]; then
    echo -e "${GREEN}AllowTcpForwarding is '${TCP_FWD}' — ProxyJump will work.${NC}"
else
    echo ""
    echo -e "${RED}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║  VPS HOST CHANGE REQUIRED                                      ║${NC}"
    echo -e "${RED}╚══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  The VPS sshd has ${YELLOW}AllowTcpForwarding ${TCP_FWD}${NC}"
    echo -e "  ProxyJump requires ${GREEN}AllowTcpForwarding local${NC}"
    echo ""
    echo -e "  This changes the VPS SSH daemon config (outside the container)."
    echo -e "  'local' only permits forwarding to 127.0.0.1 — no remote forwarding."
    echo ""
    echo -e "  ${CYAN}File: /etc/ssh/sshd_config.d/hardening.conf${NC}"
    echo -e "  ${CYAN}Change: AllowTcpForwarding ${TCP_FWD} → AllowTcpForwarding local${NC}"
    echo ""
    if [[ "$AUTO_YES" == "true" ]]; then
        REPLY=y
    else
        read -r -p "  Apply this change and restart sshd? [y/N] " REPLY
        echo ""
    fi

    if [[ "$REPLY" =~ ^[Yy]$ ]]; then
        # Back up sshd config files before modifying
        echo -e "${YELLOW}Backing up VPS sshd config...${NC}"
        BACKUP_RESULT=$($SSH_CMD "${SUDO} bash -c '
            BACKUP_DIR=${UNINSTALL_DIR}/sshd
            mkdir -p \"\$BACKUP_DIR\"
            BACKED_UP=0
            # Back up main sshd_config
            if [[ -f /etc/ssh/sshd_config ]] && [[ ! -f \"\$BACKUP_DIR/sshd_config\" ]]; then
                cp /etc/ssh/sshd_config \"\$BACKUP_DIR/sshd_config\"
                echo \"Backed up /etc/ssh/sshd_config\"
                BACKED_UP=1
            fi
            # Back up all sshd_config.d/ files
            if [[ -d /etc/ssh/sshd_config.d/ ]]; then
                mkdir -p \"\$BACKUP_DIR/sshd_config.d\"
                for f in /etc/ssh/sshd_config.d/*.conf; do
                    [[ -f \"\$f\" ]] || continue
                    fname=\$(basename \"\$f\")
                    if [[ ! -f \"\$BACKUP_DIR/sshd_config.d/\$fname\" ]]; then
                        cp \"\$f\" \"\$BACKUP_DIR/sshd_config.d/\$fname\"
                        echo \"Backed up \$f\"
                        BACKED_UP=1
                    fi
                done
            fi
            if [[ \$BACKED_UP -eq 0 ]]; then
                echo \"Backups already exist — skipped\"
            fi
            echo \"Backup dir: \$BACKUP_DIR\"
        '")
        echo -e "${GREEN}${BACKUP_RESULT}${NC}"
        CHANGES_VPS_HOST+=("Backed up sshd configs to ${UNINSTALL_DIR}/sshd/")

        # Find which config file sets AllowTcpForwarding and update it
        $SSH_CMD "${SUDO} bash -c '
            CONF_FILE=\$(grep -rl \"^AllowTcpForwarding\" /etc/ssh/sshd_config.d/ 2>/dev/null | head -1)
            if [[ -n \"\$CONF_FILE\" ]]; then
                sed -i \"s/^AllowTcpForwarding.*/#& # original setting\\nAllowTcpForwarding local  # changed by vibe-kanban ide-ssh-setup.sh/\" \"\$CONF_FILE\"
                echo \"Updated \$CONF_FILE\"
            else
                echo \"AllowTcpForwarding local\" >> /etc/ssh/sshd_config.d/ide-ssh.conf
                echo \"Created /etc/ssh/sshd_config.d/ide-ssh.conf\"
            fi
        '"
        $SSH_CMD "${SUDO} systemctl restart sshd"
        echo -e "${GREEN}VPS sshd updated and restarted.${NC}"
        CHANGES_VPS_HOST+=("Changed AllowTcpForwarding from '${TCP_FWD}' to 'local' in VPS sshd config")
        CHANGES_VPS_HOST+=("Restarted VPS sshd (systemctl restart sshd)")
    else
        echo -e "${YELLOW}Skipped. IDE SSH via ProxyJump will NOT work until AllowTcpForwarding is set to 'local'.${NC}"
    fi
fi

# --- Add Host entry to local ~/.ssh/config -----------------------------------
if [[ "$SKIP_CONFIG" == "true" ]]; then
    echo -e "${YELLOW}Skipping ~/.ssh/config update (--no-config).${NC}"
else
    SSH_CONFIG="$HOME/.ssh/config"
    mkdir -p "$HOME/.ssh"
    touch "$SSH_CONFIG"

    # Remove stale entries if present so we always write the correct config
    for host_entry in "vibe-kanban-vps" "vibe-kanban"; do
        if grep -q "^Host ${host_entry}$" "$SSH_CONFIG" 2>/dev/null; then
            echo -e "${YELLOW}Removing existing '${host_entry}' entry from ${SSH_CONFIG}...${NC}"
            # Delete from "Host <entry>" to the next "Host " line (or EOF)
            sed -i.bak "/^Host ${host_entry}$/,/^Host /{/^Host ${host_entry}$/d;/^Host /!d;}" "$SSH_CONFIG"
        fi
    done
    # Clean up trailing blank lines
    sed -i.bak -e :a -e '/^\n*$/{$d;N;ba' -e '}' "$SSH_CONFIG"
    rm -f "${SSH_CONFIG}.bak"

    EXPANDED_KEY_PATH="${SSH_KEY_PATH/#\~/$HOME}"

    # Port 2222 is bound to 127.0.0.1 on the VPS (not publicly accessible).
    # We ProxyJump through the VPS SSH connection to reach the container sshd.
    cat >> "$SSH_CONFIG" <<EOF

Host vibe-kanban-vps
    HostName ${VPS_IP}
    Port ${SSH_PORT}
    User ${SSH_USER}
    IdentityFile ${EXPANDED_KEY_PATH}
    StrictHostKeyChecking accept-new

Host vibe-kanban
    HostName 127.0.0.1
    Port ${VK_SSH_PORT}
    User vkuser
    IdentityFile ${EXPANDED_KEY_PATH}
    ProxyJump vibe-kanban-vps
    StrictHostKeyChecking accept-new
EOF
    echo -e "${GREEN}Added 'vibe-kanban-vps' and 'vibe-kanban' to ${SSH_CONFIG}${NC}"
    CHANGES_LOCAL+=("Updated ~/.ssh/config — added Host entries 'vibe-kanban-vps' and 'vibe-kanban'")
fi

# --- Print change summary ----------------------------------------------------
echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║  IDE SSH Setup — Summary of Changes                            ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════════════╝${NC}"

if [[ ${#CHANGES_VPS_HOST[@]} -gt 0 ]]; then
    echo ""
    echo -e "  ${RED}VPS Host (outside container):${NC}"
    for change in "${CHANGES_VPS_HOST[@]}"; do
        echo -e "    • $change"
    done
    echo ""
    echo -e "  ${RED}To restore original sshd config:${NC}"
    echo -e "    ${CYAN}ssh <vps> sudo cp ${UNINSTALL_DIR}/sshd/sshd_config.d/*.conf /etc/ssh/sshd_config.d/${NC}"
    echo -e "    ${CYAN}ssh <vps> sudo systemctl restart sshd${NC}"
fi

if [[ ${#CHANGES_CONTAINER[@]} -gt 0 ]]; then
    echo ""
    echo -e "  ${YELLOW}Container (vibe-kanban):${NC}"
    for change in "${CHANGES_CONTAINER[@]}"; do
        echo -e "    • $change"
    done
fi

if [[ ${#CHANGES_LOCAL[@]} -gt 0 ]]; then
    echo ""
    echo -e "  ${GREEN}Local machine:${NC}"
    for change in "${CHANGES_LOCAL[@]}"; do
        echo -e "    • $change"
    done
fi

if [[ ${#CHANGES_VPS_HOST[@]} -eq 0 && ${#CHANGES_CONTAINER[@]} -eq 0 && ${#CHANGES_LOCAL[@]} -eq 0 ]]; then
    echo ""
    echo -e "  ${GREEN}No changes made (everything was already configured).${NC}"
fi

echo ""
echo -e "${CYAN}───────────────────────────────────────────────────────────────────${NC}"
echo ""
echo "  Connect via terminal:"
echo "    ssh vibe-kanban"
echo ""
echo "  VS Code / Cursor:"
echo "    1. Install the Remote-SSH extension"
echo "    2. Cmd+Shift+P → 'Remote-SSH: Connect to Host' → select 'vibe-kanban'"
echo "    3. Open folders like /repos/ or /var/tmp/vibe-kanban/worktrees/"
echo ""
echo -e "${YELLOW}NOTE: Ensure VK_IDE_SSH=true is set in .env and the container has been"
echo -e "redeployed. Port ${VK_SSH_PORT} is only accessible via ProxyJump through the VPS.${NC}"
