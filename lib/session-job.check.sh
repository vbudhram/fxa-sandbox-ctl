#!/usr/bin/env bash
# Offline check that a boot or finish job that died settles its session and names the ship that was started.
#   bash lib/session-job.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
eval "$(sed -n '/^_session_job_died() {/,/^}/p' "$(dirname "$0")/../fxa-sandbox-ctl")"
SESSION_DIR="$tmp"
session_get() { [ "$2" = wrap_mode ] && cat "$tmp/mode" 2>/dev/null; true; }
session_set() { shift; printf '%s\n' "$*" >> "$tmp/set"; }
errors_record() { echo "$2" >> "$tmp/err"; }
run() { : > "$tmp/set"; : > "$tmp/err"; printf '%s' "$1" > "$tmp/mode"; echo "$(_session_job_died agent-ab12 "$2")|$(cat "$tmp/set")|$(cat "$tmp/err")"; }
check "a dead Push branch job says Push branch" "active|state active last_error Push branch stopped before it finished. Try again.|finish_died" "$(run push wrapping)"
check "a dead Open PR job says Open PR" "active|state active last_error Open PR stopped before it finished. Try again.|finish_died" "$(run pr wrapping)"
check "a dead boot job fails the session" "failed|state failed|boot_died" "$(run "" starting)"
check "any other state is left as it is" "active||" "$(run "" active)"
exit "$fail"
