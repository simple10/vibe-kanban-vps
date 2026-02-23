#!/bin/bash
set -e

# Start Docker daemon (sysbox provides secure isolation)
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

# Ensure data directories exist
mkdir -p /root/.local/share/vibe-kanban
mkdir -p /var/tmp/vibe-kanban/worktrees
mkdir -p /repos

exec server
