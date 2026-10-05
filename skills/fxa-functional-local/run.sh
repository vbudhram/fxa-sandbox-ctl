#!/usr/bin/env bash
# Run one functional spec on the local stack with video. See SKILL.md.
#   run.sh <spec path under packages/functional-tests> [test title filter]
#   run.sh --bg <spec> [filter]   start it in the background; a Bash call waits 10 min at most
#   run.sh wait [seconds]         wait for the background run (540 s at most): its result,
#                                 "still running" (exit 75), or that it died (exit 4)
set -u
job="${FXA_FUNCTIONAL_JOB_DIR:-/workspace/.fxa-functional-job}"
running() { [ -f "${job}/pid" ] && [ ! -f "${job}/rc" ] && kill -0 "$(cat "${job}/pid")" 2>/dev/null; }
if [ "${1:-}" = --bg ]; then
  shift; [ -n "${1:-}" ] || { echo "usage: run.sh --bg <spec> [title filter]" >&2; exit 2; }
  running && { echo "a background run is still going; use: bash $0 wait" >&2; exit 2; }
  rm -rf "$job"; mkdir -p "$job"
  # The exit code goes to a file: wait reads it, and tells a finished run from a dead one.
  # setsid: its own process group, so the end of this Bash call does not take it down (macOS has none).
  nohup $(command -v setsid) bash -c 'bash "$0" "$@" > "'"$job"'/log" 2>&1; echo $? > "'"$job"'/rc"' "$0" "$@" </dev/null >/dev/null 2>&1 &
  echo $! > "${job}/pid"; date +%s > "${job}/started"
  echo "started in the background. Wait for it with: bash $0 wait"
  exit 0
fi
if [ "${1:-}" = wait ]; then
  [ -f "${job}/pid" ] || { echo "no background run; start one with: bash $0 --bg <spec> [filter]" >&2; exit 2; }
  limit="${2:-540}"; t0=$(date +%s)
  while running && [ $(( $(date +%s) - t0 )) -lt "$limit" ]; do sleep 5; done
  ran=$(( $(date +%s) - $(cat "${job}/started" 2>/dev/null || echo "$t0") ))
  if [ -f "${job}/rc" ]; then grep -E '^(PASS|FAIL|video:|no video:|[0-9]+ video)' "${job}/log"; exit "$(cat "${job}/rc")"; fi
  if running; then echo "still running after ${ran}s. Last line: $(tail -1 "${job}/log" | cut -c1-200). Call: bash $0 wait"; exit 75; fi
  echo "the run died after ${ran}s without a result. Last lines:"; tail -5 "${job}/log"; exit 4
fi
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
# Both projects: FxA splits tests between them by the #chromium tag, so each runs once.
args=(--config "$cfg" --project=local --project=local-chromium --workers=1 --retries=0 "$spec")
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
