#!/usr/bin/env bash
# Offline check that a pause keeps the work files and .fxa-keep, and leaves .fxa-keep behind past 9 MB.
#   bash lib/session-keep.check.sh
set -u
fail=0
check() { # check <name> <want> <got>
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi
}
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
eval "$(grep "^_SESSION_WORK_TAR=" "$(dirname "$0")/session.sh")"
files() { (cd "$tmp" && eval "$_SESSION_WORK_TAR") | tar -tzf - 2>/dev/null | grep -v '/$' | sort | tr '\n' ' '; }

check "nothing to keep: no archive" "" "$(files)"
echo '{}' > "$tmp/.fxa-test-plan.json"; mkdir -p "$tmp/.fxa-keep/perf"; echo x > "$tmp/.fxa-keep/perf/measure.js"; echo y > "$tmp/other.txt"
check "the plan and .fxa-keep, nothing else" ".fxa-keep/perf/measure.js .fxa-test-plan.json " "$(files)"
# 9.5 MB that does not compress: under the old 10 MB test it passed, and the 10 MB cut broke the archive.
head -c 9961472 /dev/urandom > "$tmp/.fxa-keep/big.bin"
check "over 9 MB: .fxa-keep stays behind" ".fxa-test-plan.json " "$(files)"

exit "$fail"
