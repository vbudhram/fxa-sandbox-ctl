#!/usr/bin/env bash
# Offline check that every place that installs Claude Code pins the same version.
#   bash lib/claude-pin.check.sh
set -u
root="$(cd "$(dirname "$0")/.." && pwd)"
pins="$(grep -h '^CLAUDE_CODE_VERSION=' "$root/packer/scripts/04-claude.sh" "$root/infra/firecracker/refresh.sh" | sort -u)"
if [ "$(printf '%s\n' "$pins" | grep -c .)" = 1 ] && [[ "$pins" =~ ^CLAUDE_CODE_VERSION=[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "ok   one Claude Code pin: ${pins#*=}"
else
  echo "FAIL Claude Code pins differ or are missing: $(printf '%s' "$pins" | tr '\n' ' ')"; exit 1
fi
