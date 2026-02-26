# Fix deployment script issues

## Context

During deployment, two scripts failed when run non-interactively via the Bash tool:

1. **`ide-ssh-setup.sh`** — SSH commands consumed stdin, starving the `read` prompt. The script ran twice (likely a retry) and exited with code 1 each time. I had to manually perform the AllowTcpForwarding change and SSH config setup.

2. **`vps.sh ssh`** — Commands with `#` or single quotes broke because `sudo -s -- eval '$*'` exposes them to shell interpretation. The `#` in `# changed by vibe-kanban` was treated as a comment, truncating the sed command.

3. **`CLAUDE.md` Step 4** — Tells Claude to "let the script handle the prompts directly" but the Bash tool doesn't support interactive input.

## Changes

### 1. `ide-ssh-setup.sh` — two fixes

**a) Add `-n` to SSH_CMD (line 60)**

```
SSH_CMD="ssh -n -i ${SSH_KEY_PATH} ..."
```

`-n` redirects stdin from `/dev/null`, preventing SSH from consuming the script's stdin. This lets `read` work correctly even when piped.

**b) Add `--yes` / `-y` flag**

- Add `AUTO_YES=false` before the flag parsing loop
- Add `--yes|-y)` case to set `AUTO_YES=true`
- Replace the bare `read` on line 149 with a check: if `AUTO_YES`, set `REPLY=y` without prompting
- Update the usage line to document the new flag

### 2. `vps.sh` — fix sudo quoting (lines 37 and 54)

Replace `sudo -s -- eval '$*'` with:

```bash
printf -v _remote_cmd 'sudo bash -c %q' "$*"
ssh ... "${_remote_cmd}"
```

`printf '%q'` shell-escapes the command for one layer of parsing. The remote shell unescapes it, then `bash -c` executes the original command verbatim. This correctly handles single quotes, `#`, and all other special characters.

Same fix for the `deploy` subcommand's non-root `mkdir`/`chown` command on line 54.

### 3. `CLAUDE.md` Step 4 — update instructions

Change the IDE SSH section to tell Claude:
1. Check AllowTcpForwarding status first (via `vps.sh ssh`)
2. If a VPS host change is needed, inform the user and get confirmation
3. Run `bash ide-ssh-setup.sh --yes` (non-interactive)
4. Remove the "let the script handle the prompts directly" instruction

## Files to modify

| File | Change |
|---|---|
| `ide-ssh-setup.sh` | Add `-n` to SSH_CMD, add `--yes` flag |
| `vps.sh` | Replace `eval` quoting with `printf '%q'` + `bash -c` |
| `CLAUDE.md` | Update Step 4 IDE SSH instructions |

## Verification

1. Run `bash vps.sh ssh "echo 'hello # world'"` — should print `hello # world` (not truncated at `#`)
2. Run `bash vps.sh ssh "sed --version | head -1"` — should work through pipes
3. Run `bash ide-ssh-setup.sh --yes` — should complete without interactive prompt, exit 0
4. Run `bash ide-ssh-setup.sh --help` or check usage includes `--yes`
