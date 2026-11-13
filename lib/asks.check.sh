#!/usr/bin/env bash
# The agent's host: lines (lib/asks.sh): who may ask, which PRs, what the host runs. gh and the runner are stubbed.
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
source "$here/config.sh"
export FXA_SESSION_STORE_URI="" FXA_SESSION_BACKUP_URI=""
FXA_SESSION_DIR="$tmp" source "$here/session.sh"
source "$here/trees.sh"
source "$here/asks.sh"
SESSION_DIR="$tmp"
_session_db_sync() { :; }
PIPE_PROFILE=fxa PIPE_REPO_SLUG=mozilla/fxa
k=agent-abcd
new() { printf '{"key":"%s","state":"active","pr_url":"https://github.com/mozilla/fxa/pull/5"}\n' "$k" > "$tmp/$k.json"; rm -f "$tmp/$k".{queue,asks.jsonl,host-actions.jsonl,history.jsonl}; }

# The parser: host: lines ride on the turn end and leave the reply.
out="$(jq -nc --arg t $'Done.\nhost: rerun-ci\nhost: ready https://github.com/mozilla/fxa/pull/5\nstatus: needs-input' "${_SESSION_FIN_JQ} fin(\$t)")"
check "host: lines become the turn end's asks" '["rerun-ci","ready https://github.com/mozilla/fxa/pull/5"]|Done.' "$(jq -c .asks <<< "$out")|$(jq -r .text <<< "$out")"

# The role of a turn: a direct admin message, then a queue where one non-admin message lowers it.
new
asks_role "$k" 1 Ana; check "an admin's direct message makes an admin turn" "1|Ana" "$(session_get $k turn_admin)|$(session_get $k turn_asker)"
asks_role "$k" 1 Ana queued; echo a >> "$tmp/$k.queue"; asks_role "$k" 0 Bo queued; echo b >> "$tmp/$k.queue"
asks_role "$k" 1 Cy queued; asks_from_queue "$k"
check "a queue with one non-admin message is a non-admin turn" "0|Bo|" "$(session_get $k turn_admin)|$(session_get $k turn_asker)|$(session_get $k q_admin)"

# Who may ask, and what is never done.
new
check "a non-admin is refused with a plain reason" "refused: only a team admin of fxa can ask for this, and Bo is not one. Ask a team admin to say it in the thread.|1" \
  "$(_ask_one $k 0 Bo 'rerun-ci' | tr -d '\n'; echo "|${PIPESTATUS[0]}")"
check "merge is refused even for an admin" "1" "$(_ask_one $k 1 Ana 'merge' >/dev/null; echo $?)"
check "an unknown action is refused" "refused: rm is not a host action.|1" "$(_ask_one $k 1 Ana 'rm -rf /' | tr -d '\n'; echo "|${PIPESTATUS[0]}")"

# Which PRs: the session's own, or one in the team's work repos.
check "no URL means the session's PR" "mozilla/fxa 5 https://github.com/mozilla/fxa/pull/5" "$(_ask_pr $k)"
check "a PR in a team work repo is allowed" "mozilla/fxa 9 https://github.com/mozilla/fxa/pull/9" "$(_ask_pr $k https://github.com/mozilla/fxa/pull/9)"
check "a PR outside the team is refused" "1" "$(_ask_pr $k https://github.com/evil/repo/pull/1 >/dev/null; echo $?)"

# The GitHub calls, with the App's token for the PR's repo.
github_app_enabled() { :; }; github_app_token() { echo "tok-for-${PIPE_REPO_SLUG}"; }
gh() { printf '%s|%s\n' "$GH_TOKEN" "$*" >> "$tmp/gh"; case "$*" in *comments*) cat > "$tmp/body"; echo https://github.com/mozilla/fxa/pull/5#c1 ;; esac; }
worktree_branch_for() { echo runner; }
vm_exec_as_agent() { printf 'Looks good.\nghp_abcdefghijklmnop\n'; }
: > "$tmp/gh"; _ask_one $k 1 Ana 'ready' >/dev/null
check "ready marks the session's PR with its repo's token" "tok-for-mozilla/fxa|pr ready https://github.com/mozilla/fxa/pull/5" "$(cat "$tmp/gh")"
: > "$tmp/gh"; _ask_one $k 1 Ana 'request-review @alice bob' >/dev/null
check "request-review posts the logins" "tok-for-mozilla/fxa|api -X POST repos/mozilla/fxa/pulls/5/requested_reviewers -f reviewers[]=alice -f reviewers[]=bob" "$(cat "$tmp/gh")"
: > "$tmp/gh"; got="$(_ask_one $k 1 Ana 'comment')"
check "comment posts the agent's file with tokens masked" "done: posted https://github.com/mozilla/fxa/pull/5#c1|Looks good.|ghp_<masked>" "$got|$(paste -sd'|' "$tmp/body")"
: > "$tmp/gh"; _ask_one $k 0 Bo 'ready' >/dev/null
check "a refused ask makes no GitHub call" "0" "$(grep -c . "$tmp/gh")"

# The job: each ask runs once, is logged with who asked, and its result goes to the agent as a note.
new; asks_role "$k" 1 Ana
_ASKS_NO_JOB=1 asks_take "$k" '[{"type":"turn_end","asks":["ready","merge"]}]'
: > "$tmp/gh"; session_asks "$k"
check "the job logs each ask with who asked" "Ana:ready:true|Ana:merge:true" "$(jq -r '"\(.asked_by):\(.ask):\(.admin)"' "$tmp/$k.host-actions.jsonl" | paste -sd'|' -)"
check "the results reach the agent's next turn" "2" "$(grep -c '^- `' "$tmp/$k.queue")"
check "the note's turn keeps the asking role" "1" "$(session_get $k q_admin)"
check "the queue is empty after the job" "no" "$([ -e "$tmp/$k.asks.jsonl" ] && echo yes || echo no)"
new; asks_role "$k" 0 Bo
_ASKS_NO_JOB=1 asks_take "$k" '[{"type":"turn_end","asks":["ready"]}]'
: > "$tmp/gh"; session_asks "$k"
check "a non-admin turn's ask is refused and makes no call" "0|1" "$(grep -c . "$tmp/gh")|$(grep -c 'is not one' "$tmp/$k.queue")"

exit $fail
