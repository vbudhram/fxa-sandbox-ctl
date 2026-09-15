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
# fxa-start runs pm2 against this tree, and the repo's own `pm2-all.sh start`
# builds everything first. Without that, auth dies on a missing FTL basePath and
# content on a missing dist/libs/shared/l10n. The build needs the translations
# repo in external/l10n (l10n-prime). Every output is gitignored, so none of it
# can be pulled back into a PR. Measured on c4a-highcpu-4: clone 3 s, build ~5.5 min.
# nx has exited non-zero on flaky l10n-prime retries that still produced the
# outputs, so assert the outputs instead of trusting the exit code.
sudo -u agent bash -c 'source /etc/agent-env.sh && yarn l10n:clone' >/dev/null
sudo -u agent bash -c 'source /etc/agent-env.sh && npx nx run-many -t build --all --exclude=fxa-dev-launcher' > /tmp/nx-build.log 2>&1 \
  || echo "==> nx build exited non-zero; checking outputs (log: /tmp/nx-build.log)"
for f in dist/libs/shared/l10n libs/accounts/email-renderer/public/locales/en \
         packages/fxa-auth-server/public/locales/en/auth.ftl; do
  [ -e "$f" ] || { echo "==> ERROR: build output missing: $f"; tail -40 /tmp/nx-build.log; exit 1; }
done
# The auth-server tests need signing and VAPID keys, which git ignores. Without
# them every run spent a cycle on "keys missing" before it generated its own.
sudo -u agent bash -c 'source /etc/agent-env.sh && NODE_ENV=dev yarn workspace fxa-auth-server gen-keys' >/dev/null
# Outside the tree: anything inside would be pulled back and staged into the PR.
sha256sum yarn.lock | cut -d" " -f1 > /home/agent/.image-lock-hash
echo "==> Clone baked ($(du -sh /home/agent/fxa | cut -f1))"
