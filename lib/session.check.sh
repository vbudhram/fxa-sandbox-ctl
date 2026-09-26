#!/usr/bin/env bash
# Offline check for session records and transcript parsing.
#   bash lib/session.check.sh
set -u
fail=0
check() { # check <name> <want> <got>
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi
}
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
FXA_SESSION_DIR="$tmp" source "$(dirname "$0")/session.sh"

echo '{"key":"agent-7f3a","state":"starting"}' > "$tmp/agent-7f3a.json"
session_set agent-7f3a state active slot fxa-auto-3
check "set writes fields" "active fxa-auto-3" "$(session_get agent-7f3a state) $(session_get agent-7f3a slot)"
check "live while active" "yes" "$(session_live agent-7f3a && echo yes)"
session_set agent-7f3a state stopped
check "not live once stopped" "no" "$(session_live agent-7f3a || echo no)"
check "unknown key is not live" "no" "$(session_live agent-0000 || echo no)"

ev="$(printf '%s\n' \
  '{"type":"system","subtype":"init","session_id":"abc"}' \
  '{"type":"assistant","message":{"content":[{"type":"text","text":"working"}]}}' \
  '{"type":"result","result":"Plan.\nOPTION: keep A\nOPTION: drop A\nstatus: needs-input"}' \
  '{"type":"result","result":"Done.\nstatus: ready"}' \
  '{"type":"result","result":"no marker"}' | _session_parse | jq -s -c '.')"
check "init carries the session id" "abc" "$(jq -r '.[0].session_id' <<< "$ev")"
check "assistant chatter is dropped" "4" "$(jq length <<< "$ev")"
check "options become a question" "question keep A,drop A" "$(jq -r '.[1] | "\(.type) \(.options | join(","))"' <<< "$ev")"
check "marker lines leave the text" "Plan." "$(jq -r '.[1].text' <<< "$ev")"
check "ready marker" "ready Done." "$(jq -r '.[2] | "\(.status) \(.text)"' <<< "$ev")"
check "missing marker means needs-input" "needs-input" "$(jq -r '.[3].status' <<< "$ev")"

# session_checkout: throwaway worktree on the session branch, runner tree pulled in.
eval "$(sed -n '/^worktree_filtered_status() {/,/^}/p;/^worktree_branch_for() {/,/^}/p' "$(dirname "$0")/worktree.sh")"
_worktree_pull_if_remote() { :; }
g() { git -c init.defaultBranch=main -c core.hooksPath=/dev/null "$@"; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
g init -q "$tmp/fxa"; printf '**/node_modules\nai\n' > "$tmp/fxa/.gitignore"; printf 'a\n' > "$tmp/fxa/a.txt"
mkdir "$tmp/fxa/node_modules"
g -C "$tmp/fxa" add . && g -C "$tmp/fxa" commit -qm base
worktree_repo_root() { printf '%s\n' "$tmp/fxa"; }
# The runner's tree: one edit, one new file, orchestration files.
mkdir -p "$tmp/runner"; printf 'a\nedit\n' > "$tmp/runner/a.txt"; printf 'new\n' > "$tmp/runner/b.txt"
printf '{}' > "$tmp/runner/.fxa-auto-done.json"
vm_pull_tree() { rsync -a --exclude .git --exclude node_modules "$tmp/runner/" "$3/"; }
echo "{\"key\":\"agent-t1\",\"state\":\"active\",\"base_sha\":\"$(g -C "$tmp/fxa" rev-parse HEAD)\"}" > "$tmp/agent-t1.json"
session_checkout agent-t1 "$tmp/wt" 2>/dev/null
check "checkout is on the session branch" "agent-t1" "$(g -C "$tmp/wt" branch --show-current)"
check "only the runner's work shows" "M a.txt|?? b.txt" "$(worktree_filtered_status "$tmp/wt" | sed 's/^ //' | tr '\n' '|' | sed 's/|$//')"
check "node_modules is linked, not copied" "yes" "$([ -L "$tmp/wt/node_modules" ] && echo yes)"
check "main checkout untouched" "" "$(g -C "$tmp/fxa" status --porcelain)"
session_checkout_remove "$tmp/wt"
check "checkout removed" "gone 1" "$([ -e "$tmp/wt" ] || echo gone) $(g -C "$tmp/fxa" worktree list | grep -c .)"

# session_stop saves the runner's work as a patch before deleting the runner.
vm_is_running() { return 0; }
vm_exec_as_agent() { printf 'diff --git a/a.txt b/a.txt\n'; }
agent_stop() { echo stopped > "$tmp/agent_stop"; }
session_stop agent-t1 2>/dev/null
check "stop saves a patch" "diff --git a/a.txt b/a.txt" "$(cat "$tmp/agent-t1.patch")"
check "stop deletes the runner" "stopped" "$(cat "$tmp/agent_stop" 2>/dev/null)"
check "record says stopped" "stopped" "$(session_get agent-t1 state)"

# Lock: one holder; a stale lock is taken over.
_session_lock agent-t1 && check "first lock wins" "yes" yes
check "second lock loses" "no" "$(_session_lock agent-t1 && echo yes || echo no)"
touch -t 202001010000 "$tmp/agent-t1.lock"
check "stale lock is taken over" "yes" "$(_session_lock agent-t1 && echo yes)"
_session_unlock agent-t1

# cmd_events against a stubbed runner.
eval "$(sed -n '/^cmd_events() {/,/^}/p;/^_session_key() {/,/^}/p' "$(dirname "$0")/../fxa-sandbox-ctl")"
_session_key() { :; }
RUNNER=""; RUNNING=1; TURNS_FILE="$tmp/turns"
vm_exec_as_agent() { printf '%s' "$RUNNER"; }
_session_turn_running() { [ "$RUNNING" = 1 ]; }
_session_turn() { echo t >> "$TURNS_FILE"; session_set "$1" turn_open 1 turn_started "$(date +%s)"; }
reset() { echo "{\"key\":\"agent-t2\",\"state\":\"active\",\"turn_open\":\"1\",\"turn_started\":\"$1\"}" > "$tmp/agent-t2.json"; rm -f "$tmp/agent-t2.queue" "$TURNS_FILE"; }

reset 0; RUNNER='{"type":"system","subtype":"init","session_id":"s1"}
'; RUNNING=0
out="$(cmd_events agent-t2 --since 0)"
check "dead turn with no result is an error" "error" "$(jq -r '.events[0].type' <<< "$out")"
check "dead turn closes the turn" "0" "$(session_get agent-t2 turn_open)"
check "session id captured" "s1" "$(session_get agent-t2 claude_session_id)"

reset "$(date +%s)"; RUNNING=0
check "fresh turn gets a grace period" "0" "$(cmd_events agent-t2 --since 0 | jq '.events | length')"

reset 0; RUNNING=1
check "live turn with no result is quiet" "0" "$(cmd_events agent-t2 --since 0 | jq '.events | length')"

reset 0; RUNNING=0; printf 'next\n' > "$tmp/agent-t2.queue"
RUNNER='{"type":"result","result":"done\nstatus: ready"}
{"type":"result","res'
out="$(cmd_events agent-t2 --since 4)"
check "cursor skips the half-written line" "5" "$(jq .cursor <<< "$out")"
check "turn end closes the turn, then the queue drains" "1 1" "$(grep -c . "$TURNS_FILE") $(session_get agent-t2 turn_open)"
check "queue file consumed" "gone" "$([ -e "$tmp/agent-t2.queue" ] || echo gone)"

reset 0; session_set agent-t2 state wrapping; RUNNING=1
RUNNER='{"type":"result","result":"wrapped\nstatus: ready"}
'
check "wrap-up reply is not shown" "0" "$(cmd_events agent-t2 --since 0 | jq '.events | length')"

session_set agent-t2 state pr_open pr_url https://example.com/pull/1
check "pr announced once" "pr 0" "$(cmd_events agent-t2 | jq -r '.events[0].type') $(cmd_events agent-t2 | jq '.events | length')"
session_set agent-t2 state active turn_open 0 last_error "Open PR failed: x"; RUNNER=''
check "last error reported once" "Open PR failed: x|0" "$(cmd_events agent-t2 | jq -r '.events[0].text')|$(cmd_events agent-t2 | jq '.events | length')"
exit "$fail"
