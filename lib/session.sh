#!/bin/bash
# session.sh — owner-steered agent sessions with no Jira ticket (the Slack front door).
# A session is one branch named after its key and one Claude session on a GCE
# runner, with no pool slot. Each steer turn is `claude -p --resume` there.
# The record under FXA_SESSION_DIR is the only state; the bot keeps none.

SESSION_DIR="${FXA_SESSION_DIR:-${HOME}/.claude/state/agent-sessions}"

_session_file() { printf '%s/%s.json' "$SESSION_DIR" "$1"; }
session_exists() { [ -f "$(_session_file "$1")" ]; }
session_get() { jq -r --arg f "$2" '.[$f] // empty' "$(_session_file "$1")" 2>/dev/null; }
# session_set <key> <field> <value>...   Atomic rewrite; last_activity always moves.
session_set() {
  local key="$1" f; f="$(_session_file "$key")"; shift
  local args=() filter='.last_activity = now'
  while [ $# -ge 2 ]; do
    args+=(--arg "k$#" "$1" --arg "v$#" "$2")
    filter="${filter} | .[\$k$#] = \$v$#"
    shift 2
  done
  jq "${args[@]}" "$filter" "$f" > "${f}.tmp" && mv "${f}.tmp" "$f"
}
# A session that still owns its runner. reap --stray must leave these alone.
session_live() {
  session_exists "$1" || return 1
  case "$(session_get "$1" state)" in starting|active|wrapping) return 0 ;; esac
  return 1
}

# The first turn. Not a /goal: the owner judges done by steering, and the host
# checks the work at Open PR.
_session_first_prompt() {
  cat <<'EOF'
You are pairing with an FxA engineer through a chat thread. Their request is in
/workspace/.fxa-jira-context.md; read it first. Project conventions are in
/workspace/ai/AGENTS.md and /etc/vm-agent-guide.md.

This turn: investigate, then print a short plan with the cause, the files you
will change, and the tests you will run. Do not edit files yet unless the
request is a one-line change.

Every turn, including later ones:
- Do not commit or push, and do not run 'gh'. The host does that.
- Run only the spec files beside what you change. CI runs the full suite.
- When you need a decision, list 2 to 4 choices, one per line, each starting 'OPTION: '.
- End your final message with exactly one line: 'status: needs-input' or
  'status: ready'. Use ready only when the change is done and its tests pass.
EOF
}

_session_wrapup_prompt() {
  cat <<EOF
The engineer asked to open a PR. Wrap up now:
1. Run /fxa-review-quick on 'git diff \$(git merge-base HEAD origin/main)' plus
   untracked files, then /fxa-vm-selfcheck. Fix every blocker.
2. Revert any file unrelated to the request with 'git checkout -- <path>'.
3. Invoke /create-pr-description on the whole diff, then /humanizer on its output.
   pr_body must reuse /workspace/.github/PULL_REQUEST_TEMPLATE.md. There is no
   Jira ticket; leave the ticket field empty and do not name this session.
$(runtime_prompt_handoff_step | sed "s/^9\. /4. /")
Use "$1" as the issue value.
EOF
}

# _session_ship <name> <file>...   Copy host files into /workspace as the agent,
# over stdin. No chown -R: that walks node_modules on every turn.
_session_ship() {
  local name="$1"; shift
  local dir; dir="$(dirname "$1")"
  local -a rel=(); local f; for f in "$@"; do rel+=("./$(basename "$f")"); done
  COPYFILE_DISABLE=1 tar --no-xattrs -cf - -C "$dir" "${rel[@]}" \
    | vm_exec "$name" sudo -u agent tar -xf - -C /workspace
}

# _session_turn <key> <message>   Start one resumed turn on the runner and return.
_session_turn() {
  local key="$1" msg="$2" name sid tmp
  name="$(worktree_branch_for "$key")"
  sid="$(session_get "$key" claude_session_id)"
  if [ -z "$sid" ]; then
    sid="$(vm_exec_as_agent "$name" "grep -m1 '\"session_id\"' /workspace/.fxa-auto-claude.jsonl" 2>/dev/null | jq -r '.session_id // empty' 2>/dev/null)"
    [ -n "$sid" ] || { echo "ERROR: ${key}: no Claude session id on the runner yet." >&2; return 1; }
    session_set "$key" claude_session_id "$sid"
  fi
  tmp="$(mktemp -d)"
  ( umask 077
    printf '%s\n' "$msg" > "${tmp}/.fxa-steer-msg.txt"
    printf 'export CLAUDE_CODE_OAUTH_TOKEN=%s\n' "${CLAUDE_CODE_OAUTH_TOKEN:?CLAUDE_CODE_OAUTH_TOKEN is unset}" > "${tmp}/.fxa-auto-token"
    cat > "${tmp}/.fxa-steer.sh" <<STEER
test -f /workspace/.fxa-auto-token && source /workspace/.fxa-auto-token && rm -f /workspace/.fxa-auto-token
source /etc/agent-env.sh
cd /workspace
claude -p "\$(cat /workspace/.fxa-steer-msg.txt)" --resume ${sid} --permission-mode bypassPermissions \\
  --model ${FXA_AGENT_MODEL:-claude-opus-5-5} --output-format stream-json --verbose 2>&1 \\
  | tee -a /workspace/.fxa-auto-claude.jsonl
STEER
  )
  _session_ship "$name" "${tmp}/.fxa-steer-msg.txt" "${tmp}/.fxa-auto-token" "${tmp}/.fxa-steer.sh"; local rc=$?
  rm -rf "$tmp"
  [ "$rc" -eq 0 ] || return 1
  vm_exec_as_agent "$name" "nohup setsid bash /workspace/.fxa-steer.sh >/dev/null 2>&1 < /dev/null &" || return 1
  session_set "$key" turns "$(( $(session_get "$key" turns || echo 0) + 1 ))" turn_open 1 turn_started "$(date +%s)"
}

# _session_lock <key>   One writer per session: steer, the queue drain, and Open PR
# all start turns. A lock older than 2 min belongs to a crashed holder.
_session_lock() {
  local d="${SESSION_DIR}/$1.lock"
  [ -d "$d" ] && [ $(( $(date +%s) - $(stat -f %m "$d") )) -gt 120 ] && rmdir "$d" 2>/dev/null
  mkdir "$d" 2>/dev/null
}
_session_unlock() { rmdir "${SESSION_DIR}/$1.lock" 2>/dev/null; }

# _session_turn_running <key>   0 running, 1 idle. A dropped tunnel reads as running,
# so a message queues rather than starting a second writer on one session.
_session_turn_running() {
  local rc; agent_alive "$(worktree_branch_for "$1")"; rc=$?
  [ "$rc" -ne 1 ]
}

# _session_parse   stream-json lines on stdin → event objects, one per line.
_session_parse() {
  jq -c '
    if .type == "result" then
      (.result // "" | tostring) as $t
      | ($t | [scan("(?m)^status: *(needs-input|ready) *$")] | last // ["needs-input"] | .[0]) as $status
      | ($t | [scan("(?m)^OPTION: *(.+)$")] | map(.[0])) as $opts
      | ($t | gsub("(?m)^(status:.*|OPTION:.*)\n?"; "") | sub("\\s+$"; "")) as $body
      | if ($opts | length) > 0 then {type: "question", text: $body, options: $opts}
        else {type: "turn_end", status: $status, text: $body} end
    elif .type == "system" and .subtype == "init" then {type: "init", session_id: .session_id}
    else empty end' 2>/dev/null
}

# Sessions hold no pool slot. The run files are staged here and shipped to the
# runner; the runner holds the work until Open PR or stop.
session_run_dir() { printf '%s/%s.run' "$SESSION_DIR" "$1"; }

# session_stop <key>   Save the runner's work as a patch, then delete the runner.
# Resume and recovery apply it with `git apply --index`.
session_stop() {
  local key="$1" name; name="$(worktree_branch_for "$key")"
  if vm_is_running "$name" 2>/dev/null; then
    # ai/ is ignored on the host but not in the runner's clone; the runner is going away.
    vm_exec_as_agent "$name" "cd /workspace && rm -rf ai && git add -A -N -- . ':(exclude).fxa-*' && git diff --binary HEAD -- . ':(exclude).fxa-*'" \
      > "${SESSION_DIR}/${key}.patch" 2>/dev/null || rm -f "${SESSION_DIR}/${key}.patch"
    [ -s "${SESSION_DIR}/${key}.patch" ] || rm -f "${SESSION_DIR}/${key}.patch"
  fi
  agent_stop "$name" >&2 || return 1
  session_set "$key" state stopped
}

# session_checkout <key> <dir>   A throwaway worktree on the session branch at its
# base, holding the runner's tree, for the host-side commit and push. Hooks off:
# the post-checkout hook clones l10n. node_modules is the main checkout's, for
# the check-frozen step; **/node_modules in .gitignore keeps the link out of git.
session_checkout() {
  local key="$1" dir="$2" root name
  root="$(worktree_repo_root)" || return 1
  name="$(worktree_branch_for "$key")"
  git -C "$root" -c core.hooksPath=/dev/null worktree add --quiet -B "$key" "$dir" "$(session_get "$key" base_sha)" >&2 || return 1
  ln -s "${root}/node_modules" "${dir}/node_modules"
  vm_pull_tree "$name" /workspace "$dir"
}

session_checkout_remove() {
  git -C "$(worktree_repo_root)" worktree remove --force "$1" >&2 2>/dev/null || rm -rf "$1"
}
