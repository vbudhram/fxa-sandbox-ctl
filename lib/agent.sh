#!/bin/bash
# agent.sh — Agent lifecycle: run, attach, stop, list, logs

# Source dependencies
AGENT_LIB_DIR="$(dirname "${BASH_SOURCE[0]}")"
source "${AGENT_LIB_DIR}/config.sh"
source "${AGENT_LIB_DIR}/vm.sh"

# ── Runtime selection ──────────────────────────────────────────
# Which agent runs in the VM. Resolved once, late, because --runtime is parsed
# after this file is sourced. Precedence: FXA_AGENT_RUNTIME (env or --runtime)
# > PIPE_AGENT_RUNTIME (pipeline conf) > claude. Everything runtime-specific
# lives in lib/runtime-<name>.sh behind the contract documented there.
runtime_load() {
  [ -n "${_FXA_RUNTIME_LOADED:-}" ] && return 0
  local rt="${FXA_AGENT_RUNTIME:-${PIPE_AGENT_RUNTIME:-claude}}"
  case "$rt" in
    claude|codex) ;;
    *) echo "ERROR: unknown FXA_AGENT_RUNTIME '${rt}' (use claude or codex)" >&2; return 1 ;;
  esac
  export FXA_AGENT_RUNTIME="$rt"
  source "${AGENT_LIB_DIR}/runtime-${rt}.sh"
}

# Skills shipped into the VM, for either runtime. An allow-list, not a
# deny-list: the VM has no gh, acli, circleci, sentry-cli, or MCP, so a skill
# that reaches the network is worse than absent — the agent reads its
# description, judges it relevant, then fails on a missing binary.
# create-pr-description belongs here because the agent authors the PR title
# and body into the handoff even though the host runs `gh pr create`.
# humanizer and code-simplifier are mandatory goal conditions. package-workflows
# is deliberately absent: it reads 30 days of session history, and a VM boots,
# fixes one ticket, and is destroyed.
# Plugins whose hooks and skills the agent's session runs on. Everything else
# in ~/.claude/plugins needs a network or a data store the VM does not have.
_vm_plugin_allowlist() {
  printf '%s\n' superpowers@claude-plugins-official code-simplifier@claude-plugins-official ponytail@ponytail
}

_vm_skill_allowlist() {
  printf '%s\n' \
    code-simplifier create-pr-description fxa-save-investigation \
    fxa-storybook-capture fxa-vm-handoff fxa-vm-selfcheck humanizer \
    pr-review-typescript quick-review squash-commit
}

# ── Helpers ────────────────────────────────────────────────────

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
    if vm_exec "$name" bash -c "systemctl is-active agent-init 2>/dev/null | grep -q '^active$'" 2>/dev/null; then
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

  vm_exec "$name" sudo bash -c "
    mkdir -p /home/agent/.ssh
    echo '${pubkey}' >> /home/agent/.ssh/authorized_keys
    chown -R agent:agent /home/agent/.ssh
    chmod 700 /home/agent/.ssh
    chmod 600 /home/agent/.ssh/authorized_keys
  "
}

# _put_run_files <name> <slot>
#   gce only. No shared filesystem, so the per-run files the slot holds go over
#   in one tar: ticket context, prompt, runtime auth, ai/ docs, and the same
#   secret set worktree_copy_secrets wrote. Nothing from the tree itself.
_put_run_files() {
  local name="$1" slot="$2" tar="${LOG_DIR}/${name}-run.tar" f
  local -a items=()
  for f in .fxa-jira-context.md .fxa-auto-prompt.txt .fxa-auto-launch.sh .fxa-auto-token \
           .fxa-auto-codex-auth.json .fxa-auto-handoff.schema.json ai \
           $(worktree_secret_files) _dev/firebase/.config; do
    [ -e "${slot}/${f}" ] && items+=("$f")
  done
  # The slot's own changes too, so a relaunch resumes a cut-off run instead of
  # starting over. The runner is pinned to the slot's HEAD; this is the diff on
  # top. Deletions travel as a list, since a tar cannot carry an absence.
  local st path; : > "${slot}/.fxa-auto-deleted"
  while read -r st path; do
    [ -n "$path" ] || continue
    path="${path##* -> }"
    # Orchestration files ship from the explicit list above or not at all; an
    # empty transcript shipped from the slot blocked the agent's own writes.
    case "$path" in .fxa-auto-*|.fxa-jira-*|ai|ai/*) continue ;; esac
    case "$st" in *D*) printf '%s\n' "$path" >> "${slot}/.fxa-auto-deleted" ;; *) [ -e "${slot}/${path}" ] && items+=("$path") ;; esac
  done < <(git -C "$slot" status --porcelain -uall 2>/dev/null)
  [ -s "${slot}/.fxa-auto-deleted" ] && items+=(.fxa-auto-deleted)
  [ "${#items[@]}" -eq 0 ] && return 0
  echo "Shipping ${#items[@]} run file(s) into the runner..."
  # --no-xattrs and COPYFILE_DISABLE: macOS tar otherwise adds ._* AppleDouble files.
  # ai/data is review-mining input, 18 MB of raw JSON the agent never reads, and
  # the IAP tunnel moves it at well under 1 MB/s. The docs and AGENTS.md still ship.
  COPYFILE_DISABLE=1 tar --no-xattrs --exclude ai/data -cf "$tar" -C "$slot" "${items[@]}" || return 1
  vm_put "$name" "$tar" /workspace; local rc=$?
  rm -f "$tar"
  [ "$rc" -eq 0 ] && [ -s "${slot}/.fxa-auto-deleted" ] && \
    vm_exec "$name" sudo -u agent bash -c 'cd /workspace && xargs rm -f < .fxa-auto-deleted; rm -f .fxa-auto-deleted' >/dev/null 2>&1
  rm -f "${slot}/.fxa-auto-deleted"
  return $rc
}

# _gce_pin_runner_tree <name> <slot>
#   Fetch the slot's HEAD by sha into the runner and check it out on the branch.
#   GitHub serves any reachable sha, so this works before the branch is pushed.
_gce_pin_runner_tree() {
  local name="$1" slot="$2" sha branch got
  sha="$(git -C "$slot" rev-parse HEAD)" || return 1
  branch="$(git -C "$slot" rev-parse --abbrev-ref HEAD)" || return 1
  echo "Pinning the runner to ${branch} at ${sha:0:10}..."
  vm_exec "$name" sudo -u agent bash -c "cd /workspace && git fetch --quiet origin ${sha} && git checkout --quiet -B ${branch} ${sha}" 2>&1 | grep -v 'unable to resolve' >&2
  got="$(vm_exec "$name" sudo -u agent bash -c 'cd /workspace && git rev-parse HEAD' 2>/dev/null | tr -d '\r' | tail -1)"
  if [ "$got" != "$sha" ]; then
    echo "ERROR: runner is at '${got:0:10}', slot is at '${sha:0:10}'. Refusing to launch on a base the host did not choose." >&2
    return 1
  fi
  # The dashboard compares this against the slot's HEAD for the rest of the run.
  # agent_run rewrites .meta after launch, so it appends this again from here.
  _PINNED_BASE="$sha"
  printf 'BASE=%s\n' "$sha" >> "${LOG_DIR}/${name}.meta"
}

# ── Security: Disable SSH password auth ───────────────────────

_harden_ssh() {
  local name="$1"

  vm_exec "$name" sudo bash -c "
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
  local name="$1"

  vm_exec "$name" sudo bash -c "
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
  local name="$1"

  vm_exec "$name" sudo bash -c '
    # Allow loopback
    iptables -A OUTPUT -o lo -j ACCEPT

    # Allow established/related connections
    iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

    # Allow DNS to the gateway and to the configured resolvers. On GCE the
    # resolver is the metadata server, which the link-local drop below would
    # otherwise silence; port 53 there is DNS only, the metadata API is port 80.
    GATEWAY=$(ip route | awk "/default/ {print \$3}")
    for ns in $GATEWAY $(awk "/^nameserver/ {print \$2}" /run/systemd/resolve/resolv.conf 2>/dev/null); do
      iptables -A OUTPUT -d "$ns" -p udp --dport 53 -j ACCEPT
      iptables -A OUTPUT -d "$ns" -p tcp --dport 53 -j ACCEPT
    done

    # Block all traffic to private/link-local networks (prevents host probing)
    iptables -A OUTPUT -d 10.0.0.0/8 -j DROP
    iptables -A OUTPUT -d 172.16.0.0/12 -j DROP
    iptables -A OUTPUT -d 192.168.0.0/16 -j DROP
    # Link-local is the metadata server. The guest agent needs it to deliver the
    # ssh key; only the agent user is cut off.
    iptables -A OUTPUT -d 169.254.0.0/16 -m owner --uid-owner agent -j DROP

    # Allow all other outbound (public internet)
    iptables -A OUTPUT -j ACCEPT
  ' 2>/dev/null || true
}

# ── Security: Disable proxy (for existing golden images) ──────

_disable_proxy_in_vm() {
  local name="$1"

  vm_exec "$name" bash -c "
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
  vm_exec "$name" sudo bash -c "
    rm -f /home/agent/.claude/settings.json /home/agent/.claude/settings.local.json /home/agent/.claude/CLAUDE.md
    mkdir -p /home/agent/.claude /home/agent/.config/claude
    chown -R agent:agent /home/agent/.claude /home/agent/.config/claude
  " 2>/dev/null || true

  # settings.json — user preferences (base64 to avoid quoting issues).
  # outputStyle is forced to concise for the VM only: the agent's prose is never
  # read by a human, so terse output is pure savings. Injected here rather than
  # baked into the image, because this copy overwrites the image's settings.json.
  # claude-mem is disabled here for the same reason its cache is excluded below:
  # its store lives in ~/.claude-mem on the host and never crosses, so the VM
  # would run PreToolUse/PostToolUse hooks on every call against an empty index
  # that dies with the VM. Leaving it enabled but absent is worse than off.
  if [ -f "${claude_home}/settings.json" ]; then
    local settings_b64
    settings_b64="$(jq -c '. + {outputStyle: "concise"}
        | if .enabledPlugins then .enabledPlugins |= with_entries(
            select(.key | startswith("claude-mem@") | not)) else . end' \
      < "${claude_home}/settings.json" 2>/dev/null | base64 | tr -d '\n')"
    if [ -z "$settings_b64" ]; then
      echo "  WARN: could not adjust settings.json; copying it unchanged." >&2
      settings_b64="$(base64 < "${claude_home}/settings.json" | tr -d '\n')"
    fi
    vm_exec "$name" sudo bash -c "
      echo '${settings_b64}' | base64 -d > /home/agent/.claude/settings.json
      chown agent:agent /home/agent/.claude/settings.json
    " 2>/dev/null || echo "  WARN: Could not copy settings.json"
  fi

  # Git user config — propagate host identity so commits have correct authorship
  local git_name git_email
  git_name="$(git config --global user.name 2>/dev/null || true)"
  git_email="$(git config --global user.email 2>/dev/null || true)"
  if [ -n "$git_name" ] || [ -n "$git_email" ]; then
    vm_exec "$name" sudo -u agent bash -c "
      git config --global user.name '${git_name}'
      git config --global user.email '${git_email}'
    " 2>/dev/null || echo "  WARN: Could not set git config"
  fi

  # CLAUDE.md — custom instructions (base64 to avoid quoting issues)
  if [ -f "${claude_home}/CLAUDE.md" ]; then
    local claude_md_b64
    claude_md_b64="$(base64 < "${claude_home}/CLAUDE.md" | tr -d '\n')"
    vm_exec "$name" sudo bash -c "
      echo '${claude_md_b64}' | base64 -d > /home/agent/.claude/CLAUDE.md
      chown agent:agent /home/agent/.claude/CLAUDE.md
    " 2>/dev/null || echo "  WARN: Could not copy CLAUDE.md"
  fi

  # hooks / commands / skills / plugins — bundle into one tar, SCP it in,
  # extract inside the VM. The previous approach embedded a base64 tar in a
  # `tart exec sudo bash -c "..."` argument, which silently failed for large
  # bundles (the skills + plugins dirs blow past the ARG_MAX limit and the
  # post-hardening sudo channel is unreliable anyway). SSH/SCP via the
  # per-agent key is the clean path.
  local config_tar
  config_tar="$(mktemp -t fxa-claude-config.XXXX.tar)"
  # The golden image ships with Bun installed (packer/scripts/04-claude.sh) for
  # plugins that need it.
  local tar_items=()
  [ -d "${claude_home}/hooks" ]    && tar_items+=("hooks")
  [ -d "${claude_home}/commands" ] && tar_items+=("commands")
  # Plugins are an allow-list, like the skills below. The whole cache was 814 MB
  # (a 774 MB vercel plugin, node_modules in every cache, stale temp_git clones,
  # claude-mem), and the VM can use none of it: no network integrations, no
  # claude-mem data. Only the plugins the agent's session runs on ship, and
  # installed_plugins.json is rewritten to list just those with VM paths, so
  # Claude in the VM does not look for plugins that are not there.
  local plugins_tmp=""
  if [ -f "${claude_home}/plugins/installed_plugins.json" ]; then
    plugins_tmp="$(mktemp -d -t fxa-plugins.XXXX)"
    mkdir -p "${plugins_tmp}/plugins"
    local allow; allow="$(_vm_plugin_allowlist | jq -R . | jq -s .)"
    jq --argjson allow "$allow" --arg home "$claude_home" \
      '.plugins |= with_entries(select(.key as $k | $allow | index($k)))
       | .plugins |= map_values(map(.installPath |= sub("^" + $home; "/home/agent/.claude")))' \
      "${claude_home}/plugins/installed_plugins.json" > "${plugins_tmp}/plugins/installed_plugins.json"
    [ -f "${claude_home}/plugins/config.json" ] && cp "${claude_home}/plugins/config.json" "${plugins_tmp}/plugins/config.json"
    local rel
    while IFS= read -r rel; do
      [ -n "$rel" ] && [ -d "${claude_home}/${rel}" ] && tar_items+=("$rel")
    done < <(jq -r --arg home "$claude_home" '.plugins[][] | .installPath | sub("^" + $home + "/"; "")' \
               "${plugins_tmp}/plugins/installed_plugins.json" 2>/dev/null)
  fi
  local skill_excludes=(--exclude="*/node_modules")

  # Skills are an allow-list, not a deny-list. The VM has no gh, acli, circleci,
  # or sentry-cli, no GitHub or Jira credential, and no MCP, so any skill that
  # reaches the network is not merely useless: the agent reads its description,
  # judges it relevant, and then fails on a missing binary. Ship only the ones
  # that work against the local worktree. create-pr-description belongs here
  # because the agent authors the PR title and body into the handoff file, even
  # though the host is what runs `gh pr create`.
  # /humanizer and /code-simplifier are mandatory goal conditions in
  # VM_AGENT_GUIDE.md (steps 5 and 8), so they must ship.
  # The FxA repo supplies its own skills at /workspace/.claude/skills (fxa-review-quick,
  # fxa-simplify, and more). Those are authoritative for FxA code. The fxa-vm-* skills
  # here cover only what the repo cannot know: the sandbox handoff contract and the
  # pool-worktree diff base.
  # package-workflows is deliberately absent: it reads 30 days of session
  # history, and a VM boots, fixes one ticket, and is destroyed.
  local vm_skills=( $(_vm_skill_allowlist) )
  local s
  for s in "${vm_skills[@]}"; do
    [ -d "${claude_home}/skills/${s}" ] && tar_items+=("skills/${s}")
  done

  if [ "${#tar_items[@]}" -gt 0 ]; then
    if tar -cf "$config_tar" -C "$claude_home" "${skill_excludes[@]}" "${tar_items[@]}" 2>/dev/null \
       && { [ -z "$plugins_tmp" ] || tar -rf "$config_tar" -C "$plugins_tmp" plugins 2>/dev/null; } \
       && [ -s "$config_tar" ]; then
      local ssh_key="${LOG_DIR}/ssh/${name}/id_ed25519"
      local ip
      ip="$(vm_ip "$name")"
      if scp -i "$ssh_key" ${VM_SSH_OPTS} "$config_tar" \
           "${VM_SSH_USER}@${ip}:/tmp/fxa-claude-config.tar" 2>/dev/null; then
        ssh -i "$ssh_key" ${VM_SSH_OPTS} "${VM_SSH_USER}@${ip}" "
          mkdir -p /home/agent/.claude/plugins
          tar -xf /tmp/fxa-claude-config.tar -C /home/agent/.claude/
          chmod -R +x /home/agent/.claude/hooks 2>/dev/null
          rm -f /tmp/fxa-claude-config.tar
        " 2>/dev/null || echo "  WARN: extracting claude config bundle in VM failed"
      else
        echo "  WARN: scp of claude config bundle failed"
      fi
    fi
  fi
  rm -f "$config_tar"; [ -n "$plugins_tmp" ] && rm -rf "$plugins_tmp"

  # Append VM-specific context to CLAUDE.md (or create it if no host CLAUDE.md)
  local vm_section
  vm_section="$(cat <<'VMSECTION'

# Sandbox VM Environment

You are running inside a sandbox VM (Ubuntu 24.04 ARM64, Tart).

## IMPORTANT: First Action

At the start of every new session, read these files for full project context:
1. `/etc/vm-agent-guide.md` — Complete VM operations manual (ports, architecture, gotchas)
2. `/workspace/ai/AGENTS.md` — FxA project context and coding conventions (if it exists)

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
  vm_exec "$name" sudo bash -c "
    echo '${vm_section_b64}' | base64 -d >> /home/agent/.claude/CLAUDE.md
    chown agent:agent /home/agent/.claude/CLAUDE.md
  " 2>/dev/null || echo "  WARN: Could not append VM context to CLAUDE.md"

  # Pre-configure ~/.claude.json so Claude Code skips first-run dialogs:
  #   - hasTrustDialogAccepted: workspace trust prompt
  #   - hasCompletedOnboarding: onboarding flow
  #   - bypassPermissionsModeAccepted: the "Bypass Permissions mode" warning
  #     that appears the first time --permission-mode bypassPermissions or
  #     --dangerously-skip-permissions is used on a machine. Without this, the
  #     TUI sits at a y/n dialog and the agent never gets the goal prompt.
  # Also set the migrated form (skipDangerousModePermissionPrompt) in
  # settings.json since newer Claude versions read that instead.
  vm_exec "$name" sudo -u agent bash -c '
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
# Claude trusts the resolved path. On gce /workspace links to the baked clone.
data[\"projects\"][os.path.realpath(\"/workspace\")] = trust
data[\"hasCompletedOnboarding\"] = True
data[\"bypassPermissionsModeAccepted\"] = True
with open(path, \"w\") as f:
    json.dump(data, f)

settings_path = os.path.expanduser(\"~/.claude/settings.json\")
os.makedirs(os.path.dirname(settings_path), exist_ok=True)
try:
    with open(settings_path) as f:
        settings = json.load(f)
except:
    settings = {}
settings[\"skipDangerousModePermissionPrompt\"] = True
with open(settings_path, \"w\") as f:
    json.dump(settings, f, indent=2)
"
  ' 2>/dev/null || echo "  WARN: Could not pre-trust workspace"
}

# ── Security: Ephemeral token injection ───────────────────────

_inject_oauth_token() {
  # Args: workspace_dir, token. Writes <workspace>/.fxa-auto-token on the host;
  # the file shows up inside the VM at /workspace/.fxa-auto-token via virtiofs.
  # Claude's startup command sources and deletes it.
  #
  # Previous approach used `tart exec sudo bash -c "echo > /tmp/..."` which
  # races with our security hardening (admin password lock makes tart's
  # internal sudo channel unreliable). Writing through the mount is direct
  # and doesn't need any in-VM privilege.
  local workspace_dir="$1"
  local token="$2"
  local token_file="${workspace_dir}/.fxa-auto-token"

  printf 'export CLAUDE_CODE_OAUTH_TOKEN=%s\n' "$token" > "$token_file"
  chmod 644 "$token_file"
  echo "  Token written to ${token_file} (${#token} chars)."
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

  # Step 1: Clone the golden image. gce reads the branch from metadata at boot.
  FXA_GCE_BRANCH="$(git -C "$workspace_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  export FXA_GCE_BRANCH
  # Hold the snapshot's pull off this slot until the run files are shipped.
  local launching="${LOG_DIR}/$(basename "$workspace_dir").launching"; touch "$launching"
  vm_clone "$name" || { rm -f "$launching"; return 1; }
  # Claim the slot now, not after boot. freeslots and the launcher's collision
  # check read this file, and a gce boot takes minutes; until 2026-09-14 the
  # slot read free for that whole window. The IP is filled in below.
  mkdir -p "${LOG_DIR}"
  cat > "${LOG_DIR}/${name}.meta" <<META
NAME=${name}
WORKSPACE=${workspace_dir}
CPU=${cpu}
MEMORY=${memory}
IP=
STARTED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
META

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

  # gce: pin the runner's tree to the slot's exact commit. The image's boot
  # unit fetches on a best-effort basis and a new branch is not on origin, so
  # on 2026-09-14 FXA-2598 ran on the image's four-commit-stale main and the
  # pull read the difference as the agent's work. Refuse rather than run on a
  # base the host did not choose.
  if [ "$FXA_VM_BACKEND" = "gce" ]; then
    _gce_pin_runner_tree "$name" "$workspace_dir" || { vm_delete "$name"; return 1; }
  fi

  # Step 6: Security hardening
  echo "Applying security hardening..."

  # 6a: Disable proxy (for existing golden images with Squid baked in)
  _disable_proxy_in_vm "$name"

  # 6b: Set up egress firewall (blocks host/private network access)
  _setup_egress_firewall "$name"

  # 6c: Disable SSH password auth (key-only access)
  _harden_ssh "$name"

  # 6d: Restrict sudo to specific commands
  _restrict_sudo "$name"

  # Step 7: Install per-agent SSH key
  echo "Setting up SSH key..."
  _install_ssh_key "$name"

  # Step 8: Fix git worktrees (worktree .git files reference host paths)
  if [ -n "$gitdir" ] && [ "$FXA_VM_BACKEND" = "tart" ]; then
    echo "Linking git worktree parent (.git: ${gitdir})..."
    # Symlink /mnt/shared/gitdir to the host absolute path so the
    # worktree .git pointer resolves inside the VM
    vm_exec "$name" sudo bash -c "
      mkdir -p '$(dirname "$gitdir")'
      ln -sfn /mnt/shared/gitdir '${gitdir}'
    " 2>/dev/null || echo "  WARN: Git worktree symlink failed"
  fi

  # Step 9: Runtime config and credentials. The runtime file owns both.
  runtime_load || return 1
  echo "Setting up ${FXA_AGENT_RUNTIME} config..."
  runtime_setup_config "$name" || return 1
  runtime_inject_auth "$workspace_dir" || return 1

  # Step 10: Start the agent inside a screen session in the VM
  echo "Starting ${FXA_AGENT_RUNTIME} in VM..."

  # Write .screenrc with agent name banner
  vm_exec "$name" sudo -u agent bash -c "
    cat > /home/agent/.screenrc <<SCREENRC
defscrollback 10000
startup_message off
termcapinfo xterm* ti@:te@
hardstatus alwayslastline '%{= bW} FxA Agent: ${name} %= scroll: Ctrl-a [  detach: Ctrl-a d '
SCREENRC
  "

  # The runtime owns the launch string and how the prompt reaches the agent.
  # Both run inside a screen session so attach/tail/alive behave the same for
  # either: Claude's TUI is pasted into after boot; Codex reads stdin at exec.
  [ -n "$prompt" ] && runtime_write_prompt "$prompt" "$workspace_dir"
  if [ "$FXA_VM_BACKEND" = "gce" ]; then
    _put_run_files "$name" "$workspace_dir" || { rm -f "$launching"; vm_delete "$name"; return 1; }
    rm -f "$launching"
  fi
  local launch_cmd
  launch_cmd="$(runtime_launch_cmd)"

  vm_exec "$name" sudo -u agent bash -c "
    export HOME=/home/agent
    screen -dmS ${VM_SCREEN_SESSION} bash -c '${launch_cmd}; exec bash'
  "

  [ -n "$prompt" ] && runtime_submit_prompt "$full_name" "$name"

  # Save agent metadata
  local ip
  ip="$(vm_ip "$name")"
  cat > "${LOG_DIR}/${name}.meta" <<META
NAME=${name}
WORKSPACE=${workspace_dir}
CPU=${cpu}
MEMORY=${memory}
IP=${ip}
STARTED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
META
  [ -n "${_PINNED_BASE:-}" ] && printf 'BASE=%s\n' "$_PINNED_BASE" >> "${LOG_DIR}/${name}.meta"

  echo ""
  echo "=== Agent '${name}' is running ==="
  echo "  Attach:  fxa-sandbox-ctl attach ${name}"
  echo "  Logs:    fxa-sandbox-ctl logs ${name}"
  echo "  Stop:    fxa-sandbox-ctl stop ${name}"
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
  _disable_proxy_in_vm "$name"
  _setup_egress_firewall "$name"

  # Step 7: Fix git worktree symlinks if needed
  if [ -n "$gitdir" ] && [ "$FXA_VM_BACKEND" = "tart" ]; then
    echo "Linking git worktree parent (.git: ${gitdir})..."
    vm_exec "$name" sudo bash -c "
      mkdir -p '$(dirname "$gitdir")'
      ln -sfn /mnt/shared/gitdir '${gitdir}'
    " 2>/dev/null || echo "  WARN: Git worktree symlink failed"
  fi

  # Step 8: Re-stage credentials for the new workspace
  runtime_load || return 1
  runtime_inject_auth "$new_workspace" || return 1

  # Step 9: Start a new agent screen session
  echo "Starting ${FXA_AGENT_RUNTIME} in VM..."

  # Write .screenrc with agent name banner
  vm_exec "$name" sudo -u agent bash -c "
    cat > /home/agent/.screenrc <<SCREENRC
defscrollback 10000
startup_message off
termcapinfo xterm* ti@:te@
hardstatus alwayslastline '%{= bW} FxA Agent: ${name} %= scroll: Ctrl-a [  detach: Ctrl-a d '
SCREENRC
  "

  if [ "$FXA_VM_BACKEND" = "gce" ]; then
    _put_run_files "$name" "$new_workspace" || return 1
  fi
  local launch_cmd
  launch_cmd="$(runtime_launch_cmd)"
  vm_exec "$name" sudo -u agent bash -c "
    export HOME=/home/agent
    screen -dmS ${VM_SCREEN_SESSION} bash -c '${launch_cmd}; exec bash'
  "

  # Update metadata with new workspace and IP
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

# agent_prewarm_stack <name>
#   Kick off `fxa-start` inside a running agent's VM as a detached background
#   job so the FxA service stack warms while the agent does planning/coding.
#   Logs to <workspace>/.fxa-auto-stack-start.log (visible from the host).
agent_prewarm_stack() {
  local name="${1:-}"
  if [ -z "$name" ]; then
    echo "ERROR: agent_prewarm_stack requires <name>" >&2
    return 1
  fi
  if ! vm_is_running "$name"; then
    echo "ERROR: VM for agent '${name}' is not running." >&2
    return 1
  fi

  local full_name workspace
  full_name="$(vm_name "$name")"
  if [ -f "${LOG_DIR}/${name}.meta" ]; then
    local NAME WORKSPACE CPU MEMORY IP STARTED
    source "${LOG_DIR}/${name}.meta"
    workspace="${WORKSPACE:-}"
  fi

  # Fully detach inside the VM: nohup + setsid so fxa-start survives the
  # tart-exec dispatch returning. Output goes to a log file in the workspace
  # so it's tail-able from the host.
  vm_exec "$name" sudo -u agent bash -c '
    cd /workspace || exit 1
    nohup setsid bash -c "source /etc/agent-env.sh && fxa-start" \
      > /workspace/.fxa-auto-stack-start.log 2>&1 < /dev/null &
    disown $! 2>/dev/null || true
  ' >/dev/null 2>&1 || return 1

  if [ -n "$workspace" ]; then
    echo "  Pre-warm log: ${workspace}/.fxa-auto-stack-start.log" >&2
  else
    echo "  Pre-warm log: <workspace>/.fxa-auto-stack-start.log" >&2
  fi
}

agent_attach() {
  local name="$1"

  if ! vm_is_running "$name"; then
    echo "ERROR: Agent '${name}' is not running." >&2
    return 1
  fi

  # Let the runtime re-stage credentials if a human attaching needs them.
  # The workspace path comes from the meta file (it lives on the mounted worktree).
  local full_name
  full_name="$(vm_name "$name")"
  runtime_load || return 1
  local NAME WORKSPACE CPU MEMORY IP STARTED
  if [ -f "${LOG_DIR}/${name}.meta" ]; then
    source "${LOG_DIR}/${name}.meta"
    [ -n "${WORKSPACE:-}" ] && runtime_attach_hook "$WORKSPACE"
  fi

  # SSH into the VM's screen session. `screen -x` multi-attaches so the
  # orchestrator's auto-attach and ad-hoc `attach` calls can coexist.
  local ip
  ip="$(vm_ip "$name")"
  local ssh_key="${LOG_DIR}/ssh/${name}/id_ed25519"

  # Wait up to 30s for agent_run to generate the per-agent SSH key. Without
  # this, racing `attach` against the setup steps falls back to password auth
  # (which our hardening disables) and prints a confusing error.
  if [ ! -f "$ssh_key" ]; then
    echo "Waiting for SSH key to be provisioned..." >&2
    local wait=0
    while [ ! -f "$ssh_key" ] && [ "$wait" -lt 30 ]; do
      sleep 1
      wait=$(( wait + 1 ))
    done
    if [ ! -f "$ssh_key" ]; then
      echo "ERROR: SSH key not found at ${ssh_key} after 30s." >&2
      echo "       Agent setup may have failed; check the orchestrator output." >&2
      return 1
    fi
  fi

  ssh -t -i "${ssh_key}" ${VM_SSH_OPTS} "${VM_SSH_USER}@${ip}" \
    "screen -x ${VM_SCREEN_SESSION} || screen -S ${VM_SCREEN_SESSION}"
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
    vm_exec "$name" journalctl -f --no-pager 2>/dev/null || \
      echo "Could not stream logs. Try: fxa-sandbox-ctl attach ${name}"
  else
    echo "=== Logs for agent '${name}' ==="
    vm_exec "$name" journalctl --no-pager -n 100 2>/dev/null || \
      echo "Could not read logs. Try: fxa-sandbox-ctl attach ${name}"
  fi
}

agent_stop() {
  local name="$1"
  local full_name
  full_name="$(vm_name "$name")"
  # The host launcher that watches this slot must die with the VM. On
  # 2026-09-14 FXA-2598's first launcher outlived its VM, and when the relaunch
  # wrote its handoff two launchers raced to commit the same slot. Not a CI
  # watcher though: past the PR the launcher only reads GitHub.
  local key; key="$(printf '%s' "$name" | tr 'a-z' 'A-Z')"
  pgrep -f "jira ${key} " 2>/dev/null | while read -r pid; do
    grep -q 'pull/' "$(pipeline_launch_log "$key" 2>/dev/null)" 2>/dev/null || kill "$pid" 2>/dev/null || true
  done

  echo "Stopping agent '${name}'..."

  # Gracefully stop Claude Code via screen
  vm_exec "$name" sudo -u agent screen -S "${VM_SCREEN_SESSION}" -X quit 2>/dev/null || true
  sleep 2

  # Stop the VM
  vm_stop "$name"

  # Delete the VM clone
  vm_delete "$name"

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

  # Clean up all SSH keys
  rm -rf "${LOG_DIR}/ssh"

  echo "All agents stopped."
}

# ── Run-state introspection ────────────────────────────────────

# agent_ssh_exec <name> <remote-command...>
#   Run a command in the agent's VM over SSH and print its stdout. Returns 1
#   when there is no running VM or no key for it.
#
#   Callers used to parse the human-readable output of `fxa-sandbox-ctl ssh`
#   to find the IP and key path. That is the same two fields this reads
#   directly, without a text format in between.
agent_ssh_exec() {
  local name="${1:-}"; shift || true
  [ -n "$name" ] || return 1
  vm_is_running "$name" 2>/dev/null || return 1
  local ip key
  ip="$(vm_ip "$name")" || return 1
  key="${LOG_DIR}/ssh/${name}/id_ed25519"
  [ -n "$ip" ] && [ -f "$key" ] || return 1
  # shellcheck disable=SC2086  # VM_SSH_OPTS is a list of flags, split on purpose
  ssh -i "$key" $VM_SSH_OPTS "${VM_SSH_USER}@${ip}" "$@"
}

# agent_alive <name>
#   Exit 0 when a real claude process runs in the VM.
#
#   The status field in `agent_list` tracks the screen session, not the agent.
#   A dead agent still reports "running" because `exec bash` replaces claude
#   inside the same session, so a run can read healthy for hours after it died.
#   Confirm a real process before trusting any launch.
# Memoised for 20 s per name: on gce the answer rides an ssh through IAP, and a
# snapshot asks for the same runner several times. A string cache, not an
# associative array: macOS ships bash 3.2.
_ALIVE_MEMO=""
agent_alive() {
  local name="${1:-}" now hit
  now="$(date +%s)"
  hit="$(printf '%s\n' "$_ALIVE_MEMO" | grep -m1 "^${name} " || true)"
  if [ -n "$hit" ] && [ $(( now - $(printf '%s' "$hit" | cut -d' ' -f2) )) -lt 20 ]; then
    return "$(printf '%s' "$hit" | cut -d' ' -f3)"
  fi
  _agent_alive_now "$name"; local rc=$?
  _ALIVE_MEMO="$(printf '%s\n' "$_ALIVE_MEMO" | grep -v "^${name} " || true)
${name} ${now} ${rc}"
  return "$rc"
}
_agent_alive_now() {
  local name="${1:-}"
  local n
  # pgrep -c prints 0 AND exits non-zero on no match, so `|| echo 0` would emit
  # a second 0 and break the integer test. Use `|| true` and take one line.
  runtime_load || return 1
  local pat; pat="$(runtime_alive_pattern)"
  # Could not ask is not "no process". On gce the question rides an ssh
  # through IAP, and one dropped tunnel read as a dead agent on 2026-09-14
  # (FXA-9245, mid-test, reported exited-without-handoff). Return 2 for that.
  n="$(agent_ssh_exec "$name" "pgrep -cf '${pat}' 2>/dev/null || true" 2>/dev/null \
       | tr -d '\r' | head -1)" || return 2
  n="${n:-0}"
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  [ "$n" -gt 0 ]
}
