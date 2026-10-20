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

# The local services the agent drives (Redis, MySQL, goaws as root) get loopback only, when the agent is limited.
vm_exec() { [ "$3" = env ] && printf "%s" "${!#}" > "$tmp_s"; return 0; }
tmp_s="$(mktemp)"; _setup_egress_firewall vm >/dev/null 2>&1
check "the script limits redis-server, mysql and goaws to loopback" "yes|yes" \
  "$(grep -q 'for u in redis-server mysql goaws' "$tmp_s" && echo yes)|$(grep -q 'set-property --runtime "$u.service" IPAddressDeny=any IPAddressAllow=localhost' "$tmp_s" && echo yes)"
check "the service limit sits in the limited branch, after the agent REJECT" "yes" \
  "$(awk '/--uid-owner agent -j REJECT --reject-with/ {r=NR} /for u in redis-server mysql goaws/ {u=NR} /if \[ "\$FXA_EGRESS_ALLOW_ALL" = "1" \]; then/ && !a {a=NR} END {print (r && u > r && a < r) ? "yes" : "no"}' "$tmp_s")"
# A unit that is stopped now (goaws waits to restart) still gets the limit; a unit that is not installed is skipped.
loop="$(sed -n '/for u in redis-server mysql goaws; do/,/^ *done$/p' "$tmp_s")"
check "a stopped but loaded unit still gets the loopback limit" "goaws.service|mysql.service|redis-server.service" "$(bash -c '
  systemctl() { case "$1 $2" in "show -p") [ "$4" = nothere.service ] && echo not-found || echo loaded ;; "is-active -q") return 3 ;;
    "set-property --runtime") echo "$3" >> "'"$tmp_s"'.set" ;; esac; [ "$1" = show ] && [ "$3" = IPAddressDeny ] && echo any; return 0; }
  '"$loop"'' >/dev/null 2>&1; sort "$tmp_s.set" 2>/dev/null | paste -sd'|' -)"
rm -f "$tmp_s" "$tmp_s.set"

# After the firewall, the agent's DNS filter runs with the allowed hosts, from templates/agent-dns.sh.
# The calls tell apart by their third word: env for the firewall, bash for the DNS step.
log="$(mktemp)"
vm_exec() { if [ "$3" = bash ]; then printf 'dns %s|%s\n' "${*:8}" "$(printf %s "$7" | base64 -d | head -c 34 | tr '\n' ' ')" >> "$log"; else echo fw >> "$log"; fi; }
_setup_egress_firewall vm >/dev/null 2>&1
check "the DNS filter runs after the firewall, with the hosts, from the template" "fw|dns github.com|#!/bin/bash # agent-dns.sh <host>." \
  "$(sed -n 1p "$log")|$(sed -n 2p "$log" | sed 's/ *$//')"
: > "$log"; FXA_EGRESS_ALLOW_ALL=1 _setup_egress_firewall vm >/dev/null 2>&1; FXA_EGRESS_ALLOW_ALL=0
check "an allow-all run has no DNS filter" "fw" "$(paste -sd'|' "$log")"
vm_exec() { [ "$3" = bash ] || return 0; echo "egress: the agent's DNS answered a name outside the allowlist" >&2; return 1; }
out="$(_setup_egress_firewall vm 2>&1)"; rc=$?
check "a DNS filter that leaks fails the launch, and says why" "1|yes" "$rc|$(grep -q 'outside the allowlist' <<< "$out" && echo yes)"
vm_exec() { [ "$3" = bash ] || return 0; echo "egress: dnsmasq-base did not install, so the agent's DNS cannot be filtered" >&2; return 1; }
check "a missing dnsmasq fails the launch, and says why" "1|yes" "$(out="$(_setup_egress_firewall vm 2>&1)"; echo "$?|$(grep -q 'cannot be filtered' <<< "$out" && echo yes)")"
check "the template exits 1 when dnsmasq cannot be had" "yes" "$(grep -q 'cannot be filtered" >&2; exit 1; }' "$(dirname "$0")/../templates/agent-dns.sh" 2>/dev/null && echo yes)"
# tart exec passes no stdin: the runner's bash still runs the template, with the hosts.
fake="$(mktemp -d)"; mkdir "$fake/templates"
printf '%s\n' 'echo "egress: WARN ran with $*" >&2' > "$fake/templates/agent-dns.sh"
vm_exec() { [ "$3" = bash ] || return 0; shift 2; "$@" < /dev/null; }
check "the template runs on a backend with no stdin" "egress: WARN ran with github.com" "$(SANDBOX_ROOT="$fake" _setup_agent_dns vm github.com 2>&1)"
# The template itself, with fake tools: the agent's resolved API stays open, so it must fail.
bin="$(mktemp -d)"
for t in dnsmasq iptables busctl chmod; do printf '#!/bin/sh\nexit 0\n' > "$bin/$t"; done
printf '#!/bin/sh\n[ "$1" = -u ] && shift 2\nexec "$@"\n' > "$bin/sudo"
printf '#!/bin/sh\n[ "$2" = github.com ]\n' > "$bin/getent"
printf '#!/bin/sh\nexit 0\n' > "$bin/resolvectl"
# A fake varlinkctl too: the host's real one would ask the host's own resolved.
printf '#!/bin/sh\nexit 1\n' > "$bin/varlinkctl"
chmod +x "$bin"/*
run_tpl() { PATH="$bin:/usr/bin:/bin" bash "$SANDBOX_ROOT/templates/agent-dns.sh" github.com 2>&1 | grep '^egress:'; }
check "an open resolved D-Bus API fails the launch" "egress: the agent can look up any name through resolved's D-Bus API" "$(run_tpl)"
printf '#!/bin/sh\nexit 1\n' > "$bin/resolvectl"; printf '#!/bin/sh\nexit 0\n' > "$bin/varlinkctl"
check "an open resolved varlink socket fails the launch" "egress: the agent can look up any name through resolved's varlink socket" "$(run_tpl)"
printf '#!/bin/sh\nexit 1\n' > "$bin/varlinkctl"
check "a closed resolved API passes" "" "$(run_tpl)"

# The remote script itself, with fake firewall tools. The fake sudo decides what the agent reaches.
fw="$(mktemp -d)"
for t in iptables ip6tables; do cat > "$fw/$t" <<'FAKE'
#!/bin/sh
f="$0.rules"
case "$1" in
  -F) : > "$f" ;;
  -A) shift; echo "-A $*" >> "$f" ;;
  -S) [ -n "${NO_V6:-}" ] && [ "${0##*/}" = ip6tables ] && exit 1; cat "$f" 2>/dev/null ;;
  -D) exit 1 ;;
esac
exit 0
FAKE
done
printf '#!/bin/sh\necho "default via 10.0.0.1 dev eth0"\n' > "$fw/ip"
printf '#!/bin/sh\necho "140.82.112.3 STREAM github.com"\n' > "$fw/getent"
cat > "$fw/sudo" <<'FAKE'
#!/bin/sh
[ "$1" = -u ] && shift 2
case "$*" in
  *github.com*) exit 0 ;;
  *169.254.169.254*) [ -n "${META_OPEN:-}" ] ;;
  *::*) [ -n "${V6_OPEN:-}" ] ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$fw"/*
vm_exec() { [ "$3" = env ] || return 0; shift 2; PATH="$fw:/usr/bin:/bin" "$@"; }
fw_run() { rm -f "$fw"/*.rules; out="$(_setup_egress_firewall vm 2>&1)"; echo "$?|$out"; }
check "the remote script passes with fake tools" "0|" "$(fw_run)"
check "over IPv6 the agent user gets loopback alone" "-A OUTPUT -o lo -j ACCEPT|-A OUTPUT -m owner --uid-owner agent -j REJECT" "$(paste -sd'|' "$fw/ip6tables.rules")"
check "a reachable metadata server fails the launch" "1|egress: agent user reached the metadata server" "$(META_OPEN=1 fw_run)"
check "a host reached over IPv6 fails the launch" "1|egress: agent user reached a host over IPv6" "$(V6_OPEN=1 fw_run)"
check "a guest without ip6tables still passes" "0|" "$(NO_V6=1 fw_run)"
FXA_EGRESS_ALLOW_ALL=1 fw_run >/dev/null; FXA_EGRESS_ALLOW_ALL=0
check "an allow-all run leaves IPv6 open" "-A OUTPUT -o lo -j ACCEPT" "$(paste -sd'|' "$fw/ip6tables.rules")"
rm -rf "$log" "$fake" "$bin" "$fw"

exit "$fail"
