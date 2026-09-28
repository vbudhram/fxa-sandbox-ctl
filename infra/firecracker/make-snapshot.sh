#!/bin/bash
# make-snapshot.sh <name>: cold-boot the provisioned build guest, start the FxA
# stack as the agent, wait until it answers, then snapshot slot 0. Run as root.
# No per-run secret is in the guest yet: the controller writes those after restore.
set -euo pipefail
name="${1:?snapshot name}"; fc=/usr/local/sbin/fc
g() { "$fc" ssh 0 "$@"; }
"$fc" boot
until g 'systemctl is-active fxa-gce-checkout' 2>/dev/null | grep -qx active; do sleep 2; done
t0="$(date +%s)"
g 'sudo -u agent bash -c "cd /workspace && nohup setsid bash -c \"source /etc/agent-env.sh && fxa-start\" > /tmp/fxa-start.log 2>&1 < /dev/null &"'
until g 'curl -sf -o /dev/null http://127.0.0.1:3030/ && curl -sf -o /dev/null http://127.0.0.1:9000/__heartbeat__' 2>/dev/null; do
  [ $(( $(date +%s) - t0 )) -lt 900 ] || { echo "ERROR: stack not up after 900s" >&2; g 'tail -30 /tmp/fxa-start.log' >&2; exit 1; }
  sleep 3
done
echo "stack answered after $(( $(date +%s) - t0 ))s"
# Let the late starters (settings build, workers) settle before the memory is frozen.
sleep 30
g 'free -m | sed -n 2p'
"$fc" snapshot "$name"
