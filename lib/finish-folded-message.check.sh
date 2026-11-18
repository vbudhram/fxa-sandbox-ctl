#!/usr/bin/env bash
# Offline check that a round which folds a pushed PR into one commit keeps the PR's own message.
#   bash lib/finish-folded-message.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
eval "$(sed -n '/^_finish_folded_message() {/,/^}/p' "$(dirname "$0")/finish.sh")"
g() { git -C "$tmp/$1" -c user.email=b@example.com -c user.name='fxa-agent[bot]' -c core.hooksPath=/dev/null "${@:2}"; }
git init -q -b main "$tmp/up" && echo a > "$tmp/up/a" && g up add . && g up commit -qm base
g up checkout -qb fix && echo b > "$tmp/up/b" && g up add b && g up commit -qm "fix(x): the change" -m "Closes FXA-1"
echo c > "$tmp/up/b" && g up commit -qam "fix(x): a round" && g up checkout -q main
git clone -q "$tmp/up" "$tmp/wt"
base="$(g wt rev-parse origin/main)" head="$(g wt rev-parse origin/fix)"
check "the squash folds the PR: its first commit's message" "fix(x): the change|Closes FXA-1" \
  "$(_finish_folded_message "$tmp/wt" fix "$base" | sed '/^$/d' | paste -sd'|' -)"
check "the round goes on top of the PR head: no message" "" "$(_finish_folded_message "$tmp/wt" fix "$head")"
check "no pushed PR yet: no message" "" "$(_finish_folded_message "$tmp/wt" new "$base")"
exit "$fail"
