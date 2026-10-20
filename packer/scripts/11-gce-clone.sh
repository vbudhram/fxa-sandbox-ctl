#!/bin/bash
# 11-gce-clone.sh — bake the FxA clone and node_modules. GCE only: Tart mounts
# the host slot instead. The lock hash lets the boot unit skip yarn when the
# lock did not move.
set -euo pipefail

echo "==> Cloning mozilla/fxa into /home/agent/fxa"
sudo -u agent git clone --quiet https://github.com/mozilla/fxa.git /home/agent/fxa
cd /home/agent/fxa
# 03b-toolchain.sh installed main's .nvmrc Node; FxA's preinstall refuses any other.
[ "$(node -v | tr -d v)" = "$(tr -d 'v \n' < .nvmrc)" ] || { echo "==> ERROR: node $(node -v) is not .nvmrc $(cat .nvmrc); main moved during the build, run it again"; exit 1; }
echo "==> Node: $(node --version) (.nvmrc $(cat .nvmrc))"
sudo -u agent bash -c 'source /etc/agent-env.sh && yarn install --immutable' || {
  echo '==> yarn install failed; build logs:'; cat /tmp/xfs-*/build.log 2>/dev/null | tail -60; exit 1
}
# `npx glean` pip-installs glean_parser into a venv, and the VM's DNS refuses PyPI, so
# glean-lint and glean-generate failed in every run. Bake the venv; VIRTUAL_ENV points the CLI at it,
# and OFFLINE stops its pip upgrade. Nothing else in FxA reads OFFLINE.
gv="$(sed -n 's/^const GLEAN_PARSER_VERSION = "\(.*\)";$/\1/p' node_modules/@mozilla/glean/dist/cli/cli.js)"
[ -n "$gv" ] || { echo '==> ERROR: no GLEAN_PARSER_VERSION in @mozilla/glean'; exit 1; }
python3 -m venv /opt/glean-venv && /opt/glean-venv/bin/pip install -q wheel "glean_parser~=${gv}"
echo 'export VIRTUAL_ENV=/opt/glean-venv OFFLINE=1' >> /etc/agent-env.sh
echo "==> glean_parser $(/opt/glean-venv/bin/python -c 'import glean_parser; print(glean_parser.__version__)') baked (~=${gv})"
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
# Playwright browsers for the pinned version, into the agent's cache. 08 put the
# system libraries in the image; the boot-time install in agent-init never ran
# on GCE because /workspace is linked only after that unit. Baking them saves a
# 1.3GB download per boot; the checkout unit refreshes when the pin moves.
sudo -u agent bash -c 'source /etc/agent-env.sh && cd /home/agent/fxa/packages/functional-tests && npx playwright install chromium firefox' \
  || { echo '==> ERROR: playwright install failed'; exit 1; }
echo "==> Playwright browsers baked ($(du -sh /home/agent/.cache/ms-playwright | cut -f1))"
# Outside the tree: anything inside would be pulled back and staged into the PR.
sha256sum yarn.lock | cut -d" " -f1 > /home/agent/.image-lock-hash
echo "==> Clone baked ($(du -sh /home/agent/fxa | cut -f1))"
