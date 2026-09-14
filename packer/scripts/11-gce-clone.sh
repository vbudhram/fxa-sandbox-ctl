#!/bin/bash
# 11-gce-clone.sh — bake the FxA clone and node_modules. GCE only: Tart mounts
# the host slot instead. The lock hash lets the boot unit skip yarn when the
# lock did not move.
set -euo pipefail

echo "==> Cloning mozilla/fxa into /home/agent/fxa"
sudo -u agent git clone --quiet https://github.com/mozilla/fxa.git /home/agent/fxa
cd /home/agent/fxa
# FxA's preinstall refuses any Node but the one in .nvmrc. NodeSource gives the
# newest 24.x, so pin the exact version into /usr/local/bin, which wins on PATH.
npm install -g n >/dev/null
n "$(cat .nvmrc)"
hash -r; echo "==> Node pinned: $(node --version) (.nvmrc $(cat .nvmrc))"
sudo -u agent bash -c 'source /etc/agent-env.sh && yarn install --immutable' || {
  echo '==> yarn install failed; build logs:'; cat /tmp/xfs-*/build.log 2>/dev/null | tail -60; exit 1
}
# The auth-server tests need signing and VAPID keys, which git ignores. Without
# them every run spent a cycle on "keys missing" before it generated its own.
# The key scripts load auth-server config, which needs fxa-shared built first.
sudo -u agent bash -c 'source /etc/agent-env.sh && yarn workspace fxa-shared build && NODE_ENV=dev yarn workspace fxa-auth-server gen-keys' >/dev/null
# Outside the tree: anything inside would be pulled back and staged into the PR.
sha256sum yarn.lock | cut -d" " -f1 > /home/agent/.image-lock-hash
echo "==> Clone baked ($(du -sh /home/agent/fxa | cut -f1))"
