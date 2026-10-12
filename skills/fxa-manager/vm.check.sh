#!/usr/bin/env bash
# Offline checks for vm.sh's ssh errors and vm.sh dev fn.
#   bash skills/fxa-manager/vm.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
eval "$(sed -n '/^on_vm() {/,/^}/p;/^dev_fn_script() {/,/^}/p' "$(dirname "$0")/vm.sh")"
VM=fxa-manager Z=z P=p
hostname() { echo laptop; }
# gcloud fails the way an expired login does, the way a lost connection does, or the remote command fails.
gcloud() { cat >/dev/null; case "$MODE" in
  login) echo "ERROR: (gcloud.compute.ssh) There was a problem refreshing your current auth tokens: Reauthentication failed. cannot prompt during non-interactive execution." >&2; return 1 ;;
  ssh) echo "Existing host keys found"; echo "ssh: connect to host fxa-manager port 22: Connection timed out" >&2; return 255 ;;
  remote) echo "Existing host keys found in /home/x" >&2; echo out; return 3 ;; esac; }
MODE=login; err="$(echo true | on_vm 2>&1 >/dev/null)"; rc=$?
check "an expired gcloud login: nonzero, and it says how to log in" "1|yes" "$rc|$(grep -q 'gcloud login expired: run ! gcloud auth login' <<< "$err" && echo yes)"
MODE=ssh; err="$(echo true | on_vm 2>&1 >/dev/null)"; rc=$?
check "a failed ssh: 255, and its error is shown" "255|yes" "$rc|$(grep -q 'Connection timed out' <<< "$err" && echo yes)"
MODE=remote; err="$(echo true | on_vm 2>&1 >/dev/null)"; rc=$?
check "a failed remote command: its status, and gcloud's noise stays hidden" "3|" "$rc|$err"

# dev fn: the dev controller's functions, the GCE backend and FXA_FC_HOST, then the commands.
D="$tmp/dev"; mkdir -p "$D/fxa-sandbox-ctl/lib" "$D/fxa-agent-bot"
printf '%s\n' '#!/bin/bash' 'set -euo pipefail' 'SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"' 'source "$SCRIPT_DIR/lib/config.sh"' "trap 'echo crash-recorded' ERR" 'probe() { echo "probe ran"; }' 'main() { echo "main ran"; }' 'main "$@"; exit $?' > "$D/fxa-sandbox-ctl/fxa-sandbox-ctl"
echo 'gce_fn() { echo "gce loaded"; }' > "$D/fxa-sandbox-ctl/lib/vm-gce.sh"; echo 'cfg=1' > "$D/fxa-sandbox-ctl/lib/config.sh"
echo 'FXA_FC_HOST=10.0.0.9' > "$D/fxa-agent-bot/.env.devhost"
out="$( { echo "D=$D"; dev_fn_script 'probe; false; gce_fn; echo "host=$FXA_FC_HOST"; echo err >&2'; } | bash 2>/dev/null)"
check "dev fn: functions load, main does not run, a failure does not stop it or record a crash, stderr is merged" \
  "probe ran|gce loaded|host=10.0.0.9|err" "$(printf '%s\n' "$out" | tr '\n' '|' | sed 's/|$//')"
echo 'OTHER=1' > "$D/fxa-agent-bot/.env.devhost"
out="$( { echo "D=$D"; dev_fn_script 'echo "host=${FXA_FC_HOST:-unset}"'; } | bash 2>&1)"
check "dev fn: a devhost file without FXA_FC_HOST leaves it unset and prints no environment" "host=unset|0" \
  "$(printf '%s\n' "$out" | tail -1)|$(printf '%s\n' "$out" | grep -c 'declare -x')"
exit "$fail"
