#!/bin/bash
# =============================================================================
# VPS Operations Helper
# Reads SSH connection details from .env and provides simple subcommands.
#
# Usage:
#   bash vps.sh ssh "command"              Run command on VPS (auto-adds sudo for non-root)
#   bash vps.sh scp file1 [file2...] dest  Copy files to VPS (dest is remote path)
#   bash vps.sh deploy                     Copy deploy/ files + .env to $INSTALL_DIR on VPS
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -f "${SCRIPT_DIR}/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "${SCRIPT_DIR}/.env"
    set +a
else
    echo "ERROR: .env not found in ${SCRIPT_DIR}" >&2
    exit 1
fi

: "${VPS_IP:?VPS_IP is required in .env}"
: "${SSH_KEY_PATH:?SSH_KEY_PATH is required in .env}"
SSH_USER="${SSH_USER:-root}"
SSH_PORT="${SSH_PORT:-22}"
INSTALL_DIR="${INSTALL_DIR:-/home/vibe-kanban}"

case "${1:-}" in
    ssh)
        shift
        if [[ "${SSH_USER}" == "root" ]]; then
            ssh -i "${SSH_KEY_PATH}" -p "${SSH_PORT}" -o StrictHostKeyChecking=accept-new "${SSH_USER}@${VPS_IP}" "$*"
        else
            printf -v _remote_cmd 'sudo bash -c %q' "$*"
            ssh -i "${SSH_KEY_PATH}" -p "${SSH_PORT}" -o StrictHostKeyChecking=accept-new "${SSH_USER}@${VPS_IP}" "${_remote_cmd}"
        fi
        ;;
    scp)
        shift
        args=("$@")
        last_idx=$((${#args[@]} - 1))
        remote_path="${args[$last_idx]}"
        unset 'args[$last_idx]'
        scp -i "${SSH_KEY_PATH}" -P "${SSH_PORT}" -o StrictHostKeyChecking=accept-new "${args[@]}" "${SSH_USER}@${VPS_IP}:${remote_path}"
        ;;
    deploy)
        # Create INSTALL_DIR on VPS, owned by SSH_USER so scp can write to it
        echo "Creating ${INSTALL_DIR} on VPS..."
        if [[ "${SSH_USER}" == "root" ]]; then
            ssh -i "${SSH_KEY_PATH}" -p "${SSH_PORT}" -o StrictHostKeyChecking=accept-new "${SSH_USER}@${VPS_IP}" "mkdir -p ${INSTALL_DIR}"
        else
            printf -v _remote_cmd 'sudo bash -c %q' "mkdir -p ${INSTALL_DIR} && chown ${SSH_USER}: ${INSTALL_DIR}"
            ssh -i "${SSH_KEY_PATH}" -p "${SSH_PORT}" -o StrictHostKeyChecking=accept-new "${SSH_USER}@${VPS_IP}" "${_remote_cmd}"
        fi

        # Collect deploy/ files (including dotfiles) + root .env
        files=("${SCRIPT_DIR}"/deploy/*)
        files+=("${SCRIPT_DIR}"/deploy/.*)
        # Filter out . and .. entries
        deploy_files=()
        for f in "${files[@]}"; do
            base="$(basename "$f")"
            [[ "$base" == "." || "$base" == ".." ]] && continue
            deploy_files+=("$f")
        done
        if [[ -f "${SCRIPT_DIR}/.env" ]]; then
            deploy_files+=("${SCRIPT_DIR}/.env")
        fi

        echo "Copying files to ${SSH_USER}@${VPS_IP}:${INSTALL_DIR}/..."
        scp -i "${SSH_KEY_PATH}" -P "${SSH_PORT}" -o StrictHostKeyChecking=accept-new "${deploy_files[@]}" "${SSH_USER}@${VPS_IP}:${INSTALL_DIR}/"
        echo "Deploy files copied."
        ;;
    *)
        echo "Usage:" >&2
        echo "  bash vps.sh ssh \"command\"              Run command on VPS" >&2
        echo "  bash vps.sh scp file1 [file2...] dest  Copy files to VPS" >&2
        echo "  bash vps.sh deploy                     Copy deploy/ files + .env to VPS" >&2
        exit 1
        ;;
esac
