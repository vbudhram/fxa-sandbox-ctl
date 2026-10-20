#!/bin/bash
# agent-dns.sh <host>...   Run as root on the runner, after the egress firewall. The agent
# user's DNS then answers only the names it may connect to: the given hosts, and GitHub and
# Anthropic, which the firewall allows by address range. Any other name is refused, so a lookup
# such as <data>.attacker.example cannot carry data out. Root and services keep the normal resolver.
# Exit 1 when the filter leaks, breaks GitHub, or dnsmasq cannot be had: the agent never runs with open DNS.
set -u
command -v dnsmasq >/dev/null 2>&1 || {
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y -qq dnsmasq-base >/dev/null 2>&1 || { apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq dnsmasq-base >/dev/null 2>&1; }
}
command -v dnsmasq >/dev/null 2>&1 || { echo "egress: dnsmasq-base did not install, so the agent's DNS cannot be filtered" >&2; exit 1; }

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

# resolved also answers over D-Bus and varlink, and sends those lookups as its own user, past the
# redirect: close both to the agent. Nothing on the runner looks up names over varlink (hosts: files dns).
mkdir -p /etc/dbus-1/system.d 2>/dev/null && printf '%s\n' \
  '<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-BUS Bus Configuration 1.0//EN" "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">' \
  '<busconfig><policy user="agent"><deny send_destination="org.freedesktop.resolve1"/></policy></busconfig>' \
  > /etc/dbus-1/system.d/fxa-agent-dns.conf 2>/dev/null \
  && busctl call org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus ReloadConfig >/dev/null 2>&1
[ -S /run/systemd/resolve/io.systemd.Resolve ] && chmod 0660 /run/systemd/resolve/io.systemd.Resolve
if command -v resolvectl >/dev/null 2>&1 && sudo -u agent resolvectl query example.com >/dev/null 2>&1; then
  echo "egress: the agent can look up any name through resolved's D-Bus API" >&2; exit 1
fi
if command -v varlinkctl >/dev/null 2>&1 && sudo -u agent varlinkctl call /run/systemd/resolve/io.systemd.Resolve \
     io.systemd.Resolve.ResolveHostname '{"name":"example.com"}' >/dev/null 2>&1; then
  echo "egress: the agent can look up any name through resolved's varlink socket" >&2; exit 1
fi

# Assert behaviour: a real name outside the list (example.com resolves everywhere) is refused,
# and GitHub still resolves.
if sudo -u agent getent ahostsv4 example.com >/dev/null 2>&1; then
  echo "egress: the agent's DNS answered a name outside the allowlist" >&2; exit 1
fi
sudo -u agent getent ahostsv4 github.com >/dev/null 2>&1 \
  || { sleep 2; sudo -u agent getent ahostsv4 github.com >/dev/null 2>&1; } \
  || { echo "egress: the agent's DNS filter does not resolve github.com" >&2; exit 1; }
