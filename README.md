# FxA Agent Sandbox

Run multiple Claude Code agents in self-contained Linux VMs on macOS. Each agent gets its own MySQL, Redis, Firestore, and full Node.js toolchain. A host directory (git worktree) is mounted via VirtioFS. Interact with agents through `screen` sessions (multi-attach with `screen -x`).

Two main modes:
- **Manual** (`run`): start an agent on a worktree you choose, drive it yourself.
- **Autonomous Jira → PR** (`jira`): point at a ticket, get a pushed branch + pre-filled `gh pr create` command back. See [Autonomous Jira → PR Workflow](#autonomous-jira--pr-workflow).

On top of those, the pipeline commands drive a hands-off ticket-to-PR loop: a
labelled ticket becomes a review-ready pull request with no human in the loop.
[AI_FIXME_PIPELINE.md](AI_FIXME_PIPELINE.md) documents that layer.

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

Or put it in `.env`, which the CLI loads at startup. Copy `.env.example` to see
every variable the tool reads:

```bash
cp .env.example .env
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
cp .env.example .env && $EDITOR .env

# Dry-run first to inspect the prompt and worktree path
fxa-sandbox-ctl jira FXA-13474 --dry-run

# Actually run it
fxa-sandbox-ctl jira FXA-13474
```

What happens under the hood:

1. **Jira fetch** — `lib/jira.sh` calls `acli jira workitem view --json` and flattens the Atlassian Document Format description + comments to markdown. Result is written to `<worktree>/.fxa-jira-context.md`.
2. **Worktree** — a pool of `fxa-auto`, `fxa-auto-2`, ... worktrees. Picks the first one not in use by a running agent, else creates the next-numbered slot. Reusing a slot keeps `node_modules` warm across tickets.
3. **VM boot** — golden image cloned via APFS CoW, hardened (egress firewall, restricted sudo, ephemeral OAuth token written through the workspace mount).
4. **`/goal` autonomy** — Claude runs as `claude -p "<prompt>" --permission-mode bypassPermissions --output-format stream-json` inside a `screen` session; the prompt is an argument, so nothing is pasted and nothing can sit unsubmitted. The JSONL transcript lands in `/workspace/.fxa-auto-claude.jsonl`, which `tail` reads.
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
| `--private` | off | Provision from the checkout at `$FXA_PRIVATE_REPO` into its own pool. See [Private mode](#private-mode). |
| `--guardrails <file>` | — | Prepend a file to the agent's task context as mandatory reviewer guidance. The agent reads it first. |
| `--functional-tests` | off | Pre-warm the FxA stack in the VM and require `yarn test-sandbox` before the goal counts as met. Alias: `--with-stack`. |
| `--watch` | on | After agent starts, block until handoff lands, then push. |
| `--no-watch` | — | Fire-and-forget; resume later with `finish`. |
| `--create-pr` | off | Also run `gh pr create` after pushing. |
| `--no-ci-watch` | — | Skip CI polling (only relevant with `--create-pr`). |
| `--dry-run` | off | Print the prompt and worktree path; don't create anything. |
| `-n, --name <name>` | issue key | Agent name, lowercased issue key by default. |
| `-c, --cpu` / `-m, --memory` | 4 / 8192 | VM resources. |

### Private mode

`--private` runs a ticket against a second local checkout instead of the public
FxA repo. Point `FXA_PRIVATE_REPO` at that checkout in `.env`:

```bash
echo 'FXA_PRIVATE_REPO=/path/to/second/checkout' >> .env
fxa-sandbox-ctl jira FXA-13474 --private
```

Worktrees come from that checkout and use their own pool (`fxa-auto-private`,
`fxa-auto-private-2`, ...), so private runs never take a slot from the public
pool. `git push` and `gh pr create` both run inside the worktree, so they
resolve the target repo from that worktree's own `origin` remote. The tool is
never told which repo it is.

Dev secrets still come from the public FxA checkout through
`FXA_SECRETS_SOURCE`, because a second checkout has no populated secrets of its
own.

`FXA_PRIVATE_REPO` has no default. Without it, `--private` stops with an error
and changes nothing.

### GCE backend

`--backend gce` runs the agent in a Google Compute Engine VM instead of a Tart
VM. The laptop stays the controller: it holds the credentials, signs, pushes,
and opens the PR. Only the runner moves. Once per project:

```bash
echo 'FXA_GCE_PROJECT=<project-id>' >> .env
gcloud auth login && gcloud auth application-default login
FXA_GCE_PROJECT=<project-id> bash infra/gce/setup.sh   # VPC, subnet, NAT, IAP ssh rule
fxa-sandbox-ctl --backend gce image build              # ~30 min, bakes the FxA clone
fxa-sandbox-ctl --backend gce jira FXA-13474
```

The backend is a global flag like `--pipeline`, or `FXA_VM_BACKEND=gce` in
`.env`, or `PIPE_VM_BACKEND` in the pipeline config. Default is `tart`.

Runners have no service account and no external IP. The laptop reaches them
over ssh through an IAP tunnel, with its own passphrase-less key at
`~/.ssh/fxa-sandbox-gce`. There is no shared filesystem: the slot's per-run
files (ticket context, prompt, auth, `ai/`, dev secrets) go in as one tar at
launch, and every read of the slot pulls the runner's tree back first, so
`progress`, `snapshot`, and `finish` see what the agent wrote. `attach`, `tail`,
and `alive` work unchanged.

The default machine is `c4a-highcpu-4` (4 vCPU, 8 GB, arm64, about $0.13 an
hour while a run is up, nothing when idle). `n4a-highcpu-4` is cheaper but was
stocked out in every `us-central1` zone when this was built; set
`FXA_GCE_MACHINE_TYPE` to try it. A leaked instance keeps billing: `list` shows
it and `stop <name>` deletes it.

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

The CLI auto-loads `.env` from its script directory at startup. Shell-exported vars win over `.env`. Copy `.env.example` to get started:

```bash
cp .env.example .env
```

`.env` is gitignored. `.env.example` is not, so it carries variable names only, never values.

| Key | Purpose |
|-----|---------|
| `CLAUDE_CODE_OAUTH_TOKEN` | Generated via `claude setup-token`. Ephemerally injected into each VM. |
| `FXA_REPO` | Override the FxA monorepo path (default: `~/Desktop/working2/fxa`). |
| `FXA_PRIVATE_REPO` | Checkout that `jira --private` provisions from. No default; `--private` fails without it. |
| `FXA_SECRETS_SOURCE` | Checkout to copy dev secrets and the `ai/` mirror from (default: the worktree's own repo root). |
| `FXA_WORKTREE_BASE` | Default base branch (default: `main`). |
| `FXA_AGENT_MODEL` | Model alias for the agent's Claude (default: `opus`). |
| `FXA_SHARED_WORKTREE_NAME` | Pool base name (default: `fxa-auto`). |
| `FXA_DIRTY_IGNORE` | Extended-regex pattern of extra status lines to ignore. |
| `FXA_VM_BACKEND` | `tart` (default) or `gce`. `--backend` on the command line wins. |
| `FXA_GCE_PROJECT` | GCP project for `gce` runners. Required for that backend. |
| `FXA_GCE_ZONE` | Zone for runners and the image build (default: `us-central1-a`). |
| `FXA_GCE_MACHINE_TYPE` | Runner shape (default: `c4a-highcpu-4`). |

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
| `reap` | Remove leftover host state for agents whose VM is gone |
| `reap <ISSUE-KEY>` | Stop that ticket's agent VM (idempotent) |
| `reap --stray` | Stop every agent VM whose ticket is not inflight |

### Pipeline Commands

These drive an autonomous ticket-to-PR pipeline. Settings come from
`pipelines/<name>.conf`; pick one with the global flag `--pipeline <name>` before the
command. They are read-only unless marked WRITE. Nothing here merges or approves a PR.

See [AI_FIXME_PIPELINE.md](AI_FIXME_PIPELINE.md) for the lifecycle these commands drive.

| Command | Description |
|---------|-------------|
| `queue` | Keys in the queue, oldest first |
| `inflight` | Keys currently running |
| `done-keys` | Keys awaiting review |
| `drain` | Done keys whose PR merged, closed, or went red |
| `ticket <ISSUE-KEY>` | Ticket text **including comments** — ground with this |
| `reporter <ISSUE-KEY>` | Reporter's GitHub login, empty if unmapped |
| `label <ISSUE-KEY> <state>` | WRITE: move the ticket; also reaps its VM |
| `slots` | Pool slots, and any VM running on each |
| `freeslots` | Slots a ticket can claim — **use this, not `slots`** |
| `launch <KEY> <slot> [ctx]` | WRITE: start an agent VM in the background |
| `alive <ISSUE-KEY>` | Exit 0 if a live `claude` process runs in the VM |
| `progress <ISSUE-KEY>` | What the launcher did — **read this first** |
| `prstate <ISSUE-KEY>` | PR number, state, and check tally |
| `feedback <KEY> [sub]` | Unhandled review comments (`ack`, `rounds`, `acted`, `thumbsup`) |
| `tokens <ISSUE-KEY>` | Token and model usage — run **before** the VM stops |
| `record <ISSUE-KEY>` | Append the run to the telemetry log |
| `costs` | Rebuild the per-issue cost rollup |
| `skip <KEY> [reason]` | Record an admission skip; prints `comment` or `silent <n>` |
| `skipped [KEY]` | List recorded skips |
| `attempts <KEY> [bump]` | Read or increment the real-fix attempt counter |
| `lock` / `unlock` | One pass at a time |
| `snapshot` | The whole pipeline state as one JSON document |
| `dashboard [-p N] [-i N]` | Serve a live status page on localhost |

### Dashboard

```bash
fxa-sandbox-ctl dashboard              # http://localhost:8787
fxa-sandbox-ctl dashboard -p 9000      # different port
fxa-sandbox-ctl dashboard -i 120       # refresh every 120s instead of 60s
```

The page renders `snapshot` output: the queue, pool slots, inflight runs, PRs
awaiting review, and telemetry. A snapshot takes about 17 seconds, most of it
waiting on Jira and GitHub, so the server refreshes on a timer in the
background and serves the last good result. A failed refresh keeps the previous
snapshot rather than blanking the page.

`snapshot` is useful on its own at the terminal:

```bash
fxa-sandbox-ctl snapshot | jq '.free_slots'
```

Every field comes from the same functions a pass uses, so the page cannot
disagree with the pipeline.

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
├── .env.example                 # Variable names for .env (no values)
├── README.md                    # This file
├── VM_AGENT_GUIDE.md            # Full agent operations manual
├── AI_FIXME_PIPELINE.md         # The pipeline above this tool (source of truth)
├── AI_FIXME_PIPELINE.html       # Generated: build-pipeline-html.py
├── AI_FIXME_PIPELINE.canvas.md  # Generated: build-canvas-md.py
├── build-pipeline-html.py       # AI_FIXME_PIPELINE.md -> standalone HTML
├── build-canvas-md.py           # AI_FIXME_PIPELINE.md -> Slack Canvas markdown
├── render-diagrams.py           # Mermaid blocks -> diagrams/*.png
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
├── pipelines/
│   └── fxa-ai-fixme.conf        # Repo, label family, pool state, telemetry paths
├── dashboard/
│   ├── server.py                # Serves the snapshot as a live status page
│   └── index.html               # The page itself
├── diagrams/                    # Generated PNGs of the pipeline diagrams
├── skills/
│   └── fxa-ai-fixme/            # Pass logic; ~/.claude/skills/ symlinks here
│       ├── SKILL.md             # The decision rules
│       └── SCHEDULING.md        # The loop definitions
├── lib/
│   ├── config.sh                # Constants and defaults
│   ├── vm.sh                    # Tart VM lifecycle
│   ├── agent.sh                 # Agent run/attach/stop/list + security, alive check
│   ├── pipeline.sh              # Pipeline config, pass lock, skips, attempts, progress
│   ├── jira.sh                  # acli fetch + ADF→markdown, queue reads, label writes
│   ├── worktree.sh              # fxa-auto* pool, branch naming, slot claiming
│   ├── github.sh                # PR state, drain, review comments
│   ├── telemetry.sh             # Token usage, run log, cost rollup
│   ├── snapshot.sh              # Whole pipeline state as one JSON document
│   ├── finish.sh                # Handoff wait, push, media gist upload, PR, CI watch
│   └── stream-prettify.js       # JSONL stream prettifier (legacy -p mode)
└── logs/                        # Runtime logs (gitignored)
    ├── <name>.meta              # Agent metadata (NAME, WORKSPACE, IP, ...)
    ├── ssh/<name>/              # Per-agent SSH keys
    └── profiles/<name>/         # Per-agent Firefox profiles
```
