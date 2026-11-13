#!/usr/bin/env bash
# Offline check for lib/targets.sh: an old record reads as one target, a switch keeps both, a resume carries the
# open ones, and one writer holds each branch.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want [$2] got [$3]"; fail=1; fi; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
source "$here/config.sh"
export FXA_SESSION_STORE_URI="" FXA_SESSION_BACKUP_URI=""
FXA_SESSION_DIR="$tmp" source "$here/session.sh"
_session_db_sync() { :; }
export FXA_BRANCH_LOCK_DIR="$tmp/locks" PIPE_REPO_SLUG=mozilla/syncstorage-rs
source "$here/targets.sh"
pr2750=https://github.com/mozilla/syncstorage-rs/pull/2750 pr2738=https://github.com/mozilla/syncstorage-rs/pull/2738
echo '{"state":"active","branch":"agent-46e5fc","pr_url":"'"$pr2750"'"}' > "$tmp/agent-46e5fc.json"

check "an old record reads as one target" "1|agent-46e5fc|$pr2750|/workspace|0" \
  "$(targets_json agent-46e5fc | jq -r 'length, (.[0] | .branch, .pr_url, .target_path)' | paste -sd'|' -)|$(targets_current agent-46e5fc)"
check "the read rewrites nothing" "null" "$(jq -c .targets "$tmp/agent-46e5fc.json")"

t2738="$(jq -nc --arg u "$pr2738" '{repo: "mozilla/syncstorage-rs", branch: "stor-55", pr_url: $u, review_pr: $u, target_path: "/home/agent/targets/stor-55", target_base: "master", source: "checkout"}')"
check "a switch to PR 2738 adds it as target 1" 1 "$(target_switch agent-46e5fc "$t2738")"
check "the top level is now PR 2738's branch and PR" "stor-55|$pr2738|$pr2738|/home/agent/targets/stor-55" \
  "$(session_get agent-46e5fc branch)|$(session_get agent-46e5fc pr_url)|$(session_get agent-46e5fc review_pr)|$(session_get agent-46e5fc target_path)"
check "the first target keeps its branch and PR" "agent-46e5fc|$pr2750|/workspace" \
  "$(targets_json agent-46e5fc | jq -r '.[0] | .branch, .pr_url, .target_path' | paste -sd'|' -)"
session_set agent-46e5fc push_lease abc123
t0="$(jq -nc --arg u "$pr2750" '{repo: "mozilla/syncstorage-rs", branch: "agent-46e5fc"}')"
check "a switch back finds target 0, and target 1 keeps its push lease" "0|agent-46e5fc|$pr2750||abc123" \
  "$(target_switch agent-46e5fc "$t0")|$(session_get agent-46e5fc branch)|$(session_get agent-46e5fc pr_url)|$(session_get agent-46e5fc push_lease)|$(targets_json agent-46e5fc | jq -r '.[1].push_lease')"
check "a close of PR 2750 ends its target and leaves one open" "1|closed" \
  "$(target_end agent-46e5fc "$pr2750" CLOSED)|$(targets_json agent-46e5fc | jq -r '.[0].state')"

# A resume carries the open targets and drops the merged or closed ones.
gh() { case "$*" in *2738*) echo OPEN ;; *2750*) echo "${STATE_2750:-OPEN}" ;; esac; }
echo '{"state":"stopped","branch":"agent-46e5fc","pr_url":"'"$pr2750"'"}' > "$tmp/agent-old.json"
target_switch agent-old "$t2738" >/dev/null
echo '{"state":"starting"}' > "$tmp/agent-new.json"; session_set agent-new branch stor-55 pr_url "$pr2738"
targets_carry agent-new agent-old
check "a resume carries both open targets, PR 2738 stays current, and the new runner has only /workspace" "2|agent-46e5fc|stor-55|1||/workspace" \
  "$(targets_json agent-new | jq -r 'length, .[0].branch, .[1].branch' | paste -sd'|' -)|$(targets_current agent-new)|$(targets_json agent-new | jq -r '.[0].target_path')|$(targets_json agent-new | jq -r '.[1].target_path')"
echo '{"state":"starting"}' > "$tmp/agent-new2.json"; session_set agent-new2 branch stor-55 pr_url "$pr2738"
STATE_2750=CLOSED targets_carry agent-new2 agent-old
check "a resume drops the closed PR 2750: one target, no list" "null" "$(jq -c .targets "$tmp/agent-new2.json")"
echo '{"state":"starting"}' > "$tmp/agent-one.json"
targets_carry agent-one agent-new2
check "a resume of a one-target session writes no targets" "null" "$(jq -c .targets "$tmp/agent-one.json")"

# One writer for each branch.
check "the first writer takes the branch" "ok|" "$(branch_lock_take mozilla/syncstorage-rs stor-55 thread:C1:1.1 && echo ok)|"
check "the same writer takes it again" "ok" "$(branch_lock_take mozilla/syncstorage-rs stor-55 thread:C1:1.1 && echo ok)"
check "a second writer is refused, and the line names the holder" "no|1" \
  "$(branch_lock_take mozilla/syncstorage-rs stor-55 ticket:FXA-1 2>/dev/null && echo ok || echo no)|$(branch_lock_take mozilla/syncstorage-rs stor-55 ticket:FXA-1 2>&1 | grep -c 'thread:C1:1.1')"
check "a move takes the lock and prints the old holder" "thread:C1:1.1|ticket:FXA-1" \
  "$(branch_lock_take mozilla/syncstorage-rs stor-55 ticket:FXA-1 move)|$(branch_lock_holder mozilla/syncstorage-rs stor-55)"
branch_lock_release mozilla/syncstorage-rs stor-55 thread:C1:1.1
check "only the holder releases" "ticket:FXA-1" "$(branch_lock_holder mozilla/syncstorage-rs stor-55)"
check "a branch with a slash has its own lock" "" "$(branch_lock_holder mozilla/syncstorage-rs stor/55)"
# The one push path takes the lock: a second writer pushes nothing (exit 4).
eval "$(sed -n '/^finish_push_and_pr() {/,/^}/p' "$here/finish.sh")"
_finish_claim() { :; }; _finish_release() { :; }; _finish_push_and_pr() { echo pushed; }
git init -q -b stor-55 "$tmp/wt"
check "the ticket that holds stor-55 pushes" "pushed" "$(FXA_LOCK_HOLDER=ticket:FXA-1 finish_push_and_pr "$tmp/wt" true)"
check "a thread that does not hold it pushes nothing" "4|" "$(out="$(FXA_LOCK_HOLDER=thread:C2:2.2 finish_push_and_pr "$tmp/wt" true 2>/dev/null)"; echo "$?|$out")"
check "a push with no holder (cmd_finish) takes no lock" "pushed" "$(finish_push_and_pr "$tmp/wt" true)"
# Switch in a live session: 'host: target <ref>' and the admin's own words of that turn.
source "$here/turn-words.sh"
trees_on() { return 1; }; _thread_ok() { return 1; }; _retry() { "$@"; }
worktree_branch_for() { echo "$1"; }; vm_put() { echo put >> "$tmp/runner"; }; pipeline_ensure_clone() { :; }
_session_sh() { echo "$2" >> "$tmp/runner"; case "$2" in *cat-file*) return 0 ;; esac; }
SHA=0123456789abcdef0123456789abcdef01234567
gh() {
  case "$*" in
    "pr view https://github.com/mozilla/syncstorage-rs/pull/2738 "*) echo '{"url":"'"$pr2738"'","state":"OPEN","headRefName":"stor-55","headRefOid":"'"$SHA"'","baseRefName":"master","isCrossRepository":false,"author":{"login":"jdoe"}}' ;;
    "pr view https://github.com/mozilla/syncstorage-rs/pull/2799 "*) echo '{"url":"x/2799","state":"OPEN","headRefName":"f","headRefOid":"'"$SHA"'","baseRefName":"master","isCrossRepository":true,"author":{"login":"y"}}' ;;
    "pr list -R mozilla/syncstorage-rs --head"*) echo '[]' ;;
    "pr list -R mozilla/syncstorage-rs --base"*) echo 0 ;;
    "api repos/mozilla/syncstorage-rs/branches/agent-lock -q .protected") echo true ;;
    "api repos/mozilla/syncstorage-rs/branches/"*" -q .protected") echo false ;;
    "api repos/mozilla/syncstorage-rs/branches/"*) echo "$SHA" ;;
    "repo view"*) echo master ;;
    *) case "$*" in *2738*) echo OPEN ;; *) return 1 ;; esac ;;
  esac
}
words() { jq -nc --arg t "$2" '{user: "UA1", ts: "1.1", text: $t}' > "$tmp/w.json"; words_add "$1" "$tmp/w.json" 0; }
echo '{"state":"active","branch":"agent-46e5fc","pr_url":"'"$pr2750"'","thread":"C1:9.9"}' > "$tmp/agent-s.json"
check "a teammate's turn (no admin words) does not switch" "1|agent-46e5fc" \
  "$(session_target agent-s "$pr2738" >/dev/null; echo "$?")|$(session_get agent-s branch)"
words agent-s 'put the offset-limit-0 commit on PR 2738'
check "the admin's 'put the offset-limit-0 commit on PR 2738' switches" "0|stor-55|$pr2738|/home/agent/targets/stor-55|master|UA1|$SHA" \
  "$(session_target agent-s "$pr2738" >/dev/null; echo "$?")|$(session_get agent-s branch)|$(session_get agent-s review_pr)|$(session_get agent-s target_path)|$(session_get agent-s target_base)|$(session_get agent-s checkout_admin)|$(session_get agent-s push_lease)"
check "PR 2750 stays as target 0, the thread holds stor-55, and the agent gets a host note" "agent-46e5fc|$pr2750|thread:C1:9.9|1" \
  "$(targets_json agent-s | jq -r '.[0] | .branch, .pr_url' | paste -sd'|' -)|$(branch_lock_holder mozilla/syncstorage-rs stor-55)|$(grep -c 'targets/stor-55' "$tmp/agent-s.queue")"
check "the runner gets a worktree for stor-55, and /workspace stays" 1 "$(grep -c 'worktree add -q -f -B stor-55 /home/agent/targets/stor-55' "$tmp/runner")"
check "the same words switch only once" 1 "$(session_set agent-s current 0 branch agent-46e5fc; session_target agent-s "$pr2738" >/dev/null; echo $?)"
echo '{"state":"active","branch":"agent-x"}' > "$tmp/agent-f.json"
for w in 'work on PR 2799' 'switch to branch main' 'push to agent-lock' 'work on https://github.com/mozilla/other/pull/1'; do words agent-f "$w"; done
check "a fork PR is refused" 1 "$(session_target agent-f "https://github.com/mozilla/syncstorage-rs/pull/2799" | grep -c fork)"
check "main is refused" 1 "$(session_target agent-f main | grep -c 'default or release')"
check "a protected branch is refused" 1 "$(session_target agent-f agent-lock | grep -c protected)"
check "a PR outside the team's repo is refused" 1 "$(session_target agent-f https://github.com/mozilla/other/pull/1 | grep -c "not this team's work repo")"
check "a branch with no PR that the agent did not make is refused" 1 "$(words agent-f 'switch to stor-77'; session_target agent-f stor-77 | grep -c 'agent-\*')"
ev='[{"type":"turn_end","status":"ready","ship":true,"asks":["target main"]}]'
check "a refused target goes before the turn end and drops its ship line" "target|false|turn_end|null" \
  "$(targets_events agent-f "$ev" | jq -r '.[0].type, .[0].ok, .[1].type, .[1].ship' | paste -sd'|' -)"
check "the turn end carries the host: lines, and the reply drops them" "target #2738|done" \
  "$(jq -nc '{type: "result", result: "done\nhost: target #2738\nstatus: ready"}' | _session_parse | jq -r '.asks[0], .text' | paste -sd'|' -)"
eval "$(sed -n '/^_checkout_gate_on() {/,/^}/p' "$here/../fxa-sandbox-ctl")"
check "a person's PR that an admin named needs no push ok" no "$(_checkout_gate_on agent-s && echo gate || echo no)"
exit "$fail"
