#!/bin/bash
# Everything about one Slack session, for finding why it failed.
#   why.sh [agent-xxxx]   default: the newest session
# Run it on the host that runs the controller (the laptop before the cutover,
# the manager VM after: vm.sh run 'bash skills/fxa-session-debug/why.sh agent-xxxx').
set -uo pipefail
D="${FXA_SESSION_DIR:-$HOME/.claude/state/agent-sessions}"
CTL="$(cd "$(dirname "$0")/../.." && pwd)/fxa-sandbox-ctl"
mask() { sed -E 's/(sk-ant-[a-z0-9]+-)[A-Za-z0-9_-]+/\1<masked>/g; s/(xox[abpr]-|xapp-|ghs_|ghp_|github_pat_)[A-Za-z0-9_-]+/\1<masked>/g'; }
key="${1:-$(ls -t "$D"/agent-*.json 2>/dev/null | head -1 | xargs -n1 basename 2>/dev/null | sed 's/\.json$//')}"
[[ "$key" =~ ^agent-[a-z0-9]{4,12}$ ]] && [ -f "$D/$key.json" ] || { echo "no session '${key}' in $D" >&2; exit 1; }

{
echo "== $key"
jq -r '"state=\(.state)  runtime=\(.runtime // "claude")  created=\((.created // 0) | floor | todate)  resume_from=\(.resume_from // "-")  pr=\(.pr_url // "-")\nlast_error=\(.last_error // "-")"' "$D/$key.json"
jq -r '.summary // empty | fromjson? // . | "summary: \(.minutes // "?") min, \(.turns // "?") turns, \(.tokens // "?") tokens, $\(.cost // "?"), \(.diff // "")"' "$D/$key.json" 2>/dev/null

echo; echo "== boot log: errors and the last lines"
if [ -f "$D/$key.log" ]; then
  grep -nE 'ERROR|WARN|banner exchange|Internal error|refusing|failed|did not answer|Traceback' "$D/$key.log" | grep -v '^\s*$' | tail -12
  echo "  --- last 6 lines"; tail -6 "$D/$key.log" | sed 's/^/  /'
else echo "  none"; fi

echo; echo "== boot timings"
"$CTL" session times "$key" 2>/dev/null | sed 's/^/  /'

echo; echo "== finish log (Open PR / Push branch)"
[ -f "$D/$key.finish.log" ] && { grep -nE 'ERROR|WARN|refus|failed' "$D/$key.finish.log" | tail -8; tail -4 "$D/$key.finish.log" | sed 's/^/  /'; } || echo "  none"

echo; echo "== errors recorded for this session"
"$CTL" errors --json 2>/dev/null | jq -r --arg k "$key" '.[] | select((.keys // []) | index($k)) | "\(.sig)  \(.status)  x\(.count)  \(.source)/\(.kind)  \(.where)\n    \(.message[0:220])"' 2>/dev/null
echo "  (full list: fxa-sandbox-ctl errors show <sig>)"

echo; echo "== last messages in the thread record"
[ -f "$D/$key.history.jsonl" ] && tail -4 "$D/$key.history.jsonl" | jq -r '"\(.role): \(.text | gsub("\n"; " ") | .[0:180])"' 2>/dev/null || echo "  none"

echo; echo "== runner"
"$CTL" --backend gce alive "$key" 2>/dev/null || true
} | mask
