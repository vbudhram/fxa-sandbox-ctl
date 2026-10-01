#!/usr/bin/env bash
# Offline check that tsc_files fails only on type errors in the changed files.
#   bash skills/fxa-verify/types.check.sh
set -u
fail=0
check() { # check <name> <want> <got>
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi
}
eval "$(sed -n '/^tsc_files() {/,/^}/p' "$(dirname "$0")/verify.sh")"
npx() { printf '%s\n' "lib/old.ts(4,1): error TS2339: on main" "tests/x.spec.ts(9,2): error TS7006: new" "sub/tests/x.spec.ts(1,1): error TS1: other"; }

tsc_files tsconfig.json lib/a.ts >/dev/null; check "errors only in other files pass" 0 $?
check "the pass names the other errors" "no type errors in the changed files (3 in other files, as on main)" "$(tsc_files tsconfig.json lib/a.ts)"
tsc_files tsconfig.json tests/x.spec.ts >/dev/null; check "an error in a changed file fails" 1 $?
check "only that file's error is printed, not a longer path that ends the same" "tests/x.spec.ts(9,2): error TS7006: new" "$(tsc_files tsconfig.json tests/x.spec.ts)"
npx() { :; }
tsc_files tsconfig.json tests/x.spec.ts >/dev/null; check "a clean tsc passes" 0 $?

[ "$fail" = 0 ] && echo "all checks pass"; exit "$fail"
