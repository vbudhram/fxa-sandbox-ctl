#!/usr/bin/env bash
# Offline check of android-verify's pass rule: Playwright's exit and its summary lines.
#   bash lib/android-verify.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
eval "$(sed -n '/^_pw_passed() {/p' "$(dirname "$0")/../skills/android-verify/verify.sh")"
v() { printf '%b' "$2" > "$tmp/log"; _pw_passed "$1" "$tmp/log" && echo pass || echo fail; }
check "one test passed: pass; one of two failed: fail; two passed: pass" "pass fail pass" \
  "$(v 0 '  1 passed (30s)\n') $(v 1 '  1 failed\n  1 passed (40s)\n') $(v 0 '  2 passed (50s)\n')"
check "a zero exit with no summary, or a flaky retry, is not a pass" "fail fail" "$(v 0 'Error: no tests\n') $(v 0 '  1 flaky\n  1 passed\n')"
check "a nonzero exit after a passed summary (a timeout, a teardown error) is not a pass" "fail" "$(v 124 '  1 passed (30s)\n')"
[ "$fail" = 0 ] && echo "all checks pass"; exit "$fail"
