#!/usr/bin/env bash
# Offline check for shoot.mjs argument parsing.
#   bash skills/fxa-storybook-capture/shoot.check.sh
set -u
fail=0
check() { # check <name> <want> <got>
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi
}
command -v node >/dev/null || { echo "skip: needs node"; exit 0; }
S="$(cd "$(dirname "$0")" && pwd)/shoot.mjs"
node --check "$S"; check "shoot.mjs parses" 0 $?
check "a dry run lists each shot" "a--b -> /workspace/.fxa-auto-media/01-x.png (900x700)|c--d -> /workspace/.fxa-auto-media/02-y.png (900x700)" \
  "$(node "$S" a--b:01-x c--d:02-y --dry-run | paste -sd'|' -)"
check "--viewport sets the size" "a--b -> /workspace/.fxa-auto-media/01-x.png (1280x800)" "$(node "$S" a--b:01-x --viewport 1280x800 --dry-run)"
node "$S" --dry-run >/dev/null 2>&1; check "no shots is a usage error" 2 $?
node "$S" a--b --dry-run >/dev/null 2>&1; check "an id with no slug is a usage error" 2 $?
node "$S" a--b:01-x --viewport 900 --dry-run >/dev/null 2>&1; check "a bad viewport is a usage error" 2 $?
[ "$fail" = 0 ] && echo "all checks pass"; exit "$fail"
