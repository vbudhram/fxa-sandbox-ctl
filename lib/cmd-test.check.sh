#!/usr/bin/env bash
# Offline check that `test` runs Playwright in the VM on the local project, with the args quoted.
#   bash lib/cmd-test.check.sh
set -u
fail=0
check() { # check <name> <want> <got>
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi
}

eval "$(sed -n '/^cmd_test() {/,/^}/p' "$(dirname "$0")/../fxa-sandbox-ctl")"
vm_is_running() { :; }
vm_exec_as_agent() { echo "$2"; }

got="$(cmd_test a1 -- "tests/a b.spec.ts" -g x | tail -1)"
check "local project" "yes" "$(grep -q -- '--project=local tests/a\\ b.spec.ts -g x$' <<<"$got" && echo yes)"
check "no sandbox project" "no" "$(grep -q sandbox <<<"$got" && echo yes || echo no)"

exit "$fail"
