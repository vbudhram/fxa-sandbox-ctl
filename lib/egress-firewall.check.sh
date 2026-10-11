#!/usr/bin/env bash
# Offline check that a failed egress firewall apply says which check failed.
#   bash lib/egress-firewall.check.sh
set -u
fail=0
check() { # check <name> <want> <got>
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi
}

eval "$(sed -n '/^_setup_egress_firewall() {/,/^}/p;/^_profile_egress_extra() {/,/^}/p;/^_setup_agent_dns() {/,/^}/p' "$(dirname "$0")/agent.sh")"
SANDBOX_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FXA_EGRESS_ALLOW_ALL=0 FXA_EGRESS_CIDRS="" FXA_EGRESS_HOSTS="github.com"
_github_meta_cidrs() { :; } # offline: no fetch of GitHub's published ranges

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

# After the firewall, the agent's DNS filter runs with the allowed hosts, from templates/agent-dns.sh.
# The calls tell apart by their third word: env for the firewall, bash for the DNS step.
log="$(mktemp)"
vm_exec() { if [ "$3" = bash ]; then printf 'dns %s|%s\n' "${*:5}" "$(head -c 34 | tr '\n' ' ')" >> "$log"; else echo fw >> "$log"; fi; }
_setup_egress_firewall vm >/dev/null 2>&1
check "the DNS filter runs after the firewall, with the hosts, from the template" "fw|dns -- github.com|#!/bin/bash # agent-dns.sh <host>." \
  "$(sed -n 1p "$log")|$(sed -n 2p "$log" | sed 's/ *$//')"
: > "$log"; FXA_EGRESS_ALLOW_ALL=1 _setup_egress_firewall vm >/dev/null 2>&1; FXA_EGRESS_ALLOW_ALL=0
check "an allow-all run has no DNS filter" "fw" "$(paste -sd'|' "$log")"
vm_exec() { [ "$3" = bash ] || return 0; echo "egress: the agent's DNS answered a name outside the allowlist" >&2; return 1; }
out="$(_setup_egress_firewall vm 2>&1)"; rc=$?
check "a DNS filter that leaks fails the launch, and says why" "1|yes" "$rc|$(grep -q 'outside the allowlist' <<< "$out" && echo yes)"
vm_exec() { [ "$3" = bash ] || return 0; echo "egress: WARN dnsmasq-base did not install" >&2; return 0; }
check "a missing dnsmasq warns and goes on" "0|egress: WARN dnsmasq-base did not install" "$(out="$(_setup_egress_firewall vm 2>&1)"; echo "$?|$out")"
rm -f "$log"

exit "$fail"
