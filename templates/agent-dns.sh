#!/bin/bash
# agent-dns.sh <host>...   Run as root on the runner, after the egress firewall. The agent
# user's DNS then answers only the names it may connect to: the given hosts, and GitHub and
# Anthropic, which the firewall allows by address range. Any other name is refused, so a lookup
# such as <data>.attacker.example cannot carry data out. Root and services keep the normal resolver.
# Exit 1 when the filter leaks or breaks GitHub; 0 with a WARN when dnsmasq cannot be had.
set -u
command -v dnsmasq >/dev/null 2>&1 || {
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y -qq dnsmasq-base >/dev/null 2>&1 || { apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq dnsmasq-base >/dev/null 2>&1; }
}
command -v dnsmasq >/dev/null 2>&1 || { echo "egress: WARN dnsmasq-base did not install; the agent's DNS is not filtered" >&2; exit 0; }

up="$(awk '/^nameserver/ { print $2; exit }' /etc/resolv.conf)"
[ -n "$up" ] || { echo "egress: no nameserver in /etc/resolv.conf" >&2; exit 1; }
conf=/run/fxa-agent-dns.conf pid=/run/fxa-agent-dns.pid
{ echo "listen-address=127.0.0.2"; echo "bind-interfaces"; echo "no-resolv"; echo "no-hosts"; echo "cache-size=1000"
  for d in "$@" github.com githubusercontent.com githubassets.com anthropic.com; do
    [[ "$d" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] && echo "server=/${d}/${up}"
  done; } > "$conf"
[ -s "$pid" ] && kill "$(cat "$pid")" 2>/dev/null && sleep 0.2
dnsmasq --conf-file="$conf" --pid-file="$pid" || { echo "egress: the agent's DNS filter did not start" >&2; exit 1; }

# Every lookup the agent makes, to any resolver, goes to the filter.
iptables -t nat -N FXA_AGENT_DNS 2>/dev/null || true
{ iptables -t nat -F FXA_AGENT_DNS \
  && iptables -t nat -A FXA_AGENT_DNS -p udp --dport 53 -j DNAT --to-destination 127.0.0.2:53 \
  && iptables -t nat -A FXA_AGENT_DNS -p tcp --dport 53 -j DNAT --to-destination 127.0.0.2:53 \
  && { iptables -t nat -C OUTPUT -m owner --uid-owner agent -j FXA_AGENT_DNS 2>/dev/null \
       || iptables -t nat -A OUTPUT -m owner --uid-owner agent -j FXA_AGENT_DNS; }; } \
  || { echo "egress: the agent's DNS redirect did not apply" >&2; exit 1; }

# Assert behaviour: a real name outside the list (example.com resolves everywhere) is refused,
# and GitHub still resolves.
if sudo -u agent getent ahostsv4 example.com >/dev/null 2>&1; then
  echo "egress: the agent's DNS answered a name outside the allowlist" >&2; exit 1
fi
sudo -u agent getent ahostsv4 github.com >/dev/null 2>&1 \
  || { sleep 2; sudo -u agent getent ahostsv4 github.com >/dev/null 2>&1; } \
  || { echo "egress: the agent's DNS filter does not resolve github.com" >&2; exit 1; }
