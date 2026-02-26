# Add Resource Limits to vibe-kanban Containers

## Context

The vibe-kanban and cloudflared containers currently run with no resource limits. On a 92 GiB RAM VPS shared with other containers, runaway agents or memory leaks could starve the host. We need sensible defaults that prevent this while leaving enough headroom for concurrent coding agents.

### What runs inside the vibe-kanban container

- **vibe-kanban server** (Rust/Tokio binary): ~100-200 MB baseline
- **dockerd** (Docker-in-Docker via sysbox): ~100-300 MB
- **Coding agents** (Claude Code, Codex, Gemini CLI via npx): ~300-500 MB each, multiple can run concurrently

### What runs in cloudflared

- Single tunnel proxy to `http://vibe-kanban:3000`, light traffic
- Currently using ~18 MB, idles at <1% CPU

## Changes

### 1. `.env.example` — add resource limit env vars with defaults

Add a new "Container resource limits" section:

```
# Container resource limits (vibe-kanban)
# Adjust based on expected concurrent agents. Each coding agent uses ~500MB RAM.
# VK_CPU_LIMIT=4        # max CPU cores
# VK_MEM_LIMIT=8g       # max memory (e.g. 4g, 8g, 16g)
# VK_CPU_RESERVE=1      # guaranteed CPU cores
# VK_MEM_RESERVE=2g     # guaranteed memory
```

Defaults rationale:

- **8g memory limit**: baseline ~500 MB (server + dockerd) + room for 2-3 concurrent agents at ~500 MB each + buffer for Node.js/npx overhead and docker builds
- **4 CPU limit**: agents are CPU-intensive during code generation; 4 cores allows 2 concurrent agents without starving the server
- **2g memory reservation**: guarantees enough for server + dockerd even when host is under pressure
- **1 CPU reservation**: guarantees the server stays responsive

### 2. `docker-compose.yml` — add resource limits

**vibe-kanban service** — use env vars with fallback defaults:

```yaml
deploy:
  resources:
    limits:
      cpus: "${VK_CPU_LIMIT:-4}"
      memory: "${VK_MEM_LIMIT:-8g}"
    reservations:
      cpus: "${VK_CPU_RESERVE:-1}"
      memory: "${VK_MEM_RESERVE:-2g}"
```

**cloudflared service** — hardcoded (no env vars needed):

```yaml
deploy:
  resources:
    limits:
      cpus: "0.5"
      memory: 256m
    reservations:
      cpus: "0.1"
      memory: 128m
```

Cloudflared rationale: currently uses 18 MB and <1% CPU. 256 MB limit is ~14x headroom. Cloudflare docs recommend 128 MB minimum for buffer allocation.

### 3. `CLAUDE.md` — add env vars to the table

Add `VK_CPU_LIMIT`, `VK_MEM_LIMIT`, `VK_CPU_RESERVE`, `VK_MEM_RESERVE` to the Environment Variables table.

## Files to modify

- `docker-compose.yml` — add `deploy.resources` blocks to both services
- `.env.example` — add resource limit env vars section
- `CLAUDE.md` — add new env vars to the Environment Variables table

## Verification

1. Run `docker compose config` on VPS to confirm env var interpolation works
2. `docker stats --no-stream` to confirm limits appear
3. `docker inspect vibe-kanban --format '{{.HostConfig.Memory}}'` to verify memory cap applied
