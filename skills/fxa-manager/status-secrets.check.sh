#!/usr/bin/env bash
# Offline check that vm.sh status lists every secret infra/gce/fxa-secrets.sh reads, from that script itself.
#   bash skills/fxa-manager/status-secrets.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
here="$(cd "$(dirname "$0")" && pwd)"
names="$(grep -oE '(need|get) fxa-[a-z0-9-]+' "$here/../../infra/gce/fxa-secrets.sh" | awk '{print $2}' | sort -u)"
check "fxa-secrets.sh reads the secrets this list takes, the dashboard key and the Jira email among them" "yes|yes|yes" \
  "$([ "$(grep -c . <<< "$names")" -ge 12 ] && echo yes)|$(grep -qx fxa-dashboard-hmac <<< "$names" && echo yes)|$(grep -qx fxa-jira-email <<< "$names" && echo yes)"
check "vm.sh status reads the list from fxa-secrets.sh, not a copy" "1|0" \
  "$(grep -c "grep -oE '(need|get) fxa-\[a-z0-9-\]+' /home/fxa/Desktop/working2/fxa-sandbox-ctl/infra/gce/fxa-secrets.sh" "$here/vm.sh")|$(grep -c 'for s in fxa-slack-bot-token' "$here/vm.sh")"
check "vm.sh status takes the optional ones from opt_get in fxa-secrets.sh, not a fixed list" "1|0" \
  "$(grep -c 'grep -q "opt_get $s" /home/fxa/Desktop/working2/fxa-sandbox-ctl/infra/gce/fxa-secrets.sh' "$here/vm.sh")|$(grep -c '^opt=" fxa-' "$here/vm.sh")"
[ "$fail" = 0 ] && echo "all checks pass"
exit "$fail"
