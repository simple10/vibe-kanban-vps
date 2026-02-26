Plan: Add SSH Server Inside vibe-kanban Container for IDE Remote Access

Context

When users click "Open in Cursor/VS Code" in the vibe-kanban web UI, it generates a vscode://vscode-remote/ssh-remote+user@host/path
URL. The paths are container-internal (e.g., /repos/, /var/tmp/vibe-kanban/worktrees/...), but SSH currently connects to the VPS host
 where those paths don't exist. Running sshd inside the container on port 2222 lets editors connect directly into the container where
 paths are correct.

Files to Modify (8 total)

1. deploy/Dockerfile.vps — Install openssh-server, configure sshd

- Add openssh-server to the base packages apt-get install line (alongside existing openssh-client)
- After user creation block, add sshd config:
  - Create /run/sshd and /etc/ssh/sshd_host_keys/ directories
  - Write /etc/ssh/sshd_config.d/vk-ide.conf with: Port 2222, key-only auth, AllowUsers vkuser, AllowTcpForwarding yes, SFTP
subsystem
- Add EXPOSE 2222 alongside existing EXPOSE 3000

1. deploy/entrypoint.sh — Start sshd, export env for SSH sessions

Insert before the final exec gosu vkuser vibe-kanban:

- Generate SSH host keys if not present (persisted via bind mount at /etc/ssh/sshd_host_keys/)
- Write /etc/environment with API keys, PATH, HOME — critical so VS Code SSH sessions inherit ANTHROPIC_API_KEY, GOOGLE_API_KEY, etc.
 Without this, agents spawned from VS Code terminals would lack credentials.
- Start sshd conditionally, only when VK_IDE_SSH=true

1. deploy/docker-compose.yml — Port mapping, volume, env var

- Add port mapping: "${VK_SSH_PORT:-2222}:2222"
- Add volume: ./data/vk-sshd:/etc/ssh/sshd_host_keys (persists host keys across rebuilds, prevents "host key changed" warnings)
- Add VK_IDE_SSH: "${VK_IDE_SSH:-false}" to environment block

1. deploy/setup.sh — Add vk-sshd directory

- Line 144: add vk-sshd to the mkdir -p list of bind mount directories

1. .env.example — Add new variables

Add new section with VK_IDE_SSH (default false, opt-in) and VK_SSH_PORT (default 2222), both commented out.

1. ide-ssh-setup.sh — New helper script

Following the pattern of claude-login.sh and github-login.sh:

1. Sources .env, derives public key from SSH_KEY_PATH (or accepts --key flag)
2. SSHs to VPS, injects public key into $INSTALL_DIR/data/vk-ssh/authorized_keys (idempotent, no duplicates)
3. Adds a Host vibe-kanban entry to local ~/.ssh/config (with HostName, Port, User, IdentityFile) — skippable with --no-config
4. Prints connection instructions

5. README.md — Document IDE SSH access

- Add new section "8. (Optional) IDE Remote SSH (VS Code / Cursor)" after GitHub Integration section (~line 162)
- Add VK_IDE_SSH and VK_SSH_PORT to the Environment Variables table
- Add ide-ssh-setup.sh to the File Reference table
- Include firewall warning about port 2222

1. CLAUDE.md — Add post-deploy step + reference updates

- Architecture diagram: add sshd (port 2222, optional) line
- Deployment flow: Add new section "IDE Remote SSH Setup (Optional)" — instructs Claude to ask the user if they want IDE SSH access
after deploy, and if yes, run ide-ssh-setup.sh for them and configure their local ~/.ssh/config
- Environment Variables table: add VK_IDE_SSH, VK_SSH_PORT
- Data Locations table: add data/vk-sshd/ → /etc/ssh/sshd_host_keys/
- File Reference table: add ide-ssh-setup.sh
- Troubleshooting: add "IDE SSH not connecting" section with diagnostic commands

Key Design Decisions

- Opt-in via VK_IDE_SSH=true: sshd only starts when explicitly enabled — no extra attack surface by default
- Separate data/vk-sshd volume: keeps sshd host keys separate from user SSH keys in data/vk-ssh (used by github-login.sh for git)
- /etc/environment for SSH sessions: container env vars (API keys) aren't available in SSH sessions by default — writing them to
/etc/environment ensures VS Code terminals have them
- Key-only auth, AllowUsers vkuser: no passwords, no root SSH — only vkuser can connect
- SSH config alias vibe-kanban: since vscode:// URLs don't support inline ports, the local SSH config entry handles port mapping

Verification

After implementation and deploying:

1. Set VK_IDE_SSH=true in .env and redeploy
2. Run bash ide-ssh-setup.sh — should inject key and add SSH config entry
3. ssh vibe-kanban — should connect into the container as vkuser
4. ssh vibe-kanban "ls /repos" — should list repos inside the container
5. ssh vibe-kanban "printenv ANTHROPIC_API_KEY" — should show the API key (verifies /etc/environment works)
6. Open Cursor/VS Code → Remote-SSH: Connect to Host → select vibe-kanban → should open in container
7. In vibe-kanban UI, set Remote SSH Host to vibe-kanban, User to vkuser → click "Open in Cursor" on a workspace → should open correct worktree path
