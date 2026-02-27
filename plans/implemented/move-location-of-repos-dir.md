# Plan: Move /repos to /home/repos and add REPOS_DIR env var

## Context

The vibe-kanban UI file browser defaults to `$HOME` (`/home/vkuser`). When users browse up one level they see `/home/`, but repos are at `/repos` (root level) — requiring them to navigate all the way up to `/` and scroll to find it. Moving repos to `/home/repos` makes them visible one level up from home. Adding a `REPOS_DIR` env var makes the path configurable and gives scripts/Claude a single source of truth.

## Changes

### 1. `.env.example` — Add `REPOS_DIR`

Add after the `INSTALL_DIR` line:

```
# Directory inside the container where git repos are cloned (default: /home/repos)
# REPOS_DIR=/home/repos
```

### 2. `.env` — Add `REPOS_DIR`

Add:

```
REPOS_DIR=/home/repos
```

### 3. `deploy/docker-compose.yml`

Change bind mount from:

```yaml
- ./data/repos:/repos
```

To:

```yaml
- ./data/repos:${REPOS_DIR:-/home/repos}
```

Also pass `REPOS_DIR` into the container environment so vibe-kanban and scripts can read it:

```yaml
REPOS_DIR: "${REPOS_DIR:-/home/repos}"
```

### 4. `deploy/Dockerfile.vps`

- Change `mkdir -p /repos` → `mkdir -p /home/repos`
- Change `chown` to include `/home/repos`
- Change `WORKDIR /repos` → `WORKDIR /home/repos`

### 5. `deploy/entrypoint.sh`

- Use `REPOS_DIR` env var (with `/home/repos` default) instead of hardcoded `/repos`
- Update `mkdir -p`, symlink, and `chown` to use `$REPOS_DIR`
- Symlink becomes: `ln -s $REPOS_DIR /home/vkuser/repos` (only if REPOS_DIR is not already under /home/vkuser)

### 6. `clone-repo-remote.sh`

- Source `.env` to get `REPOS_DIR`
- Use `${REPOS_DIR:-/home/repos}` in the docker exec clone command

### 7. `ide-ssh-setup.sh` — Line 308

- Update usage docs reference from `/repos/` to `/home/repos/`

### 8. `CLAUDE.md`

- Update Data Locations table: `/repos/` → container path uses `$REPOS_DIR` (default `/home/repos`)
- Update Environment Variables table: add `REPOS_DIR`

### 9. `README.md`

- No direct `/repos` references to update

## Verification

1. Deploy to VPS: `bash vps.sh deploy && bash vps.sh ssh "bash /home/vibe-kanban/setup.sh"`
2. Verify container starts healthy
3. Verify `/home/repos` exists inside container and is writable by vkuser
4. Verify symlink at `/home/vkuser/repos` → `/home/repos`
5. Test `./clone-repo-remote.sh` with a repo URL
6. Verify browsing up from `/home/vkuser` in vibe-kanban UI shows `repos/` at `/home/`
