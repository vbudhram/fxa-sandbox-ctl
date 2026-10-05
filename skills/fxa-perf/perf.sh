#!/usr/bin/env bash
# perf.sh: how fast the fxa-settings email-first page shows, across prod builds.
#   perf.sh build <label> [rev]              prod build at <rev> (default: the working tree), about 2 min
#   perf.sh measure <a,b,..> [rounds] [flow] cold loads, the builds interleaved each round
#   perf.sh video <a,b,..> [flow]            one recorded load a build, side by side, to .fxa-auto-media
#   perf.sh report <a,b,..> [flow]           medians a build, and the change from the first
#   perf.sh stop                             stop the perf server, start the settings dev server again
# flow: first (until the email form shows, default) or email (also submit, until the next step).
# PERF_PROFILE: mobile (slow 4G, default), desktop or none. Results are kept by the build's
# asset manifest in /workspace/.fxa-keep/perf: an unchanged build is never measured twice.
set -uo pipefail
H="$(cd "$(dirname "$0")" && pwd)"
W="${PERF_DIR:-/tmp/fxa-perf}" K="${PERF_KEEP:-/workspace/.fxa-keep/perf}" WS="${PERF_WS:-/workspace}"
PROFILE="${PERF_PROFILE:-mobile}"
mkdir -p "$W/builds" "$K/results"

key() { [ -f "$W/builds/$1/asset-manifest.json" ] && { sha1sum 2>/dev/null || shasum; } < "$W/builds/$1/asset-manifest.json" | cut -c1-12; }
results() { echo "$K/results/$(key "$1")-${PROFILE}-$2.jsonl"; }
labels() { tr ',' '\n' <<< "$1" | grep .; }
have() { local f; f="$(results "$1" "$2")"; [ -f "$f" ] && grep -c . "$f" || echo 0; }

build() {
  local label="${1:?label}" rev="${2:-}" s="$WS/packages/fxa-settings" paths=(packages/fxa-settings packages/fxa-react) rc
  [[ "$label" =~ ^[a-z0-9-]+$ ]] || { echo "a label is a-z, 0-9 and -" >&2; return 2; }
  if [ -n "$rev" ]; then
    # The build reads the tree, so <rev> is checked out there and HEAD put back after.
    # Uncommitted edits in those paths would be lost: refuse instead.
    [ -z "$(git -C "$WS" status --porcelain -- "${paths[@]}")" ] || { echo "fxa-settings or fxa-react has uncommitted changes: commit them, or build the working tree with no rev" >&2; return 2; }
    git -C "$WS" checkout -q "$rev" -- "${paths[@]}" || return 1
  fi
  ( cd "$s" && NODE_ENV=production npx tailwindcss -i ./src/styles/tailwind.css -o ./src/styles/tailwind.out.css --postcss >/dev/null 2>&1 \
    && rm -rf build/perf && SKIP_PREFLIGHT_CHECK=true INLINE_RUNTIME_CHUNK=false NODE_OPTIONS="--openssl-legacy-provider --max-old-space-size=6144" \
       BUILD_PATH=build/perf node scripts/build.js > "$W/build-$label.log" 2>&1 ); rc=$?
  # Back to HEAD, and no file that only <rev> had: the guard above made the paths clean.
  [ -n "$rev" ] && { git -C "$WS" checkout -q HEAD -- "${paths[@]}"; git -C "$WS" clean -fdq -- "${paths[@]}"; }
  [ "$rc" = 0 ] || { tail -20 "$W/build-$label.log"; return 1; }
  rm -rf "${W:?}/builds/$label"; mv "$s/build/perf" "$W/builds/$label"
  echo "built $label at ${rev:-the working tree}: key $(key "$label")"
}

server() {
  local pf="$W/serve.pid"
  if [ -f "$pf" ] && kill -0 "$(cut -d' ' -f1 "$pf")" 2>/dev/null && [ "$(cut -d' ' -f2 "$pf")" = "$PROFILE" ]; then return 0; fi
  [ -f "$pf" ] && kill "$(cut -d' ' -f1 "$pf")" 2>/dev/null
  curl -sf -m 20 http://localhost:3030/ > "$W/live.html" || { echo "the content server on :3030 is down: bash ~/.claude/skills/fxa-stack/stack.sh ensure" >&2; return 1; }
  pm2 stop settings-react >/dev/null 2>&1  # it holds :3000, where the page must be served
  node "$H/serve.js" "$W" "$PROFILE" > "$W/serve.log" 2>&1 & echo "$! $PROFILE" > "$pf"
  for _ in 1 2 3 4 5 6 7 8 9 10; do curl -sf -o /dev/null localhost:3000/ && return 0; sleep 0.5; done
  echo "the perf server did not start: $(tail -2 "$W/serve.log")" >&2; return 1
}

use() { ln -sfn "$W/builds/$1" "$W/current"; }

# One load into the build's results, with 2 retries: a hung load is the runner, not the build.
load() {
  local b="$1" flow="$2" out k
  use "$b"
  for k in 1 2 3; do
    out="$(timeout 90 node "$H/load.js" "$flow" 2>>"$W/load.err")" && { echo "$out" >> "$(results "$b" "$flow")"; return 0; }
    echo "retry $b $flow ($k)" >&2
  done
  return 1
}

measure() {
  local list="${1:?labels}" rounds="${2:-7}" flow="${3:-first}" b i order
  for b in $(labels "$list"); do [ -n "$(key "$b")" ] || { echo "no build $b: perf.sh build $b [rev]" >&2; return 2; }; done
  [ -n "${PERF_DRY:-}" ] || server || return 1  # PERF_DRY: print the loads it would run
  for ((i = 1; i <= rounds; i++)); do
    # Reverse every other round, so drift on the runner falls on each build alike.
    order="$(labels "$list")"; [ $((i % 2)) = 0 ] && order="$(awk '{ a[NR] = $0 } END { for (j = NR; j > 0; j--) print a[j] }' <<< "$order")"
    for b in $order; do
      [ "$(have "$b" "$flow")" -ge "$rounds" ] && continue  # kept from an earlier run
      [ -n "${PERF_DRY:-}" ] && { echo "load $b $flow"; continue; }
      load "$b" "$flow" || echo "failed $b $flow" >&2
    done
  done
  report "$list" "$flow"
}

report() {
  local list="${1:?labels}" flow="${2:-first}" b f
  printf '%-12s %5s %7s %7s %7s %12s\n' build loads shell fcp form submit-next
  for b in $(labels "$list"); do
    f="$(results "$b" "$flow")"; [ -f "$f" ] || { printf '%-12s %5s\n' "$b" 0; continue; }
    jq -rs --arg b "$b" 'def med: map(select(. != null)) | sort | if length == 0 then "-" else .[length / 2 | floor] end;
      [$b, length, (map(.shell) | med), (map(.fcp) | med), (map(.form) | med), (map(if .next and .submit then .next - .submit else null end) | med)]
      | @tsv' "$f" | awk -F'\t' '{ printf "%-12s %5s %7s %7s %7s %12s\n", $1, $2, $3, $4, $5, $6 }'
  done
  echo "($PROFILE profile, ms from navigation; medians. Raw: $K/results)"
}

video() {
  local list="${1:?labels}" flow="${2:-first}" b n=0 v in="" lab=""
  local F=/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf out="$WS/.fxa-auto-media/perf-${flow}.mp4"
  server || return 1; rm -rf "$W/video"; mkdir -p "$W/video" "$WS/.fxa-auto-media"
  for b in $(labels "$list"); do
    use "$b"
    v="$(timeout 120 node "$H/load.js" "$flow" "$W/video" | jq -r .video)" || { echo "video of $b failed" >&2; return 1; }
    mv "$v" "$W/video/$b.webm"; in="$in -i $W/video/$b.webm"
    lab="${lab}[$n:v]scale=480:-2,drawtext=fontfile=$F:text='$b':x=8:y=h-28:fontsize=18:fontcolor=white:box=1:boxcolor=black@0.6:boxborderw=5[v$n];"
    n=$((n + 1))
  done
  # shellcheck disable=SC2086  # one -i per build
  ffmpeg -y -loglevel error $in -filter_complex "${lab}$(for ((i = 0; i < n; i++)); do printf '[v%d]' "$i"; done)hstack=inputs=$n:shortest=0,drawtext=fontfile=$F:text='%{pts\:hms}':x=w-160:y=8:fontsize=20:fontcolor=white:box=1:boxcolor=black@0.6:boxborderw=5[v]" \
    -map '[v]' -c:v libx264 -pix_fmt yuv420p -crf 24 "$out" && echo "video: $out"
}

stop() {
  [ -f "$W/serve.pid" ] && kill "$(cut -d' ' -f1 "$W/serve.pid")" 2>/dev/null; rm -f "$W/serve.pid"
  pm2 start settings-react >/dev/null 2>&1 && echo "settings dev server started again"
}

case "${1:-}" in
  build|measure|report|video|stop) cmd="$1"; shift; "$cmd" "$@" ;;
  *) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
