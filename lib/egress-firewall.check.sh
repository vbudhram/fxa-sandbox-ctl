#!/usr/bin/env bash
# Offline check that a failed egress firewall apply says which check failed.
#   bash lib/egress-firewall.check.sh
set -u
fail=0
check() { # check <name> <want> <got>
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi
}

eval "$(sed -n '/^_setup_egress_firewall() {/,/^}/p' "$(dirname "$0")/agent.sh")"
FXA_EGRESS_ALLOW_ALL=0 FXA_EGRESS_CIDRS="" FXA_EGRESS_HOSTS="github.com"

# The remote script failed its reachability assert.
vm_exec() { echo "egress: agent user cannot reach github.com; allowlist too tight" >&2; return 1; }
out="$(_setup_egress_firewall vm 2>&1)"; rc=$?
check "failure returns non-zero" "1" "$rc"
check "failure names the check" "yes" "$(grep -q 'cannot reach github.com' <<<"$out" && echo yes)"

# ssh itself failed and the script printed nothing.
vm_exec() { return 255; }
out="$(_setup_egress_firewall vm 2>&1)"; rc=$?
check "silent failure keeps its code" "255" "$rc"
check "silent failure still reports" "yes" "$(grep -q 'exit 255' <<<"$out" && echo yes)"

# Success stays quiet.
vm_exec() { return 0; }
check "success is silent" "" "$(_setup_egress_firewall vm 2>&1)"

exit "$fail"
