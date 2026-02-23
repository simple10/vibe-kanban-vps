# vibe-kanban VPS Deployment

## Architecture

```
Internet → Caddy (HTTPS + basic auth) → vibe-kanban container (sysbox-runc)
                                              ├── server binary (port 3000)
                                              ├── dockerd (overlay2)
                                              └── agents via npx (Claude Code, etc.)
```

- **Caddy** handles TLS (auto HTTPS via Let's Encrypt) and basic auth
- **vibe-kanban** runs in a sysbox container — sysbox maps container root to an unprivileged host user
- **dockerd** runs inside the container so agents have Docker access
- **Agents** are spawned via `npx` (e.g., `npx -y @anthropic-ai/claude-code@latest`)

## Quick Start

```bash
# On a fresh Ubuntu 25 VPS:
sudo bash setup.sh
```

The setup script will:
1. Install Docker CE
2. Install Sysbox (secure Docker-in-Docker runtime)
3. Copy files to `/opt/vibe-kanban/`
4. Prompt you to configure `.env`
5. Build and start the stack

## Environment Variables

| Variable | Required | Description |
|---|---|---|
| `ANTHROPIC_API_KEY` | Yes* | API key for Claude-based agents |
| `GOOGLE_API_KEY` | No | API key for Gemini agents |
| `OPENAI_API_KEY` | No | API key for OpenAI/Codex agents |
| `VK_DOMAIN` | Yes | Domain for Caddy HTTPS (e.g., `vk.example.com`) |
| `VK_AUTH_USER` | No | Basic auth username (default: `admin`) |
| `VK_AUTH_HASH` | Yes | Bcrypt hash for basic auth password |
| `RUST_LOG` | No | Log level (default: `info`) |
| `GIT_AUTHOR_NAME` | No | Git commit author name |
| `GIT_AUTHOR_EMAIL` | No | Git commit author email |
| `GITHUB_TOKEN` | No | GitHub token for private repos |

*At least one agent API key is required.

Generate the password hash:
```bash
docker run --rm -it caddy:2-alpine caddy hash-password
```

## Operations

### Logs
```bash
cd /opt/vibe-kanban
docker compose logs -f              # all services
docker compose logs -f vibe-kanban   # app only
docker compose logs -f caddy         # proxy only
```

### Restart
```bash
cd /opt/vibe-kanban
docker compose restart
```

### Update
```bash
cd /opt/vibe-kanban
git pull                             # or rsync new source
docker compose up -d --build
```

### Backup SQLite DB
```bash
# Copy DB from the named volume
docker compose exec vibe-kanban cp /root/.local/share/vibe-kanban/db.v2.sqlite /tmp/backup.sqlite
docker compose cp vibe-kanban:/tmp/backup.sqlite ./backup-$(date +%Y%m%d).sqlite
```

### Restore SQLite DB
```bash
docker compose cp ./backup.sqlite vibe-kanban:/tmp/restore.sqlite
docker compose exec vibe-kanban cp /tmp/restore.sqlite /root/.local/share/vibe-kanban/db.v2.sqlite
docker compose restart vibe-kanban
```

### Verify Docker-in-Docker
```bash
docker compose exec vibe-kanban docker info
docker compose exec vibe-kanban docker run --rm alpine echo "Docker works inside sysbox"
```

## Data Locations (inside container)

| Path | Volume | Purpose |
|---|---|---|
| `/root/.local/share/vibe-kanban/` | `vk-data` | SQLite DB, config, profiles, credentials |
| `/repos/` | `vk-repos` | Cloned repositories |
| `/var/tmp/vibe-kanban/` | `vk-worktrees` | Git worktrees for agents |
| `/var/lib/docker/` | `vk-docker` | Docker-in-Docker storage |

## Troubleshooting

### Container won't start
```bash
docker compose logs vibe-kanban
# Check if sysbox is running:
systemctl status sysbox
```

### Docker daemon not starting inside container
```bash
docker compose exec vibe-kanban cat /var/log/dockerd.log
# Ensure sysbox-runc runtime is being used:
docker inspect vibe-kanban | grep Runtime
```

### Caddy not getting certificates
- Ensure DNS A record points to the VPS IP
- Ensure ports 80 and 443 are open in the firewall
- Check Caddy logs: `docker compose logs caddy`

### "permission denied" errors
- The container runs as root internally (sysbox maps this to unprivileged host user)
- If volume permissions are wrong, try: `docker compose down -v && docker compose up -d`

## File Reference

| File | Purpose |
|---|---|
| `Dockerfile.vps` | Multi-stage build (node+rust builder, ubuntu runtime) |
| `entrypoint.sh` | Starts dockerd, then execs the server binary |
| `docker-compose.yml` | Service definitions with sysbox-runc runtime |
| `Caddyfile` | Reverse proxy with basic auth and auto-HTTPS |
| `.env` / `.env.example` | Environment configuration |
| `setup.sh` | VPS bootstrap (Docker + Sysbox + deploy) |
