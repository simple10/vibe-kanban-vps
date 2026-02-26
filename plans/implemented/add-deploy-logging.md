# Plan: Deploy Logging to `deploy-log.md`

## Context

During deployment, many things are modified on the VPS (packages installed, files copied, Docker images built, containers started, volumes created). The user has no clear record of what changed. We need Claude to write a `deploy-log.md` file locally as the deploy happens, capturing the output of every step so the user knows exactly what was modified.

## Approach

**Only modify `CLAUDE.md`** — no changes to shell scripts needed. Claude already captures stdout/stderr from every `vps.sh` command it runs. The instructions will tell Claude to write those outputs into `deploy-log.md` incrementally during deployment.

### What changes

**File: `CLAUDE.md`** — Add a new "Deploy Logging" section (before the "Deploying to the VPS" section) that instructs Claude to:

1. **At deploy start:** Create `./deploy-log.md` with a header containing timestamp, VPS target (IP, user, port), `INSTALL_DIR`, and git SHA of the deployment repo
2. **After each step:** Append the step name, the exact command(s) run, and their full output (in fenced code blocks)
3. **At deploy end:** Append a summary section

### Log structure

```markdown
# Deploy Log — YYYY-MM-DD HH:MM:SS

**Target:** user@ip:port
**Install dir:** /home/vibe-kanban
**Deploy repo commit:** abc1234

## Pre-deploy: Cloudflare Access check
\`\`\`
<curl output>
\`\`\`

## Step 1: Copy deployment files
**Files copied to ${INSTALL_DIR}/:**
- docker-compose.yml
- Dockerfile.vps
- entrypoint.sh
- .env.example
- .dockerignore
- setup.sh
- .env

## Step 2: Run setup on VPS
\`\`\`
<full setup.sh output>
\`\`\`

## Step 3: Post-deploy verification

### Container status
\`\`\`
<docker compose ps output>
\`\`\`

### Tunnel status
\`\`\`
<cloudflared logs>
\`\`\`

### App logs
\`\`\`
<vibe-kanban logs>
\`\`\`

## Summary
- **Services:** vibe-kanban (running/healthy), cloudflared (running)
- **Result:** SUCCESS / FAILED
```

### Instructions added to CLAUDE.md

Add a "Deploy Logging" subsection within the "Deploying to the VPS" section, right before "Step 1". It will instruct Claude to:

1. Create `deploy-log.md` using the Write tool at the start of deployment
2. Append to it using the Edit tool after each step, including the raw command output
3. Every command output goes in a fenced code block
4. The log captures: what files were copied, the full setup.sh output (which includes package installs, Docker builds, etc.), container status, and tunnel connectivity

## Verification

After making the change, read the updated CLAUDE.md and confirm:

- The deploy logging section is clear and actionable
- It covers all deploy steps (pre-deploy check, file copy, setup, verification)
- The log format is readable and comprehensive
