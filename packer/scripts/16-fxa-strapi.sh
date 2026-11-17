#!/bin/bash
# 16-fxa-strapi.sh — mozilla/fxa-strapi (the CMS) at ~/fxa-strapi, installed and built but not
# running, so `stack.sh strapi` starts it in seconds. Run as agent: the GCE image build runs it, and
# infra/firecracker/refresh.sh runs it in the snapshot guest, where it installs only when the lockfile
# moved and builds only when dev moved. The clone and node_modules take about 1 GB.
set -euo pipefail
cd /home/agent
[ -d fxa-strapi/.git ] || git clone -q -b dev https://github.com/mozilla/fxa-strapi fxa-strapi
cd fxa-strapi
old="$(git rev-parse HEAD)"
git fetch -q origin dev && git checkout -q -B dev FETCH_HEAD
# npm 11 rejects the lockfile (esbuild optional deps), and one dependency is a git+ssh URL.
if [ ! -d node_modules ] || ! git diff --quiet "$old" HEAD -- package-lock.json; then
  rm -rf node_modules
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=url.https://github.com/.insteadOf GIT_CONFIG_VALUE_0=ssh://git@github.com/ \
    npx -y npm@10.9.2 ci --no-audit --no-fund --loglevel=error > /tmp/strapi-install.log 2>&1 || { tail -20 /tmp/strapi-install.log; exit 1; }
fi
if [ ! -d build ] || [ "$old" != "$(git rev-parse HEAD)" ]; then
  npm run build > /tmp/strapi-build.log 2>&1 || { tail -20 /tmp/strapi-build.log; exit 1; }
fi
echo "==> fxa-strapi at $(git rev-parse --short HEAD) ($(du -sh . | cut -f1))"
