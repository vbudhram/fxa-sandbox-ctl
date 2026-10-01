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
NODE_OPTIONS="--dns-result-order=ipv4first --require $(cd "$(dirname "$0")" && pwd)/own-browser-video.cjs" npx playwright test "${args[@]}"; rc=$?
secs=$(( $(date +%s) - start ))

# A video whose frames are all near-uniform shows nothing: the test drove a
# browser that is not recorded (Marionette's headless Firefox). Measured: blank
# pages peak at 0.06 normalized entropy, pages with content at 0.2 and up.
shows_something() {
  command -v ffmpeg >/dev/null || return 0
  ffmpeg -v error -i "$1" -vf "entropy,metadata=print:key=lavfi.entropy.normalized_entropy.normal.Y:file=-" -f null - 2>/dev/null \
    | awk -F= '/entropy/ { if ($2 + 0 > m) m = $2 + 0 } END { exit !(m >= 0.12) }'
}
# Name each video after its test's output folder; a test's own browser adds -own-<n>.
n=0 blank=0
while IFS= read -r v; do
  case "$v" in
    */own-browser-video/*) t="$(basename "$(dirname "$(dirname "$v")")" | cut -c1-74)"; k=1; while [ -e "${media}/${t}-own-${k}.webm" ]; do k=$((k + 1)); done; name="${t}-own-${k}.webm" ;;
    *) name="$(basename "$(dirname "$v")" | cut -c1-80).webm" ;;
  esac
  if ! shows_something "$v"; then blank=$((blank + 1)); echo "no video: ${name%.webm} shows only a blank page"; continue; fi
  cp "$v" "${media}/${name}" && n=$((n + 1)) && echo "video: ${media}/${name}"
done < <(find "$out" -name '*.webm' 2>/dev/null | sort)
[ "$blank" -gt 0 ] && echo "${blank} video(s) were blank and are not posted: the test drove a browser that is not recorded, such as Marionette's headless Firefox."
rm -f "$cfg"
if [ "$rc" -eq 0 ]; then echo "PASS ${spec} (${secs}s, ${n} video(s))"; else echo "FAIL ${spec} (${secs}s). Read the trace: bash $(dirname "$0")/trace.sh ${out}"; fi
exit "$rc"
