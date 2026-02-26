#!/bin/bash
set -euo pipefail

# =============================================================================
# vibe-kanban VPS Setup Script
# Installs Docker CE + Sysbox on Ubuntu, then deploys the stack.
# Usage: sudo bash setup.sh
# =============================================================================

# Source .env if present (for INSTALL_DIR and other config)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "${SCRIPT_DIR}/.env"
    set +a
fi

DEPLOY_DIR="${INSTALL_DIR:-/home/vibe-kanban}"
SYSBOX_VERSION="0.6.6"

# --- Colors ----------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# --- Prerequisites ----------------------------------------------------------
check_prerequisites() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root (or with sudo)"
    fi

    if ! grep -qi 'ubuntu' /etc/os-release 2>/dev/null; then
        error "This script is designed for Ubuntu. Detected: $(. /etc/os-release && echo "$PRETTY_NAME")"
    fi

    info "Running on $(. /etc/os-release && echo "$PRETTY_NAME")"
}

# --- Docker CE --------------------------------------------------------------
install_docker() {
    if command -v docker &>/dev/null; then
        info "Docker already installed: $(docker --version)"
        return
    fi

    info "Installing Docker CE..."
    apt-get update
    apt-get install -y ca-certificates curl gnupg lsb-release

    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
    https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    > /etc/apt/sources.list.d/docker.list

    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    systemctl enable --now docker
    info "Docker installed: $(docker --version)"
}

# --- Sysbox -----------------------------------------------------------------
install_sysbox() {
    if command -v sysbox-runc &>/dev/null; then
        info "Sysbox already installed: $(sysbox-runc --version 2>/dev/null || echo 'present')"
        return
    fi

    info "Installing Sysbox v${SYSBOX_VERSION}..."

    local arch
    arch=$(dpkg --print-architecture)
    local codename
    codename=$(. /etc/os-release && echo "$VERSION_CODENAME")

    # Sysbox .deb naming: sysbox-ce_<ver>-0.linux_<arch>.deb
    local deb_url="https://downloads.nestybox.com/sysbox/releases/v${SYSBOX_VERSION}/sysbox-ce_${SYSBOX_VERSION}-0.linux_${arch}.deb"
    local deb_file="/tmp/sysbox-ce.deb"

    info "Downloading from ${deb_url}"
    curl -fsSL -o "$deb_file" "$deb_url" || error "Failed to download Sysbox. Check version/architecture."

    # Stop Docker containers before installing sysbox (required by installer)
    info "Stopping all Docker containers for sysbox installation..."
    docker rm -f $(docker ps -aq) 2>/dev/null || true

    apt-get install -y jq
    dpkg -i "$deb_file" || apt-get install -f -y
    rm -f "$deb_file"

    systemctl restart docker
    info "Sysbox installed successfully"
}

verify_sysbox() {
    info "Verifying sysbox-runc..."
    if docker run --runtime=sysbox-runc --rm alpine true 2>/dev/null; then
        info "Sysbox verification passed"
    else
        error "Sysbox verification failed. Check: systemctl status sysbox"
    fi
}

# --- Deploy ------------------------------------------------------------------
deploy_stack() {
    info "Setting up deployment directory: ${DEPLOY_DIR}"
    mkdir -p "$DEPLOY_DIR"

    # Copy deployment files (assumes script is run from repo root or files are alongside it)
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    if [[ "${script_dir}" != "${DEPLOY_DIR}" ]]; then
        for f in docker-compose.yml Dockerfile.vps entrypoint.sh .dockerignore; do
            if [[ -f "${script_dir}/${f}" ]]; then
                cp "${script_dir}/${f}" "${DEPLOY_DIR}/${f}"
            else
                warn "File not found: ${script_dir}/${f}"
            fi
        done
    else
        info "Script is running from deploy directory, skipping file copy"
    fi

    # .env should already be present (copied by vps.sh deploy)
    if [[ ! -f "${DEPLOY_DIR}/.env" ]]; then
        error "No .env found in ${DEPLOY_DIR}. Copy .env.example to .env locally, configure it, then run: bash vps.sh deploy"
    else
        info "Existing .env found, keeping it"
    fi
}

start_stack() {
    info "Creating bind mount directories..."
    mkdir -p "$DEPLOY_DIR"/data/{vk-data,vk-repos,vk-worktrees,vk-docker,vk-claude,vk-ghcli,vk-ssh}

    info "Building and starting vibe-kanban stack..."
    cd "$DEPLOY_DIR"
    docker compose up -d --build

    echo ""
    info "============================================="
    info "  vibe-kanban deployment complete!"
    info "============================================="
    echo ""
    info "Status:  docker compose -f ${DEPLOY_DIR}/docker-compose.yml ps"
    info "Logs:    docker compose -f ${DEPLOY_DIR}/docker-compose.yml logs -f"
    info "Tunnel:  docker compose -f ${DEPLOY_DIR}/docker-compose.yml logs cloudflared"
    echo ""
    info "Configure your tunnel's public hostname in the Cloudflare Zero Trust dashboard."
}

# --- Main -------------------------------------------------------------------
main() {
    info "vibe-kanban VPS Setup"
    echo ""

    check_prerequisites
    install_docker
    install_sysbox
    verify_sysbox
    deploy_stack
    start_stack
}

main "$@"
