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
3. Copy files to `/home/vibe-kanban/`
4. Prompt you to configure `.env`
5. Build and start the stack

## Deployment Checklist

Before deploying, read `.env` and verify these required values are present and non-empty. If any are missing, stop and ask the user to provide them:

1. **`VPS_IP`** — IP address of the target VPS
2. **`SSH_KEY_PATH`** — Path to the SSH private key (must exist locally, passwordless)
3. **`CF_TUNNEL_TOKEN`** — Cloudflare Tunnel token
4. At least one agent API key (`ANTHROPIC_API_KEY`, `GOOGLE_API_KEY`, or `OPENAI_API_KEY`)

If `CF_TUNNEL_TOKEN` is missing, prompt with:
> You need a Cloudflare Tunnel token. Create one at: Cloudflare Zero Trust dashboard → Networks → Tunnels → Create. Copy the token and set `CF_TUNNEL_TOKEN` in `.env`.

## Deploying to the VPS

Read SSH connection details from `.env`: `VPS_IP`, `SSH_KEY_PATH`, `SSH_USER` (default: `root`), `SSH_PORT` (default: `22`).

Build the SSH/SCP command prefixes and sudo prefix used for all remote operations:

```bash
SSH_CMD="ssh -i ${SSH_KEY_PATH} -p ${SSH_PORT} -o StrictHostKeyChecking=accept-new ${SSH_USER}@${VPS_IP}"
SCP_CMD="scp -i ${SSH_KEY_PATH} -P ${SSH_PORT} -o StrictHostKeyChecking=accept-new"
```

If `SSH_USER` is **not** `root`, prefix commands that require elevated privileges with `sudo`:

```bash
SUDO=""
if [[ "${SSH_USER}" != "root" ]]; then
    SUDO="sudo"
fi
```

### Step 1: Copy files to the VPS

```bash
# Create the deploy directory on the VPS
$SSH_CMD "${SUDO} mkdir -p /home/vibe-kanban && ${SUDO} chown ${SSH_USER}: /home/vibe-kanban"

# Copy deployment files
$SCP_CMD docker-compose.yml Dockerfile.vps entrypoint.sh .env.example .dockerignore setup.sh ${SSH_USER}@${VPS_IP}:/home/vibe-kanban/

# Copy .env (contains secrets — only if it exists locally)
$SCP_CMD .env ${SSH_USER}@${VPS_IP}:/home/vibe-kanban/.env

# Sync vibe-kanban source (needed for Docker build)
rsync -az --delete \
    -e "ssh -i ${SSH_KEY_PATH} -p ${SSH_PORT} -o StrictHostKeyChecking=accept-new" \
    --exclude 'target' --exclude 'node_modules' --exclude '.git' \
    vibe-kanban/ ${SSH_USER}@${VPS_IP}:/home/vibe-kanban/vibe-kanban/
```

### Step 2: Run setup on the VPS

For first-time setup (installs Docker + Sysbox):
```bash
$SSH_CMD "${SUDO} bash /home/vibe-kanban/setup.sh"
```

For subsequent deploys (rebuild and restart):
```bash
$SSH_CMD "cd /home/vibe-kanban && ${SUDO} docker compose up -d --build"
```

### Step 3: Post-deploy verification and report

After deploying, verify the stack is healthy and present a summary to the user.

**Check the vibe-kanban container is running:**

```bash
$SSH_CMD "cd /home/vibe-kanban && ${SUDO} docker compose ps --format json"
```

Parse the output. The `vibe-kanban` service must show `running` status and health `healthy`. If it is not running or unhealthy, fetch logs and show the error to the user:

```bash
$SSH_CMD "cd /home/vibe-kanban && ${SUDO} docker compose logs --tail=40 vibe-kanban"
```

**Check the cloudflared tunnel:**

```bash
$SSH_CMD "cd /home/vibe-kanban && ${SUDO} docker compose logs --tail=20 cloudflared"
```

Look for `"Connection registered"` in the output. If absent, warn the user the tunnel may not be connected yet.

**Present a deploy report to the user** with this information:

1. **Services status** — list each service and its state (running/healthy, starting, exited, etc.)
2. **Files modified on VPS** — list the files that were copied/synced to `/home/vibe-kanban/` during this deploy
3. **How to access vibe-kanban:**
   - If `VK_DOMAIN` is set in `.env`: `https://<VK_DOMAIN>`
   - If `VK_DOMAIN` is not set: tell the user to find their tunnel's public hostname in the Cloudflare Zero Trust dashboard under Networks → Tunnels → their tunnel → Public Hostname

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
| `VPS_IP` | Yes | IP address of the target VPS |
| `SSH_KEY_PATH` | Yes | Path to SSH private key for VPS (default: `~/.ssh/vps1_vibekanban_ed25519`) |
| `SSH_USER` | No | SSH username (default: `root`) |
| `SSH_PORT` | No | SSH port (default: `22`) |
| `RUST_LOG` | No | Log level (default: `info`) |
| `GIT_AUTHOR_NAME` | No | Git commit author name |
| `GIT_AUTHOR_EMAIL` | No | Git commit author email |
| `GITHUB_TOKEN` | No | GitHub token for private repos |

*At least one agent API key is required.

## Operations

All operations commands below are run on the VPS. If connected as a non-root user, prefix `docker` commands with `sudo`.

### Logs
```bash
cd /home/vibe-kanban
docker compose logs -f              # all services
docker compose logs -f vibe-kanban   # app only
docker compose logs -f cloudflared   # tunnel only
```

### Restart
```bash
cd /home/vibe-kanban
docker compose restart
```

### Update
```bash
cd /home/vibe-kanban
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
