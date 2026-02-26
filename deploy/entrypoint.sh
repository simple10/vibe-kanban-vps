#!/bin/bash
set -e

# Start Docker daemon as root (sysbox provides secure isolation)
if command -v dockerd &>/dev/null; then
    dockerd --storage-driver=overlay2 > /var/log/dockerd.log 2>&1 &

    # Wait up to 30s for dockerd to become ready
    for i in $(seq 1 30); do
        docker info &>/dev/null && break
        sleep 1
    done

    if docker info &>/dev/null; then
        echo "Docker daemon ready"
    else
        echo "WARNING: Docker daemon failed to start (check /var/log/dockerd.log)"
    fi
fi

# Ensure data directories exist and are owned by vkuser
mkdir -p /home/vkuser/.local/share/vibe-kanban
mkdir -p /home/vkuser/.ssh
mkdir -p /var/tmp/vibe-kanban/worktrees
mkdir -p /repos
chown -R vkuser:vkuser /repos /var/tmp/vibe-kanban /home/vkuser

# Persist .gitconfig via symlink into the data volume
GITCONFIG_PERSIST="/home/vkuser/.local/share/vibe-kanban/.gitconfig"
GITCONFIG_HOME="/home/vkuser/.gitconfig"
if [[ -f "$GITCONFIG_PERSIST" && ! -L "$GITCONFIG_HOME" ]]; then
    ln -sf "$GITCONFIG_PERSIST" "$GITCONFIG_HOME"
elif [[ ! -f "$GITCONFIG_PERSIST" ]]; then
    touch "$GITCONFIG_PERSIST"
    chown vkuser:vkuser "$GITCONFIG_PERSIST"
    ln -sf "$GITCONFIG_PERSIST" "$GITCONFIG_HOME"
fi

# Ensure correct SSH permissions (volume may reset them)
chmod 700 /home/vkuser/.ssh
find /home/vkuser/.ssh -type f -exec chmod 600 {} \; 2>/dev/null || true

# Drop privileges and run vibe-kanban as non-root user
exec gosu vkuser vibe-kanban
