#!/bin/bash
# runtime-claude.sh — Claude Code as the agent inside the VM.
#
# The runtime contract. Every lib/runtime-<name>.sh defines these, and
# agent.sh calls only these; nothing else in the tree may branch on the runtime.
#   runtime_setup_config <name>            prepare the agent's $HOME config in the VM
#   runtime_inject_auth <workspace>        stage credentials in the workspace
#   runtime_write_prompt <prompt> <ws>     write the prompt (and any sidecar) into <ws>
#   runtime_launch_cmd                     print the shell string screen runs
#   runtime_submit_prompt <full> <name>    deliver the prompt after launch, if needed
#   runtime_alive_pattern                  pgrep -f pattern for a live agent process
#   runtime_prompt_header <key> <summary>  first lines of the rendered prompt
#   runtime_prompt_handoff_step            step 9 of the prompt: how to hand off
#   runtime_skill_ref <skill>              how the prompt names a skill
#   runtime_prompt_max_chars               0 = unlimited
#
# Claude's pieces already exist in agent.sh; this file only maps the contract
# onto them so the two launch sites stop carrying their own copies.

[ -n "${_FXA_RUNTIME_LOADED:-}" ] && return 0
_FXA_RUNTIME_LOADED=claude

runtime_setup_config() { _setup_claude_config "$1"; }

runtime_inject_auth() {
  local workspace_dir="$1"
  local oauth_token="${CLAUDE_CODE_OAUTH_TOKEN:-}"
  if [ -n "$oauth_token" ]; then
    echo "Injecting Claude OAuth token..."
    _inject_oauth_token "$workspace_dir" "$oauth_token"
  else
    echo "NOTE: Set CLAUDE_CODE_OAUTH_TOKEN on the host to auto-authenticate agents."
    echo "      Generate one with: claude setup-token"
  fi
}

# The prompt keeps its newlines: `claude -p` takes it as an argument, so there
# is no TUI to paste into and nothing to submit. The paste was the worst failure
# shape in the system (FXA-10214 idled 15 min, FXA-14104 57 min, both looking
# healthy), and /goal works the same in -p mode.
#
# The launch is a script, not an inline string: it runs `claude -p "$(cat
# prompt)"`, and that $(...) must expand inside the VM, not on the host where
# agent.sh builds the screen command line inside double quotes.
#
# Prompt on stdin was tried and rejected: a SessionStart hook consumes stdin and
# claude then reports "Input must be provided". The argument form is immune.
#
# FXA_AGENT_EFFORT is unset by default, so the CLI keeps its own default and
# this changes nothing. Set it (low, medium, high, xhigh, max) to sweep effort.
# Set it once per run: a mid-session change invalidates the prompt cache, and
# cache reads are 63% of what a run costs.
runtime_write_prompt() {
  local prompt="$1" workspace_dir="$2"
  local effort=""
  [ -n "${FXA_AGENT_EFFORT:-}" ] && effort=" --effort ${FXA_AGENT_EFFORT}"
  printf '%s\n' "$prompt" > "${workspace_dir}/.fxa-auto-prompt.txt"
  cat > "${workspace_dir}/.fxa-auto-launch.sh" <<LAUNCH
test -f /workspace/.fxa-auto-token && source /workspace/.fxa-auto-token && rm -f /workspace/.fxa-auto-token
source /etc/agent-env.sh
cd /workspace
claude -p "\$(cat /workspace/.fxa-auto-prompt.txt)" --permission-mode bypassPermissions \\
  --model ${FXA_AGENT_MODEL:-claude-opus-5-5}${effort} --output-format stream-json --verbose 2>&1 \\
  | tee -a /workspace/.fxa-auto-claude.jsonl
LAUNCH
}

# Runs inside screen's `bash -c '<cmd>; exec bash'`, so no single quotes here.
# screen stays as the supervisor: attach, tail, and alive are unchanged. The
# JSONL is the durable transcript; screen scrollback dies with the session.
runtime_launch_cmd() { printf '%s' "bash /workspace/.fxa-auto-launch.sh"; }

runtime_submit_prompt() {
  echo "Prompt passed to claude -p at launch; nothing to submit." >&2
  return 0
}

runtime_alive_pattern() { printf '%s' '^claude -p'; }

runtime_prompt_header() {
  local key="$1" summary="$2"
  cat <<HDR
/goal Resolve Jira issue ${key} ("${summary}"). Full ticket context is in
/workspace/.fxa-jira-context.md — read it first. Project conventions are in
/workspace/ai/AGENTS.md and /etc/vm-agent-guide.md.
HDR
}

runtime_prompt_handoff_step() {
  cat <<'STEP'
9. Write /workspace/.fxa-auto-done.json LAST, once your changes are final, with
   keys {issue, branch, pr_title, pr_body, media_paths}. Omit commit_sha; the host
   creates the commit. pr_title is the commit subject the host will use (scoped
   conventional, e.g. 'fix(settings): handle cached signin state'); put the Jira
   key in pr_body, never the title. media_paths lists paths relative to
   /workspace, empty if none. Writing this file is your DONE signal, so write it
   only when the working tree holds exactly what should ship. Write to
   /workspace/.fxa-auto-done.json.tmp then 'mv' it into place, so the host never
   reads a half-written file. Print 'cat
   /workspace/.fxa-auto-done.json | jq .' at the end.
STEP
}

runtime_skill_ref() { printf '/%s' "$1"; }

# Claude Code rejects a /goal over 4000 chars. In -p mode the run then ends at
# once with num_turns 0 and no error flag; `progress` reports it as goal-rejected.
runtime_prompt_max_chars() { printf '%s' "${FXA_GOAL_MAX_CHARS:-4000}"; }

# A human attaching to the TUI may need to re-authenticate, so the token is
# re-staged. Existing behaviour, kept as-is.
runtime_attach_hook() {
  local workspace_dir="$1"
  [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && _inject_oauth_token "$workspace_dir" "$CLAUDE_CODE_OAUTH_TOKEN"
  return 0
}
