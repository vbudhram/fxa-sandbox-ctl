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
  # Serialized: events, steer, and the finish job all write the record, and a
  # lost write can reopen a closed turn. Unique temp name, so writers never share it.
  # A lock older than 10 s belongs to a writer that died; a slow live one is waited for.
  local lock="${f}.wlock" tmp rc=0
  while ! mkdir "$lock" 2>/dev/null; do
    [ -d "$lock" ] && [ $(( $(date +%s) - $(stat -f %m "$lock" 2>/dev/null || date +%s) )) -gt 10 ] && rmdir "$lock" 2>/dev/null
    sleep 0.1
  done
  tmp="$(mktemp "${f}.XXXXXX")"
  jq "${args[@]}" "$filter" "$f" > "$tmp" && mv "$tmp" "$f" || { rc=1; rm -f "$tmp"; }
  rmdir "$lock" 2>/dev/null || true
  return "$rc"
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
  local verify func stack
  verify="$(runtime_skill_ref fxa-verify)"; func="$(runtime_skill_ref fxa-functional-local)"; stack="$(runtime_skill_ref fxa-stack)"
  cat <<EOF
You are pairing with an FxA engineer through a chat thread. Their request is in
/workspace/.fxa-jira-context.md; read it first. The runner's operations guide is
/etc/vm-agent-guide.md.

This turn: investigate, then print a short plan with the cause, the files you
will change, and the tests you will run. Do not edit files yet unless the
request is a one-line change.

Every turn, including later ones:
- Do not commit or push, and do not run 'gh'. The host does that.
- Verify with ${verify}: it runs the right tests and lint for each package.
  For a UI flow use ${func}; for the local stack, ${stack}.
- To show the engineer a screenshot or a video, save it in /workspace/.fxa-auto-media/.
  Files there are posted to the thread when your turn ends.
- When you need a decision, list 2 to 4 choices, one per line, each starting 'OPTION: '.
- End your final message with exactly one line: 'status: needs-input' or
  'status: ready'. Use ready only when the change is done and its tests pass.
EOF
}

# The first turn of a session that continues an earlier one in the same thread.
# The conversation is restored, so this only says what changed underneath it.
_session_resume_prompt() {
  cat <<'EOF'
The engineer came back to this thread, so you are on a new runner. This
conversation and your earlier changes were carried over: run 'git status' and
'git diff' to see them, and do not start over. If a change did not carry over,
it is in /workspace/.fxa-resume.patch. The engineer's new message is in
/workspace/.fxa-jira-context.md; read it, then continue.

The same rules as before apply, including the final 'status:' line.
EOF
}

# _session_history_add <key> <role> <text>   One line of the conversation, kept
# on the host so the dashboard can show it after the runner is gone.
_session_history_add() {
  jq -nc --arg r "$2" --arg t "$3" --arg n "${4:-}" --arg i "${5:-}" \
    '{at: now, role: $r, text: $t} + (if $n != "" then {name: $n} else {} end) + (if $i != "" then {image: $i} else {} end)' \
    >> "${SESSION_DIR}/$1.history.jsonl"
}

# _session_person <name> <image>   Prints "name<TAB>image", each emptied when
# unsafe. The dashboard puts both in a page: only Slack's own avatar hosts pass.
_session_person() {
  local n i; n="$(printf '%s' "${1:-}" | tr -d '[:cntrl:]' | cut -c1-80)"; i="${2:-}"
  [[ "$i" =~ ^https://(avatars\.slack-edge\.com|ca\.slack-edge\.com|secure\.gravatar\.com)/[A-Za-z0-9._~/%?=\&-]+$ ]] || i=""
  printf '%s\t%s\n' "$n" "$i"
}

# session_history <key>   The conversation as a JSON array, oldest first,
# through every session this one resumed from.
session_history() {
  local key="$1" out="[]" chunk n=0
  while [ -n "$key" ] && [ "$n" -lt 20 ] && session_exists "$key"; do
    # The first message is the request; the bot appends earlier thread messages as context.
    chunk="$(jq -n --arg k "$key" --argjson rec "$(cat "$(_session_file "$key")")" \
      --rawfile p <(cat "${SESSION_DIR}/${key}.prompt.md" 2>/dev/null) \
      '[{at: ($rec.created // 0), role: "user", key: $k, text: ($p | split("\n\nEarlier messages")[0])}
        + (if $rec.owner_name then {name: $rec.owner_name} else {} end) + (if $rec.owner_image then {image: $rec.owner_image} else {} end)]
       + [inputs | . + {key: $k}]' <(cat "${SESSION_DIR}/${key}.history.jsonl" 2>/dev/null) 2>/dev/null)" || chunk="[]"
    out="$(jq -c --argjson a "${chunk:-[]}" '$a + .' <<< "$out")"
    key="$(session_get "$key" resume_from)"; n=$(( n + 1 ))
  done
  printf '%s\n' "$out"
}

# The origin repo as an https URL, for a compare link.
_session_repo_url() {
  git -C "$(worktree_repo_root)" remote get-url origin | sed -E 's#^git@github.com:#https://github.com/#; s#\.git$##'
}

_session_wrapup_prompt() {
  local ask="open a PR"; [ "${2:-}" = --no-pr ] && ask="push the branch (no PR yet)"
  cat <<EOF
The engineer asked to ${ask}. Wrap up now:
1. Run $(runtime_skill_ref fxa-review-quick) on 'git diff \$(git merge-base HEAD origin/main)' plus
   untracked files, then $(runtime_skill_ref fxa-vm-selfcheck). Fix every blocker.
2. Revert any file unrelated to the request with 'git checkout -- <path>'.
3. Use $(runtime_skill_ref create-pr-description) on the whole diff, then $(runtime_skill_ref humanizer) on its output.
   pr_body must reuse /workspace/.github/PULL_REQUEST_TEMPLATE.md. There is no
   Jira ticket; leave the ticket field empty and do not name this session.
4. Write /workspace/.fxa-auto-done.json LAST, once the working tree holds exactly
   what should ship, with keys {issue, branch, pr_title, pr_body, media_paths}:
   issue "$1"; branch from 'git branch --show-current'; pr_title a scoped
   conventional commit subject; media_paths relative to /workspace, empty if
   none. Write it to .fxa-auto-done.json.tmp, then mv it into place.
EOF
}

# _session_sh <name> <script>   Run a script on the runner as the agent user.
# vm_exec_as_agent goes through `sudo -i`, which blanks $vars in the script.
_session_sh() { vm_exec "$1" sudo -u agent bash -c "$2"; }

# _session_turn <key> <message>   Start one resumed turn on the runner and return.
_session_turn() {
  local key="$1" msg="$2" name sid tmp
  name="$(worktree_branch_for "$key")"
  sid="$(session_get "$key" claude_session_id)"
  if [ -z "$sid" ]; then
    sid="$(vm_exec_as_agent "$name" "grep -m1 -E '\"(session_id|thread_id)\"' /workspace/.fxa-auto-claude.jsonl" 2>/dev/null | jq -r '.session_id // .thread_id // empty' 2>/dev/null || true)"
    [ -n "$sid" ] || { echo "ERROR: ${key}: no Claude session id on the runner yet." >&2; return 1; }
    session_set "$key" claude_session_id "$sid"
  fi
  tmp="$(mktemp -d)"
  # Every exit below removes $tmp: it holds a copy of the OAuth token.
  ( umask 077
    printf '%s\n' "$msg" > "${tmp}/.fxa-steer-msg.txt"
    printf 'export CLAUDE_CODE_OAUTH_TOKEN=%s\n' "${CLAUDE_CODE_OAUTH_TOKEN:?CLAUDE_CODE_OAUTH_TOKEN is unset}" > "${tmp}/.fxa-auto-token"
    # "--": a message that starts with a dash is text, not a flag.
    if [ "$(session_get "$key" runtime)" = codex ]; then
      # Codex keeps its login in ~/.codex/auth.json on the runner; no token ships.
      : > "${tmp}/.fxa-auto-token"
      cat > "${tmp}/.fxa-steer.sh" <<STEER
export HOME=/home/agent
source /etc/agent-env.sh
cd /workspace
codex exec resume ${sid} --json --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check - < /workspace/.fxa-steer-msg.txt 2>&1 \\
  | tee -a /workspace/.fxa-auto-claude.jsonl
STEER
    else
    cat > "${tmp}/.fxa-steer.sh" <<STEER
export HOME=/home/agent # claude finds the session to resume under \$HOME/.claude
test -f /workspace/.fxa-auto-token && source /workspace/.fxa-auto-token && rm -f /workspace/.fxa-auto-token
source /etc/agent-env.sh
cd /workspace
claude -p --resume ${sid} --permission-mode bypassPermissions \\
  --model ${FXA_AGENT_MODEL:-claude-opus-5-5} --output-format stream-json --verbose -- "\$(cat /workspace/.fxa-steer-msg.txt)" 2>&1 \\
  | tee -a /workspace/.fxa-auto-claude.jsonl
STEER
    fi
  ) || { rm -rf "$tmp"; return 1; }
  # One ssh: unpack the files as the agent and start the turn. Two cost ~1.8 s more.
  # Only the launch is backgrounded: a background job's stdin is /dev/null, so tar must not be in it.
  ( cd "$tmp" && COPYFILE_DISABLE=1 tar --no-xattrs -cf - ./.fxa-steer-msg.txt ./.fxa-auto-token ./.fxa-steer.sh ) \
    | vm_exec "$name" sudo -u agent bash -c 'cd /workspace && tar -xf - && { nohup setsid bash /workspace/.fxa-steer.sh >/dev/null 2>&1 < /dev/null & }' \
    || { rm -rf "$tmp"; return 1; }
  rm -rf "$tmp"
  session_set "$key" turns "$(( $(session_get "$key" turns || echo 0) + 1 ))" turn_open 1 turn_started "$(date +%s)"
}

# session_interrupt <key>   Stop the running turn and keep the session. Claude
# writes what it has on SIGINT, so the next --resume continues from there.
session_interrupt() {
  [ "$(session_get "$1" turn_open)" = 1 ] || { echo "$1 idle"; return 0; }
  _session_lock "$1" || { echo "ERROR: $1 is busy; try again in a moment" >&2; return 1; }
  # Close the turn only once the process is gone: a steer that saw it closed
  # early started a second claude on the same session.
  local rc=0
  _session_sh "$(worktree_branch_for "$1")" "pkill -INT -f '${_SESSION_AGENT_PAT}'
    for i in \$(seq 30); do pgrep -f '${_SESSION_AGENT_PAT}' >/dev/null || exit 0; sleep 0.5; done
    pkill -KILL -f '${_SESSION_AGENT_PAT}'; true" >/dev/null 2>&1 || rc=$?
  # The kill did not reach the runner: the turn is still open.
  [ "$rc" -eq 0 ] || { _session_unlock "$1"; echo "ERROR: $1: could not reach the runner to interrupt" >&2; return 1; }
  session_set "$1" turn_open 0
  _session_unlock "$1"
  echo "$1 interrupted"
}

# session_idle_sweep   Pause every active session with no open turn, nothing
# queued, and no activity for FXA_SESSION_IDLE_SECONDS. Stop saves the work
# and the conversation, and deletes the runner; a reply resumes it.
session_idle_sweep() {
  local f key now idle="${FXA_SESSION_IDLE_SECONDS:-1800}"; now="$(date +%s)"
  for f in "$SESSION_DIR"/agent-*.json; do
    [ -f "$f" ] || continue
    key="$(basename "$f" .json)"
    [ "$(jq -r .state "$f")" = active ] && [ "$(jq -r '.turn_open // "0"' "$f")" != 1 ] || continue
    [ -s "${SESSION_DIR}/${key}.queue" ] && continue
    [ $(( now - $(jq -r '.last_activity // 0 | floor' "$f") )) -ge "$idle" ] || continue
    _session_lock "$key" || continue
    # Recheck under the lock: a steer may have just started a turn.
    if [ "$(session_get "$key" state)" = active ] && [ "$(session_get "$key" turn_open)" != 1 ]; then
      if session_stop "$key"; then session_set "$key" state paused; echo "paused ${key}"; else echo "pause-failed ${key}" >&2; fi
    fi
    _session_unlock "$key"
  done
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
_SESSION_AGENT_PAT='^(claude -p|(node )?[^ ]*codex exec)'
_session_turn_running() {
  local n
  # An unreachable runner counts as running, so a message queues instead of
  # starting a second writer on one session.
  n="$(_session_sh "$(worktree_branch_for "$1")" "pgrep -cf '${_SESSION_AGENT_PAT}' || true" 2>/dev/null | tr -d '\r' | tail -1)" || return 0
  case "$n" in ''|*[!0-9]*) return 0 ;; esac
  [ "$n" -gt 0 ]
}

# One assistant content block → one short step title for what the agent does.
# Its messages are not steps: the reply already shows them.
_SESSION_STEP_JQ='select(.type == "tool_use") | (.input // {}) as $i
  | (($i.file_path // $i.path // "") | tostring | split("/") | last) as $f
  | if .name == "Read" then "Reading " + $f
    elif .name == "Edit" or .name == "MultiEdit" or .name == "Write" then "Editing " + $f
    elif .name == "Grep" then "Searching for \"" + ($i.pattern // "" | tostring) + "\""
    elif .name == "Glob" then "Finding files " + ($i.pattern // "" | tostring)
    elif .name == "Bash" then "Running " + ($i.command // "" | tostring)
    elif .name == "Task" or .name == "Agent" then "Delegating: " + ($i.description // "" | tostring)
    elif .name == "TodoWrite" then "Updating the plan"
    elif .name == "Skill" then "Using /" + ($i.skill // $i.command // "" | tostring)
    else .name end
  | gsub("\\s+"; " ") | .[0:90]'

# _session_activity   stream-json lines on stdin → what the agent did last, one line.
# One Codex item → one step title, in the same words as Claude's.
_SESSION_CODEX_STEP_JQ='if .type == "command_execution" then "Running " + ((.command // "") | tostring | sub("^/bin/(ba)?sh -lc \u0027(?<c>.*)\u0027$"; "\(.c)"; "s"))
  elif .type == "file_change" then "Editing " + (((.changes // [])[0].path // "") | tostring | split("/") | last)
  elif .type == "web_search" then "Searching the web for " + ((.query // "") | tostring)
  elif .type == "mcp_tool_call" then "Using " + ((.tool // "a tool") | tostring)
  else empty end | gsub("\\s+"; " ") | .[0:90]'
# Either agent's event → its steps. Codex commands count when they start; its
# other items (file edits) only exist once complete.
_SESSION_STEPS_JQ="if .type == \"assistant\" then (.message.content[]? | ${_SESSION_STEP_JQ})
  elif (.type == \"item.started\" and .item.type == \"command_execution\")
    or (.type == \"item.completed\" and ((.item.type // \"\") | IN(\"command_execution\", \"agent_message\", \"reasoning\") | not))
  then (.item | ${_SESSION_CODEX_STEP_JQ})
  else empty end"

_session_activity() {
  jq -R -s -r "split(\"\\n\") | map(fromjson? | ${_SESSION_STEPS_JQ}) | last // \"\"" 2>/dev/null
}

# _session_watch <key>   Stream the running turn as JSON lines, as they happen:
# {type: "step", text} per tool call or message, {type: "result"} at the turn's end.
# Runs until the caller kills it or the runner goes away.
_session_watch() {
  _session_sh "$(worktree_branch_for "$1")" 'timeout 1800 tail -n 0 -F /workspace/.fxa-auto-claude.jsonl 2>/dev/null' \
    | jq --unbuffered -R -c "fromjson? | if .type == \"result\" or .type == \"turn.completed\" then {type: \"result\"}
        else (${_SESSION_STEPS_JQ} | {type: \"step\", text: .}) end"
}

# _session_boot_step <key>   The runner's boot progress in plain words.
_session_boot_step() {
  case "$(grep -E '^(Creating GCE|Waiting for ssh|Waiting for fxa-gce-checkout|Waiting for infrastructure|Pinning the runner|Applying security|Shipping|Starting claude)' "${SESSION_DIR}/$1.log" 2>/dev/null | tail -1)" in
    Creating*) echo "creating a sandbox" ;;
    "Waiting for ssh"*) echo "waiting for the sandbox to boot" ;;
    *checkout*|*infrastructure*|Pinning*) echo "checking out main" ;;
    Applying*|Shipping*) echo "locking down the sandbox" ;;
    Starting*) echo "starting the agent" ;;
    *) echo "preparing" ;;
  esac
}

# _session_parse   stream-json lines on stdin → event objects, one per line.
# The final text of a turn → a question (OPTION: lines) or a turn end with its
# status: line. Both agents end a turn with such text.
_SESSION_FIN_JQ='def fin($t): ($t | tostring) as $t
  | ($t | [scan("(?m)^status: *(needs-input|ready) *$")] | last // ["needs-input"] | .[0]) as $status
  | ($t | [scan("(?m)^OPTION: *(.+)$")] | map(.[0])) as $opts
  | ($t | gsub("(?m)^(status:.*|OPTION:.*)\n?"; "") | sub("\\s+$"; "")) as $body
  | if ($opts | length) > 0 then {type: "question", text: $body, options: $opts}
    else {type: "turn_end", status: $status, text: $body} end;'
_session_parse() {
  # Claude ends a turn with one result event. Codex sends its message (say) and
  # the turn end (turn_done) separately; _session_fold joins them.
  jq -R -c "${_SESSION_FIN_JQ} fromjson? |
    if .type == \"result\" then fin(.result // \"\")
    elif .type == \"system\" and .subtype == \"init\" then {type: \"init\", session_id: .session_id}
    elif .type == \"thread.started\" then {type: \"init\", session_id: .thread_id}
    elif .type == \"item.completed\" and .item.type == \"agent_message\" then {type: \"say\", text: (.item.text // \"\")}
    elif .type == \"turn.completed\" then {type: \"turn_done\"}
    elif .type == \"turn.failed\" or .type == \"error\" then {type: \"error\", text: ((.error.message // .message // \"the agent failed\") | tostring)}
    else empty end" 2>/dev/null
}

# _session_fold <last say>   A parsed event array on stdin → {events, last}: each
# Codex turn_done becomes its turn end, built from the last message said, which
# may have arrived in an earlier poll.
_session_fold() {
  jq -c --arg last "$1" "${_SESSION_FIN_JQ}
    reduce .[] as \$e ({events: [], last: \$last};
      if \$e.type == \"say\" then .last = \$e.text
      elif \$e.type == \"turn_done\" then .events += [fin(.last)] | .last = \"\"
      else .events += [\$e] end)"
}

# session_media <key> <dir>   Copy the images and videos the agent saved in
# /workspace/.fxa-auto-media into <dir>, and list them. Media types only, top
# level only, under 20 MB each: the agent picks these names.
session_media() {
  local key="$1" out="$2"
  mkdir -p "$out" || return 1
  _session_sh "$(worktree_branch_for "$key")" 'cd /workspace/.fxa-auto-media 2>/dev/null || exit 0
    find . -maxdepth 1 -type f -size -20M \( -iname "*.png" -o -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.gif" \
      -o -iname "*.webp" -o -iname "*.webm" -o -iname "*.mp4" \) -print0 | tar -cf - --null -T -' \
    | tar -xf - -C "$out" 2>/dev/null
  # Playwright records WebM, which Slack does not play inline (iOS not at all).
  # H.264 MP4 plays everywhere; the scale keeps both sides even, as x264 needs.
  local f
  if command -v ffmpeg >/dev/null 2>&1; then
    for f in "$out"/*.webm; do
      [ -f "$f" ] || continue
      ffmpeg -nostdin -y -loglevel error -i "$f" -c:v libx264 -pix_fmt yuv420p -movflags +faststart \
        -vf 'scale=trunc(iw/2)*2:trunc(ih/2)*2' -an "${f%.webm}.mp4" && rm -f "$f"
    done
  fi
  find "$out" -maxdepth 1 -type f
}

# A request about how something looks needs the stack; starting it at boot
# saves the agent the few minutes fxa-start takes.
_session_wants_stack() {
  grep -qiE 'screenshot|video|record|visual|look(s)? like|page|button|\bui\b|render|layout|style|css|storybook' \
    "${SESSION_DIR}/$1.prompt.md" 2>/dev/null
}
_SESSION_STACK_NOTE='
The FxA stack is starting in the background (log: /workspace/.fxa-auto-stack-start.log).
Before you use it, wait until curl -sf http://localhost:9000/__heartbeat__ succeeds.'

# Sessions hold no pool slot. The run files are staged here and shipped to the
# runner; the runner holds the work until Open PR or stop.
session_run_dir() { printf '%s/%s.run' "$SESSION_DIR" "$1"; }

# session_stop <key>   Save the runner's work as a patch, then delete the runner.
# Resume and recovery apply it with `git apply --index`.
session_stop() {
  local key="$1" name; name="$(worktree_branch_for "$key")"
  # First, so a boot still in progress sees it and takes its own runner down.
  session_set "$key" state stopped
  if vm_is_running "$name" 2>/dev/null; then
    # ai/ is ignored on the host but not in the runner's clone; the runner is going away.
    vm_exec_as_agent "$name" "cd /workspace && rm -rf ai && git add -A -N -- . ':(exclude).fxa-*' && git diff --binary HEAD -- . ':(exclude).fxa-*'" \
      > "${SESSION_DIR}/${key}.patch" 2>/dev/null || rm -f "${SESSION_DIR}/${key}.patch"
    [ -s "${SESSION_DIR}/${key}.patch" ] || rm -f "${SESSION_DIR}/${key}.patch"
    # The conversation too, so a later session in the thread can --resume it.
    _session_sh "$name" 'cd /home/agent && tar -czf - $(ls -d .claude/projects .codex/sessions 2>/dev/null)' > "${SESSION_DIR}/${key}.claude.tgz" 2>/dev/null || true
    [ -s "${SESSION_DIR}/${key}.claude.tgz" ] || rm -f "${SESSION_DIR}/${key}.claude.tgz"
  fi
  # No runner yet (still booting) is fine; a runner that will not go away is not.
  agent_stop "$name" >&2 || { vm_exists "$name" 2>/dev/null && return 1; }
  return 0
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
