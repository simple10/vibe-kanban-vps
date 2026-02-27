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

# Ensure essential directories exist in the home volume (empty on first start)
mkdir -p /home/vkuser/.local/share/vibe-kanban
mkdir -p /home/vkuser/.ssh
mkdir -p /home/vkuser/.claude
mkdir -p /home/vkuser/.config/gh
mkdir -p /var/tmp/vibe-kanban/worktrees
mkdir -p /repos

# Seed shell config from skeleton on first start (volume is empty)
for f in .bashrc .profile .bash_logout; do
    if [[ ! -f "/home/vkuser/$f" ]] && [[ -f "/etc/skel/$f" ]]; then
        cp "/etc/skel/$f" "/home/vkuser/$f"
    fi
done

# Migrate legacy gitconfig symlink: with the whole-home bind mount,
# .gitconfig persists naturally — no symlink needed.
GITCONFIG_HOME="/home/vkuser/.gitconfig"
GITCONFIG_LEGACY="/home/vkuser/.local/share/vibe-kanban/.gitconfig"
if [[ -L "$GITCONFIG_HOME" ]]; then
    # Replace symlink with the actual file content
    if [[ -f "$GITCONFIG_LEGACY" ]]; then
        rm "$GITCONFIG_HOME"
        cp "$GITCONFIG_LEGACY" "$GITCONFIG_HOME"
    else
        rm "$GITCONFIG_HOME"
    fi
fi

chown -R vkuser:vkuser /repos /var/tmp/vibe-kanban /home/vkuser

# Ensure correct SSH permissions (volume may reset them)
chmod 700 /home/vkuser/.ssh
find /home/vkuser/.ssh -type f -exec chmod 600 {} \; 2>/dev/null || true

# IDE SSH server (opt-in via VK_IDE_SSH=true)
if [[ "${VK_IDE_SSH:-false}" == "true" ]]; then
    # Generate host keys if not present (persisted via bind mount)
    for type in ed25519 rsa; do
        keyfile="/etc/ssh/sshd_host_keys/ssh_host_${type}_key"
        if [[ ! -f "$keyfile" ]]; then
            ssh-keygen -t "$type" -f "$keyfile" -N "" -q
            echo "Generated SSH host key: $keyfile"
        fi
    done

    # Write /etc/environment so SSH sessions inherit container env vars
    # (VS Code remote terminals need API keys, PATH, HOME, etc.)
    env | grep -E '^(ANTHROPIC_API_KEY|GOOGLE_API_KEY|OPENAI_API_KEY|PATH|HOME|RUST_LOG|GIT_AUTHOR_NAME|GIT_AUTHOR_EMAIL|PORT|HOST)=' \
        > /etc/environment 2>/dev/null || true

    /usr/sbin/sshd -e
    echo "IDE SSH server started on port 2222"
fi

# Drop privileges and run vibe-kanban as non-root user
exec gosu vkuser vibe-kanban
