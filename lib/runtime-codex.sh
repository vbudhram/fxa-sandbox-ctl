#!/bin/bash
# runtime-codex.sh — OpenAI Codex as the agent inside the VM.
#
# Same contract as runtime-claude.sh. The shape differs in one way that matters:
# `codex exec` is a subprocess that exits on its final message. There is no TUI,
# so no prompt to paste and no stuck-prompt state, and `--output-schema` makes
# that final message the handoff JSON, written by Codex itself. The handoff
# cannot be forgotten or overrun, which is the failure class Claude runs hit.

[ -n "${_FXA_RUNTIME_LOADED:-}" ] && return 0
_FXA_RUNTIME_LOADED=codex

# The list of skills is shared with Claude: same SKILL.md format, same allow-list
# reasoning (no gh, no acli, no MCP in the VM). Only the destination differs.
runtime_setup_config() {
  local name="$1" full_name
  full_name="$(vm_name "$name")"

  # config.toml carries what Claude passes as flags. Both projects paths are
  # trusted because /workspace is a symlink into /mnt/shared and Codex records
  # trust by resolved path. approval_policy=never plus the launch flag below is
  # the Codex form of bypassPermissions; the VM is the sandbox, as today.
  local config_b64
  config_b64="$(cat <<TOML | base64 | tr -d '\n'
model = "${FXA_CODEX_MODEL:-gpt-6-astra}"
approval_policy = "never"
sandbox_mode = "danger-full-access"

[projects."/workspace"]
trust_level = "trusted"

[projects."/mnt/shared/workspace"]
trust_level = "trusted"
TOML
)"
  # AGENTS.md is Codex's CLAUDE.md. The host's global one comes first, then the
  # same pointers the Claude VM section gives, so both runtimes read one guide.
  local agents_b64 host_agents=""
  [ -f "${CODEX_HOME_DIR}/AGENTS.md" ] && host_agents="$(cat "${CODEX_HOME_DIR}/AGENTS.md")"
  agents_b64="$(printf '%s\n\n%s\n' "$host_agents" '# FxA sandbox VM

You are inside the FxA sandbox VM. The mounted worktree is /workspace.
Read /etc/vm-agent-guide.md for the operations manual (port map, architecture, gotchas).
Fallback quick-reference: /etc/vm-agent-context.md.
Project conventions: /workspace/ai/AGENTS.md.' | base64 | tr -d '\n')"

  vm_exec "$name" sudo bash -c "
    mkdir -p /home/agent/.codex/skills
    echo '${config_b64}' | base64 -d > /home/agent/.codex/config.toml
    echo '${agents_b64}' | base64 -d > /home/agent/.codex/AGENTS.md
    chown -R agent:agent /home/agent/.codex
    chmod 700 /home/agent/.codex
  " 2>/dev/null || { echo "ERROR: could not write Codex config into the VM." >&2; return 1; }

  # Skills ship from the same host directory Claude's do; only the target moves.
  local skills_tar tar_items=() s
  skills_tar="$(mktemp -t fxa-codex-skills.XXXX.tar)"
  for s in $(_vm_skill_allowlist); do
    [ -d "${CLAUDE_HOME_DIR}/skills/${s}" ] && tar_items+=("skills/${s}")
  done
  if [ "${#tar_items[@]}" -gt 0 ] \
     && tar -cf "$skills_tar" -C "$CLAUDE_HOME_DIR" "${tar_items[@]}" 2>/dev/null; then
    local ssh_key="${LOG_DIR}/ssh/${name}/id_ed25519" ip
    ip="$(vm_ip "$name")"
    if scp -i "$ssh_key" ${VM_SSH_OPTS} "$skills_tar" "${VM_SSH_USER}@${ip}:/tmp/fxa-codex-skills.tar" 2>/dev/null; then
      ssh -i "$ssh_key" ${VM_SSH_OPTS} "${VM_SSH_USER}@${ip}" "
        tar -xf /tmp/fxa-codex-skills.tar -C /home/agent/.codex/ && rm -f /tmp/fxa-codex-skills.tar
      " 2>/dev/null || echo "  WARN: extracting Codex skills in VM failed" >&2
    else
      echo "  WARN: scp of Codex skills failed" >&2
    fi
  fi
  rm -f "$skills_tar"
}

# auth.json holds ChatGPT OAuth tokens. The access token lives ~10 days and Codex
# refreshes it from the refresh token when it expires. Whether that refresh
# rotates the refresh token is unverified, and if it does, a refresh inside the
# VM would log the host out. So never let a run straddle the expiry: decode the
# JWT exp here and refuse to launch when too little remains. Running `codex`
# once on the host refreshes it where the host keeps the result.
runtime_inject_auth() {
  local workspace_dir="$1" auth="${CODEX_HOME_DIR}/auth.json"
  if [ ! -f "$auth" ]; then
    echo "ERROR: ${auth} not found. Run 'codex login' on the host first." >&2
    echo "       A VM cannot log in interactively, so Codex refuses to launch without it." >&2
    return 1
  fi
  local hours_left min_hours="${FXA_CODEX_MIN_TOKEN_HOURS:-3}"
  hours_left="$(python3 - "$auth" <<'PY' 2>/dev/null
import sys, json, base64, time
t = json.load(open(sys.argv[1]))["tokens"]["access_token"]
p = t.split(".")[1]; p += "=" * (-len(p) % 4)
print(int((json.loads(base64.urlsafe_b64decode(p))["exp"] - time.time()) // 3600))
PY
)" || hours_left=""
  if [ -z "$hours_left" ]; then
    echo "ERROR: could not read the access token expiry from ${auth}." >&2
    return 1
  fi
  if [ "$hours_left" -lt "$min_hours" ]; then
    echo "ERROR: Codex access token expires in ${hours_left}h (floor ${min_hours}h)." >&2
    echo "       Run 'codex exec \"say ok\"' on the host to refresh it there, then relaunch." >&2
    return 1
  fi
  echo "Staging Codex auth (token valid ${hours_left}h)..."
  install -m 600 "$auth" "${workspace_dir}/.fxa-auto-codex-auth.json"
}

# The prompt keeps its newlines: it is read from stdin, not pasted into a TUI.
# The schema rides along so a run never depends on the image for it.
runtime_write_prompt() {
  local prompt="$1" workspace_dir="$2"
  printf '%s\n' "$prompt" > "${workspace_dir}/.fxa-auto-prompt.txt"
  cp "${SCRIPT_DIR}/templates/handoff.schema.json" "${workspace_dir}/.fxa-auto-handoff.schema.json"
}

# Runs inside screen's `bash -c '<cmd>; exec bash'`, so no single quotes here.
# stdin is redirected explicitly: codex exec blocks forever on an open non-TTY
# stdin. The handoff lands in .tmp and is moved only when non-empty, keeping the
# atomic guarantee _handoff_settled relies on. tee keeps a durable log; screen
# scrollback dies with the session.
runtime_launch_cmd() {
  printf '%s' "test -f /workspace/.fxa-auto-codex-auth.json && mkdir -p /home/agent/.codex && mv /workspace/.fxa-auto-codex-auth.json /home/agent/.codex/auth.json && chmod 600 /home/agent/.codex/auth.json; source /etc/agent-env.sh; cd /workspace; codex exec --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check -C /workspace --output-schema /workspace/.fxa-auto-handoff.schema.json -o /workspace/.fxa-auto-done.json.tmp < /workspace/.fxa-auto-prompt.txt 2>&1 | tee -a /workspace/.fxa-auto-agent.log; test -s /workspace/.fxa-auto-done.json.tmp && mv /workspace/.fxa-auto-done.json.tmp /workspace/.fxa-auto-done.json"
}

runtime_submit_prompt() {
  echo "Prompt delivered on stdin at launch; nothing to submit." >&2
  return 0
}

runtime_alive_pattern() { printf '%s' '^codex exec'; }

runtime_prompt_header() {
  local key="$1" summary="$2"
  cat <<HDR
Resolve Jira issue ${key} ("${summary}"). Full ticket context is in
/workspace/.fxa-jira-context.md — read it first. Project conventions are in
/workspace/ai/AGENTS.md and /etc/vm-agent-guide.md.
HDR
}

# Codex writes the handoff itself: its final message is captured under the
# schema. The prompt must therefore forbid writing the file and forbid any
# trailing prose, which would otherwise become part of the "final message".
runtime_prompt_handoff_step() {
  cat <<'STEP'
9. Your FINAL message must be ONLY the handoff JSON object with keys
   {issue, branch, pr_title, pr_body, media_paths}, and nothing else: no prose
   before it, none after it. The launcher captures that final message as the
   handoff, so do NOT write /workspace/.fxa-auto-done.json yourself. Omit
   commit_sha; the host creates the commit. pr_title is the commit subject the
   host will use (scoped conventional, e.g. 'fix(settings): handle cached signin
   state'); put the Jira key in pr_body, never the title. media_paths lists
   paths relative to /workspace, empty if none. Send that message only when the
   working tree holds exactly what should ship, because sending it ends the run.
STEP
}

runtime_skill_ref() { printf 'the `%s` skill' "$1"; }

runtime_prompt_max_chars() { printf '0'; }

# Nothing to do on attach. Only the launch consumes and deletes the staged
# auth.json; re-staging it here would leave the tokens at rest in the worktree.
runtime_attach_hook() { return 0; }
