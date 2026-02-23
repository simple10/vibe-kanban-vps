# vibe-kanban VPS Deployment

## Architecture

```
Internet → Cloudflare Edge → cloudflared tunnel → vibe-kanban container (sysbox-runc)
                                                        ├── server binary (port 3000)
                                                        ├── dockerd (overlay2)
                                                        └── agents via npx (Claude Code, etc.)
```

- **Cloudflare Tunnel** (`cloudflared`) connects outbound to Cloudflare's edge — no public ports exposed on the VPS
- **Auth** is handled via Cloudflare Access policies (configured in the CF dashboard, not in this stack)
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

## Deployment Checklist

Before deploying, ensure `.env` contains a valid `CF_TUNNEL_TOKEN`. If it is missing or empty, prompt the user with:
> You need a Cloudflare Tunnel token. Create one at: Cloudflare Zero Trust dashboard → Networks → Tunnels → Create. Copy the token and set `CF_TUNNEL_TOKEN` in `.env`.

## Cloudflare Access Verification

If `VK_DOMAIN` is set in `.env`, verify the domain is protected by Cloudflare Access before deploying. Run from the local machine:

```bash
curl -sI --connect-timeout 10 https://<VK_DOMAIN>/ 2>&1 | head -10
```

**If 302/403 redirect** (Location header contains `cloudflareaccess.com` or `access.`): Cloudflare Access is protecting the domain. Continue to next step.

**If 200 or no redirect to Access**: The domain is **not** protected. Stop and warn the user:
> Your domain `<VK_DOMAIN>` does not appear to be protected by Cloudflare Access. Anyone with the URL can access vibe-kanban. Configure an Access policy in the Cloudflare Zero Trust dashboard before deploying.

**If connection refused / timeout**: The tunnel is not yet running or DNS is not configured. This is expected on first deploy — verify Access is configured after the tunnel is up.

## Environment Variables

| Variable | Required | Description |
|---|---|---|
| `ANTHROPIC_API_KEY` | Yes* | API key for Claude-based agents |
| `GOOGLE_API_KEY` | No | API key for Gemini agents |
| `OPENAI_API_KEY` | No | API key for OpenAI/Codex agents |
| `CF_TUNNEL_TOKEN` | Yes | Cloudflare Tunnel token (see Deployment Checklist) |
| `VK_DOMAIN` | No | Domain served by the tunnel (for Access verification) |
| `RUST_LOG` | No | Log level (default: `info`) |
| `GIT_AUTHOR_NAME` | No | Git commit author name |
| `GIT_AUTHOR_EMAIL` | No | Git commit author email |
| `GITHUB_TOKEN` | No | GitHub token for private repos |

*At least one agent API key is required.

## Operations

### Logs
```bash
cd /opt/vibe-kanban
docker compose logs -f              # all services
docker compose logs -f vibe-kanban   # app only
docker compose logs -f cloudflared   # tunnel only
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

### Tunnel not connecting
```bash
docker compose logs cloudflared
# Look for "Connection registered" — means the tunnel is active
# Common issues:
#   - Invalid or expired CF_TUNNEL_TOKEN → regenerate in CF dashboard
#   - DNS not configured → add public hostname in CF Zero Trust → Tunnels → your tunnel
#   - vibe-kanban not healthy yet → cloudflared waits for healthcheck to pass
```

### "permission denied" errors
- The container runs as root internally (sysbox maps this to unprivileged host user)
- If volume permissions are wrong, try: `docker compose down -v && docker compose up -d`

## File Reference

| File | Purpose |
|---|---|
| `Dockerfile.vps` | Multi-stage build (node+rust builder, ubuntu runtime) |
| `entrypoint.sh` | Starts dockerd, then execs the server binary |
| `docker-compose.yml` | Service definitions with sysbox-runc runtime |
| `.env` / `.env.example` | Environment configuration |
| `setup.sh` | VPS bootstrap (Docker + Sysbox + deploy) |
