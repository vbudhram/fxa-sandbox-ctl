# FXA Agent Sandbox

Run multiple Claude Code agents in self-contained Linux VMs on macOS. Each agent gets its own MySQL, Redis, Firestore, and full Node.js toolchain. A host directory (git worktree) is mounted via VirtioFS. Interact with agents through tmux sessions.

## Prerequisites

```bash
brew install cirruslabs/cli/tart tmux
```

For building the golden image:
```bash
brew install hashicorp/tap/packer
```

## Quick Start

### 1. Build the golden image (one-time, ~15 min)

```bash
fxa-sandbox-ctl image build
```

This creates a reusable Ubuntu 24.04 ARM64 VM with everything pre-installed. Subsequent agent launches clone this image instantly via APFS CoW.

### 2. Set up authentication

Generate a long-lived OAuth token for headless agent use:

```bash
claude setup-token
```

Export it before starting agents:

```bash
export CLAUDE_CODE_OAUTH_TOKEN="sk-ant-oat01-..."
```

### 3. Start an agent

```bash
fxa-sandbox-ctl run ~/worktrees/feature-auth -n "auth-fix"
```

This:
- Clones the golden image (instant APFS CoW)
- Boots the VM with your worktree mounted at `/workspace`
- Starts MySQL, Redis, Firestore emulator inside the VM
- Applies security hardening (egress firewall, restricted sudo, SSH key-only)
- Copies only `settings.json` and `CLAUDE.md` from host (no sensitive data)
- Injects the OAuth token ephemerally (deleted from disk after Claude reads it)
- Launches Claude Code in a tmux window

### 4. Interact with the agent

```bash
# Attach to the Claude Code TUI
fxa-sandbox-ctl attach auth-fix

# Inside tmux: Ctrl-b d to detach (agent keeps working)

# See all agents
fxa-sandbox-ctl list

# Check logs
fxa-sandbox-ctl logs auth-fix --follow

# Start FXA services in the VM
fxa-sandbox-ctl services auth-fix

# Launch Firefox pointing at the VM
fxa-sandbox-ctl browser auth-fix

# Stop an agent
fxa-sandbox-ctl stop auth-fix

# Stop everything
fxa-sandbox-ctl stop --all
```

## Architecture

```
macOS Host (32GB RAM)
├── Tart (VM manager, Apple Virtualization framework)
├── tmux session: "fxa-agents"
│   ├── window 1: "auth-fix"     → SSH → VM 1 → Claude Code
│   ├── window 2: "payments"     → SSH → VM 2 → Claude Code
│   └── window 3: "profile-bug"  → SSH → VM 3 → Claude Code
│
├── VM 1 (Ubuntu ARM64, ~5GB RAM, 2 vCPU)
│   ├── /workspace ← host worktree (VirtioFS, read-write)
│   ├── MySQL 8.0 (fxa, fxa_profile, fxa_oauth, pushbox)
│   ├── Redis 6+
│   ├── Firestore emulator (:9090)
│   ├── goaws SNS/SQS emulator (:4100)
│   ├── iptables egress firewall
│   └── Claude Code --dangerously-skip-permissions
│
└── Golden Image: fxa-dev-base (~10GB, APFS CoW clones)
```

### Resource Budget (32GB host)

| Component | RAM |
|-----------|-----|
| macOS + Tart | ~4 GB |
| 5 VMs x 5 GB | ~25 GB |
| Headroom | ~3 GB |

5 concurrent agents is the practical ceiling. Use `-m 3072` for lighter tasks.

## Commands Reference

| Command | Description |
|---------|-------------|
| `run <dir> [-n name] [-p prompt]` | Start a new agent |
| `attach <name>` | Attach to agent's Claude Code TUI |
| `services <name> [options]` | Start FXA app services in an agent's VM |
| `browser <name>` | Launch Firefox configured to use an agent's VM |
| `list` | List all agents |
| `logs <name> [--follow]` | View agent logs |
| `stop <name>` | Stop and remove an agent |
| `stop --all` | Stop all agents |
| `image build` | Build the golden VM image |
| `image status` | Check golden image status |
| `status` | Show system status |

### Run Options

| Flag | Default | Description |
|------|---------|-------------|
| `-n, --name` | auto-generated | Agent name |
| `-p, --prompt` | none | Initial prompt for Claude Code |
| `-c, --cpu` | 2 | vCPU count |
| `-m, --memory` | 5120 | Memory in MB |

## Security Model

The VM is the security boundary. Each agent runs inside an isolated Linux VM with multiple layers of hardening:

### What the agent CAN do
- Read and write files in the mounted workspace directory
- Access the public internet (for npm, GitHub, Anthropic API, etc.)
- Run any command inside the VM (build, test, install packages)
- Use MySQL, Redis, Firestore locally inside the VM

### What the agent CANNOT do
- **Access the host filesystem** beyond the workspace (no `~/.claude` history, no `~/Library`, no other projects)
- **Reach the host machine** — iptables blocks all traffic to `192.168.0.0/16`, `10.0.0.0/8`, `172.16.0.0/12` (only DNS to gateway is allowed)
- **Escalate to root freely** — sudo is restricted to specific commands (`systemctl`, `apt-get`, `mysql`, `redis-cli`, `chmod`, `chown`)
- **Read the OAuth token from disk** — the token is injected via an ephemeral file that is deleted immediately after Claude reads it; it only exists in process memory
- **SSH to other agent VMs** — each agent has a unique SSH key pair; password authentication is disabled
- **Read host Claude data** — conversation history, project paths, session data, cookies, and token caches are never mounted into the VM

### Hardening applied at runtime

| Layer | Protection |
|-------|-----------|
| **Mount isolation** | Only the workspace directory is shared (read-write). No host config directories. |
| **Egress firewall** | iptables drops traffic to all private/link-local ranges. DNS to gateway allowed. Public internet open. |
| **Restricted sudo** | Agent user limited to service management and package installation commands. |
| **SSH hardening** | Password auth disabled. Per-agent Ed25519 keys. Admin user locked. |
| **Ephemeral token** | OAuth token exists only in process memory after startup. No persistent file. |
| **Minimal config** | Only `settings.json` and `CLAUDE.md` copied from host. No history, no project data. |
| **Workspace trust** | Pre-configured so Claude Code skips interactive trust dialogs. |

## Claude Auth

Authentication uses `CLAUDE_CODE_OAUTH_TOKEN` — a long-lived token generated by `claude setup-token`.

```bash
# Generate token (one-time, requires Claude subscription)
claude setup-token

# Export before starting agents
export CLAUDE_CODE_OAUTH_TOKEN="sk-ant-oat01-..."

# Start agent (token is injected ephemerally into the VM)
fxa-sandbox-ctl run ~/worktrees/feature -n my-agent
```

The token is:
1. Written to a temporary file inside the VM (readable only by the agent user)
2. Sourced into the Claude Code process environment
3. Immediately deleted from disk
4. Available only in the Claude process memory thereafter

### Model Configuration

Set the default model in `~/.claude/settings.json`:

```json
{
  "model": "claude-opus-4-6"
}
```

This is automatically copied into each new VM agent.

## Browser Command

Launch a real Firefox browser on your Mac pre-configured to talk to the FXA services running inside an agent's VM:

```bash
# Start services first
fxa-sandbox-ctl services auth-fix

# Launch Firefox
fxa-sandbox-ctl browser auth-fix
```

This creates a dedicated Firefox profile at `logs/profiles/<agent-name>/` with a `user.js` containing all the `identity.fxaccounts.*` preferences pointing at the VM's IP. Firefox is launched with `-profile` and `-no-remote` so it runs as a separate instance that won't interfere with your normal browser.

**Profile reuse:** If the profile directory already exists (e.g. after a VM restart), only `user.js` is rewritten with the new IP. Login state, cookies, and other browser data are preserved.

**Cleanup:** The profile directory is automatically deleted when you run `fxa-sandbox-ctl stop <name>`.

## Infrastructure Details

Each VM runs locally:
- **MySQL 8.0** on `:3306` — databases: `fxa`, `fxa_profile`, `fxa_oauth`, `pushbox`
- **Redis** on `:6379`
- **Firestore emulator** on `:9090`
- **goaws** on `:4100` (SNS/SQS emulation)

All services start automatically on VM boot via systemd.

## Troubleshooting

**VM won't boot:** Check `logs/<name>-vm.log`

**Auth fails (401 or "Not logged in"):** Regenerate the token with `claude setup-token` and re-export `CLAUDE_CODE_OAUTH_TOKEN`.

**"usage data" scope error:** This is cosmetic. The `setup-token` doesn't include the `user:profile` scope, but chat works fine.

**No space on disk:** Golden image is ~10GB, each clone uses CoW so minimal extra space. Run `tart list` to see all VMs.

**Tests fail (missing node_modules):** The workspace mount is your host worktree. Run `yarn install` inside the VM first.

**Settings not applied:** If Claude shows Sonnet instead of Opus, check that `~/.claude/settings.json` has the `"model"` key and restart the agent.

**Bypass permissions dialog:** This is auto-accepted after the first time. If it appears, arrow down to "Yes, I accept" and press Enter.

## File Structure

```
fxa-sandbox-ctl/               # Repo root
├── fxa-sandbox-ctl              # Main CLI (executable)
├── README.md                    # This file
├── VM_AGENT_GUIDE.md            # Full agent operations manual
├── test-oauth.js                # OAuth smoke test
├── packer/
│   ├── fxa-dev.pkr.hcl         # Golden image Packer template
│   └── scripts/
│       ├── 01-base.sh           # System packages, SSH hardening
│       ├── 02-node.sh           # Node.js toolchain
│       ├── 03-infra.sh          # MySQL, Redis, Firestore, goaws
│       ├── 04-claude.sh         # Claude Code CLI
│       ├── 05-proxy.sh          # Network config (no proxy)
│       ├── 06-agent-init.sh     # Systemd boot service + egress firewall
│       ├── 07-cleanup.sh        # Image trim
│       ├── 08-playwright.sh     # Playwright browser setup
│       ├── 09-fxa-services.sh   # FXA service scripts (fxa-start)
│       └── 10-agent-guide.sh    # Bake agent guide into image
├── templates/
│   └── agent-startup.sh         # VM entrypoint template
├── lib/
│   ├── config.sh                # Constants and defaults
│   ├── vm.sh                    # Tart VM lifecycle
│   └── agent.sh                 # Agent run/attach/stop/list + security
└── logs/                        # Runtime logs (gitignored)
    ├── ssh/<name>/              # Per-agent SSH keys
    └── profiles/<name>/         # Per-agent Firefox profiles
```
