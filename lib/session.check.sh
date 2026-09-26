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
exit "$fail"
