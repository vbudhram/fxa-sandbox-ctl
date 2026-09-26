#!/usr/bin/env bash
# Run one functional spec on the local stack with video. See SKILL.md.
#   run.sh <spec path under packages/functional-tests> [test title filter]
set -u
spec="${1:?usage: run.sh <spec> [title filter]}"; filter="${2:-}"
ft=/workspace/packages/functional-tests out=/workspace/artifacts/functional media=/workspace/.fxa-auto-media
[ -f "${ft}/${spec}" ] || { echo "no spec at ${ft}/${spec}" >&2; exit 2; }
bash "$(dirname "$0")/../fxa-stack/stack.sh" ensure >/dev/null || { echo "the stack is not healthy; run fxa-stack diagnose" >&2; exit 3; }

# Playwright has no --video flag: a wrapper config turns video on for every
# project. testDir must be absolute, since it resolves against this file.
cfg=/workspace/.fxa-auto-playwright.ts
cat > "$cfg" <<CFG
import base from '${ft}/playwright.config';
export default {
  ...base,
  testDir: '${ft}/tests',
  use: { ...base.use, video: 'on' },
  projects: (base.projects ?? []).map((p) => ({ ...p, use: { ...p.use, video: 'on' } })),
};
CFG
rm -rf "$out"; mkdir -p "$media"
cd "$ft" || exit 2
args=(--config "$cfg" --project=local --workers=1 --retries=0 "$spec")
[ -n "$filter" ] && args+=(-g "$filter")
start=$(date +%s)
NODE_OPTIONS='--dns-result-order=ipv4first' npx playwright test "${args[@]}"; rc=$?
secs=$(( $(date +%s) - start ))

# One video per test; name it after the test's output folder.
n=0
while IFS= read -r v; do
  name="$(basename "$(dirname "$v")" | cut -c1-80).webm"
  cp "$v" "${media}/${name}" && n=$((n + 1)) && echo "video: ${media}/${name}"
done < <(find "$out" -name 'video.webm' 2>/dev/null)
rm -f "$cfg"
if [ "$rc" -eq 0 ]; then echo "PASS ${spec} (${secs}s, ${n} video(s))"; else echo "FAIL ${spec} (${secs}s). Trace: $(find "$out" -name 'trace.zip' | head -1)"; fi
exit "$rc"
