#!/usr/bin/env bash
# Offline check that Claude Code has one pin, in packer/scripts/03b-toolchain.sh, which the
# image, the snapshot refresh and the manager all read.
#   bash lib/claude-pin.check.sh
set -u
root="$(cd "$(dirname "$0")/.." && pwd)"
pin="$(grep -h '^CLAUDE_CODE_VERSION=' "$root/packer/scripts/03b-toolchain.sh")"
others="$(grep -rlE '^CLAUDE_CODE_VERSION=[0-9]' "$root/packer" "$root/infra" "$root/lib" | grep -v '/03b-toolchain.sh$')"
if [[ "$pin" =~ ^CLAUDE_CODE_VERSION=[0-9]+\.[0-9]+\.[0-9]+$ ]] && [ -z "$others" ]; then
  echo "ok   one Claude Code pin: ${pin#*=}"
else
  echo "FAIL Claude Code pin missing or set elsewhere: [${pin}] ${others}"; exit 1
fi
