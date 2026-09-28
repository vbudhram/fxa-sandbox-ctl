#!/bin/bash
# agent.sh: agent lifecycle (run, attach, stop, list, logs)

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

# The sections of the operator's CLAUDE.md that apply to code and writing. An
# allowlist, so a section added later (Jira, internal links) stays on the host.
VM_RULE_SECTIONS="Working Approach|Writing Style|Naming Conventions|Testing|Code Comments|Git Commits|Untrusted text"
_vm_operator_rules() {
  local f="${CLAUDE_HOME_DIR}/CLAUDE.md"
  [ -f "$f" ] || return 0
  printf '# Operator rules\n\nFrom the instructions of the operator who runs this sandbox. They apply to your code and writing.\n\n'
  awk -v keep="^## (${VM_RULE_SECTIONS})\$" '/^## /{on = ($0 ~ keep)} on' "$f"
}

# Skills shipped into the VM, for either runtime. An allowlist: the VM has no gh,
# acli, circleci, sentry-cli, credentials or MCP, so a skill that reaches the
# network is worse than absent. The agent picks it, then fails on a missing binary.
# create-pr-description: the agent writes the PR title and body into the handoff.
# humanizer, code-simplifier and ponytail-review are mandatory goal conditions.
# package-workflows is absent on purpose: it reads 30 days of session history.
# Plugins do not load in the runner (`plugins: []`), so each skill must be a plain
# directory under ~/.claude/skills. ponytail-review is an MIT copy from the
# ponytail plugin cache; copy it again when the plugin updates.
_vm_skill_allowlist() {
  printf '%s\n' \
    code-simplifier create-pr-description fxa-save-investigation \
    fxa-storybook-capture fxa-vm-handoff fxa-vm-selfcheck fxa-verify fxa-stack fxa-functional-local humanizer \
    ponytail-review pr-review-typescript quick-review squash-commit fxa-unslop fxa-test-plan
}

# ── Helpers ────────────────────────────────────────────────────

_check_host_ram() {
  [ "$FXA_VM_BACKEND" = tart ] || return 0  # only Tart VMs use this host's RAM
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
  local key_dir="${LOG_DIR}/ssh/${name}"

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
           .fxa-auto-codex-auth.json .fxa-auto-handoff.schema.json .fxa-resume.patch .fxa-resume-claude.tgz ai \
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
    case "$path" in .fxa-*|ai|ai/*) continue ;; esac
    case "$st" in *D*) printf '%s\n' "$path" >> "${slot}/.fxa-auto-deleted" ;; *) [ -e "${slot}/${path}" ] && items+=("$path") ;; esac
  done < <(git -C "$slot" status --porcelain -uall 2>/dev/null || true)  # a session's run dir is no checkout
  [ -s "${slot}/.fxa-auto-deleted" ] && items+=(.fxa-auto-deleted)
  [ "${#items[@]}" -eq 0 ] && return 0
  echo "Shipping ${#items[@]} run file(s) into the runner..."
  # --no-xattrs and COPYFILE_DISABLE: macOS tar otherwise adds ._* AppleDouble files.
  # ai/data is 18 MB of JSON the agent never reads, slow over the IAP tunnel.
  # "./" prefix: filenames can come from the agent, and bsdtar reads a leading dash as an option.
  local -a rel=(); for f in "${items[@]}"; do rel+=("./${f#./}"); done
  ( umask 077; COPYFILE_DISABLE=1 tar --no-xattrs --exclude ./ai/data -czf "$tar" -C "$slot" "${rel[@]}" ) || return 1
  vm_put "$name" "$tar" /workspace; local rc=$?
  rm -f "$tar"
  [ "$rc" -eq 0 ] && [ -s "${slot}/.fxa-auto-deleted" ] && \
    vm_exec "$name" sudo -u agent bash -c 'cd /workspace && xargs rm -f < .fxa-auto-deleted; rm -f .fxa-auto-deleted' >/dev/null 2>&1
  rm -f "${slot}/.fxa-auto-deleted"
  # A resumed session: restore the earlier Claude conversation and re-apply its
  # work before the agent starts, so its first turn picks up where it stopped.
  if [ "$rc" -eq 0 ] && [ -s "${slot}/.fxa-resume-claude.tgz" ]; then
    vm_exec "$name" sudo -u agent bash -c 'tar -xzf /workspace/.fxa-resume-claude.tgz -C /home/agent && rm -f /workspace/.fxa-resume-claude.tgz' >/dev/null 2>&1 \
      || echo "WARN: could not restore the earlier conversation." >&2
  fi
  if [ "$rc" -eq 0 ] && [ -s "${slot}/.fxa-resume.patch" ]; then
    if vm_exec "$name" sudo -u agent bash -c 'cd /workspace && git apply --whitespace=nowarn .fxa-resume.patch && rm -f .fxa-resume.patch' >/dev/null 2>&1; then
      echo "Re-applied the earlier session's changes."
    else
      echo "WARN: the earlier changes did not apply cleanly; they are in /workspace/.fxa-resume.patch" >&2
    fi
  fi
  return $rc
}

# _gce_pin_runner_tree <name> <slot>
#   Fetch the slot's HEAD by sha into the runner and check it out on the branch.
#   GitHub serves any reachable sha, so this works before the branch is pushed.
_gce_pin_runner_tree() {
  local name="$1" slot="$2" sha branch got
  # A session has no slot; it names the commit and branch itself.
  sha="${FXA_PIN_SHA:-$(git -C "$slot" rev-parse HEAD)}" || return 1
  branch="${FXA_PIN_BRANCH:-$(git -C "$slot" rev-parse --abbrev-ref HEAD)}" || return 1
  # A detached slot (a plain `run`) has no branch; name it after the agent.
  [ "$branch" = HEAD ] && branch="$name"
  # The prompts diff against merge-base with origin/<base>. The image's copy of
  # that ref is as old as the image, so set it to the base the host sees now.
  local base="${FXA_WORKTREE_BASE:-main}" base_sha
  base_sha="${FXA_PIN_BASE_SHA:-$(git -C "$slot" rev-parse --verify -q "origin/${base}^{commit}" 2>/dev/null || true)}"
  # These go into a remote bash -c string unquoted.
  [[ "$sha" =~ ^[0-9a-f]{7,40}$ ]] && [[ -z "$base_sha" || "$base_sha" =~ ^[0-9a-f]{7,40}$ ]] &&
    git check-ref-format --branch "$branch" >/dev/null 2>&1 && git check-ref-format --branch "$base" >/dev/null 2>&1 ||
    { echo "ERROR: refusing to pin: sha, branch or base is not a plain git name." >&2; return 1; }
  echo "Pinning the runner to ${branch} at ${sha:0:10}..."
  # vm_wait_ready skips the wait for the checkout unit when one ssh flakes, and
  # parallel launches then pinned before /workspace existed. Poll for it here.
  local deadline=$(( $(date +%s) + ${GCE_CHECKOUT_TIMEOUT:-600} ))
  until vm_exec "$name" test -e /workspace/.git >/dev/null 2>&1; do
    [ "$(date +%s)" -lt "$deadline" ] || { echo "ERROR: /workspace never appeared on the runner." >&2; return 1; }
    sleep 5
  done
  # One ssh: fetch, check out, install only when yarn.lock differs from the
  # image's, and read back the commit. The install runs here, after the pin,
  # because the branch tip is not always the pinned commit. The fetch is skipped
  # when the clone has the commit: on a fresh disk it cost 20-40 s for nothing.
  # The step is safe to repeat. An IAP tunnel can time out on the ssh banner,
  # which reads as an empty answer, so retry that instead of failing the launch.
  local try
  for try in 1 2 3; do
  got="$(vm_exec "$name" sudo -u agent bash -c "cd /workspace && { git cat-file -e ${sha}^{commit} 2>/dev/null || git fetch --quiet origin ${sha}; } && git checkout --quiet -B ${branch} ${sha}
    if [ -n '${base_sha}' ]; then
      { git cat-file -e ${base_sha}^{commit} 2>/dev/null || git fetch --quiet origin ${base_sha}; } && git update-ref refs/remotes/origin/${base} ${base_sha}
    fi
    if [ \"\$(sha256sum yarn.lock | cut -d' ' -f1)\" != \"\$(cat /home/agent/.image-lock-hash 2>/dev/null)\" ]; then
      echo 'yarn.lock differs from the image; installing dependencies...' >&2
      source /etc/agent-env.sh && yarn install --immutable > /tmp/fxa-pin-yarn.log 2>&1 || echo 'WARN: yarn install failed; see /tmp/fxa-pin-yarn.log' >&2
      (cd packages/functional-tests && npx playwright install chromium firefox > /tmp/fxa-pin-playwright.log 2>&1) || true
    fi
    git rev-parse HEAD" 2> >(grep -v 'unable to resolve' >&2) | tr -d '\r' | tail -1)" || true
  [ -n "$got" ] && break
  echo "  The runner did not answer the pin (try ${try} of 3)." >&2
  [ "$try" -lt 3 ] && sleep 10
  done
  if [ -z "$got" ]; then
    echo "ERROR: could not reach the runner to pin it: ssh through IAP failed 3 times." >&2
    return 1
  fi
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
    sed -i 's/^PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
    sed -i 's/^#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
    grep -q '^PasswordAuthentication' /etc/ssh/sshd_config || echo 'PasswordAuthentication no' >> /etc/ssh/sshd_config
    # The base image ships default creds for admin.
    passwd -l admin 2>/dev/null || true
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
Cmnd_Alias FXA_UNITS = /usr/bin/systemctl start mysql, /usr/bin/systemctl stop mysql, /usr/bin/systemctl restart mysql, /usr/bin/systemctl status mysql, /usr/bin/systemctl start redis-server, /usr/bin/systemctl stop redis-server, /usr/bin/systemctl restart redis-server, /usr/bin/systemctl status redis-server, /usr/bin/systemctl start firestore-emulator, /usr/bin/systemctl stop firestore-emulator, /usr/bin/systemctl restart firestore-emulator, /usr/bin/systemctl status firestore-emulator, /usr/bin/systemctl start goaws, /usr/bin/systemctl stop goaws, /usr/bin/systemctl restart goaws, /usr/bin/systemctl status goaws
agent ALL=(ALL) NOPASSWD: FXA_UNITS
agent ALL=(ALL) NOPASSWD: /usr/bin/tee /etc/hosts
SUDOERS
    chmod 440 /etc/sudoers.d/agent
  " 2>/dev/null || true
}

# ── Security: Egress firewall ─────────────────────────────────

_setup_egress_firewall() {
  local name="$1"
  # The allowlist is per runtime: Codex talks to OpenAI, not Anthropic. Without
  # these three hosts a Codex runner boots, stages its auth, and every model
  # call is rejected, which reads as a silent stall.
  local hosts="$FXA_EGRESS_HOSTS"
  case "${FXA_AGENT_RUNTIME:-claude}" in
    codex) hosts="$hosts api.openai.com chatgpt.com auth.openai.com" ;;
  esac

  # GitHub serves github.com from more addresses than the fixed ranges, and DNS
  # rotates among them; the check below then failed about one boot in six.
  local cidrs="$FXA_EGRESS_CIDRS $(_github_meta_cidrs)"

  # Keep the script's stderr: the launch log is the only record of which
  # check refused the run, and the VM is deleted right after.
  local err rc=0 try
  for try in 1 2; do
  rc=0
  err="$(vm_exec "$name" sudo env FXA_EGRESS_ALLOW_ALL="$FXA_EGRESS_ALLOW_ALL" FXA_EGRESS_CIDRS="$cidrs" FXA_EGRESS_HOSTS="$hosts" bash -c '
    iptables -A OUTPUT -o lo -j ACCEPT
    iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

    # Allow DNS to the gateway and to the configured resolvers. On GCE the
    # resolver is the metadata server, which the link-local drop below would
    # otherwise silence; port 53 there is DNS only, the metadata API is port 80.
    GATEWAY=$(ip route | awk "/default/ {print \$3}")
    for ns in $GATEWAY $(awk "/^nameserver/ {print \$2}" /run/systemd/resolve/resolv.conf 2>/dev/null); do
      iptables -A OUTPUT -d "$ns" -p udp --dport 53 -j ACCEPT
      iptables -A OUTPUT -d "$ns" -p tcp --dport 53 -j ACCEPT
    done

    # Private ranges: no probing of the host network.
    iptables -A OUTPUT -d 10.0.0.0/8 -j DROP
    iptables -A OUTPUT -d 172.16.0.0/12 -j DROP
    iptables -A OUTPUT -d 192.168.0.0/16 -j DROP
    # Link-local is the metadata server. The guest agent needs it to deliver the
    # ssh key; only the agent user is cut off.
    iptables -A OUTPUT -d 169.254.0.0/16 -m owner --uid-owner agent -j DROP

    # Root (the guest agent, systemd units) keeps the internet. The agent user
    # gets an allowlist: a prompt-injected agent must not be able to post the
    # tree, the keys, or its own token to an arbitrary host.
    if [ "$FXA_EGRESS_ALLOW_ALL" = "1" ]; then
      iptables -A OUTPUT -j ACCEPT
    else
      for cidr in $FXA_EGRESS_CIDRS; do
        iptables -A OUTPUT -m owner --uid-owner agent -d "$cidr" -j ACCEPT
      done
      for h in $FXA_EGRESS_HOSTS; do
        for ip in $(getent ahostsv4 "$h" 2>/dev/null | awk "{print \$1}" | sort -u); do
          iptables -A OUTPUT -m owner --uid-owner agent -d "$ip" -j ACCEPT
        done
      done
      # Any unconditional ACCEPT ahead of us (older images appended one at boot)
      # makes every rule below unreachable. Remove them all before the REJECT.
      while iptables -D OUTPUT -j ACCEPT 2>/dev/null; do :; done
      iptables -A OUTPUT -m owner --uid-owner agent -j REJECT --reject-with icmp-port-unreachable
      iptables -A OUTPUT -j ACCEPT
    fi
    # Assert, so a failed apply aborts the launch instead of running open.
    iptables -S OUTPUT | grep -q -- "-d 10.0.0.0/8 -j DROP" || { echo "egress: private-range DROP rule missing" >&2; exit 1; }
    # Assert behaviour, not only rule text: a REJECT rule that never matched once
    # passed the text check while example.com answered 200.
    if [ "$FXA_EGRESS_ALLOW_ALL" != "1" ]; then
      # iptables -S prints the uid, not the name.
      iptables -S OUTPUT | grep -qE -- "--uid-owner (agent|[0-9]+) -j REJECT" || { echo "egress: REJECT rule missing" >&2; exit 1; }
      if sudo -u agent timeout 8 bash -c "exec 3<>/dev/tcp/1.1.1.1/443" 2>/dev/null; then
        echo "egress: agent user reached a non-allowlisted host; allowlist is not enforced" >&2; exit 1
      fi
      # Twice: a DNS change between the allow and the check is not a failure.
      { sudo -u agent timeout 8 bash -c "exec 3<>/dev/tcp/github.com/443" 2>/dev/null || { sleep 2; sudo -u agent timeout 8 bash -c "exec 3<>/dev/tcp/github.com/443" 2>/dev/null; }; } \
        || { echo "egress: agent user cannot reach github.com; allowlist too tight" >&2; exit 1; }
    fi
  ' 2>&1 >/dev/null)" || rc=$?
  # Retry once only when ssh failed to connect (exit 255 plus a connect error).
  # A script that ran must not run again: it appends rules.
  [ "$rc" -eq 255 ] && [ "$try" = 1 ] && grep -qiE "banner exchange|Connection timed out|Connection closed|Connection refused|kex_exchange" <<< "$err" || break
  echo "  egress: ssh did not connect; retrying once" >&2; sleep 10
  done
  [ "$rc" -eq 0 ] && return 0
  printf '%s\n' "${err:-egress: no reason given (exit $rc); ssh may have failed}" | tail -3 >&2
  return "$rc"
}

# Egress the agent user may reach: Anthropic's API range, GitHub's published
# ranges, and the hosts below resolved inside the VM at hardening time (the VM
# keeps the same resolver, so it connects to the addresses it allowed). No
# Cloudflare ranges on purpose: they would admit a large share of the internet,
# and the npm and yarn registries are covered by name. FXA_EGRESS_ALLOW_ALL=1
# restores open egress for a run that needs it.
FXA_EGRESS_ALLOW_ALL="${FXA_EGRESS_ALLOW_ALL:-0}"
FXA_EGRESS_CIDRS="${FXA_EGRESS_CIDRS:-160.79.104.0/21 140.82.112.0/20 143.55.64.0/20 185.199.108.0/22 192.30.252.0/22}"
FXA_EGRESS_HOSTS="${FXA_EGRESS_HOSTS:-api.anthropic.com statsig.anthropic.com registry.yarnpkg.com registry.npmjs.org github.com api.github.com codeload.github.com objects.githubusercontent.com playwright.azureedge.net cdn.playwright.dev pypi.org files.pythonhosted.org}"

# _github_meta_cidrs   GitHub's published IPv4 ranges for web, API, and git,
# cached for a day. Empty when the host cannot fetch them; the fixed ranges
# above still apply then.
_github_meta_cidrs() {
  local cache="${LOG_DIR}/github-meta-cidrs"
  if [ ! -s "$cache" ] || [ $(( $(date +%s) - $(_mtime "$cache") )) -gt 86400 ]; then
    curl -sf --max-time 10 https://api.github.com/meta 2>/dev/null \
      | jq -r '[.web[], .api[], .git[]] | unique | map(select(test(":") | not)) | join(" ")' > "${cache}.tmp" 2>/dev/null \
      && [ -s "${cache}.tmp" ] && mv "${cache}.tmp" "$cache" || rm -f "${cache}.tmp"
  fi
  cat "$cache" 2>/dev/null || true
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
  # Only named files, never all of ~/.claude: it holds history, paths and session data.
  local claude_home="${CLAUDE_HOME_DIR}"

  # Old images mounted ~/.claude, and agent-init still makes dangling symlinks to it.
  vm_exec "$name" sudo bash -c "
    rm -f /home/agent/.claude/settings.json /home/agent/.claude/settings.local.json /home/agent/.claude/CLAUDE.md
    mkdir -p /home/agent/.claude /home/agent/.config/claude
    chown -R agent:agent /home/agent/.claude /home/agent/.config/claude
  " 2>/dev/null || true

  # base64 avoids quoting issues. outputStyle is concise because no human reads
  # the agent's prose; it is set here since this copy replaces the image's file.
  if [ -f "${claude_home}/settings.json" ]; then
    local settings_b64
    # Allowlist of keys: the host file holds API keys (env) and hooks, which do
    # not belong on a bypassPermissions VM. enabledPlugins only gives warnings there.
    settings_b64="$(jq -c '{model, permissions, statusLine, theme} | with_entries(select(.value != null))
        | . + {outputStyle: "concise"}' \
      < "${claude_home}/settings.json" 2>/dev/null | base64 | tr -d '\n')"
    # Fail closed: the unfiltered file can hold API keys and hooks.
    [ -n "$settings_b64" ] || { echo "  WARN: could not filter settings.json; the VM gets none." >&2; settings_b64="$(printf '{}' | base64)"; }
    vm_exec "$name" sudo bash -c "
      echo '${settings_b64}' | base64 -d > /home/agent/.claude/settings.json
      chown agent:agent /home/agent/.claude/settings.json
    " 2>/dev/null || echo "  WARN: Could not copy settings.json"
  fi

  # The host identity, so commits have the correct author.
  local git_name git_email
  git_name="$(git config --global user.name 2>/dev/null || true)"
  git_email="$(git config --global user.email 2>/dev/null || true)"
  if [ -n "$git_name" ] || [ -n "$git_email" ]; then
    vm_exec "$name" sudo -u agent bash -c "
      git config --global user.name '${git_name}'
      git config --global user.email '${git_email}'
    " 2>/dev/null || echo "  WARN: Could not set git config"
  fi

  # CLAUDE.md: only the operator rules for code and writing, never the whole file
  # (it names internal links and host workflows the sandbox must not see).
  local rules; rules="$(_vm_operator_rules)"
  if [ -n "$rules" ]; then
    local claude_md_b64
    claude_md_b64="$(printf '%s\n' "$rules" | base64 | tr -d '\n')"
    vm_exec "$name" sudo bash -c "
      echo '${claude_md_b64}' | base64 -d > /home/agent/.claude/CLAUDE.md
      chown agent:agent /home/agent/.claude/CLAUDE.md
    " 2>/dev/null || echo "  WARN: Could not copy CLAUDE.md"
  fi

  # hooks, commands and skills go in one tar over scp. A base64 tar inside a
  # `bash -c` argument failed silently once the skills passed ARG_MAX.
  local config_tar
  config_tar="$(mktemp "${TMPDIR:-/tmp}/fxa-claude-config.XXXXXX")"
  local tar_items=()
  [ -d "${claude_home}/hooks" ]    && tar_items+=("hooks")
  [ -d "${claude_home}/commands" ] && tar_items+=("commands")
  local skill_excludes=(--exclude="*/node_modules")

  # See _vm_skill_allowlist. The repo's own skills in /workspace/.claude/skills
  # win for FxA code; the fxa-vm-* skills cover only the sandbox contract.
  local vm_skills=( $(_vm_skill_allowlist) )
  local s
  for s in "${vm_skills[@]}"; do
    [ -d "${claude_home}/skills/${s}" ] && tar_items+=("skills/${s}")
  done

  if [ "${#tar_items[@]}" -gt 0 ]; then
    # --dereference: skills kept in a repo are symlinks here, and a link to a
    # host path arrives on the runner dangling.
    # COPYFILE_DISABLE: macOS tar would add a ._<name> metadata file for each one.
    if COPYFILE_DISABLE=1 tar --dereference -cf "$config_tar" -C "$claude_home" "${skill_excludes[@]}" "${tar_items[@]}" 2>/dev/null \
       && [ -s "$config_tar" ]; then
      local ssh_key="${LOG_DIR}/ssh/${name}/id_ed25519"
      local ip
      ip="$(vm_ip "$name")"
      if _retry scp -i "$ssh_key" ${VM_SSH_OPTS} "$config_tar" \
           "${VM_SSH_USER}@${ip}:/tmp/fxa-claude-config.tar" 2>/dev/null; then
        # Twice: this runs right after the hardening batch restarts sshd, and a
        # connection in that window can stall. Extracting again is harmless.
        local x
        for x in 1 2; do
          ssh -i "$ssh_key" ${VM_SSH_OPTS} "${VM_SSH_USER}@${ip}" "
            mkdir -p /home/agent/.claude && tar -xf /tmp/fxa-claude-config.tar -C /home/agent/.claude/ || exit 1
            chmod -R +x /home/agent/.claude/hooks 2>/dev/null
            rm -f /tmp/fxa-claude-config.tar
          " 2>/dev/null && break
          [ "$x" = 2 ] && echo "  WARN: extracting claude config bundle in VM failed; the agent has no host skills" >&2 || sleep 10
        done
      else
        echo "  WARN: scp of claude config bundle failed"
      fi
    fi
  fi
  rm -f "$config_tar"

  # Appends, or creates CLAUDE.md when the host has no rules.
  local vm_section
  vm_section="$(cat <<'VMSECTION'

# Sandbox VM

You are inside the FxA sandbox VM (Ubuntu 24.04, ARM64, 4 vCPU, 8GB RAM).

First, read `/etc/vm-agent-guide.md`, the operations manual. It covers the
backend you are on, the network allowlist, what the host refuses to ship, the
stack and its ports, and how to verify. For FxA itself, read
`/workspace/ai/AGENTS.md` and the rules in `/workspace/.claude/rules/`.

What trips agents most often:
- You cannot commit or push, and there is no `gh`. The host commits, signs and
  pushes your working tree. Revert a file with `git checkout -- <path>`.
- The host refuses changes to CI and tooling files (`.github/`, `.circleci/`,
  `.husky/`, `_scripts/`, `package.json` scripts) and to frozen paths.
- The network is an allowlist (Anthropic, npm and yarn, PyPI, GitHub, Playwright).
  Any other host is refused.
- Verify with `/fxa-verify --run`, never a whole package suite: it can run the
  8GB machine out of memory. `nx test-unit fxa-settings` runs no tests.
- The FxA services are not running. Start them with `fxa-start` only when you
  need them. Set `PLAYWRIGHT_WORKERS=2` for functional tests.
- Save screenshots and videos in `/workspace/.fxa-auto-media/`.
VMSECTION
)"
  local vm_section_b64
  vm_section_b64="$(printf '%s' "$vm_section" | base64 | tr -d '\n')"
  vm_exec "$name" sudo bash -c "
    echo '${vm_section_b64}' | base64 -d >> /home/agent/.claude/CLAUDE.md
    chown agent:agent /home/agent/.claude/CLAUDE.md
  " 2>/dev/null || echo "  WARN: Could not append VM context to CLAUDE.md"

  # Skip the first-run dialogs (trust, onboarding, bypass-permissions warning), or
  # the TUI waits at a y/n prompt and never gets the goal. Newer Claude versions
  # read skipDangerousModePermissionPrompt in settings.json instead.
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
  # Args: workspace_dir, token. The file reaches /workspace through the tart mount
  # or _put_run_files on gce; the launch script sources and deletes it. No in-VM
  # sudo: after hardening, that channel is unreliable.
  local workspace_dir="$1"
  local token="$2"
  local token_file="${workspace_dir}/.fxa-auto-token"

  ( umask 077; printf 'export CLAUDE_CODE_OAUTH_TOKEN=%s\n' "$token" | slot_write "$token_file" )
  echo "  Token written to ${token_file} (${#token} chars)."
}

# _worktree_gitdir <workspace>   The parent .git of a worktree, or empty.
_worktree_gitdir() {
  [ -f "${1}/.git" ] || return 0
  local gitdir_path
  gitdir_path="$(sed 's/^gitdir: //' "${1}/.git")"
  [ -d "$gitdir_path" ] || return 0
  # /path/fxa/.git/worktrees/name -> /path/fxa/.git
  cd "$gitdir_path/../.." && pwd
}

# _link_worktree_gitdir <name> <gitdir>
#   tart only. The worktree .git file names a host path; point it at the mount.
_link_worktree_gitdir() {
  local name="$1" gitdir="$2"
  [ -n "$gitdir" ] && [ "$FXA_VM_BACKEND" = "tart" ] || return 0
  echo "Linking git worktree parent (.git: ${gitdir})..."
  vm_exec "$name" sudo bash -c "
      mkdir -p '$(dirname "$gitdir")'
      ln -sfn /mnt/shared/gitdir '${gitdir}'
    " 2>/dev/null || echo "  WARN: Git worktree symlink failed"
}

_write_screenrc() {
  local name="$1"
  vm_exec "$name" sudo -u agent bash -c "
    cat > /home/agent/.screenrc <<SCREENRC
defscrollback 10000
startup_message off
termcapinfo xterm* ti@:te@
hardstatus alwayslastline '%{= bW} FxA Agent: ${name} %= scroll: Ctrl-a [  detach: Ctrl-a d '
SCREENRC
  "
}

_launch_in_screen() {
  local name="$1" launch_cmd
  launch_cmd="$(runtime_launch_cmd)"
  vm_exec "$name" sudo -u agent bash -c "
    export HOME=/home/agent
    screen -dmS ${VM_SCREEN_SESSION} bash -c '${launch_cmd}; exec bash'
  "
}

# _write_meta <name> <workspace> <cpu> <memory> <ip> <started>
_write_meta() {
  cat > "${LOG_DIR}/${1}.meta" <<META
NAME=${1}
WORKSPACE=${2}
CPU=${3}
MEMORY=${4}
IP=${5}
STARTED=${6}
META
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
  # Claim the slot now, not after boot: freeslots and the launcher's collision
  # check read this file, and a gce boot takes minutes. The IP comes later.
  mkdir -p "${LOG_DIR}"
  _write_meta "$name" "$workspace_dir" "$cpu" "$memory" "" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # Step 2: Configure VM resources
  vm_configure "$name" "$cpu" "$memory"

  local gitdir
  gitdir="$(_worktree_gitdir "$workspace_dir")"

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

  # gce: pin the runner to the slot's exact commit. The boot unit's fetch is best
  # effort, and a run on the image's stale main made the pull read the gap as agent work.
  if [ "$FXA_VM_BACKEND" = "gce" ]; then
    _gce_pin_runner_tree "$name" "$workspace_dir" || { vm_delete "$name"; return 1; }
  fi

  # Step 6: Security hardening
  echo "Applying security hardening..."

  # 6a: Egress firewall. A run that starts open is worse than no run. Its own
  # ssh: the status and stderr decide whether the run starts.
  _setup_egress_firewall "$name" || { echo "ERROR: egress firewall did not apply; refusing to start the agent." >&2; vm_delete "$name"; return 1; }

  # 6b-6d and step 7 in one ssh: proxy off (older images bake Squid in),
  # password auth off, sudo restricted, per-agent key installed. Flushed before
  # the config step, whose bundle copy logs in with that key.
  vm_batch_start
  _disable_proxy_in_vm "$name"
  _harden_ssh "$name"
  _restrict_sudo "$name"
  echo "Setting up SSH key..."
  _install_ssh_key "$name"
  vm_batch_flush "$name" || { echo "ERROR: hardening did not reach the runner; refusing to start the agent." >&2; vm_delete "$name"; return 1; }

  # Step 8: Fix git worktrees
  _link_worktree_gitdir "$name" "$gitdir"

  # Step 9: Runtime config and credentials. The runtime file owns both.
  runtime_load || return 1
  echo "Setting up ${FXA_AGENT_RUNTIME} config..."
  # The config writes and the screenrc below go in one ssh.
  vm_batch_start
  # The guide in the image goes stale between image builds; send the current one.
  local guide_b64; guide_b64="$(base64 < "${SANDBOX_ROOT}/VM_AGENT_GUIDE.md" | tr -d '\n')"
  vm_exec "$name" sudo bash -c "echo '${guide_b64}' | base64 -d > /etc/vm-agent-guide.md && chmod 644 /etc/vm-agent-guide.md" 2>/dev/null \
    || echo "  WARN: could not send the VM guide; the image's copy stays" >&2
  runtime_setup_config "$name" || { vm_batch_flush "$name" || true; vm_delete "$name"; return 1; }
  runtime_inject_auth "$workspace_dir" || { vm_batch_flush "$name" || true; vm_delete "$name"; return 1; }

  # Step 10: Start the agent inside a screen session in the VM
  echo "Starting ${FXA_AGENT_RUNTIME} in VM..."
  _write_screenrc "$name"
  vm_batch_flush "$name" || { echo "ERROR: agent config did not reach the runner." >&2; vm_delete "$name"; return 1; }

  # The runtime owns the launch string and how the prompt reaches the agent.
  # Both run inside a screen session so attach/tail/alive behave the same for
  # either: Claude's TUI is pasted into after boot; Codex reads stdin at exec.
  if [ -n "$prompt" ]; then
    runtime_write_prompt "$prompt" "$workspace_dir"
  else
    # The launch always runs .fxa-auto-launch.sh, so an earlier run's files must
    # go, or a plain `run` starts the slot's last ticket again. The token too: only
    # the launch script deletes it, so it would sit in plain text in the slot.
    rm -f "${workspace_dir}/.fxa-auto-launch.sh" "${workspace_dir}/.fxa-auto-prompt.txt" \
      "${workspace_dir}/.fxa-jira-context.md" "${workspace_dir}/.fxa-auto-done.json" "${workspace_dir}/.fxa-auto-token"
  fi
  if [ "$FXA_VM_BACKEND" = "gce" ]; then
    _put_run_files "$name" "$workspace_dir" || { rm -f "$launching"; vm_delete "$name"; return 1; }
    rm -f "$launching"
  fi
  _launch_in_screen "$name"

  [ -n "$prompt" ] && runtime_submit_prompt "$full_name" "$name"

  local ip
  ip="$(vm_ip "$name")"
  _write_meta "$name" "$workspace_dir" "$cpu" "$memory" "$ip" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
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

  if [ "$new_workspace" = "$WORKSPACE" ]; then
    echo "Agent '${name}' is already using workspace: ${WORKSPACE}"
    return 0
  fi

  echo ""
  echo "=== Switching agent '${name}' ==="
  echo "  Old workspace: ${WORKSPACE}"
  echo "  New workspace: ${new_workspace}"
  echo ""

  # Step 1: Stop the VM (preserves disk clone)
  echo "Stopping VM (disk clone preserved)..."
  vm_stop "$name"

  # Step 2: Detect git worktree for new directory
  local gitdir
  gitdir="$(_worktree_gitdir "$new_workspace")"

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
  _link_worktree_gitdir "$name" "$gitdir"

  # Step 8: Re-stage credentials for the new workspace
  runtime_load || return 1
  runtime_inject_auth "$new_workspace" || return 1

  # Step 9: Start a new agent screen session
  echo "Starting ${FXA_AGENT_RUNTIME} in VM..."
  _write_screenrc "$name"

  if [ "$FXA_VM_BACKEND" = "gce" ]; then
    _put_run_files "$name" "$new_workspace" || return 1
  fi
  _launch_in_screen "$name"

  _write_meta "$name" "$new_workspace" "$CPU" "$MEMORY" "$IP" "$STARTED"

  echo ""
  echo "=== Agent '${name}' switched ==="
  echo "  Workspace: ${new_workspace}"
  echo "  Attach:    fxa-sandbox-ctl attach ${name}"
  echo ""
  echo "  NOTE: If FxA services were running, re-run: fxa-sandbox-ctl services ${name}"
}

# agent_prewarm_stack <name>
#   Start `fxa-start` detached in the VM, so the stack warms while the agent plans.
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

  local workspace
  if [ -f "${LOG_DIR}/${name}.meta" ]; then
    local NAME WORKSPACE CPU MEMORY IP STARTED
    source "${LOG_DIR}/${name}.meta"
    workspace="${WORKSPACE:-}"
  fi

  # nohup + setsid, so fxa-start outlives the exec that started it.
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
  runtime_load || return 1
  local NAME WORKSPACE CPU MEMORY IP STARTED
  if [ -f "${LOG_DIR}/${name}.meta" ]; then
    source "${LOG_DIR}/${name}.meta"
    [ -n "${WORKSPACE:-}" ] && runtime_attach_hook "$WORKSPACE"
  fi

  # `screen -x` multi-attaches, so the orchestrator's attach and an ad-hoc one coexist.
  local ip
  ip="$(vm_ip "$name")"
  local ssh_key="${LOG_DIR}/ssh/${name}/id_ed25519"

  # An attach during setup otherwise falls back to password auth, which is disabled.
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

    local status ram_display
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
  # The name becomes rm -rf paths below; `stop ../..` must not reach outside LOG_DIR.
  [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]] || { echo "ERROR: Invalid name '${name}'." >&2; return 1; }
  # The launcher that watches this slot dies with the VM, or it races a relaunch
  # to commit the same slot. Not a CI watcher: past the PR it only reads GitHub.
  local key; key="$(printf '%s' "$name" | tr 'a-z' 'A-Z')"
  pgrep -f "jira ${key} " 2>/dev/null | while read -r pid; do
    grep -q 'pull/' "$(pipeline_launch_log "$key" 2>/dev/null)" 2>/dev/null || kill "$pid" 2>/dev/null || true
  done || true  # no launcher: pgrep exits 1, and under pipefail and set -e that ended stop before the VM went

  echo "Stopping agent '${name}'..."

  # Stop the agent gracefully through screen.
  vm_exec "$name" sudo -u agent screen -S "${VM_SCREEN_SESSION}" -X quit 2>/dev/null || true
  sleep 2

  vm_stop "$name"
  vm_delete "$name"
  rm -rf "${LOG_DIR}/ssh/${name}" "${LOG_DIR}/profiles/${name}"
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

  # The content server sends strict-transport-security over plain HTTP.
  rm -f "${profile_dir}/SiteSecurityServiceState.bin"

  # Strip the HSTS header in the proxy too, so Firefox never caches it.
  local ssh_key="${LOG_DIR}/ssh/${name}/id_ed25519"
  ssh -i "${ssh_key}" ${VM_SSH_OPTS} "${VM_SSH_USER}@${ip}" bash -c "'
    if [ -f /tmp/fxa-proxy.js ] && ! grep -q \"strict-transport-security\" /tmp/fxa-proxy.js; then
      sed -i \"s/res.writeHead(proxyRes.statusCode, proxyRes.headers);/const h = Object.assign({}, proxyRes.headers); delete h[\\\"strict-transport-security\\\"]; res.writeHead(proxyRes.statusCode, h);/\" /tmp/fxa-proxy.js
      pm2 restart fxa-proxy --silent 2>/dev/null || true
    fi
  '" 2>/dev/null && echo "  Proxy patched: HSTS header stripped." || true

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
      # nginx proxy: add the routes once.
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
      # Legacy Node.js proxy: run a separate server on :9002.
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

  local urls=("http://${ip}:3030")
  if [ -n "${inbox_url}" ]; then
    echo "  Inbox viewer: ${inbox_url}"
    urls+=("${inbox_url}")
  fi
  /Applications/Firefox.app/Contents/MacOS/firefox -profile "${profile_dir}" -no-remote "${urls[@]}" &
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

  rm -rf "${LOG_DIR}/ssh"

  echo "All agents stopped."
}

# ── Run-state introspection ────────────────────────────────────

# agent_ssh_exec <name> <remote-command...>
#   Run a command in the agent's VM over SSH and print its stdout. Returns 1
#   when there is no running VM or no key for it.
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
#   Exit 0 when a real agent process runs in the VM. agent_list shows the screen
#   session, which stays "running" after the agent dies because of `exec bash`.
# Memoised for 20 s per name, since each answer is an ssh through IAP. A string
# cache, not an associative array: macOS ships bash 3.2.
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
  runtime_load || return 1
  local pat; pat="$(runtime_alive_pattern)"
  # Return 2 when ssh fails: one dropped IAP tunnel once read as a dead agent.
  # pgrep -c prints 0 and exits 1 on no match, so `|| echo 0` would print two lines.
  n="$(agent_ssh_exec "$name" "pgrep -cf '${pat}' 2>/dev/null || true" 2>/dev/null \
       | tr -d '\r' | head -1)" || return 2
  n="${n:-0}"
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  [ "$n" -gt 0 ]
}
