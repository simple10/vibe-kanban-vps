# vibe-kanban VPS Deployment

## Architecture

```
Internet → Cloudflare Edge → cloudflared tunnel → vibe-kanban container (sysbox-runc)
                                                        ├── server binary (port 3000)
                                                        ├── sshd (port 2222, optional)
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

This SSHs into the VPS, docker execs into the vibe-kanban container, and runs the Claude Code login flow. The user will see a URL to open in their browser. Credentials are persisted in `data/claude/`.

### Cloudflare Access Verification

If `VK_DOMAIN` is set in `.env`, it must not contain `<YOUR-DOMAIN>` (the placeholder from `.env.example`). If it does, stop and ask the user to either replace it with their real domain or comment it out.

If `VK_DOMAIN` is set to a real domain, verify it is protected by Cloudflare Access before deploying. Run from the local machine:

```bash
curl -sI --connect-timeout 10 https://<VK_DOMAIN>/ 2>&1 | head -10
```

**If 302/403 redirect** (Location header contains `cloudflareaccess.com` or `access.`): Cloudflare Access is protecting the domain. Continue to deploy.

**If 200 or no redirect to Access**: The domain is **not** protected. Stop and warn the user:
> Your domain `<VK_DOMAIN>` does not appear to be protected by Cloudflare Access. Anyone with the URL can access vibe-kanban. Configure an Access policy in the Cloudflare Zero Trust dashboard before deploying.

**If connection refused / timeout**: The tunnel is not yet running or DNS is not configured. This is expected on first deploy — verify Access is configured after the tunnel is up.

## Deploying to the VPS

All VPS operations use the `vps.sh` helper script, which reads SSH connection details from `.env` and auto-adds `sudo` for non-root users:

```bash
bash vps.sh ssh "command to run on VPS"
bash vps.sh scp file1 [file2...] /remote/path/
bash vps.sh deploy    # copy deploy/ files + .env to $INSTALL_DIR on VPS
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
<bash vps.sh deploy output>
```
**Files copied to /home/vibe-kanban/:**
- deploy/docker-compose.yml
- deploy/Dockerfile.vps
- deploy/entrypoint.sh
- deploy/.dockerignore
- deploy/setup.sh
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

### Container resources
```
| Container | CPU % | Mem Usage | Mem % | CPU Limit | Mem Limit | Mem Reserve |
|---|---|---|---|---|---|---|
| vibe-kanban | 0.12% | 629 MiB | 0.67% | 8 cores | 8 GiB | 2 GiB |
| vibe-kanban-tunnel | 0.22% | 14.7 MiB | 5.76% | 0.5 cores | 256 MiB | 128 MiB |
```

## Step 4: IDE SSH setup (if VK_IDE_SSH=true)
```
<ide-ssh-setup.sh output, or "Skipped — VK_IDE_SSH not enabled" / "Skipped — user declined">
```

### VPS host changes (outside container)
> **IMPORTANT:** List every change made to the VPS host itself (not the container).
> If no host changes were made, write "None".

- <e.g., Changed AllowTcpForwarding from 'no' to 'local' in /etc/ssh/sshd_config.d/hardening.conf>
- <e.g., Restarted VPS sshd (systemctl restart sshd)>

## Summary
- **Services:** vibe-kanban (running/healthy), cloudflared (running)
- **IDE SSH:** configured / skipped
- **VPS host changes:** <list changes or "None">
- **Result:** SUCCESS
````

### Step 1: Copy deployment files to the VPS

The vibe-kanban source is **not** copied from the local machine — `setup.sh` clones it directly from GitHub on the VPS.

The `deploy` subcommand creates `$INSTALL_DIR` on the VPS (with `chown` for non-root SSH users), then copies all files from `deploy/` plus root `.env` flat to `$INSTALL_DIR/` in a single scp:

```bash
bash vps.sh deploy
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

**Check container resources (live usage + limits):**

```bash
bash vps.sh ssh 'docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.NetIO}}\t{{.BlockIO}}"'
bash vps.sh ssh 'docker inspect --format "{{.Name}}: CPU={{.HostConfig.NanoCpus}} Memory={{.HostConfig.Memory}} CPUReserve={{.HostConfig.CpuShares}} MemReserve={{.HostConfig.MemoryReservation}}" $(docker ps -q)'
```

Convert NanoCpus to cores (÷ 1e9), Memory/MemReserve to human-readable (GiB/MiB).

**Present a deploy report to the user** as a markdown table with these columns:

| Container | CPU % | Mem Usage | Mem % | CPU Limit | Mem Limit | Mem Reserve |
|---|---|---|---|---|---|---|

Include all running containers. Follow the table with:

1. **Services status** — note any unhealthy or missing services
2. **Files deployed** — list the deployment files copied to `$INSTALL_DIR`
3. **How to access vibe-kanban:**
   - If `VK_DOMAIN` is set in `.env`: `https://<VK_DOMAIN>`
   - If `VK_DOMAIN` is not set: tell the user to find their tunnel's public hostname in the Cloudflare Zero Trust dashboard under Networks → Tunnels → their tunnel → Public Hostname

### Step 4: IDE SSH setup (optional)

After the deploy report, if `VK_IDE_SSH` is set to `true` in `.env`, ask the user if they want to run the IDE SSH setup now. Present this as a yes/no question:

> IDE SSH is enabled. Would you like to run `ide-ssh-setup.sh` to configure your local SSH config and inject your public key into the container? This lets VS Code / Cursor connect directly into the container via Remote-SSH.

If the user says yes, run:

```bash
bash ide-ssh-setup.sh
```

The script is interactive — it will prompt the user if VPS host changes are needed (e.g., changing `AllowTcpForwarding` in sshd config). Let the script handle the prompts directly.

If `VK_IDE_SSH` is not set or is `false`, skip this step silently.

**After the script completes**, capture its output in the deploy log. Pay special attention to the "Summary of Changes" section the script prints. In the deploy log, you **must** separately list any VPS host changes (changes outside the container) under a `### VPS host changes (outside container)` heading. This includes:

- sshd config changes (e.g., `AllowTcpForwarding`)
- sshd restarts
- Any other modifications to VPS host files or services

If the script made no VPS host changes, write "None" under that heading. The deploy log summary must also include a **VPS host changes** line.

**Note:** Port 2222 is bound to `127.0.0.1` on the VPS (Docker daemon is configured with `"ip": "127.0.0.1"`), so it is not publicly accessible. The script configures SSH ProxyJump through the VPS to reach port 2222 locally.

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
| `VK_CPU_LIMIT` | No | Max CPU cores for vibe-kanban container (default: `4`) |
| `VK_MEM_LIMIT` | No | Max memory for vibe-kanban container (default: `8g`) |
| `VK_CPU_RESERVE` | No | Guaranteed CPU cores for vibe-kanban container (default: `1`) |
| `VK_MEM_RESERVE` | No | Guaranteed memory for vibe-kanban container (default: `2g`) |
| `VK_IDE_SSH` | No | Enable sshd inside the container for IDE access (default: `false`) |
| `VK_SSH_PORT` | No | Host port for IDE SSH (default: `2222`) |
| `RUST_LOG` | No | Log level (default: `info`) |
| `GIT_AUTHOR_NAME` | No | Git commit author name |
| `GIT_AUTHOR_EMAIL` | No | Git commit author email |

*At least one agent API key is required, or use Claude Code OAuth login via `claude-login.sh`.

GitHub integration uses `gh` CLI (not a token). Run `bash github-login.sh` after deploying to authenticate. This also auto-configures `git user.name` and `git user.email` inside the container from the GitHub profile.

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

Stream the DB file from the VPS bind mount to your local machine:

```bash
bash vps.sh ssh "cat ${INSTALL_DIR}/data/vibe-kanban/db.v2.sqlite" > backup-$(date +%Y%m%d).sqlite
```

### Backup all data

All persistent data lives in `$INSTALL_DIR/data/` on the VPS. Tar the entire directory and stream it to your local machine:

```bash
bash vps.sh ssh "cd ${INSTALL_DIR} && tar czf - data/" > vk-backup-$(date +%Y%m%d).tar.gz
```

### Restore SQLite DB

Copy the backup to the VPS, then swap it in:

```bash
bash vps.sh scp ./backup.sqlite ${INSTALL_DIR}/backup.sqlite
bash vps.sh ssh "cd ${INSTALL_DIR} && docker compose stop vibe-kanban && cp backup.sqlite data/vibe-kanban/db.v2.sqlite && docker compose start vibe-kanban && rm backup.sqlite"
```

### Verify Docker-in-Docker

```bash
docker compose exec vibe-kanban docker info
docker compose exec vibe-kanban docker run --rm alpine echo "Docker works inside sysbox"
```

## Data Locations

All persistent data is stored in bind mounts under `$INSTALL_DIR/data/` on the VPS, making backups straightforward (`cp`, `rsync`, `tar`).

| Container path | Host bind mount | Purpose |
|---|---|---|
| `/home/vkuser/.local/share/vibe-kanban/` | `data/vibe-kanban/` | SQLite DB, config, profiles, credentials |
| `/repos/` | `data/repos/` | Cloned repositories |
| `/var/tmp/vibe-kanban/` | `data/worktrees/` | Git worktrees for agents |
| `/var/lib/docker/` | `data/docker/` | Docker-in-Docker storage |
| `/home/vkuser/.claude/` | `data/claude/` | Claude Code OAuth credentials |
| `/home/vkuser/.config/gh/` | `data/ghcli/` | GitHub CLI OAuth credentials |
| `/home/vkuser/.ssh/` | `data/ssh/` | SSH keys for git push to GitHub |
| `/etc/ssh/sshd_host_keys/` | `data/sshd/` | sshd host keys (IDE SSH) |

### VPS host file backups

`$INSTALL_DIR/.uninstall/` stores original copies of VPS host files before they were modified by setup scripts. This enables rollback/uninstall. Backups are only created once — re-running scripts does not overwrite existing backups.

| Backup path | Original file | Modified by |
|---|---|---|
| `.uninstall/sshd/sshd_config` | `/etc/ssh/sshd_config` | `ide-ssh-setup.sh` |
| `.uninstall/sshd/sshd_config.d/*.conf` | `/etc/ssh/sshd_config.d/*.conf` | `ide-ssh-setup.sh` |

To restore original sshd config:

```bash
sudo cp ${INSTALL_DIR}/.uninstall/sshd/sshd_config.d/*.conf /etc/ssh/sshd_config.d/
sudo systemctl restart sshd
```

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

### IDE SSH not connecting

```bash
# Verify sshd is running inside the container
docker compose exec vibe-kanban pgrep -a sshd
# Check VK_IDE_SSH is set
docker compose exec vibe-kanban printenv VK_IDE_SSH
# Check authorized_keys
cat data/ssh/authorized_keys
# Check host keys exist
ls -la data/sshd/
```

Common issues:
- `VK_IDE_SSH` not set to `true` in `.env` — sshd won't start
- Port 2222 is bound to `127.0.0.1` on the VPS (not publicly accessible) — IDE SSH uses `ProxyJump` through VPS SSH
- `AllowTcpForwarding` must be set to `local` (not `no`) in VPS sshd config (`/etc/ssh/sshd_config.d/hardening.conf`) for ProxyJump to work
- `authorized_keys` owned by `root` instead of `vkuser` inside the container — re-run `bash ide-ssh-setup.sh` (it fixes ownership via `docker exec`)
- Public key not in `data/ssh/authorized_keys` — re-run `bash ide-ssh-setup.sh`
- "Host key changed" warning — delete old key with `ssh-keygen -R "[127.0.0.1]:2222"`

### "permission denied" errors

- The container runs as root internally (sysbox maps this to unprivileged host user)
- If bind mount permissions are wrong, try: `chown -R root:root data/ && docker compose restart`

## File Reference

| File | Purpose |
|---|---|
| `deploy/Dockerfile.vps` | Multi-stage build (node+rust builder, ubuntu runtime) |
| `deploy/entrypoint.sh` | Starts dockerd, then execs the server binary |
| `deploy/docker-compose.yml` | Service definitions with sysbox-runc runtime |
| `.env.example` | Example environment configuration |
| `deploy/.dockerignore` | Docker build ignore rules |
| `deploy/setup.sh` | VPS bootstrap (Docker + Sysbox + deploy) |
| `.env` | Environment configuration (secrets — stays in root) |
| `vps.sh` | SSH/SCP/deploy wrapper — reads `.env`, auto-adds sudo for non-root |
| `claude-login.sh` | Helper to run Claude Code OAuth login inside the container |
| `codex-login.sh` | Helper to run OpenAI Codex CLI login inside the container |
| `github-login.sh` | Helper to run GitHub CLI OAuth login inside the container |
| `ide-ssh-setup.sh` | Setup IDE SSH access (injects key, configures local SSH config) |
| `ssh-vps.sh` | SSH into the VPS host |
| `ssh-vibekanban.sh` | SSH into the VPS and exec into the vibe-kanban container |
