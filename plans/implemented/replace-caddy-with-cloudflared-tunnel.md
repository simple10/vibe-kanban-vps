# Plan: Replace Caddy with Cloudflared Tunnel

## Context

The current deployment exposes ports 80/443 via Caddy for HTTPS + basic auth. We're replacing this with a Cloudflare Tunnel (`cloudflared`) so **no public ports are exposed** on the VPS. The tunnel connects outbound to Cloudflare's edge, and auth is handled via Cloudflare Access policies (configured in the CF dashboard, not in our stack). The user provides a pre-created `CF_TUNNEL_TOKEN` in `.env`.

Additionally, CLAUDE.md should instruct Claude to check for `CF_TUNNEL_TOKEN` in `.env` before deploying, and prompt the user for it if missing.

## Changes

### 1. `docker-compose.yml` — Replace caddy with cloudflared, remove all public ports

- Remove `ports` from `vibe-kanban` service (no longer needs `127.0.0.1:3000:3000` — cloudflared reaches it via Docker network)
- Replace `caddy` service with `cloudflared` service:

  ```yaml
  cloudflared:
    image: cloudflare/cloudflared:latest
    container_name: vibe-kanban-tunnel
    restart: unless-stopped
    command: tunnel --no-autoupdate run --token ${CF_TUNNEL_TOKEN}
    environment:
      CF_TUNNEL_TOKEN: ${CF_TUNNEL_TOKEN}
    depends_on:
      vibe-kanban:
        condition: service_healthy
  ```

- Remove `caddy-data` and `caddy-config` volumes (cloudflared is stateless)

### 2. Delete `Caddyfile` — No longer needed

### 3. `.env.example` — Replace Caddy vars with CF_TUNNEL_TOKEN

- Remove: `VK_DOMAIN`, `VK_AUTH_USER`, `VK_AUTH_HASH`
- Add: `CF_TUNNEL_TOKEN=` with a comment explaining how to get it (Cloudflare Zero Trust dashboard → Networks → Tunnels → Create → copy token)
- Add comment noting auth is configured via Cloudflare Access policies

### 4. `setup.sh` — Update for cloudflared

- Remove `Caddyfile` from the file copy list
- Update `.env` prompt to mention `CF_TUNNEL_TOKEN` instead of Caddy vars
- Remove domain display at end (domain is configured in CF dashboard, not in `.env`)

### 5. `CLAUDE.md` — Update architecture, env vars, operations, troubleshooting

- Architecture diagram: `Internet → Cloudflare Edge → cloudflared tunnel → vibe-kanban:3000`
- Remove Caddy-related env vars from table, add `CF_TUNNEL_TOKEN`
- Remove Caddy log commands, add cloudflared log commands
- Remove "Caddy not getting certificates" troubleshooting
- Add cloudflared troubleshooting (tunnel not connecting, token issues)
- Add deploy instructions: Claude should check `.env` for `CF_TUNNEL_TOKEN` and ask user for it if missing
- Remove Caddyfile from file reference table

### 6. `Dockerfile.vps` — No changes

`EXPOSE 3000` stays as documentation; no functional port changes needed.

### 7. `entrypoint.sh` — No changes

### 8. `.dockerignore` — Remove Caddyfile exclusion if present (minor)

No change needed — Caddyfile wasn't in .dockerignore.

## Files Modified

| File | Action |
|---|---|
| `docker-compose.yml` | Edit: replace caddy→cloudflared, remove public ports |
| `Caddyfile` | **Delete** |
| `.env.example` | Edit: CF_TUNNEL_TOKEN replaces Caddy vars |
| `setup.sh` | Edit: remove Caddyfile, update prompts |
| `CLAUDE.md` | Edit: full rewrite of architecture/ops/troubleshooting |

## Verification

1. `docker compose config` — validates compose file syntax
2. On VPS with sysbox: `docker compose up -d --build`, check `docker compose ps` shows both services healthy
3. cloudflared connects: `docker compose logs cloudflared` shows "Connection registered"
4. Access via configured CF tunnel hostname — should reach vibe-kanban UI
5. No ports listening externally: `ss -tlnp` shows no 80/443/3000
