#!/usr/bin/env bash
# Offline check for verify.sh's lint row: fxa-settings fails on a warning, as its CI build does; other packages do not.
#   bash skills/fxa-verify/lint.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
add() { cmd="$3"; }; pre="" r="src/a.tsx"
row="$(grep -m1 'add "${pre}$p lint"' "$(dirname "$0")/verify.sh")"
p=packages/fxa-settings; eval "$row"; check "fxa-settings lint fails on a warning" "npx eslint --max-warnings 0 src/a.tsx" "$cmd"
p=packages/fxa-auth-server; eval "$row"; check "other packages lint as before" "npx eslint src/a.tsx" "$cmd"
exit "$fail"
