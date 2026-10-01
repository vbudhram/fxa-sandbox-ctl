#!/usr/bin/env bash
# Offline check for session rebase: the runner script on real git repos, and the
# host's records (base_sha, push lease) from its result.
#   bash lib/rebase.check.sh
set -u
fail=0
check() { # check <name> <want> <got>
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi
}
tmp="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$tmp"' EXIT
source "$(dirname "$0")/config.sh"
FXA_SESSION_DIR="$tmp" source "$(dirname "$0")/session.sh"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
g() { git -c init.defaultBranch=main -c core.hooksPath=/dev/null "$@"; }

# A runner checkout: main at M, the session branch, and main moved on to N upstream.
setup() {
  rm -rf "$tmp/ws"; mkdir -p "$tmp/ws/src" && cd "$tmp/ws" && g init -q
  printf 'one\ntwo\nthree\n' > src/a.ts; echo lock1 > yarn.lock; echo keep > src/b.ts
  g add . && g commit -qm M && M="$(g rev-parse HEAD)"
  g checkout -qb agent-x
}
main_moves() { # main_moves <file> <content>   commit on main, back on the branch with the work intact
  g stash -q -u 2>/dev/null; local had=$?
  g checkout -q --detach "$M" && printf '%b' "$2" > "$1" && g add "$1" && g commit -qm N && N="$(g rev-parse HEAD)"
  g checkout -q agent-x; [ "$had" = 0 ] && g stash pop -q >/dev/null; true
}
rb() { bash -c "$(_session_rebase_script "$1" | sed "s#cd /workspace#cd $tmp/ws#")" 2>&1; }

setup; check "on main already: up to date" "result=uptodate" "$(rb "$M")"

setup; printf 'one\ntwo\nTHREE\n' > src/a.ts; echo new > src/new.ts; echo notes > .fxa-thread-notes.md
main_moves src/b.ts 'keep2\n'
out="$(rb "$N")"
check "an edit moves cleanly" "result=clean" "$(grep result= <<<"$out")"
check "HEAD is the new main, on the same branch" "$N agent-x" "$(g rev-parse HEAD) $(g branch --show-current)"
check "the edit, the new file and main's change are all there" "THREE|new|keep2" "$(sed -n 3p src/a.ts)|$(cat src/new.ts)|$(cat src/b.ts)"
check "the edits are uncommitted, as the agent keeps them" " M src/a.ts|?? src/new.ts" "$(g status --porcelain -- src | sort | paste -sd'|' -)"
check "the .fxa- files stay in place" "notes" "$(cat .fxa-thread-notes.md)"
check "yarn.lock unchanged is reported" "lock=0" "$(grep lock= <<<"$out")"

setup; printf 'one\nTWO\nthree\n' > src/a.ts; g commit -qam "pr head"; echo more > src/c.ts
main_moves yarn.lock 'lock2\n'
out="$(rb "$N")"
check "a PR commit and an edit both move" "result=clean|TWO|more|$N" "$(grep result= <<<"$out")|$(sed -n 2p src/a.ts)|$(cat src/c.ts)|$(g rev-parse HEAD)"
check "a changed yarn.lock is reported" "lock=1" "$(grep lock= <<<"$out")"

setup; printf 'one\ntwo\nmine\n' > src/a.ts
main_moves src/a.ts 'one\ntwo\ntheirs\n'
out="$(rb "$N")"
check "the same line on both sides conflicts" "result=conflict|file=src/a.ts" "$(grep result= <<<"$out")|$(grep file= <<<"$out")"
check "the file holds both sides with markers" "1|1|1" "$(grep -c '^<<<<<<<' src/a.ts)|$(grep -c mine src/a.ts)|$(grep -c theirs src/a.ts)"
check "the index is clean, so the agent sees plain edits" "" "$(g diff --name-only --diff-filter=U)"
check "the work before the move is kept in the stash" "1" "$(g stash list | grep -c fxa-rebase)"

# The host side: base_sha and the push lease from the runner's answer.
_session_turn_running() { return 1; }; worktree_repo_root() { echo "$tmp/host"; }; worktree_branch_for() { echo "agent-$1"; }
_retry() { "$@"; }; _session_history_add() { :; }
mkdir -p "$tmp/host" && g -C "$tmp/host" init -q && g -C "$tmp/host" commit -q --allow-empty -m base && NEW="$(g -C "$tmp/host" rev-parse HEAD)"
git() { [ "$*" = "-C $tmp/host fetch -q origin main" ] && return 0; [ "$*" = "-C $tmp/host rev-parse origin/main" ] && { echo "$NEW"; return 0; }; command git "$@"; }
_session_sh() { printf '%s\n' "$RUNNER_OUT"; }
echo '{"key":"agent-r1","state":"active","base_sha":"oldhead","review_pr":"https://github.com/o/r/pull/1"}' > "$tmp/agent-r1.json"
RUNNER_OUT=$'file=src/a.ts\nfile=bad;rm -rf\nlock=1\nresult=conflict'
j="$(session_rebase agent-r1)"
check "the result is JSON for the bot" "conflict|src/a.ts|true" "$(jq -r '"\(.result)|\(.files | join(","))|\(.lock_changed)"' <<<"$j")"
check "a path with shell characters is dropped" "0" "$(jq -r '.prompt' <<<"$j" | grep -c 'rm -rf')"
check "the prompt names the conflicted file" "1" "$(jq -r '.prompt' <<<"$j" | grep -c '^- src/a.ts$')"
check "base_sha is the new main" "$NEW" "$(session_get agent-r1 base_sha)"
check "the push lease keeps the PR head" "oldhead" "$(session_get agent-r1 push_lease)"
session_set agent-r1 base_sha "$NEW"; RUNNER_OUT=result=clean; session_rebase agent-r1 >/dev/null
check "a second rebase keeps the first lease" "oldhead" "$(session_get agent-r1 push_lease)"
RUNNER_OUT=result=uptodate; check "up to date says so" "uptodate" "$(session_rebase agent-r1 | jq -r .result)"
RUNNER_OUT=garbage; session_rebase agent-r1 >/dev/null 2>&1; check "no result is an error" 1 $?
session_set agent-r1 state paused; session_rebase agent-r1 >/dev/null 2>&1; check "a paused session is refused" 1 $?

[ "$fail" = 0 ] && echo "all checks pass"; exit "$fail"
