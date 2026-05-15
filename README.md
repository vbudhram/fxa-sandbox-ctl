# FxA Agent Sandbox

Run multiple Claude Code agents in self-contained Linux VMs on macOS. Each agent gets its own MySQL, Redis, Firestore, and full Node.js toolchain. A host directory (git worktree) is mounted via VirtioFS. Interact with agents through `screen` sessions (multi-attach with `screen -x`).

Two main modes:
- **Manual** (`run`): start an agent on a worktree you choose, drive it yourself.
- **Autonomous Jira → PR** (`jira`): point at a ticket, get a pushed branch + pre-filled `gh pr create` command back. See [Autonomous Jira → PR Workflow](#autonomous-jira--pr-workflow).

## Prerequisites

```bash
brew install cirruslabs/cli/tart oven-sh/bun/bun
```

(`bun` is needed because some Claude Code plugins ship hooks that shell out to it. Without it, every tool call spams a non-blocking "Bun not found" message.)

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
- Copies `settings.json`, `CLAUDE.md`, `hooks/`, `commands/`, `skills/`, and `plugins/` from host (no sensitive data)
- Injects the OAuth token ephemerally via the workspace mount (deleted after Claude reads it)
- Launches Claude Code in a `screen` session (`screen -x` multi-attach)

### 4. Interact with the agent

```bash
# Attach to the Claude Code TUI (multi-attach safe)
fxa-sandbox-ctl attach auth-fix

# Inside screen: Ctrl-a d to detach (agent keeps working)

# Switch to a different workspace (VM restarts, DB preserved)
fxa-sandbox-ctl switch auth-fix ~/worktrees/new-feature

# See all agents
fxa-sandbox-ctl list

# Check logs
fxa-sandbox-ctl logs auth-fix --follow

# Start FxA services in the VM
fxa-sandbox-ctl services auth-fix

# Launch Firefox pointing at the VM
fxa-sandbox-ctl browser auth-fix

# Run all functional tests against the VM
fxa-sandbox-ctl test auth-fix

# Run a specific test
fxa-sandbox-ctl test auth-fix -- tests/signin/signIn.spec.ts

# Stop an agent
fxa-sandbox-ctl stop auth-fix

# Stop everything
fxa-sandbox-ctl stop --all
```

## Autonomous Jira → PR Workflow

The `jira` subcommand drives a full ticket-to-PR pipeline. Given a Jira key, it fetches the ticket, prepares a worktree, runs an autonomous Claude Code agent against a strict `/goal` directive, watches for a handoff signal, pushes the branch, and prints the `gh pr create` command for you to review.

### One-shot

```bash
# Set CLAUDE_CODE_OAUTH_TOKEN in .env (auto-loaded at script start)
echo 'CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-...' > .env

# Dry-run first to inspect the prompt and worktree path
fxa-sandbox-ctl jira FXA-13474 --dry-run

# Actually run it
fxa-sandbox-ctl jira FXA-13474
```

What happens under the hood:

1. **Jira fetch** — `lib/jira.sh` calls `acli jira workitem view --json` and flattens the Atlassian Document Format description + comments to markdown. Result is written to `<worktree>/.fxa-jira-context.md`.
2. **Worktree** — a pool of `fxa-auto`, `fxa-auto-2`, ... worktrees. Picks the first one not in use by a running agent, else creates the next-numbered slot. Reusing a slot keeps `node_modules` warm across tickets.
3. **VM boot** — golden image cloned via APFS CoW, hardened (egress firewall, restricted sudo, ephemeral OAuth token written through the workspace mount).
4. **`/goal` autonomy** — Claude starts in TUI mode (`--permission-mode bypassPermissions`), the prompt is pasted via `screen paste` so it works with curly quotes, parens, and other special chars. Bypass dialog is pre-accepted via `bypassPermissionsModeAccepted` in `~/.claude.json` + `skipDangerousModePermissionPrompt` in `settings.json`.
5. **Agent runs through 8 conditions** (see `_jira_render_prompt` in `fxa-sandbox-ctl`):
    1. Print a plan
    2. Unit tests pass
    3. `npx nx lint <pkg>` clean for every modified package
    4. Functional tests pass (+ Playwright media capture for UI flows)
    5. `/code-simplifier` applied
    6. `/fxa-review-quick` clean
    7. Exactly one commit ahead of `origin/main` with a scoped conventional message (scope-creep guard via `git diff --stat`)
    8. Write `/workspace/.fxa-auto-done.json` (the handoff signal)
6. **Host watcher** — polls for the handoff file (visible via virtiofs). When it lands, host pushes the branch, uploads any media files as secret gists, and assembles the PR body via `/create-pr-description` + `/humanizer`.
7. **PR not auto-created** by default. The orchestrator prints the exact `gh pr create --body-file .fxa-auto-pr-body.md` command for you to review and run. Add `--create-pr` to skip the manual step.

### Jira options

| Flag | Default | Description |
|------|---------|-------------|
| `--worktree <name>` | auto-pool | Pin to a named worktree slot (creates if missing). Without it, the pool picks a free `fxa-auto*` slot. |
| `--base <branch>` | `main` | Base branch for new ticket branches. |
| `--watch` | on | After agent starts, block until handoff lands, then push. |
| `--no-watch` | — | Fire-and-forget; resume later with `finish`. |
| `--create-pr` | off | Also run `gh pr create` after pushing. |
| `--no-ci-watch` | — | Skip CI polling (only relevant with `--create-pr`). |
| `--dry-run` | off | Print the prompt and worktree path; don't create anything. |
| `-c, --cpu` / `-m, --memory` | 4 / 8192 | VM resources. |

### Worktree pool

Workspaces live as sibling dirs of the FxA repo: `<parent>/fxa-auto`, `<parent>/fxa-auto-2`, ... Each is a real git worktree. A `<name>-holding` branch keeps the slot checked out when idle. Per-ticket branches (`fxa-13474`, `fxa-13737`, ...) are created off `origin/main`.

Detection of "busy" is anchored on `tart` — the orchestrator scans `logs/*.meta` and only counts a workspace as busy if `vm_is_running` confirms its VM is alive. Stale metas (from crashed orchestrators or `TaskStop`'d shells) don't block new runs.

### Picking up where the agent left off

If you `Ctrl-C` the watcher (or it times out), the agent keeps working inside the VM. When you're ready:

```bash
fxa-sandbox-ctl finish              # auto-detects which slot has a handoff ready
fxa-sandbox-ctl finish --create-pr  # also create the PR
```

Or attach live to see what Claude is doing:

```bash
fxa-sandbox-ctl attach fxa-13474     # multi-attach via screen -x
fxa-sandbox-ctl tail fxa-13474       # snapshot the screen scrollback
```

### Handoff JSON schema

The agent writes `/workspace/.fxa-auto-done.json` when its `/goal` conditions are met:

```json
{
  "issue":      "FXA-13474",
  "branch":     "fxa-13474",
  "commit_sha": "abc123...",
  "pr_title":   "fix(settings): match commit subject exactly",
  "pr_body":    "## Summary\n...\n\n## Test Plan\n...",
  "media_paths": [".fxa-auto-media/before.png", ".fxa-auto-media/after.png"]
}
```

`pr_title` must equal the commit subject (scoped conventional). `media_paths` are relative to the worktree root — host uploads each as a secret gist and embeds raw URLs in the rendered PR body.

### Dirty-state handling

The orchestrator filters certain untracked paths from the "is the worktree clean?" check:
- `.fxa-auto-*` / `.fxa-jira-*` — our own orchestration files
- `ai/` — agent-context symlink convention (referenced by `CLAUDE.md`)
- `.claude/` — per-worktree claude-code state
- `packages/fxa-auth-server/config/newKey.json` — known FxA test artifact

Set `FXA_DIRTY_IGNORE='<extended-regex>'` to extend the filter for your own scratch files.

### `.env`

The CLI auto-loads `.env` from its script directory at startup. Shell-exported vars win over `.env`. Useful keys:

| Key | Purpose |
|-----|---------|
| `CLAUDE_CODE_OAUTH_TOKEN` | Generated via `claude setup-token`. Ephemerally injected into each VM. |
| `FXA_REPO` | Override the FxA monorepo path (default: `~/Desktop/working2/fxa`). |
| `FXA_WORKTREE_BASE` | Default base branch (default: `main`). |
| `FXA_AGENT_MODEL` | Model alias for the agent's Claude (default: `opus`). |
| `FXA_SHARED_WORKTREE_NAME` | Pool base name (default: `fxa-auto`). |
| `FXA_DIRTY_IGNORE` | Extended-regex pattern of extra status lines to ignore. |

## Architecture

```
macOS Host (32GB RAM)
├── Tart (VM manager, Apple Virtualization framework)
├── fxa-sandbox-ctl  (CLI; loads .env at startup)
│   ├── jira          → autonomous ticket→PR pipeline
│   ├── run / attach  → manual agent driving
│   └── finish        → resume push + PR after a paused watcher
│
├── Worktree pool (sibling dirs of the FxA repo)
│   ├── fxa-auto       ← VM "fxa-13463" mounts this (per-agent)
│   ├── fxa-auto-2     ← VM "fxa-13474" mounts this
│   └── ...            ← created on demand when all are busy
│
├── VM 1 (Ubuntu ARM64, ~8GB RAM, 4 vCPU)
│   ├── /workspace ← host worktree (VirtioFS, read-write)
│   ├── MySQL 8.0 (fxa, fxa_profile, fxa_oauth, pushbox)
│   ├── Redis 6+
│   ├── Firestore emulator (:9090)
│   ├── goaws SNS/SQS emulator (:4100)
│   ├── iptables egress firewall
│   ├── screen session "claude" (multi-attach via screen -x)
│   └── Claude Code --permission-mode bypassPermissions
│
└── Golden Image: fxa-dev-base (~10GB, APFS CoW clones)
    └── Pre-installed: Node, MySQL, Redis, Firestore, Playwright, Claude Code, Bun
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
| `jira <ISSUE-KEY> [options]` | Autonomous ticket→PR pipeline (see [Autonomous Jira → PR Workflow](#autonomous-jira--pr-workflow)) |
| `finish [--wait] [--create-pr]` | Resume after a `jira --no-watch` or `Ctrl-C`: push + optional PR |
| `run <dir> [-n name] [-p prompt]` | Start a new agent manually |
| `switch <name> <directory>` | Switch an agent's workspace (VM restarts, DB preserved) |
| `attach <name>` | Attach to agent's Claude Code TUI (multi-attach via `screen -x`) |
| `tail [<name>]` | Snapshot the agent's screen scrollback |
| `services <name> [options]` | Start FxA app services in an agent's VM |
| `browser <name>` | Launch Firefox configured to use an agent's VM |
| `test <name> [-- args]` | Run Playwright functional tests against an agent's VM |
| `ssh <name>` | Print SSH connection info for an agent's VM |
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
1. Written by the host to `<worktree>/.fxa-auto-token` (visible inside the VM at `/workspace/.fxa-auto-token` via virtiofs — bypasses the in-VM sudo channel which is unreliable after admin hardening)
2. Sourced into the Claude Code process environment at startup
3. Immediately deleted from disk
4. Available only in the Claude process memory thereafter

`.env` in the script directory is auto-loaded at every CLI invocation. Putting `CLAUDE_CODE_OAUTH_TOKEN=...` there is the recommended setup (the file is gitignored).

### Model Configuration

Set the default model in `~/.claude/settings.json`:

```json
{
  "model": "claude-opus-4-6"
}
```

This is automatically copied into each new VM agent.

## Browser Command

Launch a real Firefox browser on your Mac pre-configured to talk to the FxA services running inside an agent's VM:

```bash
# Start services first
fxa-sandbox-ctl services auth-fix

# Launch Firefox
fxa-sandbox-ctl browser auth-fix
```

This creates a dedicated Firefox profile at `logs/profiles/<agent-name>/` with a `user.js` containing all the `identity.fxaccounts.*` preferences pointing at the VM's IP. Firefox opens two tabs:
- **Tab 1:** `http://<VM_IP>:3030/` — FxA content server
- **Tab 2:** `http://<VM_IP>:3030/__inbox` — Inbox viewer for captured emails

The browser uses `oauth_webchannel_v1` context (the modern OAuth-based Sync flow). HSTS headers from the auth server are stripped by the proxy so plain HTTP works correctly.

Firefox is launched with `-profile` and `-no-remote` so it runs as a separate instance that won't interfere with your normal browser.

**Profile reuse:** If the profile directory already exists (e.g. after a VM restart), only `user.js` is rewritten with the new IP. Login state, cookies, and other browser data are preserved.

**Cleanup:** The profile directory is automatically deleted when you run `fxa-sandbox-ctl stop <name>`.

### Inbox Viewer

The inbox viewer at `/__inbox` shows emails captured by mail_helper. Enter an email address to watch for verification codes, password reset links, etc. Codes are displayed prominently with copy-to-clipboard buttons.

### Running Functional Tests from Host

The easiest way to run tests from your Mac is the `test` command:

```bash
# Run all functional tests
fxa-sandbox-ctl test auth-fix

# Run a specific test
fxa-sandbox-ctl test auth-fix -- tests/signin/signIn.spec.ts
```

Or manually with `FXA_SANDBOX_IP`:

```bash
cd packages/functional-tests
FXA_SANDBOX_IP=<VM_IP> yarn test-sandbox

# Run specific tests:
FXA_SANDBOX_IP=<VM_IP> npx playwright test --project=sandbox tests/signin/signIn.spec.ts
```

The sandbox Playwright project uses `oauth_webchannel_v1` context and includes HSTS-disabling Firefox prefs so tests work over plain HTTP.

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

**Switch fails midway:** The VM disk clone is preserved. Retry the switch or run `fxa-sandbox-ctl stop <name>` to clean up.

**Settings not applied:** If Claude shows Sonnet instead of Opus, check that `~/.claude/settings.json` has the `"model"` key and restart the agent.

**Bypass permissions dialog:** Pre-accepted automatically via `bypassPermissionsModeAccepted: true` in `~/.claude.json` + `skipDangerousModePermissionPrompt: true` in `~/.claude/settings.json` (set by `_setup_claude_config` at VM init). If it still appears, the python config-write step likely failed silently — check the orchestrator output for `WARN: Could not pre-trust workspace`.

**`Bun not found` errors after every tool call:** A plugin (e.g. `claude-mem`) ships a hook that shells out to `bun`. Install bun on whichever side is complaining (`brew install oven-sh/bun/bun` on host; rebuild the golden image to refresh the in-VM install — `04-claude.sh` puts bun at `/usr/local/bin/bun`).

**`fxa-sandbox-ctl stop fxa-auto` did nothing useful:** That's a workspace name, not an agent name. Agents are named after their Jira key (`fxa-13474`). Run `fxa-sandbox-ctl list` to see actual agent names.

**Worktree refuses with "uncommitted changes":** Filter is permissive about our orchestration files, `ai/`, `.claude/`, and the FxA test key. For your own scratch files, set `FXA_DIRTY_IGNORE='^\?\? mypath/'`.

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
│       ├── 09-fxa-services.sh   # FxA service scripts (fxa-start)
│       └── 10-agent-guide.sh    # Bake agent guide into image
├── templates/
│   ├── agent-startup.sh         # VM entrypoint template
│   └── inbox-viewer.html        # Email inbox viewer (served at /__inbox)
├── lib/
│   ├── config.sh                # Constants and defaults
│   ├── vm.sh                    # Tart VM lifecycle
│   ├── agent.sh                 # Agent run/attach/stop/list + security
│   ├── jira.sh                  # acli fetch + ADF→markdown rendering
│   ├── worktree.sh              # fxa-auto* pool, dirty-state filter, branch swap
│   ├── finish.sh                # Handoff wait, push, media gist upload, PR, CI watch
│   └── stream-prettify.js       # JSONL stream prettifier (legacy -p mode)
└── logs/                        # Runtime logs (gitignored)
    ├── <name>.meta              # Agent metadata (NAME, WORKSPACE, IP, ...)
    ├── ssh/<name>/              # Per-agent SSH keys
    └── profiles/<name>/         # Per-agent Firefox profiles
```
