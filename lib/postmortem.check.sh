#!/usr/bin/env bash
# Offline check of the runner postmortem: a team profile's failed boot reaches the error store.
#   bash lib/postmortem.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
eval "$(sed -n '/^_runner_postmortem() {/,/^}/p' "$(dirname "$0")/agent.sh")"
FXA_VM_BACKEND=gce LOG_DIR="$tmp" SESSION_DIR="$tmp/none"
# The runner's script runs here, on fake files in place of /run/fxa-profile and the boot log.
vm_exec() { local c="$4"; c="${c//\/run\/fxa-profile/$tmp/run}"; c="${c//\/var\/log\//$tmp/log/}"; bash -c "$c"; }
errors_record() { echo "$*" >> "$tmp/errors"; }
mkdir -p "$tmp/run" "$tmp/log"; echo "cargo build failed" > "$tmp/run/failed"; printf 'step %s\n' 1 2 3 4 5 6 > "$tmp/log/profile-boot.log"
out="$(_runner_postmortem agent-x 2>/dev/null)"
check "a failed profile boot is in the postmortem, with the boot log's end" "1|5" "$(grep -c '^  profile boot failed: cargo build failed' <<< "$out")|$(grep -c '^    boot: step' <<< "$out")"
check "and in the error store" "1" "$(grep -c '^runner profile_boot agent-x runner profile boot profile boot failed: cargo build failed' "$tmp/errors")"
# The build log a step names goes with the runner: its error lines go into the kept postmortem.
echo "cargo build failed (see $tmp/log/syncstorage-build.log)" > "$tmp/run/failed"
printf '   Compiling x\nerror[E0425]: cannot find value `y` in this scope\n  --> src/main.rs:3\n' > "$tmp/log/syncstorage-build.log"
out="$(_runner_postmortem agent-z 2>/dev/null)"
check "the named build log's error is in the postmortem and its kept file" "1|1" "$(grep -c '^    build: error\[E0425\]: cannot find value' <<< "$out")|$(grep -c '^  build: error\[E0425\]' "$tmp/agent-z.postmortem")"
rm -f "$tmp/run/failed" "$tmp/errors"
_runner_postmortem agent-y >/dev/null 2>&1
check "a good boot records nothing" "0" "$( [ -f "$tmp/errors" ] && grep -c profile_boot "$tmp/errors" || echo 0)"
[ "$fail" = 0 ] && echo "all checks pass"; exit "$fail"
