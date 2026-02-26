# Rename bind mount directories: remove vk- prefix

## Context

The `data/` subdirectories on the VPS use a `vk-` prefix (e.g. `data/vk-repos/`, `data/vk-ssh/`). The prefix is unnecessary since they're already under the vibe-kanban install dir. Remove it for cleaner paths.

## Rename mapping

| Old | New |
|---|---|
| `data/vk-data/` | `data/vibe-kanban/` |
| `data/vk-repos/` | `data/repos/` |
| `data/vk-worktrees/` | `data/worktrees/` |
| `data/vk-docker/` | `data/docker/` |
| `data/vk-claude/` | `data/claude/` |
| `data/vk-ghcli/` | `data/ghcli/` |
| `data/vk-ssh/` | `data/ssh/` |
| `data/vk-sshd/` | `data/sshd/` |

## Files to modify

1. **`deploy/docker-compose.yml`** — all 8 volume mount paths (lines 12-19)
2. **`deploy/setup.sh`** — `mkdir -p` list (line 144)
3. **`ide-ssh-setup.sh`** — `AUTH_KEYS_DIR` reference (line 96)
4. **`github-login.sh`** — echo message mentioning `vk-ssh` (line 48)
5. **`CLAUDE.md`** — Data Locations table, backup/restore examples, troubleshooting references
6. **`README.md`** — backup/restore examples

Skip `plans/implemented/*.md` — those are historical records, not active config.

## VPS migration

The VPS already has data in the old directory names. `setup.sh` needs a migration step to rename existing dirs on next deploy. Add before the `mkdir -p`:

```bash
# Migrate old vk- prefixed data directories
declare -A MIGRATE=(
    [vk-data]=vibe-kanban [vk-repos]=repos [vk-worktrees]=worktrees
    [vk-docker]=docker [vk-claude]=claude [vk-ghcli]=ghcli [vk-ssh]=ssh [vk-sshd]=sshd
)
for old in "${!MIGRATE[@]}"; do
    new="${MIGRATE[$old]}"
    if [[ -d "$DEPLOY_DIR/data/$old" ]] && [[ ! -d "$DEPLOY_DIR/data/$new" ]]; then
        mv "$DEPLOY_DIR/data/$old" "$DEPLOY_DIR/data/$new"
        echo "Migrated data/$old → data/$new"
    fi
done
```

## Verification

1. Run `bash vps.sh ssh "ls /home/vibe-kanban/data/"` to confirm new names exist
2. Run `bash vps.sh ssh "cd /home/vibe-kanban && docker compose up -d --build"` to verify mounts work
3. `ssh vibe-kanban` to verify IDE SSH still connects
4. Verify no `vk-` references remain: `grep -r "vk-" deploy/ ide-ssh-setup.sh github-login.sh CLAUDE.md`
