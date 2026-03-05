#!/bin/bash
# agent.sh — Agent lifecycle: run, attach, stop, list, logs

# Source dependencies
AGENT_LIB_DIR="$(dirname "${BASH_SOURCE[0]}")"
source "${AGENT_LIB_DIR}/config.sh"
source "${AGENT_LIB_DIR}/vm.sh"

# ── Helpers ────────────────────────────────────────────────────

_ensure_tmux_session() {
  if ! tmux has-session -t "${TMUX_SESSION}" 2>/dev/null; then
    tmux new-session -d -s "${TMUX_SESSION}" -n "_control" \
      "echo 'FxA Agent Sandbox — use fxa-sandbox-ctl to manage agents'; read"
  fi
}

_check_host_ram() {
  local free_mb
  local pages_free
  pages_free=$(vm_stat | awk '/Pages free/ {gsub(/\./,"",$3); print $3}')
  local pages_inactive
  pages_inactive=$(vm_stat | awk '/Pages inactive/ {gsub(/\./,"",$3); print $3}')
  local page_size=16384  # 16KB on Apple Silicon

  free_mb=$(( (pages_free + pages_inactive) * page_size / 1024 / 1024 ))

  if [ "$free_mb" -lt "$MIN_HOST_FREE_RAM_MB" ]; then
    echo "WARNING: Only ${free_mb}MB free RAM on host (minimum recommended: ${MIN_HOST_FREE_RAM_MB}MB)" >&2
    echo "Consider stopping some agents before starting new ones." >&2
    return 1
  fi
  return 0
}

_wait_for_infra() {
  local name="$1"
  local full_name
  full_name="$(vm_name "$name")"

  echo "Waiting for infrastructure services inside VM..."

  local attempts=0
  while [ $attempts -lt 30 ]; do
    if tart exec "${full_name}" bash -c "systemctl is-active agent-init 2>/dev/null | grep -q '^active$'" 2>/dev/null; then
      echo "  Infrastructure ready."
      return 0
    fi
    attempts=$((attempts + 1))
    sleep 2
  done

  echo "  WARN: agent-init may not have completed. Continuing anyway."
}

_generate_name() {
  local adjectives=("swift" "keen" "bold" "calm" "fair" "warm" "wise" "neat" "true" "pure")
  local nouns=("fox" "owl" "elk" "ram" "jay" "bee" "ant" "emu" "yak" "cod")
  local adj="${adjectives[$((RANDOM % ${#adjectives[@]}))]}"
  local noun="${nouns[$((RANDOM % ${#nouns[@]}))]}"
  echo "${adj}-${noun}"
}

# ── Security: Per-agent SSH keys ──────────────────────────────

_install_ssh_key() {
  local name="$1"
  local full_name
  full_name="$(vm_name "$name")"
  local key_dir="${LOG_DIR}/ssh/${name}"

  # Generate a unique SSH key pair per agent
  mkdir -p "${key_dir}"
  ssh-keygen -t ed25519 -f "${key_dir}/id_ed25519" -N "" -q

  local pubkey
  pubkey="$(cat "${key_dir}/id_ed25519.pub")"

  tart exec "${full_name}" sudo bash -c "
    mkdir -p /home/agent/.ssh
    echo '${pubkey}' >> /home/agent/.ssh/authorized_keys
    chown -R agent:agent /home/agent/.ssh
    chmod 700 /home/agent/.ssh
    chmod 600 /home/agent/.ssh/authorized_keys
  "
}

# ── Security: Disable SSH password auth ───────────────────────

_harden_ssh() {
  local full_name="$1"

  tart exec "${full_name}" sudo bash -c "
    # Disable password authentication — SSH key only
    sed -i 's/^PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
    sed -i 's/^#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
    # Ensure the setting exists
    grep -q '^PasswordAuthentication' /etc/ssh/sshd_config || echo 'PasswordAuthentication no' >> /etc/ssh/sshd_config
    # Lock the admin user password (base image default creds)
    passwd -l admin 2>/dev/null || true
    # Restart SSH to apply
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
  " 2>/dev/null || true
}

# ── Security: Restrict sudo ───────────────────────────────────

_restrict_sudo() {
  local full_name="$1"

  tart exec "${full_name}" sudo bash -c "
    # Replace blanket NOPASSWD:ALL with specific allowed commands
    cat > /etc/sudoers.d/agent <<'SUDOERS'
# Agent user: restricted sudo access
agent ALL=(ALL) NOPASSWD: /usr/bin/systemctl start *
agent ALL=(ALL) NOPASSWD: /usr/bin/systemctl stop *
agent ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart *
agent ALL=(ALL) NOPASSWD: /usr/bin/systemctl status *
agent ALL=(ALL) NOPASSWD: /usr/sbin/service *
agent ALL=(ALL) NOPASSWD: /usr/bin/apt-get *
agent ALL=(ALL) NOPASSWD: /usr/bin/apt *
agent ALL=(ALL) NOPASSWD: /usr/bin/dpkg *
agent ALL=(ALL) NOPASSWD: /usr/bin/mysql *
agent ALL=(ALL) NOPASSWD: /usr/bin/redis-cli *
agent ALL=(ALL) NOPASSWD: /usr/bin/tee /etc/hosts
agent ALL=(ALL) NOPASSWD: /usr/bin/chmod *
agent ALL=(ALL) NOPASSWD: /usr/bin/chown *
SUDOERS
    chmod 440 /etc/sudoers.d/agent
  " 2>/dev/null || true
}

# ── Security: Egress firewall ─────────────────────────────────

_setup_egress_firewall() {
  local full_name="$1"

  tart exec "${full_name}" sudo bash -c '
    # Allow loopback
    iptables -A OUTPUT -o lo -j ACCEPT

    # Allow established/related connections
    iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

    # Allow DNS to gateway (VM needs this for name resolution)
    GATEWAY=$(ip route | awk "/default/ {print \$3}")
    if [ -n "$GATEWAY" ]; then
      iptables -A OUTPUT -d "$GATEWAY" -p udp --dport 53 -j ACCEPT
      iptables -A OUTPUT -d "$GATEWAY" -p tcp --dport 53 -j ACCEPT
    fi

    # Block all traffic to private/link-local networks (prevents host probing)
    iptables -A OUTPUT -d 10.0.0.0/8 -j DROP
    iptables -A OUTPUT -d 172.16.0.0/12 -j DROP
    iptables -A OUTPUT -d 192.168.0.0/16 -j DROP
    iptables -A OUTPUT -d 169.254.0.0/16 -j DROP

    # Allow all other outbound (public internet)
    iptables -A OUTPUT -j ACCEPT
  ' 2>/dev/null || true
}

# ── Security: Disable proxy (for existing golden images) ──────

_disable_proxy_in_vm() {
  local full_name="$1"

  tart exec "${full_name}" bash -c "
    sudo systemctl stop squid 2>/dev/null || true
    sudo systemctl disable squid 2>/dev/null || true
    sudo sed -i '/HTTP_PROXY/d; /HTTPS_PROXY/d; /http_proxy/d; /https_proxy/d; /NO_PROXY/d; /no_proxy/d' /etc/agent-env.sh 2>/dev/null || true
    sudo sed -i '/HTTP_PROXY/d; /HTTPS_PROXY/d; /http_proxy/d; /https_proxy/d; /NO_PROXY/d; /no_proxy/d' /etc/environment 2>/dev/null || true
    sed -i '/^proxy=/d; /^https-proxy=/d' /home/agent/.npmrc 2>/dev/null || true
  " 2>/dev/null || true
}

# ── Security: Minimal Claude config (not full directory) ──────

_setup_claude_config() {
  local name="$1"
  local full_name
  full_name="$(vm_name "$name")"

  # Copy ONLY the specific config files the agent needs (not the entire ~/.claude)
  # This prevents exposure of: conversation history, project paths, session data,
  # shell snapshots, debug logs, etc.

  local claude_home="${CLAUDE_HOME_DIR}"

  # Remove dangling symlinks left by old golden images that mounted ~/.claude
  # (the mounts were removed for security, but agent-init still creates symlinks)
  tart exec "${full_name}" sudo bash -c "
    rm -f /home/agent/.claude/settings.json /home/agent/.claude/settings.local.json /home/agent/.claude/CLAUDE.md
    mkdir -p /home/agent/.claude /home/agent/.config/claude
    chown -R agent:agent /home/agent/.claude /home/agent/.config/claude
  " 2>/dev/null || true

  # settings.json — user preferences (base64 to avoid quoting issues)
  if [ -f "${claude_home}/settings.json" ]; then
    local settings_b64
    settings_b64="$(base64 < "${claude_home}/settings.json" | tr -d '\n')"
    tart exec "${full_name}" sudo bash -c "
      echo '${settings_b64}' | base64 -d > /home/agent/.claude/settings.json
      chown agent:agent /home/agent/.claude/settings.json
    " 2>/dev/null || echo "  WARN: Could not copy settings.json"
  fi

  # CLAUDE.md — custom instructions (base64 to avoid quoting issues)
  if [ -f "${claude_home}/CLAUDE.md" ]; then
    local claude_md_b64
    claude_md_b64="$(base64 < "${claude_home}/CLAUDE.md" | tr -d '\n')"
    tart exec "${full_name}" sudo bash -c "
      echo '${claude_md_b64}' | base64 -d > /home/agent/.claude/CLAUDE.md
      chown agent:agent /home/agent/.claude/CLAUDE.md
    " 2>/dev/null || echo "  WARN: Could not copy CLAUDE.md"
  fi

  # commands/ — custom slash commands (if any)
  if [ -d "${claude_home}/commands" ]; then
    local commands_tar_b64
    commands_tar_b64="$(tar -cf - -C "${claude_home}" commands | base64 | tr -d '\n')"
    tart exec "${full_name}" sudo bash -c "
      echo '${commands_tar_b64}' | base64 -d | tar -xf - -C /home/agent/.claude/
      chown -R agent:agent /home/agent/.claude/commands
    " 2>/dev/null || echo "  WARN: Could not copy commands/"
  fi

  # plugins/ — installed plugins (cache + registry, skip large marketplace data)
  if [ -d "${claude_home}/plugins/cache" ]; then
    local plugins_tar_b64
    plugins_tar_b64="$(tar -cf - -C "${claude_home}" \
      plugins/cache \
      plugins/installed_plugins.json \
      plugins/config.json \
      2>/dev/null | base64 | tr -d '\n')"
    tart exec "${full_name}" sudo bash -c "
      mkdir -p /home/agent/.claude/plugins
      echo '${plugins_tar_b64}' | base64 -d | tar -xf - -C /home/agent/.claude/
      chown -R agent:agent /home/agent/.claude/plugins
    " 2>/dev/null || echo "  WARN: Could not copy plugins/"
  fi

  # Append VM-specific context to CLAUDE.md (or create it if no host CLAUDE.md)
  local vm_section
  vm_section="$(cat <<'VMSECTION'

# Sandbox VM Environment

You are running inside a sandbox VM (Ubuntu 24.04 ARM64, Tart).

## Key Facts
- **Workspace:** `/workspace` (host repo mounted read-write)
- **All services on localhost** — auth :9000, content :3030, settings :3000, profile :1111
- **Infrastructure auto-started at boot:** MySQL :3306, Redis :6379, Firestore :9090
- **FxA services require manual start:** run `fxa-start`

## Starting Services

Run `fxa-start` to start all FxA application services. This script:
1. Installs Linux-arm64 native modules (esbuild, sass-embedded, swc) — the workspace `node_modules` are from macOS
2. Runs database migrations (`db-migrations/bin/patcher.mjs`)
3. Starts the Cloud Tasks emulator and goaws SNS stub (if needed)
4. Starts all application services via PM2 (auth, content, settings, profile, 123done, mail_helper)
5. Starts nginx reverse proxy on :3030

```bash
fxa-start              # Start all FxA services (~30s)
fxa-start --status     # Show PM2 process list
fxa-start --stop       # Stop all services + nginx
```

## Verifying Services

After `fxa-start`, verify services are healthy before running tests:

```bash
curl -sf http://localhost:9000/__heartbeat__   # Auth server (:9000)
curl -sf http://localhost:3030/                # Content server via nginx (:3030)
curl -sf http://localhost:3000/                # Settings React dev server (:3000)
curl -sf http://localhost:1111/__heartbeat__   # Profile server (:1111)
curl -sf http://localhost:8080/                # 123done test RP (:8080)
curl -sf http://localhost:9001/mail            # mail_helper (:9001)
pm2 describe cloud-tasks-emulator             # Cloud Tasks emulator (:8123)
```

## Running Functional Tests

Functional tests use Playwright with the `sandbox` project configuration.

```bash
# Run all functional tests
cd /workspace
yarn test-sandbox

# Run a specific test file
npx playwright test --project=sandbox tests/signin/signIn.spec.ts

# Run tests matching a grep pattern
npx playwright test --project=sandbox -g "sign in"

# Run with headed browser (visible)
npx playwright test --project=sandbox --headed tests/signin/signIn.spec.ts
```

**WARNING:** Do NOT set `FXA_SANDBOX_IP` inside the VM. That variable is only for the host Mac. Inside the VM, tests use `localhost` automatically.

## Running Unit Tests

```bash
npx nx test-unit fxa-auth-server
npx nx test-unit fxa-settings
npx nx test-unit <package-name>
```

## Inbox Viewer
- **URL:** `http://localhost:3030/__inbox` — web UI for viewing captured emails
- Enter an email address to see verification codes, reset links, etc.
- Codes displayed prominently with copy-to-clipboard
- Polls mail_helper every 3 seconds via `/__mail/` nginx proxy

## Context
- Browser context: `oauth_webchannel_v1` (modern OAuth-based Sync flow)
- HSTS stripped by nginx proxy (auth server sends strict-transport-security over HTTP)

## Full Guide
Read `/etc/vm-agent-guide.md` for the complete operations manual (port map, architecture, gotchas).
Fallback quick-reference: `/etc/vm-agent-context.md`
VMSECTION
)"
  local vm_section_b64
  vm_section_b64="$(printf '%s' "$vm_section" | base64 | tr -d '\n')"
  tart exec "${full_name}" sudo bash -c "
    echo '${vm_section_b64}' | base64 -d >> /home/agent/.claude/CLAUDE.md
    chown agent:agent /home/agent/.claude/CLAUDE.md
  " 2>/dev/null || echo "  WARN: Could not append VM context to CLAUDE.md"

  # Pre-trust the workspace paths so Claude Code skips the trust dialog.
  # The trust dialog can't be dismissed via screen stuffing (TUI raw input),
  # so we pre-configure it in .claude.json.
  tart exec "${full_name}" sudo -u agent bash -c '
    export HOME=/home/agent
    python3 -c "
import json, os
path = os.path.expanduser(\"~/.claude.json\")
try:
    with open(path) as f:
        data = json.load(f)
except:
    data = {}
if \"projects\" not in data:
    data[\"projects\"] = {}
trust = {\"hasTrustDialogAccepted\": True, \"allowedTools\": []}
data[\"projects\"][\"/workspace\"] = trust
data[\"projects\"][\"/mnt/shared/workspace\"] = trust
data[\"hasCompletedOnboarding\"] = True
with open(path, \"w\") as f:
    json.dump(data, f)
"
  ' 2>/dev/null || echo "  WARN: Could not pre-trust workspace"
}

# ── Security: Ephemeral token injection ───────────────────────

_inject_oauth_token() {
  local full_name="$1"
  local token="$2"

  # Write token to a temporary file that is deleted immediately after
  # Claude Code reads it. The token never persists on disk.
  # Note: The token still exists in the Claude process environment (/proc/<pid>/environ),
  # which is readable by the process owner. With restricted sudo, the agent user
  # cannot read other users' /proc entries.

  tart exec "${full_name}" sudo bash -c "
    echo 'export CLAUDE_CODE_OAUTH_TOKEN=${token}' > /tmp/.claude-token
    chmod 600 /tmp/.claude-token
    chown agent:agent /tmp/.claude-token
  "

  echo "  Token staged for ephemeral injection (${#token} chars)."
}

# ── Agent commands ─────────────────────────────────────────────

agent_run() {
  local workspace_dir="$1"
  local name="${2:-}"
  local prompt="${3:-}"
  local cpu="${4:-$DEFAULT_VM_CPU}"
  local memory="${5:-$DEFAULT_VM_MEMORY_MB}"

  # Resolve workspace to absolute path
  workspace_dir="$(cd "$workspace_dir" 2>/dev/null && pwd)" || {
    echo "ERROR: Directory does not exist: ${workspace_dir}" >&2
    return 1
  }

  # Generate name if not provided
  if [ -z "$name" ]; then
    name="$(_generate_name)"
    echo "Auto-generated agent name: ${name}"
  fi

  # Validate name (alphanumeric and hyphens only)
  if ! [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "ERROR: Invalid name '${name}'. Use only letters, numbers, hyphens, underscores." >&2
    return 1
  fi

  # Check if agent already exists
  if vm_exists "$name"; then
    echo "ERROR: Agent '${name}' already exists. Stop it first or choose a different name." >&2
    return 1
  fi

  # Check host RAM
  _check_host_ram || true

  local full_name
  full_name="$(vm_name "$name")"

  echo ""
  echo "=== Starting agent '${name}' ==="
  echo "  Workspace: ${workspace_dir}"
  echo "  Resources: ${cpu} vCPU, $((memory / 1024))GB RAM"
  echo ""

  # Step 1: Clone the golden image
  vm_clone "$name" || return 1

  # Step 2: Configure VM resources
  vm_configure "$name" "$cpu" "$memory"

  # Detect git worktree and resolve parent .git directory for mounting
  local gitdir=""
  if [ -f "${workspace_dir}/.git" ]; then
    local gitdir_path
    gitdir_path="$(sed 's/^gitdir: //' "${workspace_dir}/.git")"
    if [ -d "$gitdir_path" ]; then
      # Parent .git is two levels up from the worktree entry
      # e.g. /path/fxa/.git/worktrees/name -> /path/fxa/.git
      gitdir="$(cd "$gitdir_path/../.." && pwd)"
    fi
  fi

  # Step 3: Start the VM (workspace + optional parent .git for worktrees)
  vm_start "$name" "$workspace_dir" "$gitdir" || {
    vm_delete "$name"
    return 1
  }

  # Step 4: Wait for VM to be ready
  vm_wait_ready "$name" || {
    echo "ERROR: VM failed to boot. Check logs: ${LOG_DIR}/${name}-vm.log" >&2
    vm_stop "$name"
    vm_delete "$name"
    return 1
  }

  # Step 5: Wait for agent-init to complete (starts infra services)
  _wait_for_infra "$name"

  # Step 6: Security hardening
  echo "Applying security hardening..."

  # 6a: Disable proxy (for existing golden images with Squid baked in)
  _disable_proxy_in_vm "$full_name"

  # 6b: Set up egress firewall (blocks host/private network access)
  _setup_egress_firewall "$full_name"

  # 6c: Disable SSH password auth (key-only access)
  _harden_ssh "$full_name"

  # 6d: Restrict sudo to specific commands
  _restrict_sudo "$full_name"

  # Step 7: Install per-agent SSH key
  echo "Setting up SSH key..."
  _install_ssh_key "$name"

  # Step 8: Fix git worktrees (worktree .git files reference host paths)
  if [ -n "$gitdir" ]; then
    echo "Linking git worktree parent (.git: ${gitdir})..."
    # Symlink /mnt/shared/gitdir to the host absolute path so the
    # worktree .git pointer resolves inside the VM
    tart exec "${full_name}" sudo bash -c "
      mkdir -p '$(dirname "$gitdir")'
      ln -sfn /mnt/shared/gitdir '${gitdir}'
    " 2>/dev/null || echo "  WARN: Git worktree symlink failed"
  fi

  # Step 9: Copy minimal Claude config (only settings.json + CLAUDE.md)
  echo "Setting up Claude config..."
  _setup_claude_config "$name"

  # Step 9: Inject OAuth token (ephemeral — deleted after Claude reads it)
  local oauth_token="${CLAUDE_CODE_OAUTH_TOKEN:-}"
  if [ -n "$oauth_token" ]; then
    echo "Injecting Claude OAuth token..."
    _inject_oauth_token "$full_name" "$oauth_token"
  else
    echo "NOTE: Set CLAUDE_CODE_OAUTH_TOKEN on the host to auto-authenticate agents."
    echo "      Generate one with: claude setup-token"
  fi

  # Step 10: Start Claude Code inside a screen session in the VM
  echo "Starting Claude Code in VM..."

  # The startup command sources the ephemeral token, deletes the file, then runs Claude
  local claude_cmd="test -f /tmp/.claude-token && source /tmp/.claude-token && rm -f /tmp/.claude-token; source /etc/agent-env.sh; cd /workspace; claude --dangerously-skip-permissions"
  if [ -n "$prompt" ]; then
    local escaped_prompt
    escaped_prompt="$(printf '%q' "$prompt")"
    claude_cmd="test -f /tmp/.claude-token && source /tmp/.claude-token && rm -f /tmp/.claude-token; source /etc/agent-env.sh; cd /workspace; claude --dangerously-skip-permissions -p ${escaped_prompt}"
  fi

  tart exec "${full_name}" sudo -u agent bash -c "
    export HOME=/home/agent
    screen -dmS ${VM_SCREEN_SESSION} bash -c '${claude_cmd}; exec bash'
  "

  # Step 11: Create tmux window on host
  _ensure_tmux_session

  local ip
  ip="$(vm_ip "$name")"

  local ssh_key="${LOG_DIR}/ssh/${name}/id_ed25519"
  local ssh_cmd="ssh -t -i ${ssh_key} ${VM_SSH_OPTS} ${VM_SSH_USER}@${ip} 'screen -r ${VM_SCREEN_SESSION}'"

  tmux new-window -t "${TMUX_SESSION}" -n "$name" "${ssh_cmd}"

  # Save agent metadata
  cat > "${LOG_DIR}/${name}.meta" <<META
NAME=${name}
WORKSPACE=${workspace_dir}
CPU=${cpu}
MEMORY=${memory}
IP=${ip}
STARTED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
META

  echo ""
  echo "=== Agent '${name}' is running ==="
  echo "  Attach:  fxa-sandbox-ctl attach ${name}"
  echo "  Logs:    fxa-sandbox-ctl logs ${name}"
  echo "  Stop:    fxa-sandbox-ctl stop ${name}"
  echo ""
  echo "  Or switch tmux windows: Ctrl-b then select '${name}'"
}

agent_switch() {
  local name="$1"
  local new_workspace="$2"

  # Validate agent is running and metadata exists
  local meta_file="${LOG_DIR}/${name}.meta"
  if [ ! -f "$meta_file" ]; then
    echo "ERROR: No metadata for agent '${name}'. Is it running?" >&2
    return 1
  fi

  if ! vm_is_running "$name"; then
    echo "ERROR: Agent '${name}' is not running." >&2
    return 1
  fi

  # Resolve new workspace to absolute path (validate before stopping VM)
  new_workspace="$(cd "$new_workspace" 2>/dev/null && pwd)" || {
    echo "ERROR: Directory does not exist: ${new_workspace}" >&2
    return 1
  }

  # Load current metadata
  local NAME WORKSPACE CPU MEMORY IP STARTED
  source "$meta_file"

  # No-op if same directory
  if [ "$new_workspace" = "$WORKSPACE" ]; then
    echo "Agent '${name}' is already using workspace: ${WORKSPACE}"
    return 0
  fi

  local full_name
  full_name="$(vm_name "$name")"

  echo ""
  echo "=== Switching agent '${name}' ==="
  echo "  Old workspace: ${WORKSPACE}"
  echo "  New workspace: ${new_workspace}"
  echo ""

  # Step 1: Stop the VM (preserves disk clone)
  echo "Stopping VM (disk clone preserved)..."
  vm_stop "$name"

  # Step 2: Detect git worktree for new directory
  local gitdir=""
  if [ -f "${new_workspace}/.git" ]; then
    local gitdir_path
    gitdir_path="$(sed 's/^gitdir: //' "${new_workspace}/.git")"
    if [ -d "$gitdir_path" ]; then
      gitdir="$(cd "$gitdir_path/../.." && pwd)"
    fi
  fi

  # Step 3: Restart VM with new workspace mount
  echo "Restarting VM with new workspace..."
  vm_start "$name" "$new_workspace" "$gitdir" || {
    echo "ERROR: VM restart failed. Clone preserved — retry with 'switch' or clean up with 'stop'." >&2
    return 1
  }

  # Step 4: Wait for VM to be ready
  vm_wait_ready "$name" || {
    echo "ERROR: VM failed to boot after restart. Check logs: ${LOG_DIR}/${name}-vm.log" >&2
    return 1
  }

  # Step 5: Wait for infrastructure services
  _wait_for_infra "$name"

  # Step 6: Re-apply in-memory security (lost on restart)
  echo "Re-applying security hardening..."
  _disable_proxy_in_vm "$full_name"
  _setup_egress_firewall "$full_name"

  # Step 7: Fix git worktree symlinks if needed
  if [ -n "$gitdir" ]; then
    echo "Linking git worktree parent (.git: ${gitdir})..."
    tart exec "${full_name}" sudo bash -c "
      mkdir -p '$(dirname "$gitdir")'
      ln -sfn /mnt/shared/gitdir '${gitdir}'
    " 2>/dev/null || echo "  WARN: Git worktree symlink failed"
  fi

  # Step 8: Re-inject OAuth token
  local oauth_token="${CLAUDE_CODE_OAUTH_TOKEN:-}"
  if [ -n "$oauth_token" ]; then
    echo "Re-injecting Claude OAuth token..."
    _inject_oauth_token "$full_name" "$oauth_token"
  fi

  # Step 9: Start new Claude Code screen session
  echo "Starting Claude Code in VM..."
  local claude_cmd="test -f /tmp/.claude-token && source /tmp/.claude-token && rm -f /tmp/.claude-token; source /etc/agent-env.sh; cd /workspace; claude --dangerously-skip-permissions"
  tart exec "${full_name}" sudo -u agent bash -c "
    export HOME=/home/agent
    screen -dmS ${VM_SCREEN_SESSION} bash -c '${claude_cmd}; exec bash'
  "

  # Step 10: Kill old tmux window, create new one with fresh SSH
  tmux kill-window -t "${TMUX_SESSION}:${name}" 2>/dev/null || true

  local ip
  ip="$(vm_ip "$name")"

  local ssh_key="${LOG_DIR}/ssh/${name}/id_ed25519"
  local ssh_cmd="ssh -t -i ${ssh_key} ${VM_SSH_OPTS} ${VM_SSH_USER}@${ip} 'screen -r ${VM_SCREEN_SESSION}'"

  _ensure_tmux_session
  tmux new-window -t "${TMUX_SESSION}" -n "$name" "${ssh_cmd}"

  # Step 11: Update metadata with new workspace and IP
  cat > "${LOG_DIR}/${name}.meta" <<META
NAME=${name}
WORKSPACE=${new_workspace}
CPU=${CPU}
MEMORY=${MEMORY}
IP=${ip}
STARTED=${STARTED}
META

  echo ""
  echo "=== Agent '${name}' switched ==="
  echo "  Workspace: ${new_workspace}"
  echo "  Attach:    fxa-sandbox-ctl attach ${name}"
  echo ""
  echo "  NOTE: If FxA services were running, re-run: fxa-sandbox-ctl services ${name}"
}

agent_attach() {
  local name="$1"

  if ! vm_is_running "$name"; then
    echo "ERROR: Agent '${name}' is not running." >&2
    return 1
  fi

  _ensure_tmux_session

  # If the tmux window exists, select it and attach
  if tmux list-windows -t "${TMUX_SESSION}" 2>/dev/null | grep -q "${name}"; then
    tmux select-window -t "${TMUX_SESSION}:${name}"
  else
    # Recreate the tmux window (may have been closed)
    local ip
    ip="$(vm_ip "$name")"
    local ssh_key="${LOG_DIR}/ssh/${name}/id_ed25519"
    local ssh_cmd="ssh -t -i ${ssh_key} ${VM_SSH_OPTS} ${VM_SSH_USER}@${ip} 'screen -r ${VM_SCREEN_SESSION} || screen -S ${VM_SCREEN_SESSION}'"
    tmux new-window -t "${TMUX_SESSION}" -n "$name" "${ssh_cmd}"
  fi

  # Attach to the tmux session
  if [ -n "${TMUX:-}" ]; then
    tmux switch-client -t "${TMUX_SESSION}:${name}"
  else
    tmux attach -t "${TMUX_SESSION}:${name}"
  fi
}

agent_list() {
  printf "%-4s %-20s %-40s %-10s %-8s\n" "ID" "NAME" "DIRECTORY" "STATUS" "RAM"
  printf "%-4s %-20s %-40s %-10s %-8s\n" "──" "────" "─────────" "──────" "───"

  local id=1
  for meta_file in "${LOG_DIR}"/*.meta; do
    [ -f "$meta_file" ] || continue

    local name workspace cpu memory ip started status ram_display
    source "$meta_file"

    if vm_is_running "$NAME" 2>/dev/null; then
      status="running"
    else
      status="stopped"
    fi

    ram_display="$((MEMORY / 1024)).$(( (MEMORY % 1024) * 10 / 1024 ))G"
    local short_dir="${WORKSPACE/#$HOME/~}"

    printf "%-4s %-20s %-40s %-10s %-8s\n" "$id" "$NAME" "$short_dir" "$status" "$ram_display"
    id=$((id + 1))
  done

  if [ "$id" -eq 1 ]; then
    echo "  No agents found."
  fi
}

agent_logs() {
  local name="$1"
  local follow="${2:-false}"
  local full_name
  full_name="$(vm_name "$name")"

  if ! vm_is_running "$name"; then
    if [ -f "${LOG_DIR}/${name}-vm.log" ]; then
      echo "=== VM log for '${name}' ==="
      cat "${LOG_DIR}/${name}-vm.log"
    else
      echo "ERROR: Agent '${name}' is not running and no logs found." >&2
    fi
    return 1
  fi

  if [ "$follow" = "true" ]; then
    echo "=== Following logs for agent '${name}' (Ctrl-C to stop) ==="
    tart exec "${full_name}" journalctl -f --no-pager 2>/dev/null || \
      echo "Could not stream logs. Try: fxa-sandbox-ctl attach ${name}"
  else
    echo "=== Logs for agent '${name}' ==="
    tart exec "${full_name}" journalctl --no-pager -n 100 2>/dev/null || \
      echo "Could not read logs. Try: fxa-sandbox-ctl attach ${name}"
  fi
}

agent_stop() {
  local name="$1"
  local full_name
  full_name="$(vm_name "$name")"

  echo "Stopping agent '${name}'..."

  # Gracefully stop Claude Code via screen
  tart exec "${full_name}" sudo -u agent screen -S "${VM_SCREEN_SESSION}" -X quit 2>/dev/null || true
  sleep 2

  # Stop the VM
  vm_stop "$name"

  # Delete the VM clone
  vm_delete "$name"

  # Remove tmux window
  tmux kill-window -t "${TMUX_SESSION}:${name}" 2>/dev/null || true

  # Clean up per-agent SSH keys
  rm -rf "${LOG_DIR}/ssh/${name}"

  # Clean up Firefox profile
  rm -rf "${LOG_DIR}/profiles/${name}"

  # Clean up metadata
  rm -f "${LOG_DIR}/${name}.meta"

  echo "Agent '${name}' stopped and cleaned up."
}

agent_browser() {
  local name="$1"

  if ! vm_is_running "$name"; then
    echo "ERROR: Agent '${name}' is not running." >&2
    return 1
  fi

  local ip
  ip="$(vm_ip "$name")"

  local profile_dir="${LOG_DIR}/profiles/${name}"
  mkdir -p "${profile_dir}"

  # Write user.js with FxA prefs pointing at the VM
  cat > "${profile_dir}/user.js" <<USERJS
// FxA sandbox prefs — auto-generated by fxa-sandbox-ctl
user_pref("identity.fxaccounts.auth.uri", "http://${ip}:9000/v1");
user_pref("identity.fxaccounts.allowHttp", true);
user_pref("identity.fxaccounts.remote.root", "http://${ip}:3030/");
user_pref("identity.fxaccounts.remote.force_auth.uri", "http://${ip}:3030/force_auth?service=sync&context=oauth_webchannel_v1");
user_pref("identity.fxaccounts.remote.signin.uri", "http://${ip}:3030/signin?service=sync&context=oauth_webchannel_v1");
user_pref("identity.fxaccounts.remote.signup.uri", "http://${ip}:3030/signup?service=sync&context=oauth_webchannel_v1");
user_pref("identity.fxaccounts.remote.webchannel.uri", "http://${ip}:3030/");
user_pref("identity.fxaccounts.remote.oauth.uri", "http://${ip}:9000/v1");
user_pref("identity.fxaccounts.remote.profile.uri", "http://${ip}:1111/v1");
user_pref("identity.fxaccounts.settings.uri", "http://${ip}:3030/settings?service=sync&context=oauth_webchannel_v1");
user_pref("identity.sync.tokenserver.uri", "http://${ip}:8000/token/1.0/sync/1.5");
user_pref("services.sync.tokenServerURI", "http://${ip}:8000/token/1.0/sync/1.5");
user_pref("identity.fxaccounts.contextParam", "oauth_webchannel_v1");
user_pref("identity.fxaccounts.lastSignedInUserHash", "");
user_pref("identity.fxaccounts.oauth.enabled", true);
user_pref("browser.newtabpage.activity-stream.fxaccounts.endpoint", "http://${ip}:3030/");
user_pref("webchannel.allowObject.urlWhitelist", "http://${ip}:3030");
user_pref("dom.securecontext.allowlist", "${ip},localhost");
user_pref("browser.tabs.remote.separatePrivilegedMozillaWebContentProcess", true);
user_pref("browser.tabs.remote.separatePrivilegedContentProcess", true);

// Disable HTTPS upgrades — sandbox VM serves plain HTTP
user_pref("dom.security.https_only_mode", false);
user_pref("dom.security.https_only_mode_ever_enabled", false);
user_pref("dom.security.https_only_mode_pbm", false);
user_pref("dom.security.https_first", false);
user_pref("dom.security.https_first_pbm", false);

// Disable HSTS — content server sends strict-transport-security over plain HTTP
user_pref("network.stricttransportsecurity.preloadlist", false);
user_pref("network.stricttransportsecurity.enabled", false);
user_pref("security.cert_pinning.enforcement_level", 0);
user_pref("security.mixed_content.upgrade_display_content", false);
USERJS

  # Clear HSTS cache — content server sends strict-transport-security over plain HTTP
  rm -f "${profile_dir}/SiteSecurityServiceState.bin"

  # Strip HSTS header from the reverse proxy so Firefox never caches it.
  # Works with both the Node.js proxy (fxa-proxy.js) and nginx (fxa-proxy.conf).
  local ssh_key="${LOG_DIR}/ssh/${name}/id_ed25519"
  ssh -i "${ssh_key}" ${VM_SSH_OPTS} "${VM_SSH_USER}@${ip}" bash -c "'
    if [ -f /tmp/fxa-proxy.js ] && ! grep -q \"strict-transport-security\" /tmp/fxa-proxy.js; then
      sed -i \"s/res.writeHead(proxyRes.statusCode, proxyRes.headers);/const h = Object.assign({}, proxyRes.headers); delete h[\\\"strict-transport-security\\\"]; res.writeHead(proxyRes.statusCode, h);/\" /tmp/fxa-proxy.js
      pm2 restart fxa-proxy --silent 2>/dev/null || true
    fi
  '" 2>/dev/null && echo "  Proxy patched: HSTS header stripped." || true

  # ── Inbox viewer setup ──────────────────────────────────────
  # SCP the self-contained inbox viewer HTML to the VM
  local inbox_html="${SANDBOX_ROOT}/templates/inbox-viewer.html"
  local inbox_url=""
  if [ -f "${inbox_html}" ]; then
    echo "  Uploading inbox viewer..."
    scp -i "${ssh_key}" ${VM_SSH_OPTS} \
      "${inbox_html}" \
      "${VM_SSH_USER}@${ip}:/tmp/inbox-viewer.html" 2>/dev/null \
      && echo "  Inbox viewer uploaded." || echo "  WARN: Failed to upload inbox viewer."

    # Patch the running proxy to serve /__inbox and /__mail/
    if ssh -i "${ssh_key}" ${VM_SSH_OPTS} "${VM_SSH_USER}@${ip}" \
      'test -f /tmp/fxa-proxy.conf' 2>/dev/null; then
      # nginx proxy — inject routes if not already present
      ssh -i "${ssh_key}" ${VM_SSH_OPTS} "${VM_SSH_USER}@${ip}" bash -c "'
        if ! grep -q __inbox /tmp/fxa-proxy.conf; then
          sed -i \"/# Everything else -> content server/i\\
        # Inbox viewer\\n\
        location = /__inbox {\\n\
            alias /tmp/inbox-viewer.html;\\n\
            default_type text\\/html;\\n\
        }\\n\\n\
        # Mail API proxy\\n\
        location /__mail\\/ {\\n\
            rewrite ^\\/__mail\\/(.*)$ \\/mail\\/\\\$1 break;\\n\
            proxy_pass http:\\/\\/127.0.0.1:9001;\\n\
            proxy_http_version 1.1;\\n\
            proxy_set_header Host \\\$http_host;\\n\
            proxy_set_header Accept-Encoding \\\"\\\";\\n\
            proxy_read_timeout 5s;\\n\
        }\\n\" /tmp/fxa-proxy.conf
          nginx -c /tmp/fxa-proxy.conf -s reload 2>/dev/null && echo \"nginx reloaded with inbox routes\" || echo \"WARN: nginx reload failed\"
        else
          echo \"Inbox routes already present.\"
        fi
      '" 2>/dev/null && inbox_url="http://${ip}:3030/__inbox"
    elif ssh -i "${ssh_key}" ${VM_SSH_OPTS} "${VM_SSH_USER}@${ip}" \
      'test -f /tmp/fxa-proxy.js' 2>/dev/null; then
      # Node.js proxy (legacy) — start a standalone server on :9002
      ssh -i "${ssh_key}" ${VM_SSH_OPTS} "${VM_SSH_USER}@${ip}" bash -c "'
        if ! pm2 describe inbox-proxy >/dev/null 2>&1; then
          cat > /tmp/inbox-proxy.js <<\"INBOXPROXY\"
const http = require(\"http\");
const fs = require(\"fs\");
const server = http.createServer((req, res) => {
  if (req.url === \"/__inbox\" || req.url === \"/__inbox/\") {
    try {
      const html = fs.readFileSync(\"/tmp/inbox-viewer.html\", \"utf8\");
      res.writeHead(200, {\"Content-Type\": \"text/html\"});
      res.end(html);
    } catch (e) {
      res.writeHead(404);
      res.end(\"inbox-viewer.html not found\");
    }
    return;
  }
  const m = req.url.match(/^\\/__mail\\/(.+)/);
  if (m) {
    const opts = {hostname: \"127.0.0.1\", port: 9001, path: \"/mail/\" + m[1], method: req.method, timeout: 5000};
    const proxy = http.request(opts, (pRes) => {
      res.writeHead(pRes.statusCode, pRes.headers);
      pRes.pipe(res);
    });
    proxy.on(\"error\", () => { if (!res.headersSent) { res.writeHead(502); } res.end(); });
    proxy.on(\"timeout\", () => { proxy.destroy(); if (!res.headersSent) { res.writeHead(504); res.end(\"timeout\"); } });
    req.pipe(proxy);
    return;
  }
  res.writeHead(404);
  res.end(\"not found\");
});
server.listen(9002, \"0.0.0.0\", () => console.log(\"[inbox-proxy] :9002\"));
INBOXPROXY
          pm2 start /tmp/inbox-proxy.js --name inbox-proxy 2>&1 | tail -1
        fi
      '" 2>/dev/null && inbox_url="http://${ip}:9002/__inbox"
    fi
  else
    echo "  WARN: templates/inbox-viewer.html not found, skipping inbox."
  fi

  echo "Firefox profile: ${profile_dir}"
  echo "Launching Firefox pointing at http://${ip}:3030/ ..."

  if [ -n "${inbox_url}" ]; then
    echo "  Inbox viewer: ${inbox_url}"
    /Applications/Firefox.app/Contents/MacOS/firefox \
      -profile "${profile_dir}" -no-remote \
      "http://${ip}:3030" "${inbox_url}" &
  else
    /Applications/Firefox.app/Contents/MacOS/firefox \
      -profile "${profile_dir}" -no-remote \
      "http://${ip}:3030" &
  fi
  disown

  echo "Firefox launched (PID $!)."
}

agent_stop_all() {
  echo "Stopping all agents..."

  local found=false
  for meta_file in "${LOG_DIR}"/*.meta; do
    [ -f "$meta_file" ] || continue
    found=true

    local NAME
    source "$meta_file"
    agent_stop "$NAME"
  done

  if [ "$found" = false ]; then
    echo "No agents to stop."
  fi

  # Kill the tmux session
  tmux kill-session -t "${TMUX_SESSION}" 2>/dev/null || true

  # Clean up all SSH keys
  rm -rf "${LOG_DIR}/ssh"

  echo "All agents stopped."
}
