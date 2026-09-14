#!/bin/bash
# 11-gce-clone.sh — bake the FxA clone and node_modules. GCE only: Tart mounts
# the host slot instead. The lock hash lets the boot unit skip yarn when the
# lock did not move.
set -euo pipefail

echo "==> Cloning mozilla/fxa into /home/agent/fxa"
sudo -u agent git clone --quiet https://github.com/mozilla/fxa.git /home/agent/fxa
cd /home/agent/fxa
sudo -u agent bash -c 'source /etc/agent-env.sh && yarn install --immutable'
sudo -u agent bash -c 'sha256sum yarn.lock | cut -d" " -f1 > .image-lock-hash'
echo "==> Clone baked ($(du -sh /home/agent/fxa | cut -f1))"
