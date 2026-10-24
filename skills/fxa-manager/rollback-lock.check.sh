#!/bin/bash
# vm.sh rollback_script: the sync lock line keeps stderr, so a failed reset or npm ci still says why.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"; t="$(mktemp -d "${TMPDIR:-/tmp}/rollback-lock.XXXXXX")"; trap 'rm -rf "$t"' EXIT
line="$(grep -F '/run/fxa-sync.lock' "$here/vm.sh" | head -1)"
[ -n "$line" ] || { echo "FAIL rollback lock: no lock line in vm.sh"; exit 1; }
: > "$t/lock"
err="$(printf '%s\necho after-the-lock >&2\n' "$(printf '%s' "$line" | sed "s#/run/fxa-sync.lock#$t/lock#g; s#flock -w 600 9#:#")" | bash -s 2>&1 >/dev/null)"
if [ "$err" = after-the-lock ]; then echo "ok   rollback lock: a stderr line after the lock still shows"
else echo "FAIL rollback lock: a stderr line after the lock is lost (got '${err}')"; exit 1; fi
