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
3. Copy deployment files to `$INSTALL_DIR` (default: `/home/vibe-kanban`)
4. Clone vibe-kanban source from GitHub
5. Prompt you to configure `.env`
6. Build and start the stack

## Deployment Checklist

Before deploying, read `.env` and verify these required values are present and non-empty. If any are missing, stop and ask the user to provide them:

1. **`VPS_IP`** — IP address of the target VPS
2. **`SSH_KEY_PATH`** — Path to the SSH private key (must exist locally, passwordless)
3. **`CF_TUNNEL_TOKEN`** — Cloudflare Tunnel token
4. At least one of: an agent API key (`ANTHROPIC_API_KEY`, `GOOGLE_API_KEY`, or `OPENAI_API_KEY`) **or** Claude Code OAuth login (see below)

If `CF_TUNNEL_TOKEN` is missing, prompt with:
> You need a Cloudflare Tunnel token. Create one at: Cloudflare Zero Trust dashboard → Networks → Tunnels → Create. Copy the token and set `CF_TUNNEL_TOKEN` in `.env`.

If no `ANTHROPIC_API_KEY` is set, ask the user if they want to use Claude Code OAuth login instead. If yes, after deploying, run:
```bash
bash claude-login.sh
```
This SSHs into the VPS, docker execs into the vibe-kanban container, and runs the Claude Code login flow. The user will see a URL to open in their browser. Credentials are persisted in the `vk-claude` volume.

## Deploying to the VPS

All VPS operations use the `vps.sh` helper script, which reads SSH connection details from `.env` and auto-adds `sudo` for non-root users:

```bash
bash vps.sh ssh "command to run on VPS"
bash vps.sh scp file1 [file2...] /remote/path/
```

### Deploy Logging

During deployment, write a local `deploy-log.md` file that captures every step's commands and output. This gives the user a complete record of what changed on the VPS.

**At deploy start** (before any VPS commands), create `./deploy-log.md` with the Write tool:

```markdown
# Deploy Log — YYYY-MM-DD HH:MM:SS

**Target:** <SSH_USER>@<VPS_IP>:<SSH_PORT>
**Install dir:** <INSTALL_DIR>
**Deploy repo commit:** <output of `git rev-parse --short HEAD`>
```

**After each step**, append to `deploy-log.md` using the Edit tool. Include:
- A section heading with the step name
- The exact command(s) run
- The full stdout/stderr output in a fenced code block

**At deploy end**, append a summary section:

```markdown
## Summary
- **Services:** <each service and its state>
- **Result:** SUCCESS or FAILED — <reason if failed>
```

The final log should follow this structure:

````markdown
# Deploy Log — YYYY-MM-DD HH:MM:SS

**Target:** user@1.2.3.4:22
**Install dir:** /home/vibe-kanban
**Deploy repo commit:** abc1234

## Pre-deploy: Cloudflare Access check
```
<curl output>
```

## Step 1: Copy deployment files
**Commands:**
```
<mkdir output>
<scp output for each file>
```
**Files copied to /home/vibe-kanban/:**
- docker-compose.yml
- Dockerfile.vps
- entrypoint.sh
- .env.example
- .dockerignore
- setup.sh
- .env

## Step 2: Run setup on VPS
```
<full setup.sh output>
```

## Step 3: Post-deploy verification

### Container status
```
<docker compose ps output>
```

### Tunnel status
```
<cloudflared logs>
```

### App logs (if container unhealthy)
```
<vibe-kanban logs>
```

## Summary
- **Services:** vibe-kanban (running/healthy), cloudflared (running)
- **Result:** SUCCESS
````

### Step 1: Copy deployment files to the VPS

The vibe-kanban source is **not** copied from the local machine — `setup.sh` clones it directly from GitHub on the VPS.

Read `INSTALL_DIR` from `.env` (default: `/home/vibe-kanban`) and use it as the remote path:

```bash
# Create the deploy directory on the VPS
bash vps.sh ssh "mkdir -p ${INSTALL_DIR} && chown \$(whoami): ${INSTALL_DIR}"

# Copy deployment files
bash vps.sh scp docker-compose.yml Dockerfile.vps entrypoint.sh .env.example .dockerignore setup.sh ${INSTALL_DIR}/

# Copy .env (contains secrets — only if it exists locally)
bash vps.sh scp .env ${INSTALL_DIR}/.env
```

### Step 2: Run setup on the VPS

For first-time setup (installs Docker + Sysbox, clones vibe-kanban source):
```bash
bash vps.sh ssh "bash ${INSTALL_DIR}/setup.sh"
```

For subsequent deploys (pulls latest source, rebuilds, and restarts):
```bash
bash vps.sh ssh "bash ${INSTALL_DIR}/setup.sh"
```

Or to rebuild without pulling source updates:
```bash
bash vps.sh ssh "cd ${INSTALL_DIR} && docker compose up -d --build"
```

### Step 3: Post-deploy verification and report

After deploying, verify the stack is healthy and present a summary to the user.

**Check the vibe-kanban container is running:**

```bash
bash vps.sh ssh "cd ${INSTALL_DIR} && docker compose ps --format json"
```

Parse the output. The `vibe-kanban` service must show `running` status and health `healthy`. If it is not running or unhealthy, fetch logs and show the error to the user:

```bash
bash vps.sh ssh "cd ${INSTALL_DIR} && docker compose logs --tail=40 vibe-kanban"
```

**Check the cloudflared tunnel:**

```bash
bash vps.sh ssh "cd ${INSTALL_DIR} && docker compose logs --tail=20 cloudflared"
```

Look for `"Connection registered"` in the output. If absent, warn the user the tunnel may not be connected yet.

**Present a deploy report to the user** with this information:

1. **Services status** — list each service and its state (running/healthy, starting, exited, etc.)
2. **Files modified on VPS** — list the deployment files that were copied to `$INSTALL_DIR` and whether vibe-kanban source was cloned/updated
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
| `ANTHROPIC_API_KEY` | No* | API key for Claude-based agents (or use OAuth via `claude-login.sh`) |
| `GOOGLE_API_KEY` | No | API key for Gemini agents |
| `OPENAI_API_KEY` | No | API key for OpenAI/Codex agents |
| `CF_TUNNEL_TOKEN` | Yes | Cloudflare Tunnel token (see Deployment Checklist) |
| `VK_DOMAIN` | No | Domain served by the tunnel (for Access verification) |
| `VPS_IP` | Yes | IP address of the target VPS |
| `SSH_KEY_PATH` | Yes | Path to SSH private key for VPS (default: `~/.ssh/vps1_vibekanban_ed25519`) |
| `SSH_USER` | No | SSH username (default: `root`) |
| `SSH_PORT` | No | SSH port (default: `22`) |
| `INSTALL_DIR` | No | Install directory on VPS (default: `/home/vibe-kanban`) |
| `RUST_LOG` | No | Log level (default: `info`) |
| `GIT_AUTHOR_NAME` | No | Git commit author name |
| `GIT_AUTHOR_EMAIL` | No | Git commit author email |

*At least one agent API key is required, or use Claude Code OAuth login via `claude-login.sh`.

GitHub integration uses `gh` CLI (not a token). Run `bash gh-login.sh` after deploying to authenticate. This also auto-configures `git user.name` and `git user.email` inside the container from the GitHub profile.

## Operations

All operations commands below are run on the VPS. If connected as a non-root user, prefix `docker` commands with `sudo`.

### Logs
```bash
cd ${INSTALL_DIR}
docker compose logs -f              # all services
docker compose logs -f vibe-kanban   # app only
docker compose logs -f cloudflared   # tunnel only
```

### Restart
```bash
cd ${INSTALL_DIR}
docker compose restart
```

### Update
```bash
cd ${INSTALL_DIR}
docker compose up -d --build         # rebuilds image with latest npm package
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
| `/home/vkuser/.local/share/vibe-kanban/` | `vk-data` | SQLite DB, config, profiles, credentials |
| `/repos/` | `vk-repos` | Cloned repositories |
| `/var/tmp/vibe-kanban/` | `vk-worktrees` | Git worktrees for agents |
| `/var/lib/docker/` | `vk-docker` | Docker-in-Docker storage |
| `/home/vkuser/.claude/` | `vk-claude` | Claude Code OAuth credentials |
| `/home/vkuser/.config/gh/` | `vk-ghcli` | GitHub CLI OAuth credentials |
| `/home/vkuser/.ssh/` | `vk-ssh` | SSH keys for git push to GitHub |

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
| `vps.sh` | SSH/SCP wrapper — reads `.env`, auto-adds sudo for non-root |
| `claude-login.sh` | Helper to run Claude Code OAuth login inside the container |
| `gh-login.sh` | Helper to run GitHub CLI OAuth login inside the container |
