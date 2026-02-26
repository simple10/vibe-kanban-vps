# Vibe Kanban VPS Deployment

This project auto deploys [vibe-kanban](https://github.com/BloopAI/vibe-kanban) to a VPS with zero exposed ports. Traffic is routed through a Cloudflare Tunnel, and authentication is handled by Cloudflare Access.

The [Dockerfile.vps](./deploy/Dockerfile.vps) used in this project installs `vibe-kanban` using npm.
It's equivalent to running `npx vibe-kanban` on your local machine.

You can optionally modify this project (via claude code) to use vibe-kanban's self hosted deployment
(Supabase, ElasticSQL, etc.). The current basic setup works fine for personal use.

```text
Internet → Cloudflare Access → [VPS Docker Container]
    → cloudflared tunnel
    → vibe-kanban container (sysbox-runc)
         ├── server binary (port 3000)
         ├── dockerd (overlay2)
         └── agents via npx (Claude Code, etc.)
```

First deploy takes about 3-5 minutes to install docker & sysbox on the VPS (if needed).
The container build is fast because `npm -g install vibe-kanban` only downloads a ~50MB rust binary.

## Prerequisites

- Ubuntu VPS (tested on Ubuntu 24.04/25.04)
- A Cloudflare account with a domain
- A Cloudflare Tunnel token ([create one](https://one.dash.cloudflare.com/) under Networks → Tunnels)
- SSH key access to the VPS (passwordless)
- Github account (if using git with Vibe Kanban)

## Setup

### 1. Clone this repo

```bash
git clone https://github.com/simple10/vibe-kanban-vps.git
cd vibekanban-vps
cp deploy/.env.example .env
```

### 2. Create a Cloudflare Tunnel

1. Go to [Cloudflare Zero Trust](https://one.dash.cloudflare.com/) → Networks → Tunnels
2. Create a tunnel and copy the token
3. Add a **Public Hostname** pointing to `http://vibe-kanban:3000`
4. (Recommended) Add a Cloudflare Access policy to protect the hostname

### 3. Configure `.env`

Edit `.env` and fill in the required values:

```bash
# Claude agent: API key OR OAuth login (see below)
# ANTHROPIC_API_KEY=sk-ant-...
# GOOGLE_API_KEY=...
# OPENAI_API_KEY=...
CF_TUNNEL_TOKEN=eyJ...              # from Cloudflare Tunnels dashboard

# VPS connection
VPS_IP=x.x.x.x  # Replace with your real VPS IP address
SSH_KEY_PATH=~/.ssh/vps1_vibekanban_ed25519
SSH_USER=root                        # default: root
SSH_PORT=22                          # default: 22

# Optional
# Your tunnel's public hostname protected by Cloudflare Access
# If VK_DOMAIN is not set, you'll need to manually connect to the cloudflare tunnel
VK_DOMAIN=vibekanban.example.com
```

### 4. Deploy Using Claude Code

Just ask `claude` to deploy. It reads `.env`, copies deployment files to the VPS via scp, installs
docker & sysbox (if needed) on the VPS, and starts the vibe-kanban docker-compose.yml.

```bash
claude "deploy"
```

#### After Deploy

Use the helper scripts to authenticate Github and Claude Code.

```bash
# Log vibe-kanban into your github account
# This step is required for vibe-kanban to git commit and push/pull code
# Auto generates a ssh key (if needed) for vibe-kanban and adds it to your github account
./github-login.sh

# Log claude code into anthropic subscription (optional)
./claude-login.sh

# Log codex CLI into OpenAI account (optional)
./codex-login.sh

# SSH into the vibe-kanban container for debugging
./ssh-vibekanban.sh
```

NOTE: You will optionally need to sign-in to Vibe Kanban to enable the kanban features.
Simply sign-in with your Github or Google account. No additional configuration is needed.

---

### Manual deploy (optional)

If not using `claude` to deploy for you, follow these instructions.

Copy deployment files to the VPS and run the setup script.

```bash
# Copy deployment files to the VPS (uses vps.sh helper)
bash vps.sh deploy

# First-time setup (installs Docker + Sysbox, clones vibe-kanban, builds, and starts)
bash vps.sh ssh "bash /home/vibe-kanban/setup.sh"
```

For subsequent deploys (pulls latest source, rebuilds, and restarts):

```bash
bash vps.sh ssh "bash /home/vibe-kanban/setup.sh"
```

---

### 5. Verify

Claude will verify everything for you after first deploy.
The following steps are only if you want to manually verify.

```bash
bash vps.sh ssh "cd /home/vibe-kanban && docker compose ps"
```

Both `vibe-kanban` and `cloudflared` should show as running. Check the tunnel logs for `"Connection registered"`:

```bash
bash vps.sh ssh "cd /home/vibe-kanban && docker compose logs --tail=20 cloudflared"
```

Access vibe-kanban at the public hostname you configured in Cloudflare Tunnels.

### 6. (Optional) Claude Code OAuth Login

You can use your Claude Pro/Max/Teams/Enterprise subscription via OAuth. After deploying, run:

```bash
bash claude-login.sh
```

This SSHs into the VPS, opens a shell inside the vibe-kanban container, and runs the Claude Code login flow. You'll see a URL — open it in your browser to authorize. Credentials are persisted across container restarts in a Docker volume.

### 7. (Optional) GitHub Integration

vibe-kanban uses the GitHub CLI (`gh`) for PR creation — not a `GITHUB_TOKEN`. After deploying, run:

```bash
bash github-login.sh
```

This SSHs into the container and runs `gh auth login`. You'll get a URL and a one-time code to authorize in your browser. After login, it also auto-configures `git user.name` and `git user.email` inside the container from your GitHub profile and adds a generated ssh key to your Github account. Credentials are persisted in a Docker volume.

## Environment Variables

| Variable | Required | Description |
|---|---|---|
| `ANTHROPIC_API_KEY` | No* | API key for Claude agents (or use OAuth via `claude-login.sh`) |
| `GOOGLE_API_KEY` | No | API key for Gemini agents |
| `OPENAI_API_KEY` | No | API key for OpenAI/Codex agents |
| `CF_TUNNEL_TOKEN` | Yes | Cloudflare Tunnel token |
| `VK_DOMAIN` | No | Domain served by the tunnel (for Access verification) |
| `VPS_IP` | Yes | IP address of the target VPS |
| `SSH_KEY_PATH` | Yes | Path to SSH private key (default: `~/.ssh/vps1_vibekanban_ed25519`) |
| `SSH_USER` | No | SSH username (default: `root`) |
| `SSH_PORT` | No | SSH port (default: `22`) |
| `RUST_LOG` | No | Log level (default: `info`) |
| `GIT_AUTHOR_NAME` | No | Git commit author name |
| `GIT_AUTHOR_EMAIL` | No | Git commit author email |

*At least one agent API key is required, or use Claude Code OAuth login via `claude-login.sh`.

GitHub integration uses `gh` CLI auth — run `bash github-login.sh` after deploying (see step 7).

## Operations

All commands below are run on the VPS. If using a non-root SSH user, prefix `docker` commands with `sudo`.

```bash
cd /home/vibe-kanban

# Logs
docker compose logs -f                # all services
docker compose logs -f vibe-kanban    # app only
docker compose logs -f cloudflared    # tunnel only

# Restart
docker compose restart

# Update (pull latest source and rebuild)
git -C vibe-kanban pull
docker compose up -d --build

# Backup SQLite DB (bind mount — direct host access)
cp data/vk-data/db.v2.sqlite ./backup-$(date +%Y%m%d).sqlite

# Backup all data
tar czf vk-backup-$(date +%Y%m%d).tar.gz data/

# Restore SQLite DB
docker compose stop vibe-kanban
cp ./backup.sqlite data/vk-data/db.v2.sqlite
docker compose start vibe-kanban
```

## How It Works

- **Sysbox** provides a secure Docker-in-Docker runtime. The vibe-kanban container runs as root internally, but sysbox maps it to an unprivileged host user.
- **dockerd** runs inside the container so AI agents can use Docker.
- **Agents** are spawned via `npx` (e.g., `npx -y @anthropic-ai/claude-code@latest`).
- **cloudflared** establishes an outbound-only tunnel to Cloudflare's edge — no ports are exposed on the VPS.
- **Cloudflare Access** (configured in the CF dashboard) protects the public hostname with identity-aware auth.

## File Reference

| File | Purpose |
|---|---|
| `deploy/Dockerfile.vps` | Multi-stage build (node+rust builder, ubuntu runtime) |
| `deploy/entrypoint.sh` | Starts dockerd, then execs the server binary |
| `deploy/docker-compose.yml` | Service definitions with sysbox-runc runtime |
| `deploy/.env.example` | Environment variable template |
| `deploy/.dockerignore` | Docker build ignore rules |
| `deploy/setup.sh` | VPS bootstrap (Docker + Sysbox + deploy) |
| `vps.sh` | SSH/SCP/deploy wrapper — reads `.env`, auto-adds sudo for non-root |
| `claude-login.sh` | Helper to run Claude Code OAuth login inside the container |
| `codex-login.sh` | Helper to run OpenAI Codex CLI login inside the container |
| `github-login.sh` | Helper to run GitHub CLI OAuth login inside the container |
| `ssh-vps.sh` | SSH into the VPS host |
| `ssh-vibekanban.sh` | SSH into the VPS and exec into the vibe-kanban container |
| `CLAUDE.md` | Instructions for Claude Code to deploy and operate the stack |

## Troubleshooting

**Container won't start** — Check logs and sysbox status:

```bash
docker compose logs vibe-kanban
systemctl status sysbox
```

**Docker daemon not starting inside container:**

```bash
docker compose exec vibe-kanban cat /var/log/dockerd.log
docker inspect vibe-kanban | grep Runtime   # should show sysbox-runc
```

**Tunnel not connecting** — Check cloudflared logs:

```bash
docker compose logs cloudflared
```

Common issues: invalid/expired `CF_TUNNEL_TOKEN`, missing public hostname config in CF dashboard, vibe-kanban not healthy yet.

**Permission denied errors** — The container uses root internally (sysbox isolates it). If bind mount permissions break:

```bash
chown -R root:root data/ && docker compose restart
```
