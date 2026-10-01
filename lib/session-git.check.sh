#!/usr/bin/env bash
# Offline check that a session's own git (commits, a rebase) reaches the PR base,
# the change count, !diff, and the save and resume, on real repos.
#   bash lib/session-git.check.sh
set -u
fail=0
check() { # check <name> <want> <got>
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi
}
HERE="$(cd "$(dirname "$0")" && pwd)"
tmp="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$tmp"' EXIT
source "$(dirname "$0")/config.sh"
FXA_SESSION_DIR="$tmp" source "$(dirname "$0")/session.sh"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
g() { git -c init.defaultBranch=main -c core.hooksPath=/dev/null "$@"; }

# origin (GitHub) with main at M; the host's clone; the runner's clone at M.
g init -q --bare "$tmp/origin.git"
g clone -q "$tmp/origin.git" "$tmp/seed" 2>/dev/null; cd "$tmp/seed"
printf 'one\ntwo\n' > a.txt; echo keep > b.txt; g add . && g commit -qm M && g push -q origin HEAD:main; M="$(g rev-parse HEAD)"
g clone -q "$tmp/origin.git" "$tmp/host"; g clone -q "$tmp/origin.git" "$tmp/ws"
cd "$tmp/ws" && g checkout -qb agent-gt01 && printf '%s\n' ".fxa-*" "ai/" "artifacts/" >> .git/info/exclude
# The runner: commands run in the runner clone in place of /workspace.
_session_sh() { (cd "$tmp/ws" && bash -c "${2//\/workspace/$tmp/ws}"); }
vm_exec_as_agent() { _session_sh "$1" "$2"; }
worktree_repo_root() { echo "$tmp/host"; }; worktree_branch_for() { echo "agent-$1"; }
_retry() { "$@"; }
eval "$(sed -n '/^cmd_diff() {/,/^}/p;/^_session_key() {/,/^}/p' "$HERE/../fxa-sandbox-ctl")"
vm_pull_tree() { rsync -a -c --delete --exclude .git --exclude node_modules "$tmp/ws/" "$3/"; }
echo "{\"key\":\"agent-gt01\",\"state\":\"active\",\"base_sha\":\"$M\"}" > "$tmp/agent-gt01.json"

# The agent commits one change, leaves one edit and one new file, and its notes.
printf 'one\nTWO\n' > a.txt; g commit -qam "fix(a): two"; echo new > c.txt; echo edit >> b.txt; echo n > .fxa-thread-notes.md
check "the count has the commit, the edit and the new file, not the notes" "3" "$(_session_changes gt01 | tr -d ' ')"
check "!diff shows the committed change too" "1" "$(cmd_diff agent-gt01 2>/dev/null | grep -c '^+TWO$')"

# Main moves on upstream, and the agent rebases onto it.
cd "$tmp/seed" && echo up > d.txt && g add d.txt && g commit -qm N && g push -q origin HEAD:main; N="$(g rev-parse HEAD)"
cd "$tmp/ws" && g stash -q -u && g fetch -q origin main && g rebase -q origin/main && g stash pop -q
check "after the rebase the count is still the agent's 3" "3" "$(_session_changes gt01 | tr -d ' ')"
session_checkout gt01 "$tmp/wt" 2>/dev/null
check "the PR worktree starts at the new main, not the old base" "$N" "$(g -C "$tmp/wt" rev-parse HEAD)"
check "so main's own change is not in the PR" "" "$(g -C "$tmp/wt" status --porcelain -- d.txt)"
check "the PR holds the commit, the edit and the new file" "?? c.txt|M a.txt|M b.txt" "$(g -C "$tmp/wt" status --porcelain | grep -vE '\.fxa-|node_modules' | sed 's/^ //' | sort | paste -sd'|' -)"
session_checkout_remove "$tmp/wt"

# Save: the commits go in a bundle, the edit in the patch, the whole change in full.patch.
vm_is_running() { return 0; }; _session_record_summary() { :; }; session_media() { :; }; _thread_save_notes() { :; }
_session_save agent-gt01
check "the save keeps the commits in a bundle" "yes" "$([ -s "$tmp/agent-gt01.bundle" ] && echo yes)"
check "the patch holds only the uncommitted edit" "0|1" "$(grep -c '^+TWO$' "$tmp/agent-gt01.patch")|$(grep -c '^+edit$' "$tmp/agent-gt01.patch")"
check "!diff on a paused session shows the commit too" "1" "$(session_set agent-gt01 state paused; cmd_diff agent-gt01 | grep -c '^+TWO$')"

# Resume on a fresh runner at the session's base: the commits come back, then the edit.
g clone -q "$tmp/origin.git" "$tmp/ws2"; cd "$tmp/ws2" && g checkout -q -B agent-gt01 "$M"
cp "$tmp/agent-gt01.bundle" .fxa-resume.bundle; cp "$tmp/agent-gt01.patch" .fxa-resume.patch
git fetch -q .fxa-resume.bundle HEAD && g checkout -q -B "$(git branch --show-current)" FETCH_HEAD && git apply --whitespace=nowarn .fxa-resume.patch
check "the resumed runner has the commit on the new main" "fix(a): two|$N" "$(g log -1 --format=%s)|$(g rev-parse HEAD~1)"
check "and the uncommitted edit and new file" "edit|new" "$(tail -1 b.txt)|$(cat c.txt)"

# No commits: no bundle.
rm -f "$tmp/agent-gt02.bundle"; echo "{\"key\":\"agent-gt02\",\"state\":\"active\",\"base_sha\":\"$(g -C "$tmp/ws" rev-parse HEAD)\"}" > "$tmp/agent-gt02.json"
worktree_branch_for() { echo "agent-$1"; }; _session_save agent-gt02
check "with no commits since the base there is no bundle" "no" "$([ -e "$tmp/agent-gt02.bundle" ] && echo yes || echo no)"

[ "$fail" = 0 ] && echo "all checks pass"; exit "$fail"
