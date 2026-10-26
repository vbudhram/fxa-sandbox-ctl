#!/usr/bin/env bash
# Offline check of skills/fxa-ctl-dev/pr-media.sh with a stub gh: it counts visible PRs by source and lists the gaps.
#   bash skills/fxa-ctl-dev/pr-media.check.sh
set -u
here="$(cd "$(dirname "$0")" && pwd)"; tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"; cat > "$tmp/bin/gh" <<'GH'
#!/bin/bash
f() { printf '{"number":%s,"title":"t%s","createdAt":"2026-10-20T00:00:00Z","headRefName":"%s","body":"%s","comments":[],"files":[{"path":"%s"}]}' "$@"; }
echo "[$(f 1 1 fxa-1 '![x](u.png)' packages/fxa-settings/src/A.tsx),$(f 2 2 fxa-2 'none' packages/fxa-settings/src/B.css),$(f 3 3 fxa-3 'none' packages/fxa-settings/src/B.test.tsx),$(f 4 4 agent-ab 'none' packages/fxa-settings/src/C.ftl)]"
GH
chmod +x "$tmp/bin/gh"
out="$(PATH="$tmp/bin:$PATH" bash "$here/pr-media.sh" 2026-10-01)"
want="pipeline: 1 of 2 visible PRs have a screenshot or a video
slack: 0 of 1 visible PRs have a screenshot or a video
visible PRs with none:
  #2 2026-10-20 pipeline packages/fxa-settings/src/B.css  t2
  #4 2026-10-20 slack    packages/fxa-settings/src/C.ftl  t4"
if [ "$out" = "$want" ]; then echo "ok   counts by source, a test-only PR left out, and the gaps listed"; else echo "FAIL pr-media.sh: want [$want] got [$out]"; exit 1; fi
