#!/usr/bin/env bash
# lib/agent.sh: a pipeline runner's CLAUDE.md asks for a screenshot or a video of a visible change, names the
# handoff gate, holds the guide's section on it, and the FxA repo's runners get the three skills it names.
#   bash lib/pipeline-media.check.sh
set -u
here="$(cd "$(dirname "$0")" && pwd)"; fail=0
ck() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want [$2] got [$3]"; fail=1; fi; }
SANDBOX_ROOT="$(cd "$here/.." && pwd)"
_profile_guide_trees() { :; }; profile_file() { :; }; android_overlay() { :; }
eval "$(sed -n '/^vm_guide_build() {/,/^}/p; /^_vm_guide_inline() {/,/^}/p' "$here/agent.sh")"
# The runner section as _setup_claude_config writes it for a pipeline run (FXA_SESSION_MODE unset).
md="$(sed -n "/vm_section=\"\$(cat <<'VMSECTION'/,/^VMSECTION\$/p" "$here/agent.sh" | sed '1d;$d' | _vm_guide_inline)"
has() { grep -qF -- "$1" <<< "$md" && echo yes || echo no; }
ck "the pipeline prompt asks for a screenshot or a short video of a visible change" yes "$(has 'save a screenshot or a short video of it')"
ck "it names the skills and the handoff gate's way out" "yes|yes" "$(has '`/fxa-page-shot`, `/fxa-storybook-capture` or `/fxa-functional-local`')|$(has '.fxa-auto-media-skipped.txt` says why')"
ck "the inlined guide holds the media section's rule" yes "$(has 'ships with a screenshot or a short video of it')"
ck "the FxA repo's runners get the three capture skills" "3" "$(grep -cxE 'fxa-page-shot|fxa-storybook-capture|fxa-functional-local' "$SANDBOX_ROOT/repos/mozilla__fxa/skills.txt")"
exit "$fail"
