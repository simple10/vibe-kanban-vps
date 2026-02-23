# Plan: Standalone Docker Deployment for vibe-kanban (Sysbox)

## Context

We're creating a standalone Docker deployment that runs the vibe-kanban local/desktop server inside a sysbox-enabled container on an Ubuntu 25 VPS. Sysbox provides secure Docker-in-Docker capability so that coding agents spawned by vibe-kanban (as native OS processes) have access to Docker for their work. The deployment includes a setup script that installs Docker + sysbox on a fresh VPS.

**Key architectural facts:**

- The `server` binary is self-contained: frontend is embedded via `RustEmbed` from `frontend/dist`
- Data stored at `~/.local/share/vibe-kanban/` (SQLite DB, config, profiles, credentials)
- Worktrees at `/var/tmp/vibe-kanban/`
- Agents spawned via `npx` (e.g., `npx -y @anthropic-ai/claude-code@2.1.45`) — requires Node.js
- No built-in auth — Caddy provides basic auth for VPS exposure
- Rust nightly `nightly-2025-12-04`, resolver v3

## Files to Create

All files in `/Users/joe/Development/openclaw/vibekanban-vps/`:

### 1. `Dockerfile.vps`

Multi-stage build adapted from `vibe-kanban/Dockerfile`:

**Stage 1 — Builder** (based on `node:24-bookworm` instead of Alpine for glibc compat):

- Install build deps: `build-essential`, `pkg-config`, `libssl-dev`, `cmake`, `clang`, `llvm-dev`, `git`
- Install Rust nightly-2025-12-04 via rustup
- Copy package files, install pnpm, `pnpm install`
- Copy source, run `npm run generate-types`, build frontend (`cd frontend && pnpm run build`)
- `cargo build --release --bin server`
- Remove the `RUSTFLAGS="-C target-feature=-crt-static"` (not needed on glibc)

**Stage 2 — Runtime** (based on `ubuntu:24.04`):

- Install: `ca-certificates`, `curl`, `wget`, `git`, `tini`, `openssh-client`
- Install Docker CE from official apt repo (docker-ce, docker-ce-cli, containerd.io)
- Install Node.js 24.x from NodeSource (needed for `npx`-based agents)
- Copy server binary from builder
- Create dirs: `/repos`, `/var/tmp/vibe-kanban/worktrees`, `/root/.local/share/vibe-kanban`
- Copy `entrypoint.sh`
- `ENV HOST=0.0.0.0 PORT=3000`, `EXPOSE 3000`
- `ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]`

**Note:** Run as root inside sysbox container (sysbox maps container root to unprivileged host user). This avoids Docker socket permission issues and is the idiomatic sysbox pattern.

### 2. `entrypoint.sh`

```bash
#!/bin/bash
set -e

# Start Docker daemon (sysbox provides isolation)
if command -v dockerd &>/dev/null; then
    dockerd --storage-driver=overlay2 > /var/log/dockerd.log 2>&1 &
    # Wait up to 30s for dockerd
    for i in $(seq 1 30); do
        docker info &>/dev/null && break
        sleep 1
    done
    docker info &>/dev/null && echo "Docker daemon ready" || echo "WARNING: Docker daemon failed to start"
fi

# Ensure data directories exist
mkdir -p /root/.local/share/vibe-kanban
mkdir -p /var/tmp/vibe-kanban/worktrees
mkdir -p /repos

exec server
```

### 3. `docker-compose.yml`

```yaml
services:
  vibe-kanban:
    build:
      context: ./vibe-kanban
      dockerfile: ../Dockerfile.vps
    runtime: sysbox-runc
    container_name: vibe-kanban
    restart: unless-stopped
    ports:
      - "127.0.0.1:3000:3000"
    volumes:
      - vk-data:/root/.local/share/vibe-kanban   # SQLite DB + config
      - vk-repos:/repos                           # Cloned repositories
      - vk-worktrees:/var/tmp/vibe-kanban          # Worktrees
      - vk-docker:/var/lib/docker                  # Docker-in-Docker storage
    env_file:
      - .env
    environment:
      HOST: "0.0.0.0"
      PORT: "3000"
      HOME: /root

  caddy:
    image: caddy:2-alpine
    container_name: vibe-kanban-caddy
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy-data:/data
      - caddy-config:/config
    depends_on:
      vibe-kanban:
        condition: service_healthy

volumes:
  vk-data:
  vk-repos:
  vk-worktrees:
  vk-docker:
  caddy-data:
  caddy-config:
```

### 4. `Caddyfile`

Caddy with basic auth + HTTPS + reverse proxy:

```
{$VK_DOMAIN:localhost} {
    basicauth * {
        {$VK_AUTH_USER:admin} {$VK_AUTH_HASH}
    }
    reverse_proxy vibe-kanban:3000
}
```

### 5. `.env.example`

```bash
# Agent API keys (at least one required for corresponding agent)
ANTHROPIC_API_KEY=sk-ant-...
# GOOGLE_API_KEY=
# OPENAI_API_KEY=

# Domain & auth for Caddy
VK_DOMAIN=vibekanban.example.com
VK_AUTH_USER=admin
VK_AUTH_HASH=              # Generate: docker run --rm caddy:2-alpine caddy hash-password

# Optional
# RUST_LOG=info
# GIT_AUTHOR_NAME=Your Name
# GIT_AUTHOR_EMAIL=you@example.com
# GITHUB_TOKEN=ghp_...
```

### 6. `setup.sh`

VPS bootstrap script for Ubuntu 25:

1. Check prerequisites (root/sudo, Ubuntu version)
2. Install Docker CE if `docker` not found
3. Install sysbox if `sysbox-runc` not found:
   - Download appropriate .deb for architecture (amd64/arm64)
   - `dpkg -i` + configure Docker daemon to register sysbox-runc
   - Restart Docker
4. Verify: `docker run --runtime=sysbox-runc --rm alpine true`
5. Copy deployment files to `/opt/vibe-kanban/` (or pwd)
6. Prompt to create `.env` from `.env.example`
7. `docker compose up -d --build`
8. Print access URL and status

### 7. `CLAUDE.md`

Deployment playbook:

- Architecture overview (Caddy → vibe-kanban sysbox container → dockerd + agents)
- Quick start steps
- Environment variable reference
- Operations: logs, restart, update, backup/restore SQLite
- Troubleshooting common issues

## Critical Reference Files

| File | Why |
|---|---|
| `vibe-kanban/Dockerfile` | Builder stage pattern to adapt (Alpine→Debian) |
| `vibe-kanban/crates/utils/src/assets.rs:6-25` | `asset_dir()` → `~/.local/share/vibe-kanban/` on Linux |
| `vibe-kanban/crates/utils/src/path.rs:108-125` | `get_vibe_kanban_temp_dir()` → `/var/tmp/vibe-kanban/` on Linux |
| `vibe-kanban/crates/server/src/main.rs:94-113` | PORT/HOST env var handling |
| `vibe-kanban/rust-toolchain.toml` | Rust nightly-2025-12-04 |
| `vibe-kanban/Cargo.toml` | Workspace deps, codex patch, git-based ts-rs |

## Implementation Order

1. `Dockerfile.vps` — most complex, adapt builder from existing Dockerfile
2. `entrypoint.sh` — start dockerd then exec server
3. `docker-compose.yml` — sysbox runtime + volumes + Caddy
4. `Caddyfile` — basic auth reverse proxy
5. `.env.example` — template
6. `setup.sh` — VPS bootstrap
7. `CLAUDE.md` — playbook
8. `.gitignore` — exclude `.env`

## Verification

1. Build locally: `docker compose build` (requires sysbox or just test the build stage)
2. On VPS: Run `setup.sh`, verify all services healthy via `docker compose ps`
3. Check vibe-kanban UI accessible at `https://<domain>` with basic auth
4. Verify Docker works inside container: `docker compose exec vibe-kanban docker info`
5. Create a project, spawn an agent, verify it executes successfully
