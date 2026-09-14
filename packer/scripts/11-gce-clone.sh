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
# Outside the tree: anything inside would be pulled back and staged into the PR.
sha256sum yarn.lock | cut -d" " -f1 > /home/agent/.image-lock-hash
echo "==> Clone baked ($(du -sh /home/agent/fxa | cut -f1))"
