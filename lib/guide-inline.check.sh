#!/usr/bin/env bash
# _vm_guide_inline: a pipeline runner's CLAUDE.md holds the guide in place of the "First, read" paragraph.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
eval "$(sed -n '/^_vm_guide_inline() {/,/^}/p' "$here/agent.sh")"
vm_guide_build() { printf 'GUIDE LINE 1\nGUIDE a\\nb LINE 2'; }
out="$(printf '# Sandbox VM\n\nYou are inside.\n\nFirst, read `/etc/vm-agent-guide.md`, the operations manual. It covers the\nbackend, and how to verify.\n\nWhat trips agents most often:\n- x\n' | _vm_guide_inline)"
f=0
grep -q 'First, read' <<<"$out" && { echo "FAIL: the read line stays"; f=1; }
grep -q 'and how to verify' <<<"$out" && { echo "FAIL: the paragraph's tail stays"; f=1; }
grep -qx 'GUIDE LINE 1' <<<"$out" || { echo "FAIL: no guide"; f=1; }
grep -qF 'GUIDE a\nb LINE 2' <<<"$out" || { echo "FAIL: a backslash in the guide changed"; f=1; }
grep -q "runner's operations guide follows" <<<"$out" || { echo "FAIL: no lead line"; f=1; }
grep -q 'What trips agents' <<<"$out" && grep -q 'You are inside' <<<"$out" || { echo "FAIL: lost the rest"; f=1; }
[ "$f" = 0 ] && echo "guide-inline.check: ok"
exit "$f"
