#!/bin/bash
# runtime-claude.sh: Claude Code as the agent inside the VM.
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
  local workspace_dir="$1" run="${2:-}"
  if _claude_auth_line >/dev/null; then
    _inject_claude_auth "$workspace_dir" "$run"
  else
    echo "NOTE: Set ANTHROPIC_API_KEY (billed per token) or CLAUDE_CODE_OAUTH_TOKEN"
    echo "      (a subscription's 'claude setup-token') on the host to authenticate agents."
  fi
}

# `claude -p` takes the prompt as an argument, newlines intact. A TUI paste let
# runs idle up to 57 min while they looked healthy; /goal works the same in -p.
# The launch is a script so that $(cat prompt) expands in the VM, not on the host
# inside agent.sh's double quotes. Not stdin: a SessionStart hook consumes it.
# FXA_AGENT_EFFORT (unset: the CLI default) must stay fixed for a run: a change
# invalidates the prompt cache, and cache reads are 63% of a run's cost.
runtime_write_prompt() {
  local prompt="$1" workspace_dir="$2"
  local effort=""
  [ -n "${FXA_AGENT_EFFORT:-}" ] && effort=" --effort ${FXA_AGENT_EFFORT}"
  printf '%s\n' "$prompt" | slot_write "${workspace_dir}/.fxa-auto-prompt.txt"
  local partial="" out="tee -a /workspace/.fxa-auto-claude.jsonl"
  [ "${FXA_SESSION_MODE:-}" = 1 ] && { partial="$_SESSION_CLAUDE_PARTIAL"; out=": > /workspace/.fxa-auto-stream.jsonl; ${_SESSION_CLAUDE_SPLIT}"; }
  # A team stack: each repo's CLAUDE.md, rules, skills and agents load (lib/trees.sh).
  local trees; trees="$({ trees_claude_flags < "${workspace_dir}/.fxa-trees.tsv"; } 2>/dev/null || true)"
  slot_write "${workspace_dir}/.fxa-auto-launch.sh" <<LAUNCH
test -f /workspace/.fxa-auto-token && source /workspace/.fxa-auto-token && rm -f /workspace/.fxa-auto-token
source /etc/agent-env.sh
${_MCP_LAUNCH_SNIPPET}
cd /workspace
${trees:+export CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1}
claude -p "\$(cat /workspace/.fxa-auto-prompt.txt)"${FXA_CLAUDE_RESUME:+ --resume ${FXA_CLAUDE_RESUME}} --permission-mode bypassPermissions${_MCP_CLAUDE_FLAGS}${trees} \\
  --model ${FXA_AGENT_MODEL:-claude-opus-5-5}${effort} --output-format stream-json --verbose${partial} 2>&1 \\
  | { ${out}; }
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
   keys {issue, branch, pr_title, pr_body, commit_body, media_paths}. Omit commit_sha; the host
   creates the commit. pr_title is the commit subject the host will use (scoped
   conventional, e.g. 'fix(settings): handle cached signin state'); put the Jira
   key in pr_body, never the title. commit_body is the short commit body:
   'Because:', 'This commit:' and 'Closes FXA-N', at most 15 lines. media_paths lists paths relative to
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

# A human attaching to the TUI may need to re-authenticate, so the credential is re-staged.
runtime_attach_hook() {
  local workspace_dir="$1"
  _claude_auth_line >/dev/null && _inject_claude_auth "$workspace_dir" "${2:-}"
  return 0
}
