#!/usr/bin/env bash
# Offline check for a repo whose default branch is not main (syncstorage-rs uses master): the
# session fetches the profile's base, and the runner gets origin/main as an alias of it.
#   bash lib/base-branch.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
here="$(cd "$(dirname "$0")" && pwd)"
# Out of the repo: a mounted checkout reads as dubious ownership to git in the Linux test run.
cd "$tmp"
eval "$(sed -n '/^_gce_pin_runner_tree() {/,/^}/p' "$here/agent.sh")"
# The runner: the pin's one command goes to a file, and the runner answers with the pinned sha.
vm_exec() { shift; case "$1" in test) return 0 ;; esac; printf '%s\n' "$*" > "$tmp/pin.cmd"; echo "$FXA_PIN_SHA"; }
LOG_DIR="$tmp"; S=1111111111111111111111111111111111111111 B=2222222222222222222222222222222222222222
pin() { FXA_WORKTREE_BASE="$1" FXA_PIN_SHA="$S" FXA_PIN_BASE_SHA="$B" FXA_PIN_BRANCH=agent-x _gce_pin_runner_tree r1 "$tmp" >/dev/null; }
pin master
check "a master base moves origin/master, and makes origin/main its alias when the repo has none" "1|1" \
  "$(grep -c "update-ref refs/remotes/origin/master $B" "$tmp/pin.cmd")|$(grep -c "\[ 'master' = main \] || git rev-parse -q --verify refs/remotes/origin/main >/dev/null || git update-ref refs/remotes/origin/main $B" "$tmp/pin.cmd")"
# The alias line, run in a real clone: it adds origin/main only where it is missing.
g() { git -c user.name=t -c user.email=t@example.com "$@"; }
r="$tmp/repo"; git init -q "$r"; g -C "$r" commit -q --allow-empty -m one; b1="$(git -C "$r" rev-parse HEAD)"
git -C "$r" update-ref refs/remotes/origin/master "$b1"
alias_line="$(grep -o "\[ 'master' = main \] ||.*" <<< "$(pin master; cat "$tmp/pin.cmd")" | head -1 | sed "s/$B/$b1/")"
( cd "$r" && eval "$alias_line" )
check "in a clone with no origin/main, the alias points at the base" "$b1" "$(git -C "$r" rev-parse -q --verify refs/remotes/origin/main)"
g -C "$r" commit -q --allow-empty -m two; b2="$(git -C "$r" rev-parse HEAD)"; git -C "$r" update-ref refs/remotes/origin/main "$b2"
( cd "$r" && eval "$alias_line" )
check "a real origin/main is left alone" "$b2" "$(git -C "$r" rev-parse refs/remotes/origin/main)"
r2="$tmp/repo2"; git init -q "$r2"; g -C "$r2" commit -q --allow-empty -m one
main_line="$(grep -o "\[ 'main' = main \] ||.*" <<< "$(pin main; cat "$tmp/pin.cmd")" | head -1 | sed "s/$B/$(git -C "$r2" rev-parse HEAD)/")"
( cd "$r2" && eval "$main_line" )
check "a main base makes no alias" "none" "$(git -C "$r2" rev-parse -q --verify refs/remotes/origin/main || echo none)"
check "the session fetches the profile's base, not main" "1|0" \
  "$(grep -c 'fetch --quiet origin "\$base"' "$here/../fxa-sandbox-ctl")|$(grep -c 'fetch --quiet origin main &&' "$here/../fxa-sandbox-ctl")"
exit "$fail"
