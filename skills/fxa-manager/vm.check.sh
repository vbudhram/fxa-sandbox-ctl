#!/usr/bin/env bash
# Offline checks for vm.sh's ssh errors.
#   bash skills/fxa-manager/vm.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
eval "$(sed -n '/^on_vm() {/,/^}/p' "$(dirname "$0")/vm.sh")"
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

exit "$fail"
