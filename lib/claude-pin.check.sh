#!/usr/bin/env bash
# Offline check that Claude Code and Codex each have one pin, in packer/scripts/03b-toolchain.sh,
# which the image, the snapshot refresh and the manager all read.
#   bash lib/claude-pin.check.sh
set -u
root="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
for v in CLAUDE_CODE_VERSION CODEX_VERSION; do
  pin="$(grep -h "^${v}=" "$root/packer/scripts/03b-toolchain.sh")"
  others="$(grep -rlE "^${v}=[0-9]" "$root/packer" "$root/infra" "$root/lib" | grep -v '/03b-toolchain.sh$')"
  if [[ "$pin" =~ ^${v}=[0-9]+\.[0-9]+\.[0-9]+$ ]] && [ -z "$others" ]; then echo "ok   one ${v} pin: ${pin#*=}"
  else echo "FAIL ${v} pin missing or set elsewhere: [${pin}] ${others}"; fail=1; fi
done
exit "$fail"
