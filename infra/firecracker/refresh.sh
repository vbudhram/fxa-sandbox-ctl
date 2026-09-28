#!/bin/bash
# refresh.sh [--force]: when main moved, bring the build guest's clone to main,
# install only when yarn.lock moved, and take a new snapshot with the stack
# running. Run as root on the host; fc-refresh.timer runs it. New slots restore
# the newest snapshot; running slots keep theirs. The two newest are kept.
set -euo pipefail
exec 9> /fc/run/refresh.lock
flock -n 9 || { echo "a refresh is already running"; exit 0; }
fc=/usr/local/sbin/fc
cur="$(cat /fc/snap/latest/commit 2>/dev/null || echo none)"
new="$(git ls-remote https://github.com/mozilla/fxa.git refs/heads/main | cut -f1)"
[[ "$new" =~ ^[0-9a-f]{40}$ ]] || { echo "ERROR: could not read main" >&2; exit 1; }
[ "$new" = "$cur" ] && [ "${1:-}" != --force ] && { echo "snapshot is at main (${new:0:10})"; exit 0; }
echo "main moved: ${cur:0:10} -> ${new:0:10}"

"$fc" boot
# agent-init appends to /etc/agent-env.sh at boot: wait until it has finished.
until [ "$("$fc" ssh 0 'systemctl is-active agent-init fxa-gce-checkout' 2>/dev/null | grep -cx active)" = 2 ]; do sleep 2; done
# The image build wrote the lock hash as root; the agent keeps it current from here.
"$fc" ssh 0 'sudo chown agent:agent /home/agent/.image-lock-hash'
"$fc" ssh 0 "sudo -u agent bash -s -- $new" <<'GUEST'
set -euo pipefail
cd /home/agent/fxa && source /etc/agent-env.sh
git fetch -q origin main && git checkout -q -B main "$1"
if [ "$(sha256sum yarn.lock | cut -d' ' -f1)" != "$(cat /home/agent/.image-lock-hash 2>/dev/null)" ]; then
  echo "yarn.lock moved: installing"
  yarn install --immutable > /tmp/refresh-yarn.log 2>&1 || { tail -30 /tmp/refresh-yarn.log; exit 1; }
  (cd packages/functional-tests && npx playwright install chromium firefox > /dev/null 2>&1) || true
  sha256sum yarn.lock | cut -d' ' -f1 > /home/agent/.image-lock-hash
fi
echo "clone at $(git rev-parse --short HEAD)"
GUEST
"$fc" ssh 0 'sudo sync; sudo systemctl poweroff' || true
sleep 8

name="$(date -u +%Y%m%d-%H%M)"
/usr/local/sbin/fc-make-snapshot "$name"
echo "$new" > "/fc/snap/${name}/commit"
# Keep the two newest; a slot already restored keeps its memory and disk copy.
ls -1dt /fc/snap/2*/ 2>/dev/null | tail -n +3 | xargs -r rm -rf
[ -d /fc/snap/v1 ] && [ "$(readlink /fc/snap/latest)" != /fc/snap/v1 ] && rm -rf /fc/snap/v1
echo "snapshot ${name} at ${new:0:10}"
