#!/bin/bash
# session.sh: owner-steered agent sessions with no Jira ticket (the Slack front door).
# A session is one branch named after its key and one Claude session on a GCE
# runner, with no pool slot. Each steer turn is `claude -p --resume` there.
# The record under FXA_SESSION_DIR is the only state; the bot keeps none.

SESSION_DIR="${FXA_SESSION_DIR:-${HOME}/.claude/state/agent-sessions}"

_session_file() { printf '%s/%s.json' "$SESSION_DIR" "$1"; }
session_exists() { [ -f "$(_session_file "$1")" ]; }
session_get() { jq -r --arg f "$2" '.[$f] // empty' "$(_session_file "$1")" 2>/dev/null; }
# _session_db_sync <key>   Mirror the record to the store, or drop its row when the file is gone.
_session_db_sync() { declare -F db_session >/dev/null && db_session "$1" "$(_session_file "$1")"; return 0; }
# _session_records   Every record, one JSON per line, in key order: from the store when it is up.
_session_records() {
  if declare -F db_on >/dev/null && db_on; then _db -list "SELECT data FROM sessions ORDER BY key;"
  else local f; for f in "$SESSION_DIR"/agent-*.json; do [ -f "$f" ] && cat "$f"; done; fi
  return 0
}
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
  # lost write can reopen a closed turn. A lock older than 10 s belongs to a dead writer.
  local lock="${f}.wlock" tmp rc=0
  while ! mkdir "$lock" 2>/dev/null; do
    [ -d "$lock" ] && [ $(( $(date +%s) - $(_mtime "$lock" 2>/dev/null || date +%s) )) -gt 10 ] && rmdir "$lock" 2>/dev/null
    sleep 0.1
  done
  tmp="$(mktemp "${f}.XXXXXX")"
  jq "${args[@]}" "$filter" "$f" > "$tmp" && mv "$tmp" "$f" && _session_db_sync "$key" || { rc=1; rm -f "$tmp"; }
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
  local verify stack tplan slack=""
  verify="$(runtime_skill_ref fxa-verify)"; stack="$(runtime_skill_ref fxa-stack)"
  tplan="$(runtime_skill_ref fxa-test-plan)"
  # The bot links FXA keys itself; a Slack message needs its channel and ts, which only the agent has.
  [ -n "${FXA_SLACK_URL:-}" ] && slack="
- Link each Slack message you cite as [#channel](${FXA_SLACK_URL}/archives/<channel_id>/p<ts without the dot>).
  Read with response_format detailed to get each message's ts."
  cat <<EOF
You are pairing with an FxA engineer through a Slack thread. Read their message
in /workspace/.fxa-jira-context.md first, before you write anything. Talk to them
as "you". Do not mention that file or Jira unless they linked a ticket. The
runner's operations guide is /etc/vm-agent-guide.md: before you change code,
start the stack or record anything, read all of it in one call, not in slices.

Investigate first. Before you change code, write a test plan with ${tplan}:
each behavior and how you will see it work the way a user or client would (a
functional flow, a check on the running stack, an integration spec), with unit
tests for edge cases. Save it to /workspace/.fxa-test-plan.json and print a
short summary: the cause, the files you will change, and how you will verify.
Then make the change and verify it; nobody approves the plan first, so use your
judgement. Stop to ask only when the request is ambiguous or a decision is the
engineer's to make. A question or an investigation needs no plan: just answer.

Every turn, including later ones:
- Write like a teammate in a Slack thread, not like a report. Lead with the
  answer or the result in one or two sentences. Then give the details the
  engineer needs, with markdown where it helps: bold, short lists, code blocks.
  An emoji now and then is fine (✅ done, ⚠️ a risk, 🔍 a finding). Code in
  backticks and files as path:line. No tables and no section headers. Do not
  repeat the question or end with an offer of help. Keep a reply to about 6
  lines; the thread hides anything past 8 behind Show more, so put what matters first.
- Before a command that takes more than a minute (a build, a test run, the
  verify), say what it is and about how long it takes.
- After you read the request, write one short sentence that says what you will
  do about it, for example "I'll trace the sign-in route first."
  The thread shows it at once.
- For work with three or more steps, keep a todo list in /workspace/.fxa-todo.md:
  one line per step, '- [ ] step', '- [>] step' for the one you are on, and
  '- [x] step' when done. Rewrite the whole file with Write each time it changes.
  The thread shows it as your progress.
- A late notice from a finished background task or an expired monitor needs no
  answer: reply with only 'No response requested.' The thread hides that reply.
- Keep /workspace/.fxa-thread-notes.md current, at most 25 lines: the goal,
  decisions and why, what is built and verified, open questions, and the next
  step. Rewrite it with Write before you end a turn that changed any of these.
  The next session in this thread starts from these notes, not from this conversation.
- Use git as you like: commit, amend, fetch, and rebase onto origin/main. You
  cannot push and there is no 'gh': the host pushes your branch at Open PR or
  Push, squashed to one commit. Keep the work on origin/main: rebase, do not
  merge main in, and never start from another branch.
- Verify with ${verify} --run --plan /workspace/.fxa-test-plan.json: it runs your
  planned tests, then the related specs of what you changed, and lint. Update
  the plan when the work changes. For the local stack, ${stack}; wait for a
  service with its 'wait' command, not a sleep loop.
- To show the engineer a screenshot, a video or a patch, save it in /workspace/.fxa-auto-media/.
  Files there are posted to the thread when your turn ends. For a change the engineer
  can see (a page, an email, a flow), attach a screenshot or a video before you end
  with 'status: ready'.
- Before you send a path:line, check it against the file with grep -n or sed -n.
- When a decision blocks the work, list 2 to 4 answers, one per line, each starting
  'OPTION: '. The engineer taps one. For several decisions at once (at most 5),
  put 'QUESTION: <the question>' on its own line before each group of OPTION lines.
  Never use OPTION lines to ask what to look at next.
- End your final message with exactly one line: 'status: needs-input' or
  'status: ready'. Use ready only when the change is done and its tests pass.
- If you changed no files (an answer, an investigation), do not suggest a push
  or a pull request: there is nothing to ship.${slack}
EOF
}

# The quiet turn before a pause (session_idle_sweep): the notes only, no reply.
_SESSION_HANDOFF_PROMPT='This session is about to pause. Update /workspace/.fxa-thread-notes.md so the next
session in this thread can continue from it alone: the goal, decisions and why,
what is built and verified, open questions, and the next step, at most 25 lines.
Do nothing else. Nobody reads your reply.'

# _session_notes_note   The first turn of a session whose thread has notes:
# a new conversation, with the earlier work in the notes and the checkout.
_SESSION_NOTES_NOTE='

This thread has earlier work. Read /workspace/.fxa-thread-notes.md before
anything else: it says where the work stands. The earlier changes are in the
checkout ("git log origin/main..HEAD" and "git diff"); the earlier conversation is not. If a
change did not carry over, it is in /workspace/.fxa-resume.patch. Keep the notes
current from here on.'

# The first turn of a session that continues an earlier one in the same thread.
# The conversation is restored, so this only says what changed underneath it.
_session_resume_prompt() {
  cat <<'EOF'
The engineer came back to this thread, so you are on a new runner. This
conversation and your earlier changes were carried over, commits included: run 'git status',
'git log origin/main..HEAD' and 'git diff' to see them, and do not start over. If a change did not carry over,
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
  # A push is a checkpoint: the review and PR write-up run once, at Open PR.
  # The host checks (tooling guard, frozen paths, markers) still run on the push.
  if [ "${2:-}" = --no-pr ]; then
    cat <<EOF
The engineer asked to push the branch (no PR yet). Do not review, test or
write a PR description; that happens when they open the PR. Only:
1. Revert any file unrelated to the request with 'git checkout "\$(git merge-base HEAD origin/main)" -- <path>'.
2. Write /workspace/.fxa-auto-done.json with keys {issue, branch, pr_title, pr_body, media_paths}:
   issue "$1"; branch from 'git branch --show-current'; pr_title a scoped
   conventional commit subject; pr_body two or three plain lines on what changed
   and why; media_paths []. Write it to .fxa-auto-done.json.tmp, then mv it into place.
EOF
    return
  fi
  cat <<EOF
The engineer asked to open a PR. Wrap up now. First, if
'git add -N . && git diff --stat \$(git merge-base HEAD origin/main) -- . ":(exclude).fxa-*"'
prints nothing, say there is nothing to open, write no handoff, and stop. If an
earlier wrap-up in this session ran steps 1 and 3 and no file changed since, go
straight to step 4.
1. Run $(runtime_skill_ref fxa-review-quick) on 'git diff \$(git merge-base HEAD origin/main)' plus
   untracked files, then $(runtime_skill_ref fxa-vm-selfcheck) and $(runtime_skill_ref fxa-unslop) Part 1. Fix every blocker.
2. Revert any file unrelated to the request with 'git checkout "\$(git merge-base HEAD origin/main)" -- <path>'.
   Then commit everything ('git add -A && git commit'), so the PR description sees all of it.
3. Use $(runtime_skill_ref create-pr-description) on the whole diff, then $(runtime_skill_ref humanizer) and $(runtime_skill_ref fxa-unslop) Part 2 on its output.
   pr_body must reuse /workspace/.github/PULL_REQUEST_TEMPLATE.md. There is no
   Jira ticket; leave the ticket field empty and do not name this session.
4. Write /workspace/.fxa-auto-done.json LAST, once the working tree holds exactly
   what should ship, with keys {issue, branch, pr_title, pr_body, media_paths}:
   issue "$1"; branch from 'git branch --show-current'; pr_title a scoped
   conventional commit subject; media_paths relative to /workspace, empty if
   none. Write it with the Write tool (not an inline script) to
   .fxa-auto-done.json.tmp, then mv it into place.
5. Run 'bash ~/.claude/skills/fxa-vm-handoff/check.sh --fix' and fix what it prints.
6. If this session taught you something that a later session in this repo needs
   (a command that works, a trap, a wrong assumption that cost time), write
   /workspace/.fxa-lessons.json as [{"lesson": "...", "why": "..."}]: at most 3,
   one sentence each, about the repo or the sandbox, never about this change.
   Write none when there is nothing new. The operator reviews each one first.
EOF
}

# _session_sh <name> <script>   Run a script on the runner as the agent user.
# vm_exec_as_agent goes through `sudo -i`, which blanks $vars in the script.
_session_sh() { vm_exec "$1" sudo -u agent bash -c "$2"; }

# _session_media_scrub <dir>   Leave only plain media files with safe names and
# a sane size. Symlinks would let a sandbox point ffmpeg's output at a host file;
# a newline in a name would split the one-per-line list the bot reads.
_session_media_scrub() {
  local dir="$1" f
  find "$dir" -mindepth 1 \( ! -type f -o -links +1 \) -exec rm -rf {} + 2>/dev/null
  find "$dir" -mindepth 2 -exec rm -rf {} + 2>/dev/null
  while IFS= read -r -d '' f; do
    [[ "$(basename "$f")" =~ ^[A-Za-z0-9._-]{1,120}\.(png|jpe?g|gif|webp|mp4|webm|patch|diff)$ ]] && [ "$(_fsize "$f")" -le 52428800 ] \
      || rm -f "$f"
  done < <(find "$dir" -mindepth 1 -maxdepth 1 -type f -print0)
}

# A Slack thread's record, across its sessions: the request, the session keys,
# and the open PR's branch and URL. Its notes file holds where the work stands,
# written by the agent, so a new session starts from it, not from a replay.
_thread_ok() { [[ "${1:-}" =~ ^[A-Z0-9]+:[0-9]+\.[0-9]+$ ]]; }
_thread_file() { printf '%s/thread-%s.json' "$SESSION_DIR" "${1/:/-}"; }
_thread_notes() { printf '%s/thread-%s.notes.md' "$SESSION_DIR" "${1/:/-}"; }
# A thread with no record yet is empty, not an error: callers run under set -e.
thread_get() { jq -r --arg f "$2" '.[$f] // empty' "$(_thread_file "$1")" 2>/dev/null || true; }
# thread_set <thread> <field> <value>...   One writer at a time is enough: only task and the finish job write it.
thread_set() {
  local f t filter='.' i=0; f="$(_thread_file "$1")"; shift
  local -a args=()
  while [ $# -ge 2 ]; do args+=(--arg "k$i" "$1" --arg "v$i" "$2"); filter="${filter} | .[\$k$i] = \$v$i"; i=$((i + 1)); shift 2; done
  t="$(mktemp "${f}.XXXXXX")"
  { cat "$f" 2>/dev/null || echo '{}'; } | jq "${args[@]}" "$filter" > "$t" && mv "$t" "$f" || rm -f "$t"
}
# _thread_save_notes <key> <file>   Keep the agent's notes for the session's thread.
# notes_stale 1: the last turn did not change them, so the pause asks for a handoff.
_thread_save_notes() {
  local tid; tid="$(session_get "$1" thread)"; _thread_ok "$tid" || return 0
  if [ -s "$2" ] && ! cmp -s "$2" "$(_thread_notes "$tid")"; then
    cp "$2" "$(_thread_notes "$tid")"; session_set "$1" notes_stale 0
  else session_set "$1" notes_stale 1; fi
}
# _session_handoff_busy <key>   0 while the quiet handoff turn still runs. One
# that ended, or ran past 5 min, is marked done.
_session_handoff_busy() {
  [ "$(session_get "$1" handoff)" = running ] || return 1
  if [ $(( $(date +%s) - $(session_get "$1" handoff_at || echo 0) )) -lt 300 ] \
    && _session_sh "$(worktree_branch_for "$1")" "pgrep -f '${_SESSION_AGENT_PAT}' >/dev/null" 2>/dev/null; then return 0; fi
  session_set "$1" handoff done
  return 1
}

# _session_valid_sid <id>   A conversation id from the transcript, which the agent can write.
_session_valid_sid() { [[ "${1:-}" =~ ^[A-Za-z0-9-]{8,64}$ ]]; }

# _session_turn <key> <message> [quiet]   Start one resumed turn on the runner and return.
# quiet: the handoff before a pause. Its output stays out of the transcript, so
# the thread never sees it, and it opens no turn.
_session_turn() {
  local key="$1" msg="$2" quiet="${3:-}" name sid tmp out="${_SESSION_CLAUDE_SPLIT}"
  [ -n "$quiet" ] && out='cat > /workspace/.fxa-handoff.jsonl'
  name="$(worktree_branch_for "$key")"
  sid="$(session_get "$key" claude_session_id)"
  if [ -z "$sid" ]; then
    sid="$(vm_exec_as_agent "$name" "grep -m1 -E '\"(session_id|thread_id)\"' /workspace/.fxa-auto-claude.jsonl" 2>/dev/null | jq -r '.session_id // .thread_id // empty' 2>/dev/null || true)"
    [ -n "$sid" ] || { echo "ERROR: ${key}: no Claude session id on the runner yet." >&2; return 1; }
    _session_valid_sid "$sid" || { echo "ERROR: ${key}: the runner reported a malformed session id" >&2; return 1; }
    session_set "$key" claude_session_id "$sid"
  fi
  tmp="$(mktemp -d)"
  # A CircleCI link in a later message: the host reads it, and its traces ride in the tar below.
  msg="${msg}$(circleci_digests "$msg" "$(openssl rand -hex 6)" "${tmp}/.fxa-ci" 2>/dev/null || true)"
  # Every exit below removes $tmp: it holds a copy of the Claude credential.
  ( umask 077
    printf '%s\n' "$msg" > "${tmp}/.fxa-steer-msg.txt"
    # The session's own connectors: an empty --mcp stays off.
    _FXA_SESSION_MCP="$(session_get "$key" mcp)" _claude_auth_line "$name" > "${tmp}/.fxa-auto-token" || [ "$(session_get "$key" runtime)" = codex ] \
      || { echo "ERROR: set ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN on the host" >&2; exit 1; }
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
    # "--": a message that starts with a dash is text, not a flag.
    cat > "${tmp}/.fxa-steer.sh" <<STEER
export HOME=/home/agent # claude finds the session to resume under \$HOME/.claude
test -f /workspace/.fxa-auto-token && source /workspace/.fxa-auto-token && rm -f /workspace/.fxa-auto-token
source /etc/agent-env.sh
${_MCP_LAUNCH_SNIPPET}
cd /workspace
: > /workspace/.fxa-auto-stream.jsonl
claude -p --resume ${sid} --permission-mode bypassPermissions${_MCP_CLAUDE_FLAGS} \\
  --model ${FXA_AGENT_MODEL:-claude-opus-5-5} --output-format stream-json --verbose${_SESSION_CLAUDE_PARTIAL} -- "\$(cat /workspace/.fxa-steer-msg.txt)" 2>&1 \\
  | ${out}
STEER
    fi
  ) || { rm -rf "$tmp"; return 1; }
  # One ssh: unpack the files as the agent and start the turn. Two cost ~1.8 s more.
  # Only the launch is backgrounded: a background job's stdin is /dev/null, so tar must not be in it.
  ( cd "$tmp" && COPYFILE_DISABLE=1 tar --no-xattrs -cf - ./.fxa-steer-msg.txt ./.fxa-auto-token ./.fxa-steer.sh $([ -d .fxa-ci ] && echo ./.fxa-ci) ) \
    | vm_exec "$name" sudo -u agent bash -c 'cd /workspace && tar -xf - && { nohup setsid bash /workspace/.fxa-steer.sh >/dev/null 2>&1 < /dev/null & }' \
    || { rm -rf "$tmp"; return 1; }
  rm -rf "$tmp"
  if [ -n "$quiet" ]; then session_set "$key" handoff running handoff_at "$(date +%s)"; return 0; fi
  # A real turn means someone is here: a later pause asks for a new handoff.
  session_set "$key" turns "$(( $(session_get "$key" turns || echo 0) + 1 ))" turn_open 1 turn_started "$(date +%s)" handoff ""
}

# session_interrupt <key>   Stop the running turn and keep the session. Claude
# writes what it has on SIGINT, so the next --resume continues from there.
session_interrupt() {
  [ "$(session_get "$1" turn_open)" = 1 ] || { echo "$1 idle"; return 0; }
  _session_lock "$1" || { echo "ERROR: $1 is busy; try again in a moment" >&2; return 1; }
  # Close the turn only once the process is gone: a steer that saw it closed
  # early started a second claude on the same session.
  _session_sh "$(worktree_branch_for "$1")" "pkill -INT -f '${_SESSION_AGENT_PAT}'
    for i in \$(seq 30); do pgrep -f '${_SESSION_AGENT_PAT}' >/dev/null || exit 0; sleep 0.5; done
    pkill -KILL -f '${_SESSION_AGENT_PAT}'; true" >/dev/null 2>&1 \
    || { _session_unlock "$1"; echo "ERROR: $1: could not reach the runner to interrupt" >&2; return 1; }
  _session_turn_log "$1"
  session_set "$1" turn_open 0
  _session_unlock "$1"
  echo "$1 interrupted"
}

# session_idle_sweep   Pause every active session with no open turn, nothing
# queued, and no activity for FXA_SESSION_IDLE_SECONDS (10 min: the prompt cache
# is cold after 5, so waiting longer saves nothing on resume). Stop saves the work
# and the conversation, and deletes the runner; a reply resumes it.
session_idle_sweep() {
  local f key now idle="${FXA_SESSION_IDLE_SECONDS:-600}"; now="$(date +%s)"
  for f in "$SESSION_DIR"/agent-*.json; do
    [ -f "$f" ] || continue
    key="$(basename "$f" .json)"
    # A pause nobody came back to in a day is over: stopped. A reply still resumes it from the saved work.
    if [ "$(jq -r .state "$f")" = paused ] && [ $(( now - $(jq -r '.last_activity // 0 | floor' "$f") )) -ge "${FXA_SESSION_PAUSED_SECONDS:-86400}" ]; then
      _session_lock "$key" || continue
      [ "$(session_get "$key" state)" = paused ] && session_set "$key" state stopped stop_reason inactive && echo "stopped ${key}"
      _session_unlock "$key"; continue
    fi
    [ "$(jq -r .state "$f")" = active ] && [ "$(jq -r '.turn_open // "0"' "$f")" != 1 ] || continue
    [ -s "${SESSION_DIR}/${key}.queue" ] && continue
    _session_handoff_busy "$key" && continue
    # The handoff's own writes moved last_activity: once it is done, pause at once.
    [ "$(jq -r '.handoff // ""' "$f")" = done ] || [ $(( now - $(jq -r '.last_activity // 0 | floor' "$f") )) -ge "$idle" ] || continue
    # An open desktop is a person at work, even with no agent turn.
    if _session_desktop_in_use "$key"; then session_set "$key" last_activity "$now"; continue; fi
    # So is a test or verify run the agent left in the background (run.sh --bg).
    if _session_job_running "$key"; then session_set "$key" last_activity "$now"; continue; fi
    # Notes the last turn did not update: one quiet turn writes them, and the next sweep pauses.
    if [ "$(jq -r '.notes_stale // ""' "$f")" = 1 ] && [ -z "$(jq -r '.handoff // ""' "$f")" ] && [ "$(jq -r '.runtime // "claude"' "$f")" = claude ]; then
      if _session_lock "$key"; then
        # A handoff that cannot start must not hold the pause off: the next sweep pauses.
        if [ "$(session_get "$key" turn_open)" != 1 ]; then
          if _session_turn "$key" "$_SESSION_HANDOFF_PROMPT" quiet >/dev/null 2>&1; then echo "handoff ${key}"; else session_set "$key" handoff done; fi
        fi
        _session_unlock "$key"
      fi
      continue
    fi
    _session_lock "$key" || continue
    # Recheck under the lock: a steer may have just started a turn.
    if [ "$(session_get "$key" state)" = active ] && [ "$(session_get "$key" turn_open)" != 1 ]; then
      if session_stop "$key" idle; then session_set "$key" state paused; echo "paused ${key}"
      else echo "pause-failed ${key}" >&2; errors_record session pause_failed "$key" "idle sweep" "the idle pause could not stop the runner" ""; fi
    fi
    _session_unlock "$key"
  done
}

# _session_job_running <key>   A Playwright or fxa-verify run younger than 2 h on the
# runner. Older is taken as hung, so it cannot hold a runner up. [p]: pgrep must not match this script.
_session_job_running() {
  _session_sh "$(worktree_branch_for "$1")" 'for p in $(pgrep -f "[p]laywright test|[f]xa-verify/verify.sh"); do
      [ "$(ps -o etimes= -p "$p" | tr -d " ")" -lt 7200 ] 2>/dev/null && exit 0; done; exit 1' >/dev/null 2>&1
}

# session_prune   Retention: delete what a session left on the host (its prompt and
# thread text, history, transcript, patch, media) FXA_SESSION_RETAIN_DAYS (30) after
# its last activity, then thread records no session uses, the MCP call log's old
# lines (they hold tool arguments), and old per-run token files. Prints each key it
# deleted, so the bot forgets those threads too. Live sessions are never touched.
# session_backup [--now]   Copy the session folder to the state bucket, at most daily: the saved
# work and conversations that a resume needs live only on this disk. Only new or changed
# files go up, and nothing is deleted there, so a local loss never reaches the copy.
# Restore: gcloud storage rsync -r <uri>/<host> "$SESSION_DIR"
# ponytail: the copy keeps pruned sessions; add a bucket lifecycle rule if it grows.
session_backup() {
  local uri="${FXA_SESSION_BACKUP_URI-${FXA_GCE_PROJECT:+gs://${FXA_GCE_PROJECT}-fxa-ai-fixme/sessions}}" stamp="${SESSION_DIR}/.backed-up"
  [ -n "$uri" ] && [ -d "$SESSION_DIR" ] || return 0
  if [ "${1:-}" != --now ] && [ -f "$stamp" ] && [ $(( $(date +%s) - $(_mtime "$stamp") )) -lt 86400 ]; then return 0; fi
  touch "$stamp"
  # Not the .run folders: launch staging, with the stack's secret files in it.
  gcloud storage rsync -r -q "$SESSION_DIR" "${uri}/$(hostname -s)" \
    --exclude='[^/]*\.run/.*|.*\.w?lock(/.*)?|PAUSED|\.pause-cache|\.backed-up|.*\.json\.[A-Za-z0-9]{6}' >/dev/null 2>&1 \
    || { rm -f "$stamp"; return 1; }
}

session_prune() {
  local cutoff f key k used
  cutoff=$(( $(date +%s) - ${FXA_SESSION_RETAIN_DAYS:-30} * 86400 ))
  for f in "$SESSION_DIR"/agent-*.json; do
    [ -f "$f" ] || continue
    key="$(basename "$f" .json)"
    session_live "$key" && continue
    [ "$(jq -r '.last_activity // 0 | floor' "$f" 2>/dev/null || echo 0)" -lt "$cutoff" ] || continue
    [ -n "$(_session_store)" ] && { gcloud storage rm -q "$(_session_store)/${key}.*" >/dev/null 2>&1 || true; }
    rm -rf "${SESSION_DIR:?}/${key}".* && _session_db_sync "$key" && echo "$key"
  done
  for f in "$SESSION_DIR"/thread-*.json; do
    [ -f "$f" ] || continue
    used=0; for k in $(jq -r '.sessions // ""' "$f" 2>/dev/null || true); do session_exists "$k" && used=1; done
    [ "$used" = 1 ] || rm -f "$f" "${f%.json}.notes.md"
  done
  local d calls="${FXA_MCP_GATEWAY_DIR:-$HOME/.claude/state/mcp-gateway}/calls.jsonl" t
  if [ -s "$calls" ]; then
    t="$(mktemp "${calls}.XXXXXX")"
    jq -c --argjson c "$cutoff" 'select((.at // 0) >= $c)' "$calls" > "$t" 2>/dev/null && mv "$t" "$calls" || rm -f "$t"
  fi
  # The LLM proxy's call log keeps 90 days, for spend trends past the sessions' 30.
  # ponytail: a call the proxy appends during this rewrite is lost; rotate by month if that matters.
  local usage="${FXA_LLM_PROXY_DIR:-$HOME/.claude/state/llm-proxy}/usage.jsonl"
  if [ -s "$usage" ]; then
    t="$(mktemp "${usage}.XXXXXX")"
    jq -c --argjson c "$(( $(date +%s) - ${FXA_LLM_USAGE_RETAIN_DAYS:-90} * 86400 ))" 'select((.at // "" | fromdate? // 0) >= $c)' "$usage" > "$t" 2>/dev/null \
      && mv "$t" "$usage" || rm -f "$t"
  fi
  for f in "${LOG_DIR:-/nonexistent}"/*.postmortem; do
    [ -f "$f" ] && [ "$(_mtime "$f")" -lt "$cutoff" ] && rm -f "$f"
  done
  for d in "${FXA_MCP_GATEWAY_DIR:-$HOME/.claude/state/mcp-gateway}" "${FXA_LLM_PROXY_DIR:-$HOME/.claude/state/llm-proxy}"; do
    for f in "$d"/tokens/* "$d"/runs/*; do
      [ -f "$f" ] && [ "$(_mtime "$f")" -lt "$cutoff" ] && rm -f "$f"
    done
  done
  return 0
}

# _session_lock <key>   One writer per session: steer, the queue drain, and Open PR
# all start turns. A lock older than 2 min belongs to a crashed holder.
_session_lock() {
  local d="${SESSION_DIR}/$1.lock"
  [ -d "$d" ] && [ $(( $(date +%s) - $(_mtime "$d") )) -gt 120 ] && rmdir "$d" 2>/dev/null
  mkdir "$d" 2>/dev/null
}
_session_unlock() { rmdir "${SESSION_DIR}/$1.lock" 2>/dev/null; }

# _session_turn_running <key>   0 running, 1 idle. A dropped tunnel reads as running,
# so a message queues rather than starting a second writer on one session.
_SESSION_AGENT_PAT='^(claude -p|(node )?[^ ]*codex exec)'
_session_turn_running() {
  local n
  n="$(_session_sh "$(worktree_branch_for "$1")" "pgrep -cf '${_SESSION_AGENT_PAT}' || true" 2>/dev/null | tr -d '\r' | tail -1)" || return 0
  case "$n" in ''|*[!0-9]*) return 0 ;; esac
  [ "$n" -gt 0 ]
}

# One assistant content block → one short step title for what the agent does.
# Its messages are not steps: the reply already shows them.
_SESSION_STEP_JQ='select(.type == "tool_use") | (.input // {}) as $i
  | (($i.file_path // $i.path // "") | tostring | split("/") | last) as $f
  | if .name == "Read" then "Reading " + $f
    elif (.name == "Write" or .name == "Edit") and $f == ".fxa-todo.md" then "Updating the plan"
    elif (.name == "Write" or .name == "Edit") and $f == ".fxa-thread-notes.md" then "Updating the notes"
    elif .name == "Edit" or .name == "MultiEdit" or .name == "Write" then "Editing " + $f
    elif .name == "Grep" then "Searching for \"" + ($i.pattern // "" | tostring) + "\""
    elif .name == "Glob" then "Finding files " + ($i.pattern // "" | tostring)
    elif .name == "Bash" then "Running " + ($i.command // "" | tostring)
    elif .name == "Task" or .name == "Agent" then "Delegating: " + ($i.description // "" | tostring)
    elif .name == "TodoWrite" then "Updating the plan"
    elif .name == "Skill" then "Using /" + ($i.skill // $i.command // "" | tostring)
    else .name end
  | gsub("\\s+"; " ") | .[0:90]'

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

# The live status's own events, from one Claude transcript line: the main
# agent's todo list (its /workspace/.fxa-todo.md, or TodoWrite where Claude Code
# has it) and subagents, every edit with its line counts, and test,
# lint and type-check counts read from the last 4 KB of a tool's output. Tool
# output itself never leaves: only the counts.
_SESSION_LIVE_JQ='(.parent_tool_use_id // null) as $p
  | if .type == "assistant" then (.message.content[]? | select(.type? == "tool_use") | .input as $i | .id as $id
      | if .name == "TodoWrite" then (select($p == null) | {type: "todos", items: [($i.todos // [])[]
            | {content: (.content // "" | tostring | .[0:200]), status: (.status // "pending" | tostring), active: (.activeForm // "" | tostring | .[0:200])}]})
        elif .name == "Agent" or .name == "Task" then (select($p == null) | {type: "subagent_start", id: $id, description: ($i.description // "" | tostring | .[0:120])})
        elif ($i.file_path // "" | tostring | endswith("/.fxa-todo.md")) then (select($p == null and .name == "Write") | {type: "todos", items: [($i.content // "" | tostring | split("\n")[]
            | capture("^\\s*[-*] \\[(?<m>[ xX>~])\\] +(?<t>.+)$")? | {content: (.t | .[0:200]), status: ({"x": "completed", "X": "completed", ">": "in_progress", "~": "in_progress"}[.m] // "pending"), active: (.t | .[0:200])})]})
        elif ($i.file_path // "" | tostring | endswith("/.fxa-thread-notes.md")) then empty
        elif .name == "Edit" or .name == "MultiEdit" or .name == "Write" then
          ((if .name == "MultiEdit" then ($i.edits // []) elif .name == "Write" then [{new_string: $i.content}] else [$i] end) as $e
          | {type: "edit", file: ($i.file_path // "" | tostring | sub("^(/workspace|/home/agent/fxa)/"; "")),
             added: ([$e[] | .new_string // "" | tostring | split("\n") | length] | add // 0),
             removed: ([$e[] | .old_string // null | select(. != null) | tostring | split("\n") | length] | add // 0)})
        else empty end)
    elif .type == "user" and $p == null then (.message.content[]? | select(type == "object" and .type == "tool_result") | .tool_use_id as $id
      | ((.content // "") | if type == "array" then map(.text? // "") | join("\n") else tostring end | .[-4096:]) as $o
      | {type: "tool_done", id: $id, ok: (.is_error != true)},
        (([$o | scan("Tests:\\s+(?:(\\d+) failed, )?(?:\\d+ skipped, )?(?:\\d+ todo, )?(\\d+) passed")] | last) as $j
         | ([$o | scan("(\\d+) passing")] | last) as $m
         | if $j then {type: "tests", passed: ($j[1] | tonumber), failed: ($j[0] // "0" | tonumber)}
           elif $m then {type: "tests", passed: ($m[0] | tonumber), failed: (([$o | scan("(\\d+) failing")] | last // ["0"])[0] | tonumber)}
           else empty end),
        (([$o | scan("(\\d+) problems? \\((\\d+) errors?, (\\d+) warnings?\\)")] | last) as $l
         | select($l) | {type: "lint", errors: ($l[1] | tonumber), warnings: ($l[2] | tonumber)}),
        (([$o | scan("Found (\\d+) errors?")] | last) as $t | select($t) | {type: "types", errors: ($t[0] | tonumber)}))
    else empty end'

# The watch: one runner line in, its events out. {type: "result"} at the turn's
# end; {type: "text_start"} and {type: "text", text} as the main agent writes;
# {type: "step", text} per tool call or message; then the live-status events.
_SESSION_WATCH_JQ="fromjson? | if .type == \"result\" or .type == \"turn.completed\" then {type: \"result\"}
  elif .type == \"stream_event\" then (select(.parent_tool_use_id == null) | .event
    | if .type == \"content_block_start\" and .content_block.type == \"text\" then {type: \"text_start\"}
      elif .type == \"content_block_delta\" and .delta.type == \"text_delta\" then {type: \"text\", text: .delta.text}
      else empty end)
  else ((${_SESSION_STEPS_JQ} | {type: \"step\", text: .}), (${_SESSION_LIVE_JQ})) end"

# _session_activity   stream-json lines on stdin → what the agent did last, one line.
_session_activity() {
  jq -R -s -r "split(\"\\n\") | map(fromjson? | ${_SESSION_STEPS_JQ}) | last // \"\"" 2>/dev/null
}

# _session_watch <key>   Stream the running turn as JSON lines, as they happen:
# {type: "step", text} per tool call or message, {type: "result"} at the turn's end.
# Runs until the caller kills it or the runner goes away.
# Also {type: "text", text} for each piece of the reply as Claude writes it, and
# {type: "text_start"} when a new block of text begins (not a subagent's).
_session_watch() {
  _session_sh "$(worktree_branch_for "$1")" 'timeout 1800 tail -q -n 0 -F /workspace/.fxa-auto-claude.jsonl /workspace/.fxa-auto-stream.jsonl 2>/dev/null' \
    | jq --unbuffered -R -c "$_SESSION_WATCH_JQ" \
    || true # the watch ends when its runner stops or after 30 min; neither is a failure
}

# The session cap. With Firecracker slots on it is at least the slot count
# (FXA_FC_SLOTS, the host's FC_SLOTS): a slot costs nothing extra while it waits.
_session_cap() {
  local c="${FXA_SESSION_MAX:-4}"
  [ -n "${FXA_FC_HOST:-}" ] && [ "${FXA_FC_SLOTS:-4}" -gt "$c" ] && c="${FXA_FC_SLOTS:-4}"
  echo "$c"
}

# A Slack session's claude also streams its text as it writes (partial messages).
# Those lines go to .fxa-auto-stream.jsonl, which the watch reads for the bot;
# the transcript keeps only what it had, so every reader of it is unchanged. No
# single quotes: the steer script runs inside a bash -c '...'.
_SESSION_CLAUDE_PARTIAL=' --include-partial-messages'
_SESSION_CLAUDE_SPLIT='awk -v s=/workspace/.fxa-auto-stream.jsonl -v t=/workspace/.fxa-auto-claude.jsonl "/^[{]\"type\":\"stream_event\"/ { print >> s; fflush(s); next } { print >> t; fflush(t); print; fflush() }"'

# _session_boot_label <log line>   One boot log line → its step in plain words, or nothing.
_session_boot_label() {
  case "$1" in
    "On main at "*) echo "on main at ${1#On main at }" ;;
    "Resuming "*" at "*) echo "on the earlier base at ${1##* at }" | sed 's/[,.].*//' ;;
    "Creating GCE"*) echo "creating a sandbox" ;;
    Restoring*) echo "restoring a sandbox with FxA running" ;;
    "Waiting for ssh"*) echo "waiting for the sandbox to boot" ;;
    "Waiting for fxa-gce-checkout"*|"Waiting for infrastructure"*) echo "waiting for the sandbox's services" ;;
    "Pinning the runner"*) echo "checking out the commit" ;;
    "Checking out the commit"*) echo "checking out the commit, and installing keys and settings" ;;
    "Applying security"*) echo "locking down the sandbox" ;;
    "Setting up SSH"*|"Setting up claude"*|"Setting up codex"*) echo "installing keys and settings" ;;
    "Starting claude"*|"Starting codex"*|Shipping*) echo "starting the agent" ;;
  esac
}

# _session_boot_step <key>   The runner's boot progress in plain words.
_session_boot_step() {
  local l; l="$(grep -E '^(Creating GCE|Restoring|Waiting for ssh|Waiting for fxa-gce-checkout|Waiting for infrastructure|Pinning the runner|Checking out the commit|Applying security|Setting up (SSH|claude|codex)|Shipping|Starting (claude|codex))' "${SESSION_DIR}/$1.log" 2>/dev/null | tail -1 || true)"
  l="$(_session_boot_label "$l")"; echo "${l:-preparing}"
}

# A session's boot job and a pipeline launch send their output through this:
# the log as written (appended), plus each line with its seconds since the
# start in a .tsv beside it, for the timings.
# shellcheck disable=SC2016  # perl code, not shell
_SESSION_STAMP_PL='use IO::Handle; use Time::HiRes qw(time);
open(my $l, ">>", $ARGV[0]) or die; open(my $t, ">", $ARGV[1]) or die; $l->autoflush(1); $t->autoflush(1);
my $t0 = time; printf $t "#t0\t%.3f\n", $t0;
while (my $x = <STDIN>) { print $l $x; printf $t "%.1f\t%s", time - $t0, $x; }'

# _session_boot_times <key>   The boot's steps and how long each took, as JSON:
# {steps: [{step, s}], elapsed, done, total, expect}. Each step lasts until the
# next one starts; the last one runs until the agent starts or now.
_session_boot_times() {
  local f="${SESSION_DIR}/$1.boot.tsv" t0 x line lab rows="" done=false end
  [ -f "$f" ] || { echo null; return 0; }
  t0="$(awk -F'\t' '$1 == "#t0" { print $2; exit }' "$f")"
  while IFS=$'\t' read -r x line; do
    [ "$x" = "#t0" ] && continue
    case "$line" in *"is running ==="*) done=true; end="$x"; break ;; esac
    lab="$(_session_boot_label "$line")"
    [ -n "$lab" ] && rows="${rows}${x}"$'\t'"${lab}"$'\n'
  done < "$f"
  [ "$done" = true ] || end="$(awk -v t0="${t0:-0}" -v now="$(date +%s)" 'BEGIN { printf "%.1f", now - t0 }')"
  # A restore prints its own sub-second timing; keep it as a detail.
  local fc; fc="$(grep -oE 'restore_ms=[0-9]+ ssh_ms=[0-9]+' "$f" | tail -1 || true)"
  printf '%s' "$rows" | jq -R -s --argjson end "$end" --argjson done "$done" --arg fc "$fc" '
    split("\n") | map(select(. != "") | split("\t") | {at: (.[0] | tonumber), step: .[1]})
    | reduce .[] as $r ([]; if length > 0 and .[-1].step == $r.step then . else . + [$r] end)
    | [range(length) as $i | {step: .[$i].step, s: ((if $i + 1 < length then .[$i + 1].at else $end end) - .[$i].at | . * 10 | round / 10)}] as $steps
    | {steps: $steps, elapsed: ([$end, 0] | max), done: $done, total: (if $done then $end else null end),
       restore: (if $fc == "" then null else ($fc | capture("restore_ms=(?<r>[0-9]+) ssh_ms=(?<s>[0-9]+)") | {restore_ms: (.r | tonumber), ssh_ms: (.s | tonumber)}) end),
       expect: (if any($steps[]; .step | startswith("restoring")) then 20 else 80 end)}'
}

# _session_parse   stream-json lines on stdin → event objects, one per line.
# The final text of a turn → a question (OPTION: lines) or a turn end with its
# status: line. Both agents end a turn with such text.
_SESSION_FIN_JQ='def fin($t): ($t | tostring) as $t
  | ($t | [scan("(?m)^status: *(needs-input|ready) *$")] | last // ["needs-input"] | .[0]) as $status
  # QUESTION: lines open groups; OPTION: lines answer the latest one (or one unnamed group).
  | (reduce ($t | split("\n"))[] as $l ([];
      if ($l | test("^QUESTION: *")) then . + [{q: ($l | sub("^QUESTION: *"; "")), options: []}]
      elif ($l | test("^OPTION: *")) then (if length == 0 then [{q: null, options: []}] else . end)
        | .[length - 1].options += [$l | sub("^OPTION: *"; "")]
      else . end) | map(select(.options | length > 0))) as $groups
  | ($t | gsub("(?m)^(status:|OPTION:|QUESTION:).*\n?"; "") | sub("\\s+$"; "")) as $body
  | if ($groups | length) > 1 then {type: "question", text: $body, questions: ($groups | .[0:5])}
    elif ($groups | length) == 1 then {type: "question", options: $groups[0].options,
      text: (if $groups[0].q then ($body + (if $body == "" then "" else "\n\n" end) + "**" + $groups[0].q + "**") else $body end)}
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

# session_media <key> <dir>   Copy the images, videos and patches the agent saved in
# /workspace/.fxa-auto-media into <dir>, and list them. Media types only, top
# level only, under 20 MB each: the agent picks these names.
session_media() {
  local key="$1" out="$2" f
  mkdir -p "$out" || return 1
  # The sandbox filter below is a courtesy, not a boundary: the agent controls
  # the VM, so the stream is capped and everything is checked again here.
  # No media folder is the usual turn: send an empty archive, which tar reads
  # without error. Nothing at all failed the extract with exit 2.
  _session_sh "$(worktree_branch_for "$key")" 'cd /workspace/.fxa-auto-media 2>/dev/null || { tar -cf - -T /dev/null; exit 0; }
    find . -maxdepth 1 -type f -size -20M \( -iname "*.png" -o -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.gif" \
      -o -iname "*.webp" -o -iname "*.webm" -o -iname "*.mp4" -o -iname "*.patch" -o -iname "*.diff" \) -print0 | tar -cf - --null -T -' \
    | head -c 524288000 | tar -xf - -C "$out" 2>/dev/null
  _session_media_scrub "$out"
  # Playwright records WebM, which Slack does not play inline (iOS not at all).
  # H.264 MP4 plays everywhere; the scale keeps both sides even, as x264 needs.
  if command -v ffmpeg >/dev/null 2>&1; then
    for f in "$out"/*.webm; do
      [ -f "$f" ] || continue
      ffmpeg -nostdin -y -loglevel error -i "$f" -map_metadata -1 -c:v libx264 -pix_fmt yuv420p -movflags +faststart \
        -vf 'scale=trunc(iw/2)*2:trunc(ih/2)*2' -an "${f%.webm}.mp4" && rm -f "$f"
    done
  fi
  _session_media_scrub "$out"
  # Keep a copy on the host: the sandbox and the Slack upload dir both go away,
  # and the dashboard shows these on the session.
  mkdir -p "${SESSION_DIR}/${key}.media" && find "$out" -maxdepth 1 -type f -exec cp -p {} "${SESSION_DIR}/${key}.media/" \;
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

# The changed-file count on the runner: the work since it left origin/main
# (commits and edits), plus untracked files, without the session's own files.
_SESSION_COUNT='{ git diff --name-only "$(git merge-base HEAD origin/main 2>/dev/null || echo HEAD)" 2>/dev/null; git ls-files -o --exclude-standard; } | grep -vE "^(\.fxa-|ai/|artifacts/)" | sort -u | wc -l'

# _session_changes <key>   How many files the runner has changed, not counting
# the .fxa-* scratch files, ai/ and artifacts/, which never ship. Empty when the
# runner did not answer.
_session_changes() {
  # shellcheck disable=SC2016  # expanded on the runner
  _session_sh "$(worktree_branch_for "$1")" 'cd /workspace && '"$_SESSION_COUNT" 2>/dev/null | tr -dc '0-9'
}

# _session_finish_notes <key>   What a handoff could not do, in plain lines for the
# thread: the PR link alone hid that none of its screenshots uploaded.
_session_finish_notes() {
  local log="${SESSION_DIR}/$1.finish.log" n
  n="$(grep -c 'WARN: could not upload .* to the media bucket' "$log" 2>/dev/null || true)"
  [ "${n:-0}" -gt 0 ] && echo "${n} screenshot(s) did not upload, so the PR is missing them."
  grep -q "WARN: could not attach round media\|WARN: could not post round media" "$log" 2>/dev/null && echo "This round's screenshots did not reach the PR."
  grep -q "NOTE: the PR was created; some media did not upload" "$log" 2>/dev/null && echo "Some screenshots did not attach to the PR."
  grep -q "NOTE: PR created without the" "$log" 2>/dev/null && echo "The PR has no label."
  true
}

# _session_wrap_step <key>   The host step an Open PR or Push branch is on, once
# the agent's wrap-up turn is over, from the finish log.
_session_wrap_step() {
  local l; l="$(grep -E '^(Staging agent changes|Squashing|Committing and pushing|Pushing |Creating pull request|PR already open)' "${SESSION_DIR}/$1.finish.log" 2>/dev/null | tail -1)"
  case "$l" in
    Creating*|"PR already"*) echo "Opening the pull request" ;;
    Committing*|Pushing*) echo "Committing and pushing" ;;
    Staging*|Squashing*) echo "Checking the change: tooling, frozen paths, conflict markers" ;;
    *) echo "Staging the work on the host" ;;
  esac
}

# session_pr_status <key>   The session PR's CI, reviews and state, for the thread
# to follow after Open PR. A failing check named in PIPE_INFRA_CHECKS is listed
# as infra too: it is the repo's CI setup, not the change.
session_pr_status() {
  local url; url="$(session_get "$1" pr_url)"
  [ -n "$url" ] || { echo null; return 0; }
  gh pr view "$url" --json state,reviewDecision,statusCheckRollup,latestReviews,isDraft,mergeable,title,body,headRefName 2>/dev/null \
    | jq -c --arg url "$url" --arg infra "${PIPE_INFRA_CHECKS:-extract=Bad credentials}" '
      ($infra | split(" ") | map(split("=")[0])) as $inf
      | [.statusCheckRollup[]? | {name: (.name // .context),
          done: (if .status then .status == "COMPLETED" else ((.state // "") | IN("PENDING", "EXPECTED") | not) end),
          bad: ((.conclusion // .state // "") | IN("FAILURE", "ERROR", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED")),
          link: (.detailsUrl // .targetUrl // "")}] as $c
      | {url: $url, state, review: .reviewDecision, draft: (.isDraft == true), mergeable,
         jira: ([.title, .headRefName, .body] | map(. // "") | join(" ") | [scan("(?<![A-Za-z0-9-])FXA-[0-9]+")] | first // null),
         ci: (if ($c | length) == 0 then "none" elif any($c[]; .bad) then "fail" elif all($c[]; .done) then "pass" else "running" end),
         failing: [$c[] | select(.bad) | .name], infra: [$c[] | select(.bad) | .name | select(IN($inf[]))],
         links: [$c[] | select(.bad and (.name | IN($inf[]) | not)) | .link | select(startswith("https://"))],
         running: any($c[]; .done | not),
         reviews: [.latestReviews[]? | {login: .author.login, state, at: .submittedAt}]}' || echo null
}

# _session_pr_parts <key>   "owner/repo<TAB>number" of the session's PR, or nothing.
_session_pr_parts() {
  [[ "$(session_get "$1" pr_url)" =~ ^https://github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/pull/([0-9]+)$ ]] && printf '%s\t%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
}
_SESSION_COPILOT='IN("Copilot", "copilot-pull-request-reviewer[bot]")'

# session_copilot_comments <key>   The inline comments of Copilot's latest review
# that are still on current lines: [{id, path, line, body}]. [] when there are none.
session_copilot_comments() {
  local p r; p="$(_session_pr_parts "$1")" || { echo '[]'; return 0; }
  # The latest review from the review list: one with no inline comments must give [], not an older review's.
  r="$(gh api "repos/${p%%$'\t'*}/pulls/${p#*$'\t'}/reviews" --paginate 2>/dev/null \
    | jq -sr "[.[][] | select(.user.login | ${_SESSION_COPILOT}) | .id] | max // empty" 2>/dev/null || true)"
  [ -n "$r" ] || { echo '[]'; return 0; }
  gh api "repos/${p%%$'\t'*}/pulls/${p#*$'\t'}/comments" --paginate 2>/dev/null \
    | jq -sc --argjson r "$r" "[.[][] | select(.user.login | ${_SESSION_COPILOT}) | select(.pull_request_review_id == \$r and .line != null)
        | {id, path, line, body: (.body | .[0:2000])}]" 2>/dev/null || echo '[]'
}

# session_review_comments <key> <login>   A person's latest review on the PR: its
# body as id "review", then its inline comments on current lines. [] when empty.
session_review_comments() {
  local p r; p="$(_session_pr_parts "$1")" || { echo '[]'; return 0; }
  [[ "${2:-}" =~ ^[A-Za-z0-9-]{1,39}$ ]] || { echo '[]'; return 0; }
  r="$(gh api "repos/${p%%$'\t'*}/pulls/${p#*$'\t'}/reviews" --paginate 2>/dev/null \
    | jq -sc --arg u "$2" '[.[][] | select(.user.login == $u)] | max_by(.id) // empty' 2>/dev/null || true)"
  [ -n "$r" ] || { echo '[]'; return 0; }
  gh api "repos/${p%%$'\t'*}/pulls/${p#*$'\t'}/comments" --paginate 2>/dev/null \
    | jq -sc --argjson r "$r" '[($r | select((.body // "") != "") | {id: "review", path: "", line: 0, body: (.body | .[0:4000])})]
        + [.[][] | select(.pull_request_review_id == $r.id and .line != null) | {id, path, line, body: (.body | .[0:2000])}]' 2>/dev/null || echo '[]'
}

# session_pr_ready <key>   Take the session's draft PR out of draft. GitHub then
# asks the code owners for review.
session_pr_ready() {
  local url; url="$(session_get "$1" pr_url)"
  [ -n "$url" ] || { echo "no PR for $1" >&2; return 1; }
  gh pr ready "$url" >/dev/null 2>&1 || [ "$(gh pr view "$url" --json isDraft -q .isDraft 2>/dev/null)" = false ] \
    || { echo "could not mark $url ready" >&2; return 1; }
  _session_history_add "$1" action "Marked ${url} ready for review"
}

# session_review_ack <key> <pr_url>   After a PR update: a thumbs up on each Copilot
# comment the agent fixed, from its /workspace/.fxa-review-outcomes.json.
session_review_ack() {
  local p id ids; p="$(_session_pr_parts "$1")" || return 0
  ids="$(vm_exec_as_agent "$(worktree_branch_for "$1")" 'cat /workspace/.fxa-review-outcomes.json 2>/dev/null; rm -f /workspace/.fxa-review-outcomes.json' 2>/dev/null \
    | jq -r '.[]? | select(.outcome == "fixed") | .id | tostring | select(test("^[0-9]{1,15}$"))' 2>/dev/null || true)"
  for id in $ids; do
    gh api -X POST "repos/${p%%$'\t'*}/pulls/comments/${id}/reactions" -f content=+1 >/dev/null 2>&1 || echo "NOTE: could not react to comment ${id}" >&2
  done
}

# _session_end_facts <key>   What a turn's end needs, in one ssh: the cost so
# far as {cost, tokens}, a tab, then the changed-file count (as _session_changes).
_session_end_facts() {
  local t n cost b; t="$(mktemp)"
  # Only this runner's verify runs and stack starts: a resume brings back the earlier runner's files.
  b="$(session_get "$1" booted_at | tr -dc 0-9)"; b="${b:-0}"
  # shellcheck disable=SC2016  # expanded on the runner
  _session_sh "$(worktree_branch_for "$1")" 'tail -n 5000 /workspace/.fxa-auto-claude.jsonl 2>/dev/null; echo
    printf "@@changes %s\n" "$(cd /workspace && '"$_SESSION_COUNT"')"
    printf "@@notes %s\n" "$(head -c 20000 /workspace/.fxa-thread-notes.md 2>/dev/null | base64 -w0)"
    printf "@@fixed %s\n" "$(grep -o "\"outcome\": *\"fixed\"" /workspace/.fxa-review-outcomes.json 2>/dev/null | wc -l)"
    printf "@@res %s %s %s\n" "$(cut -d" " -f1 /proc/loadavg)" "$(free -m | awk "/^Mem:/ {print \$3}")" "$(df --output=pcent /workspace 2>/dev/null | tail -1 | tr -dc 0-9)"
    printf "@@vr %s\n" "$(jq -rs "map(select(.at >= '"$b"')) | [length, (map(select(.mode == \"full\")) | length), (map(.secs) | add // 0), (map(select(.fail > 0)) | length)] | @tsv" /workspace/.fxa-verify-runs.jsonl 2>/dev/null)"
    printf "@@st %s\n" "$(jq -rs "map(select(.at >= '"$b"')) | [length, (map(.secs) | add // 0), (map(select(.ok | not)) | length)] | @tsv" /workspace/.fxa-stack-times.jsonl 2>/dev/null)"' > "$t" 2>/dev/null || true
  n="$(sed -n 's/^@@changes *\([0-9]*\)$/\1/p' "$t" | tail -1)"
  # The notes ride in the same ssh, saved at every turn end: a crash or the runner's time limit loses none.
  grep '^@@notes ' "$t" | tail -1 | cut -c9- | openssl base64 -d -A > "${t}.n" 2>/dev/null || true
  _thread_save_notes "$1" "${t}.n"; rm -f "${t}.n"
  session_set "$1" round_fixed "$(sed -n 's/^@@fixed *\([0-9]*\)$/\1/p' "$t" | tail -1)"
  _session_res_peaks "$1" "$(sed -n 's/^@@res \([0-9.]* [0-9]* [0-9]*\)$/\1/p' "$t" | tail -1)"
  _session_work_times "$1" "$(grep '^@@vr ' "$t" | tail -1 | cut -c6-)" "$(grep '^@@st ' "$t" | tail -1 | cut -c6-)"
  grep -v '^@@changes \|^@@notes \|^@@fixed \|^@@res \|^@@vr \|^@@st ' "$t" > "${t}.j" || true
  cost="$(_snapshot_agent_json "${t}.j" "$(date +%s)" 2>/dev/null \
    | jq -c 'select(.cost_so_far != null) | {cost: .cost_so_far, tokens: (.tokens | [.in, .out, .cache_read, .cache_write] | map(. // 0) | add)}' 2>/dev/null || true)"
  rm -f "$t" "${t}.j"
  printf '%s\t%s\n' "$cost" "$n"
}

# _session_res_peaks <key> "<load1> <mem_mb> <disk_pct>"   The highest load, memory
# and disk the runner showed at any turn end. A sample a turn, not a sampler.
_session_res_peaks() {
  [ -n "$2" ] || return 0
  local l m d; read -r l m d <<< "$2"
  session_set "$1" res_peak "$(jq -c --arg l "$l" --argjson m "${m:-0}" --argjson d "${d:-0}" \
    '{load1: ([.load1 // 0, ($l | tonumber? // 0)] | max), mem_mb: ([.mem_mb // 0, $m] | max), disk_pct: ([.disk_pct // 0, $d] | max)}' \
    <<< "$(session_get "$1" res_peak | grep . || echo '{}')" 2>/dev/null)"
}

# _session_work_times <key> "<runs> <full> <secs> <failed>" "<starts> <secs> <failed>"
# This runner's verify runs and stack starts so far, from its own records.
_session_work_times() {
  local a b c d
  if [[ "$2" =~ ^[0-9]+[[:space:]][0-9]+[[:space:]][0-9]+[[:space:]][0-9]+$ ]]; then
    read -r a b c d <<< "$2"; session_set "$1" verify_runs "$a" verify_full "$b" verify_s "$c" verify_fail_runs "$d"
  fi
  if [[ "$3" =~ ^[0-9]+[[:space:]][0-9]+[[:space:]][0-9]+$ ]]; then
    read -r a b c <<< "$3"; session_set "$1" stack_starts "$a" stack_s "$b" stack_fails "$c"
  fi
  return 0
}

# _session_cost <key>   {cost, tokens} so far, from the runner's
# transcript (its last 5000 events). Empty when the runner did not answer.
_session_cost() {
  local t; t="$(mktemp)"
  _session_sh "$(worktree_branch_for "$1")" 'tail -n 5000 /workspace/.fxa-auto-claude.jsonl 2>/dev/null' > "$t" 2>/dev/null || true
  _snapshot_agent_json "$t" "$(date +%s)" 2>/dev/null \
    | jq -c 'select(.cost_so_far != null) | {cost: .cost_so_far, tokens: (.tokens | [.in, .out, .cache_read, .cache_write] | map(. // 0) | add)}' 2>/dev/null || true
  rm -f "$t"
}

# _session_summary_json <key>   Time, turns, cost and the size of the change, live.
_session_summary_json() {
  local key="$1" name cost diff
  name="$(worktree_branch_for "$key")"
  cost="$(_session_cost "$key")"
  diff="$(_session_sh "$name" "cd /workspace && git add -A -N -- . ':(exclude).fxa-*' ':(exclude)ai' && git diff --shortstat \"\$(git merge-base HEAD origin/main 2>/dev/null || echo HEAD)\" -- . ':(exclude).fxa-*' ':(exclude)ai'" 2>/dev/null | tail -1 || true)"
  jq -nc --argjson u "${cost:-null}" --arg d "${diff:-}" --arg t "$(session_get "$key" turns)" --arg c0 "$(session_get "$key" created)" \
    '{cost: ($u.cost // null), tokens: ($u.tokens // null), diff: ($d | gsub("^\\s+"; "")), turns: ($t | tonumber? // 0),
      minutes: (if ($c0 | tonumber? // null) == null then null else ((now - ($c0 | tonumber)) / 60 | floor) end)}'
}

# _session_record_summary <key>   Before the runner goes: keep the summary the
# bot posts on Stop and Open PR.
_session_record_summary() { session_set "$1" summary "$(_session_summary_json "$1")"; }

# Kill switch for agent sessions: a marker in GCS, so a pause set on any host
# holds on every host, or a local file when there is no bucket. While it is
# set, new sessions and resumes are refused. Unreadable GCS reads as not
# paused: a network blip should not stop every engineer's work.
_SESSIONS_PAUSE_URI="${FXA_SESSIONS_PAUSE_URI-${FXA_GCE_PROJECT:+gs://${FXA_GCE_PROJECT}-fxa-ai-fixme/sessions/PAUSED}}"
sessions_paused() {
  if [ -n "$_SESSIONS_PAUSE_URI" ]; then
    # The GCS read costs about 2 s on every tag, so its answer is kept 30 s. A pause
    # or resume on this host clears it; one from another host applies within 30 s.
    local c="${SESSION_DIR}/.pause-cache" out
    if [ ! -f "$c" ] || [ $(( $(date +%s) - $(_mtime "$c") )) -ge 30 ]; then
      mkdir -p "$SESSION_DIR"
      if out="$(gcloud storage cat "$_SESSIONS_PAUSE_URI" 2>/dev/null)"; then printf 'P%s' "$out" > "$c.$$"; else printf 'R' > "$c.$$"; fi
      mv -f "$c.$$" "$c"
    fi
    [ "$(head -c1 "$c")" = P ] || return 1
    tail -c +2 "$c"; echo; return 0
  fi
  [ -f "${SESSION_DIR}/PAUSED" ] && cat "${SESSION_DIR}/PAUSED"
}

# sessions_pause [reason] [--now]   --now also stops every active session, even
# mid-turn; its change and conversation are saved and a reply resumes it later.
sessions_pause() {
  local reason="${1:-paused by the operator}" now="${2:-}" f key
  if [ -n "$_SESSIONS_PAUSE_URI" ]; then
    printf '%s\n' "$reason" | gcloud storage cp -q - "$_SESSIONS_PAUSE_URI" >/dev/null 2>&1 \
      || { echo "ERROR: could not write the pause marker to ${_SESSIONS_PAUSE_URI}" >&2; return 1; }
  else
    mkdir -p "$SESSION_DIR" && printf '%s\n' "$reason" > "${SESSION_DIR}/PAUSED"
  fi
  rm -f "${SESSION_DIR}/.pause-cache"
  echo "sessions paused: ${reason}"
  [ "$now" = --now ] || return 0
  for f in "$SESSION_DIR"/agent-*.json; do
    [ -f "$f" ] || continue
    key="$(basename "$f" .json)"
    [ "$(session_get "$key" state)" = active ] || continue
    if ! _session_lock "$key"; then echo "WARN: ${key} is busy; not paused" >&2; continue; fi
    if session_stop "$key" "kill switch"; then session_set "$key" state paused; echo "paused ${key}"
    else echo "ERROR: could not stop ${key}" >&2; fi
    _session_unlock "$key"
  done
}

sessions_resume() {
  if [ -n "$_SESSIONS_PAUSE_URI" ]; then gcloud storage rm -q "$_SESSIONS_PAUSE_URI" >/dev/null 2>&1 || true; fi
  rm -f "${SESSION_DIR}/PAUSED" "${SESSION_DIR}/.pause-cache"
  echo "sessions resumed"
}

# session_desktop <key> [owner_email]   Start a Linux desktop with Firefox on
# the runner (templates/desktop-setup.sh) and print its VNC password. With an
# email and FXA_DESKTOP_GATEWAY, also publish the record the IAP gateway reads,
# and print the link to it.
session_desktop() {
  local key="$1" email="${2:-}" name out ip pw
  name="$(worktree_branch_for "$key")"
  session_live "$key" && vm_is_running "$name" 2>/dev/null || { echo "ERROR: ${key} has no running sandbox" >&2; return 1; }
  out="$(vm_exec "$name" bash -c "$(cat "${SANDBOX_ROOT}/templates/desktop-setup.sh")" _ \
    "$(base64 < "${SANDBOX_ROOT}/templates/novnc-fxa.html" | tr -d '\n')" \
    "$(base64 < "${SANDBOX_ROOT}/templates/inbox-viewer.html" | tr -d '\n')")" || true
  ip="$(sed -n 's/^ip=\([0-9.]*\)$/\1/p' <<< "$out" | tail -1)"
  pw="$(sed -n 's/^password=\([A-Za-z0-9]\{8\}\)$/\1/p' <<< "$out" | tail -1)"
  [ -n "$ip" ] && [ -n "$pw" ] || { echo "ERROR: the desktop did not start on ${key}" >&2; return 1; }
  # A Firecracker slot sees its own inside address; the gateway needs the routed one.
  local routed; routed="$(ssh -G -F "${_GCE_SSH_CONFIG:-/dev/null}" "$(vm_name "$name")" 2>/dev/null | awk '$1 == "hostname" { print $2 }')"
  [[ "$routed" =~ ^[0-9.]+$ ]] && ip="$routed"
  session_set "$key" desktop_open 1
  if [ -n "$email" ] && [ -n "${FXA_DESKTOP_GATEWAY:-}" ]; then
    [[ "$email" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+$ ]] || { echo "ERROR: bad owner email" >&2; return 1; }
    # Expires with the runner's own limit, in case no stop ever removes it. A
    # private file, not a pipe, so the upload can be retried.
    local rec rc=0; rec="$(umask 077; mktemp)"
    jq -n --arg e "$email" --arg ip "$ip" --arg pw "$pw" --argjson exp "$(( $(date +%s) + ${FXA_SESSION_MAX_RUN_SECONDS:-14400} ))" \
      '{owner_email: $e, ip: $ip, vnc_password: $pw, expires: $exp}' > "$rec"
    _retry gcloud storage cp -q "$rec" "$(_session_desktop_uri "$key")" >/dev/null 2>&1 || rc=$?
    rm -f "$rec"
    [ "$rc" = 0 ] || { echo "ERROR: could not publish the desktop for the gateway" >&2; return 1; }
    echo "url=${FXA_DESKTOP_GATEWAY%/}/d/${key}"
  fi
  echo "password=${pw}"
}

_session_desktop_uri() { printf 'gs://%s-fxa-ai-fixme/desktops/%s.json' "$FXA_GCE_PROJECT" "$1"; }

# _session_desktop_close <key>   The runner is going: the gateway link dies with it.
_session_desktop_close() {
  [ "$(session_get "$1" desktop_open)" = 1 ] || return 0
  session_set "$1" desktop_open 0
  ( gcloud storage rm -q "$(_session_desktop_uri "$1")" >/dev/null 2>&1 || true ) </dev/null &
}

# _session_desktop_in_use <key>   Someone is looking at the desktop right now.
_session_desktop_in_use() {
  [ "$(session_get "$1" desktop_open)" = 1 ] || return 1
  local n; n="$(vm_exec "$(worktree_branch_for "$1")" bash -c "ss -Htn state established '( sport = :6080 )' | wc -l" 2>/dev/null | tr -dc 0-9)"
  [ "${n:-0}" -gt 0 ]
}

# session_tunnel <key> <local_port>   Forward 127.0.0.1:<local_port> to the
# runner's noVNC. Runs until the runner goes or the caller stops it.
session_tunnel() {
  local key="$1" port="$2"
  [[ "$port" =~ ^[0-9]{4,5}$ ]] || { echo "ERROR: bad port" >&2; return 1; }
  vm_forward "$(worktree_branch_for "$key")" "$port" 6080
}

# session_attach <key> <file>...   Put files a person attached in Slack into the
# runner's /workspace/.fxa-inbox/. Plain files only, safe names, 25 MB each.
session_attach() {
  local key="$1" d f b n=0 rc=0; shift
  session_live "$key" || { echo "ERROR: ${key} has no running sandbox" >&2; return 1; }
  d="$(mktemp -d)"
  for f in "$@"; do
    b="$(basename "$f")"
    [[ "$b" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,119}$ ]] || { echo "skipped ${b}: name" >&2; continue; }
    [ -f "$f" ] && [ ! -L "$f" ] || { echo "skipped ${b}: not a plain file" >&2; continue; }
    [ "$(_fsize "$f")" -le 26214400 ] || { echo "skipped ${b}: over 25 MB" >&2; continue; }
    cp "$f" "${d}/${b}" && n=$((n + 1))
  done
  [ "$n" -gt 0 ] || { rm -rf "$d"; echo "ERROR: no file to attach" >&2; return 1; }
  COPYFILE_DISABLE=1 tar -czf "${d}.tgz" -C "$d" . && vm_put "$(worktree_branch_for "$key")" "${d}.tgz" /workspace/.fxa-inbox || rc=$?
  rm -rf "$d" "${d}.tgz"
  [ "$rc" -eq 0 ] && echo "attached ${n}"
  return "$rc"
}

# session_pause <key>   What the idle sweep does, on request (the bot's cost cap):
# save the work, stop the runner, and let a reply resume it.
session_pause() {
  local key="$1"
  _session_lock "$key" || { echo "ERROR: ${key} is busy; try again in a moment" >&2; return 1; }
  if [ "$(session_get "$key" state)" = active ] && [ "$(session_get "$key" turn_open)" != 1 ]; then
    if session_stop "$key" "paused on request"; then session_set "$key" state paused; echo "paused ${key}"
    else _session_unlock "$key"; echo "ERROR: could not stop ${key}" >&2; return 1; fi
  else
    _session_unlock "$key"; echo "ERROR: ${key} is not idle; pause it after the turn ends" >&2; return 1
  fi
  _session_unlock "$key"
}

# _session_turn_log <key> [cost-json]   Close the open turn's clock, once per turn:
# one line in <key>.turns.jsonl with its seconds and the cost so far.
_session_turn_log() {
  local s n now; s="$(session_get "$1" turn_started)"; n="$(session_get "$1" turns)"; now="$(date +%s)"
  [[ "$s" =~ ^[0-9]+$ ]] || return 0
  [ "$(session_get "$1" turn_logged)" = "$s" ] && return 0
  jq -nc --argjson s "$s" --argjson e "$now" --argjson n "${n:-0}" --argjson c "${2:-null}" \
    '{turn: $n, start: $s, end: $e, secs: ($e - $s), cost_so_far: ($c.cost // null), tokens_so_far: ($c.tokens // null)}' \
    >> "${SESSION_DIR}/$1.turns.jsonl" 2>/dev/null || true
  session_set "$1" turn_logged "$s" turn_ended_at "$now"
}

# _session_usage_close <key> <reason>   At the end of a runner's life (each resume is
# a new key): when and why it ended, and its runner, busy and idle seconds.
_session_usage_close() {
  local now up busy b; now="$(date +%s)"; b="$(session_get "$1" booted_at)"
  [ -n "$(session_get "$1" stopped_at)" ] && return 0
  [ "$(session_get "$1" turn_open)" = 1 ] && _session_turn_log "$1"
  if [[ "$b" =~ ^[0-9]+$ ]]; then
    up=$(( now - b ))
    busy="$(jq -s 'map(.secs) | add // 0' "${SESSION_DIR}/$1.turns.jsonl" 2>/dev/null || echo 0)"
    [ "${busy:-0}" -le "$up" ] || busy="$up"
    # Compute at list price. A Firecracker slot is a quarter of its host:
    # ponytail: assumes all slots busy, so it is the low end; divide by busy slot-seconds for the real share.
    local rate; case "$(session_get "$1" boot_backend)" in
      firecracker) rate="$(awk -v h="${FXA_FC_HOURLY_USD:-1.12}" -v n="${FXA_FC_SLOTS:-4}" 'BEGIN { print h / n }')" ;;
      *) rate="${FXA_GCE_HOURLY_USD:-0.18}" ;; esac
    session_set "$1" stopped_at "$now" stop_reason "$2" runner_s "$up" busy_s "${busy:-0}" idle_s "$(( up - ${busy:-0} ))" \
      compute_usd "$(awk -v s="$up" -v r="$rate" 'BEGIN { printf "%.4f", s * r / 3600 }')"
  else
    session_set "$1" stopped_at "$now" stop_reason "$2"
  fi
}

# session_stop <key> [reason]   Save the runner's work as a patch, then delete the runner.
# Resume and recovery apply it with `git apply --index`. reason: idle, kill switch, cost cap, stopped, ...
session_stop() {
  local key="$1" name; name="$(worktree_branch_for "$key")"
  _session_usage_close "$key" "${2:-stopped}"
  # First, so a boot still in progress sees it and takes its own runner down.
  session_set "$key" state stopped
  _session_save "$key"
  _session_desktop_close "$key"
  # No runner yet (still booting) is fine; a runner that will not go away is not.
  agent_stop "$name" >&2 || { vm_exists "$name" 2>/dev/null && return 1; }
  return 0
}

# _session_save <key>   Before the runner goes: the summary, the change, the
# media, and the conversation, so a later session in the thread can resume it.
_session_save() {
  local key="$1" name; name="$(worktree_branch_for "$key")"
  if vm_is_running "$name" 2>/dev/null; then
    _session_record_summary "$key" || true
    # ai/ is ignored on the host but not in the runner's clone; the runner is going away.
    vm_exec_as_agent "$name" "cd /workspace && rm -rf ai && git add -A -N -- . ':(exclude).fxa-*' && git diff --binary HEAD -- . ':(exclude).fxa-*'" \
      > "${SESSION_DIR}/${key}.patch" 2>/dev/null || rm -f "${SESSION_DIR}/${key}.patch"
    [ -s "${SESSION_DIR}/${key}.patch" ] || rm -f "${SESSION_DIR}/${key}.patch"
    # The agent's commits since the session's base, for a resume; empty (no commits) makes no file.
    local base; base="$(session_get "$key" base_sha)"
    if [[ "$base" =~ ^[0-9a-f]{40}$ ]]; then
      _session_sh "$name" "cd /workspace && git bundle create /tmp/fxa-work.bundle HEAD ^${base} >/dev/null 2>&1 && cat /tmp/fxa-work.bundle" \
        2>/dev/null | head -c 524288000 > "${SESSION_DIR}/${key}.bundle" || true
    fi
    [ -s "${SESSION_DIR}/${key}.bundle" ] || rm -f "${SESSION_DIR}/${key}.bundle"
    # The whole change, commits included, for !diff once the runner is gone.
    # shellcheck disable=SC2016  # expanded on the runner
    _session_sh "$name" 'cd /workspace && git diff --binary "$(git merge-base HEAD origin/main 2>/dev/null || echo HEAD)" -- . ":(exclude).fxa-*"' \
      > "${SESSION_DIR}/${key}.full.patch" 2>/dev/null || true
    [ -s "${SESSION_DIR}/${key}.full.patch" ] || rm -f "${SESSION_DIR}/${key}.full.patch"
    local media; media="$(mktemp -d)"; session_media "$key" "$media" >/dev/null 2>&1 || true; rm -rf "$media"
    _session_sh "$name" 'cd /home/agent && tar -czf - $(ls -d .claude/projects .codex/sessions 2>/dev/null)' 2>/dev/null | head -c 1073741824 > "${SESSION_DIR}/${key}.claude.tgz" || true
    [ -s "${SESSION_DIR}/${key}.claude.tgz" ] || rm -f "${SESSION_DIR}/${key}.claude.tgz"
    # The agent's work files are not in the patch (it leaves out .fxa-*); without them a
    # resumed runner writes its test plan and PR body again from memory.
    _session_sh "$name" 'cd /workspace && f="$(ls .fxa-test-plan.json .fxa-pr-body.md .fxa-verify-verdict.txt 2>/dev/null)"; [ -z "$f" ] || tar -czf - $f' \
      2>/dev/null | head -c 10485760 > "${SESSION_DIR}/${key}.work.tgz" || true
    [ -s "${SESSION_DIR}/${key}.work.tgz" ] || rm -f "${SESSION_DIR}/${key}.work.tgz"
    local notes; notes="$(mktemp)"
    _session_sh "$name" 'head -c 20000 /workspace/.fxa-thread-notes.md 2>/dev/null' > "$notes" 2>/dev/null || true
    _thread_save_notes "$key" "$notes"; rm -f "$notes"
    # In the background: the files are on this disk already, so the stop need not wait for the
    # bucket. No fd stays open, or the bot would wait on this process's output until it ends.
    ( _session_upload "$key" </dev/null >/dev/null 2>&1 & )
  fi
  return 0
}

# The saved work a resume needs lives in the bucket; this disk keeps a copy until prune,
# so a resume here stays local, and one after a lost disk still has it.
_SESSION_SAVED="patch bundle full.patch claude.tgz work.tgz"
_session_store() { printf '%s' "${FXA_SESSION_STORE_URI-${FXA_GCE_PROJECT:+gs://${FXA_GCE_PROJECT}-fxa-ai-fixme/saved}}"; }

# _session_upload <key>   The saved files to the bucket, in one call. A failure leaves them on this disk.
_session_upload() {
  local uri n files=(); uri="$(_session_store)"; [ -n "$uri" ] || return 0
  for n in $_SESSION_SAVED; do [ -s "${SESSION_DIR}/$1.$n" ] && files+=("${SESSION_DIR}/$1.$n"); done
  [ "${#files[@]}" -gt 0 ] || return 0
  gcloud storage cp -q "${files[@]}" "${uri}/" >/dev/null 2>&1 \
    || { errors_record session upload_failed "$1" "_session_upload" "the saved work did not reach ${uri}; it stays on this disk" "" 2>/dev/null || true; return 1; }
}

# _session_fetch <key>   The saved files from the bucket, when this disk has none of them.
_session_fetch() {
  local uri n; uri="$(_session_store)"; [ -n "$uri" ] || return 0
  for n in $_SESSION_SAVED; do [ -s "${SESSION_DIR}/$1.$n" ] && return 0; done
  gcloud storage cp -q "${uri}/$1.*" "${SESSION_DIR}/" >/dev/null 2>&1 || true
}

# _session_review <pr_url>   The PR's open review feedback as context for the
# agent: review bodies, inline comments still on current lines, and conversation
# comments. Only members' and Copilot's words are copied; others are named only.
_session_review() {
  local url="$1" slug n reviews inline conv
  [[ "$url" =~ ^https://github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/pull/([0-9]+)$ ]] || return 1
  slug="${BASH_REMATCH[1]}"; n="${BASH_REMATCH[2]}"
  local trust='((.author_association // "") | IN("OWNER","MEMBER","COLLABORATOR")) or (.user.login | IN("Copilot","copilot-pull-request-reviewer[bot]"))'
  reviews="$(gh api "repos/${slug}/pulls/${n}/reviews" --paginate 2>/dev/null \
    | jq -c "[.[] | select((.body // \"\") != \"\") | {who: .user.login, ok: (${trust}), where: .state, body}]")" || return 1
  inline="$(gh api "repos/${slug}/pulls/${n}/comments" --paginate 2>/dev/null \
    | jq -c "[.[] | select(.line != null) | {who: .user.login, ok: (${trust}), where: \"\\(.path):\\(.line)\", body}]")" || return 1
  conv="$(gh api "repos/${slug}/issues/${n}/comments" --paginate 2>/dev/null \
    | jq -c "[.[] | select(.user.type != \"Bot\" and (.body | startswith(\"🤖\") | not)) | {who: .user.login, ok: (${trust}), where: \"conversation\", body}]")" || return 1
  jq -rn --argjson a "$reviews" --argjson b "$inline" --argjson c "$conv" '
    ($a + $b + $c) as $all
    | ($all | map(select(.ok)) | map("### \(.who) (\(.where))\n\(.body | .[0:4000])") | join("\n\n")),
      ($all | map(select(.ok | not) | .who) | unique | if length > 0 then "\nNot copied, from people outside the repo: \(join(", "))" else empty end)'
}

# session_checkout <key> <dir>   A throwaway worktree on the session branch at its
# base, holding the runner's tree, for the host-side commit and push. Hooks off:
# the post-checkout hook clones l10n. node_modules is the main checkout's, for
# the check-frozen step; **/node_modules in .gitignore keeps the link out of git.
session_checkout() {
  local key="$1" dir="$2" root name
  root="$(worktree_repo_root)" || return 1
  name="$(worktree_branch_for "$key")"
  local branch base; branch="$(session_get "$key" branch)"; branch="${branch:-$key}"; base="$(session_get "$key" base_sha)"
  # The agent commits and rebases, so the PR's base is where its HEAD leaves the
  # latest main, not the base it started on. The tree below holds the whole change.
  local main work=""
  _retry git -C "$root" fetch -q origin main 2>/dev/null || true
  main="$(git -C "$root" rev-parse -q --verify origin/main 2>/dev/null || true)"
  if [[ "$main" =~ ^[0-9a-f]{40}$ ]]; then
    work="$(_session_sh "$name" "cd /workspace && { git cat-file -e ${main}^{commit} 2>/dev/null || git fetch -q origin ${main}; } && git merge-base HEAD ${main}" 2>/dev/null | tail -1 || true)"
    [[ "$work" =~ ^[0-9a-f]{40}$ ]] && git -C "$root" merge-base --is-ancestor "$work" "$main" 2>/dev/null || work=""
  fi
  git -C "$root" -c core.hooksPath=/dev/null worktree add --quiet -B "$branch" "$dir" "${work:-$base}" >&2 || return 1
  # A review round starts at the PR's head: the push may replace only that
  # commit, so a push someone made to the PR meanwhile is refused, not lost.
  # push_lease: the PR head after this session pushed, which base_sha no longer is.
  local lease; lease="$(session_get "$key" push_lease)"
  [ -n "$(session_get "$key" review_pr)" ] && git -C "$root" update-ref "refs/remotes/origin/${branch}" "${lease:-$base}"
  ln -s "${root}/node_modules" "${dir}/node_modules"
  vm_pull_tree "$name" /workspace "$dir"
}

session_checkout_remove() {
  git -C "$(worktree_repo_root)" worktree remove --force "$1" >&2 2>/dev/null || rm -rf "$1"
}
