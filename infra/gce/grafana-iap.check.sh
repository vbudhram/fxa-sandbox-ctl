#!/usr/bin/env bash
# Offline check that manager setup keeps a grafana-iap an operator disabled off, and turns it on otherwise.
#   bash infra/gce/grafana-iap.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
f="$(dirname "$0")/manager-setup.sh"
code="$(sed -n '/^iap_state=/p; /^if \[ "\$iap_state" = disabled \]/,/fi$/p' "$f")"
[ -n "$code" ] || { echo "FAIL the grafana-iap lines are not in manager-setup.sh"; exit 1; }
# A fake systemctl: is-enabled answers STATE (none: a new manager); every other call is printed.
systemctl() {
  case "$1" in
    is-enabled) [ -n "$STATE" ] || return 1; echo "$STATE"; [ "$STATE" = enabled ] ;;
    *) echo "systemctl $*" ;;
  esac
}
iap_calls() { STATE="$1"; eval "$code" | grep -c '^systemctl .*fxa-grafana-iap'; }
check "disabled by an operator: setup leaves it off" "0" "$(iap_calls disabled)"
check "enabled: setup enables and restarts it" "2" "$(iap_calls enabled)"
check "a new manager: setup turns it on" "2" "$(iap_calls "")"
[ "$fail" = 0 ] && echo "all checks pass"; exit "$fail"
