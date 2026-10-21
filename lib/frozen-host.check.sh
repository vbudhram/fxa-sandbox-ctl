#!/usr/bin/env bash
# Offline check of _finish_check_frozen (lib/finish.sh): the frozen-path check runs with the team clone's
# ts-node, or the FxA host clone's when the team's clone has no install (a private fork), and says so when
# neither can run it, in place of "rejects this change".
#   bash lib/frozen-host.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
T="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$T"' EXIT
eval "$(sed -n '/^_finish_check_frozen() {/,/^}/p' "$(dirname "$0")/finish.sh")"
mkdir -p "$T/fork" "$T/fxa/node_modules/.bin" "$T/wt"
printf '#!/bin/sh\n' > "$T/fxa/node_modules/.bin/ts-node"; chmod +x "$T/fxa/node_modules/.bin/ts-node"
worktree_repo_root() { echo "$T/fork"; }; worktree_git_ok() { echo "$T/wt/.git"; }
pipeline_host_clone() { echo "$FXA_CLONE"; }
git() { case "$*" in *"show origin/main:_scripts/check-frozen.ts") echo 'console.log("frozen check")' ;; *) command git "$@" ;; esac; }
npx() { pwd -P > "$T/ran-in"; [ -z "${REJECT:-}" ]; }
run() { rm -f "$T/ran-in"; ( _finish_check_frozen "$T/wt" ) 2>&1; echo "rc=$?"; }
FXA_CLONE="$T/fxa"
check "a fork clone with no install runs the check with the FxA clone's ts-node" "rc=0|$T/fxa" "$(run | tail -1)|$(cat "$T/ran-in")"
mkdir -p "$T/fork/node_modules/.bin"; cp "$T/fxa/node_modules/.bin/ts-node" "$T/fork/node_modules/.bin/"
check "a clone with its own install runs it there, as before" "rc=0|$T/fork" "$(run | tail -1)|$(cat "$T/ran-in")"
check "a real rejection still says so" "1|rc=1" "$(REJECT=1 run | grep -c 'rejects this change')|$(REJECT=1 run | tail -1)"
rm -rf "$T/fork/node_modules"; FXA_CLONE="$T/none"
o="$(run)"
check "no ts-node anywhere: a could-not-run error with the next step, not a rejection, and no run" "1|0|rc=1|no" \
  "$(grep -c "the frozen-path check could not run: no ts-node in $T/fork or in the FxA host clone. Run yarn install in $T/fork" <<< "$o")|$(grep -c 'rejects this change' <<< "$o")|$(tail -1 <<< "$o")|$([ -e "$T/ran-in" ] && echo yes || echo no)"
[ "$fail" = 0 ] && echo "all checks pass"; exit "$fail"
