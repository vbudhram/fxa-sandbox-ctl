#!/usr/bin/env bash
# fake-ctl.sh: a stand-in for fxa-sandbox-ctl that the dev bot can use (FXA_DEV_FAKE=1 vm.sh dev).
# No runner, no push, no PR: each session plays a script on the clock, so a test of the bot's
# Slack messages takes about two minutes and costs nothing.
#
#   task       setup 5 s, then a turn: four steps of three kinds, and a reply with Open PR
#   steer      a reply starts the same turn again
#   finish     wrap-up 12 s, then a draft PR event (a PR number that does not exist)
#   pr-status  CI running for FAKE_CI_S seconds (default 60), then passed
#   answer     busy (exit 3), so the bot starts a session at once
#   stacks     --repos gives each turn_end a row per repo; finish --repo opens that repo's fake PR
#              (mozilla/fxa ships a PR, others a diff); find-pr and --resume-from carry the PRs
#   profile    passed to the real controller, unless FAKE_PROFILES is set
#
# For the e2e harness (fxa-agent-bot/e2e), all opt-in:
#   FAKE_NOW_FILE  the clock: epoch seconds in a file that the harness moves, else the real clock
#   FAKE_TICK      the watch loop's sleep, default 1 s
#   FAKE_CTL_LOG   one JSON line per call: argv, and the text of each *-file argument
#   FAKE_PROFILES  a JSON array of teams (profile list's shape) in place of the real controller
set -euo pipefail
DIR="${FAKE_CTL_DIR:-$HOME/.fxa-fake-ctl}"
CI_S="${FAKE_CI_S:-60}"
PR_URL="https://github.com/mozilla/fxa/pull/999999"
all=("$@") pipe="" REAL="$(cd "$(dirname "$0")/../.." && pwd)/fxa-sandbox-ctl"
while :; do case "${1:-}" in --backend) shift 2 ;; --pipeline) pipe="$2"; shift 2 ;; *) break ;; esac; done
# profile list | profile show (with --pipeline)
profile() {
  [ -n "${FAKE_PROFILES:-}" ] || { "$REAL" "${all[@]}"; return; }
  case "${1:-}" in list) jq -c . "$FAKE_PROFILES" ;; show) jq -c --arg p "${pipe:-fxa}" '.[] | select(.profile == $p)' "$FAKE_PROFILES" ;; esac
}
now() { if [ -n "${FAKE_NOW_FILE:-}" ]; then cat "$FAKE_NOW_FILE"; else date +%s; fi; }
if [ -n "${FAKE_CTL_LOG:-}" ]; then
  # The bot deletes each file after the call, so keep its text here.
  _files='{}' _prev=""
  for a in "${all[@]}"; do
    case "$_prev" in --*-file) [ -f "$a" ] && _files="$(jq -c --arg k "${_prev#--}" --rawfile v "$a" '. + {($k): $v}' <<< "$_files")" ;; esac
    _prev="$a"
  done
  printf '%s\0' "$@" | jq -cRs --argjson at "$(now)" --argjson files "$_files" '{at: $at, argv: (split("\u0000")[:-1]), files: $files}' >> "$FAKE_CTL_LOG"
fi
get() { cat "$DIR/$1/$2" 2>/dev/null || true; }

# The session's script as JSON: every event with its time, and the state now.
# Steps go to watch only; turn_end, pr and pushed go to events.
script() {
  local k="$1" t; t="$(now)"
  jq -n --argjson now "$t" --argjson t0 "$(get "$k" t0)" --arg turns "$(get "$k" turns)" \
    --arg fins "$(get "$k" fins)" --arg repos "$(get "$k" repos)" --arg over "$(get "$k" over)" --arg pr "$PR_URL" '
    def url($s): if $s == "" then $pr else "https://github.com/\($s)/pull/999999" end;
    ($turns | split("\n") | map(select(. != "") | tonumber)) as $ts
    | ($fins | split("\n") | map(select(. != "") | split(" ") | {at: (.[0] | tonumber), mode: .[1], slug: (if .[2] == "-" then "" else .[2] end)})) as $fs
    | ($repos | split(",") | map(select(. != ""))) as $rs
    | [ $ts | to_entries[] | .value as $T | .key as $n
        | {at: ($T + 1), ev: {type: "step", text: "Reading packages/fxa-settings/src/index.tsx"}},
          {at: ($T + 3), ev: {type: "step", text: "Running grep -rn useAccount packages/fxa-settings/src"}},
          {at: ($T + 5), ev: {type: "step", text: "Editing packages/fxa-settings/src/index.tsx"}},
          {at: ($T + 6), ev: {type: "diffstat", files: [{file: "a.ts", added: 3, removed: 1}, {file: "b.ts", added: 2, removed: 0}, {file: "c.ts", added: 1, removed: 1}]}},
          {at: ($T + 7), ev: {type: "step", text: "Running yarn test index"}},
          {at: ($T + 10), ev: ({type: "turn_end", status: "ready", changes: 1, cost: (0.1 * ($n + 1)),
            text: "Fake turn \($n + 1): I changed one file and the test passes. Tap Open PR, or reply to steer."}
            + (if ($rs | length) == 0 then (if any($fs[]; .slug == "" and .at < $T) then {pr: $pr} else {} end)
               else {trees: [$rs[] as $s | {name: ($s | split("/")[1] | ascii_downcase), slug: $s, changes: 1,
                 out: (if $s == "mozilla/fxa" then "pr" else "diff" end),
                 pr: (if any($fs[]; .slug == $s and .at < $T and (.mode | startswith("pr"))) then url($s) else null end)}]} end))} ]
      + [$fs[] | select(.mode == "pr" or .mode == "push") | {at: (.at + 12), ev: ((if .mode == "push" then
          {type: "pushed", branch: "agent-fake", url: "https://github.com/\(if .slug == "" then "mozilla/fxa" else .slug end)/compare/main...agent-fake?expand=1", notes: []}
          else {type: "pr", url: url(.slug), updated: false, notes: [], summary: null} end) + (if .slug == "" then {} else {repo: .slug} end))}]
    | map(select(.at <= $now)) | sort_by(.at) as $evs
    | ($ts | map(select(. <= $now and $now < . + 10)) | length > 0) as $inturn
    | (if $over != "" then $over elif $now < $t0 + 5 then "starting"
       elif any($fs[]; (.mode == "pr" or .mode == "push") and $now < .at + 12) then "wrapping" else "active" end) as $state
    | {now: $now, state: $state, inturn: $inturn, evs: $evs, t0: $t0}'
}

events() {
  local k="$1" since="${3:-0}"
  [ -f "$DIR/$k/t0" ] || { jq -n --argjson c "$since" '{cursor: $c, state: "stopped", events: []}'; return; }
  script "$k" | jq --argjson since "$since" '
    (.evs | map(select(.ev.type != "step" and .ev.type != "diffstat") | .ev)) as $e
    | (.evs | map(select(.ev.type == "step")) | last | .ev.text) as $last
    | {cursor: ($e | length), state, events: $e[$since:],
       activity: {busy: (.state == "starting" or .state == "wrapping" or (.state == "active" and .inturn)),
                  host: (.state == "wrapping"),
                  text: (if .state == "wrapping" then "Reviewing the change, then the title and body"
                         elif .state == "active" and .inturn then $last else null end)},
       boot: (if .now - .t0 > 600 then null else
              {steps: [{step: "cloning the runner", s: 2}, {step: "restoring the snapshot", s: 3}]
                , total: 5, done: (.state != "starting")} end)}'
}

# prstatus <key> [--repo <slug>]
prstatus() {
  local s="${3:--}" f u="$PR_URL"; f="$(get "$1" fins | awk -v s="$s" '$3 == s && $2 ~ /^pr/ {print $1; exit}')"
  [ "$s" = - ] || u="https://github.com/$s/pull/999999"
  [ -n "$f" ] && [ "$(now)" -ge $(( f + 12 )) ] || { echo null; return; }
  jq -n --arg u "$u" --argjson ci "$(( $(now) - f - 12 < CI_S ? 0 : 1 ))" \
    '{state: "OPEN", draft: true, url: $u, ci: (if $ci == 1 then "pass" else "running" end), running: ($ci == 0),
      reviews: [], mergeable: "MERGEABLE", failing: [], infra: [], links: [], jira: null}'
}

opt() { local want="$1"; shift; while [ $# -gt 0 ]; do [ "$1" = "$want" ] && { echo "${2:-}"; return; }; shift; done; }

cmd="${1:-}"; shift || true
case "$cmd" in
  task) k="$(opt --id "$@")"; [[ "$k" =~ ^agent-[a-z0-9]+$ ]] || { echo "fake-ctl: task needs --id" >&2; exit 1; }
    mkdir -p "$DIR/$k"; t="$(now)"; echo "$t" > "$DIR/$k/t0"; echo $(( t + 5 )) > "$DIR/$k/turns"
    opt --owner "$@" > "$DIR/$k/owner"; r="$(opt --repos "$@")"; from="$(opt --resume-from "$@")"; co="$(opt --checkout "$@")"
    # A resume carries the repos and PRs; carried PRs are not announced again.
    if [[ "$from" =~ ^agent-[a-z0-9]+$ ]]; then [ -n "$r" ] || r="$(get "$from" repos)"
      get "$from" fins | awk '{sub(/-c$/, "", $2); print $1, $2 "-c", $3}' > "$DIR/$k/fins"; fi
    # Like the real task: a team with default repos starts a stack without a pick.
    [ -z "$r" ] && [ -n "$pipe" ] && r="$(all=(--pipeline "$pipe" profile show); profile show 2>/dev/null | jq -r '(.defaults // []) | join(",")' || true)"
    [ -z "$r" ] && [[ "$co" =~ ^https://github\.com/([^/]+/[^/]+)/pull/ ]] && r="${BASH_REMATCH[1]}"
    echo "$r" > "$DIR/$k/repos"; echo "started $k (fake)" ;;
  # Like the real steer: during a turn (or the boot) the message waits, and its turn starts when that one ends.
  steer) k="$1"; t="$(now)"; last="$(sort -n "$DIR/$k/turns" | tail -1)"
    if [ -z "$(get "$k" over)" ] && [ "$t" -lt $(( last + 10 )) ]; then echo $(( last + 10 )) >> "$DIR/$k/turns"; echo queued
    else echo "$t" >> "$DIR/$k/turns"; fi
    rm -f "$DIR/$k/over" ;;
  events) events "$@" ;;
  watch) k="$1"; n=0
    # Like the real watch: it stays open between turns, and each step prints once.
    for _ in $(seq 1 1800); do
      out="$(script "$k" | jq -c '[.evs[] | select(.ev.type == "step" or .ev.type == "diffstat" or .ev.type == "turn_end") | if .ev.type == "turn_end" then {type: "result"} else .ev end]')"
      jq -c --argjson n "$n" '.[$n:][]' <<< "$out"; n="$(jq length <<< "$out")"
      sleep "${FAKE_TICK:-1}"
    done ;;
  finish) k="$(opt --session "$@")"; [ -f "$DIR/$k/t0" ] || { echo "ERROR: no session $k" >&2; exit 1; }
    s="$(opt --repo "$@")"; s="${s:--}"; m=pr; case " $* " in *" --no-pr "*) m=push ;; esac
    get "$k" fins | awk -v s="$s" '$3 == s {f=1} END {exit !f}' && { echo "ERROR: the fake opens one PR per repo" >&2; exit 1; }
    echo "$(now) $m $s" >> "$DIR/$k/fins" ;;
  stop) echo stopped > "$DIR/$1/over" ;;
  interrupt) k="$1"; last="$(sort -n "$DIR/$k/turns" 2>/dev/null | tail -1)"
    [ -n "$last" ] && [ "$(now)" -lt $(( last + 10 )) ] && echo interrupted || true ;;
  diff) s="$(opt --repo "$@")"; [ -n "$s" ] && { n="$(printf %s "${s#*/}" | tr A-Z a-z)"; printf -- '--- a/%s/README.md\n+++ b/%s/README.md\n@@ -1 +1 @@\n-old line\n+new line (fake)\n' "$n" "$n"; exit 0; }
    printf -- '--- a/packages/fxa-settings/src/index.tsx\n+++ b/packages/fxa-settings/src/index.tsx\n@@ -1 +1 @@\n-old line\n+new line (fake)\n' ;;
  media) ;;
  answer) exit 3 ;;
  profile) profile "$@" ;;
  jira-card) echo null ;;
  errors) case "${1:-}" in --json) echo '[]' ;; esac ;;
  session) sub="${1:-}"; shift || true
    case "$sub" in
      pr-status) prstatus "$@" ;;
      find-pr) for d in "$DIR"/agent-*; do k="${d##*/}"
          get "$k" fins | while read -r _ m s; do case "$m" in pr*) [ "$s" = - ] && u="$PR_URL" || u="https://github.com/$s/pull/999999"
            [ "$u" = "$1" ] && echo "$(get "$k" t0) $k"; esac; done; done | sort -rn | awk 'NR == 1 {print $2}' | {
          read -r k || { echo null; exit 0; }
          jq -nc --arg k "$k" --arg o "$(get "$k" owner)" --arg over "$(get "$k" over)" \
            '{key: $k, state: (if $over == "" then "active" else $over end), profile: "", thread: null, owner: $o, live: ($over == "")}'; } ;;
      pause) echo paused > "$DIR/$1/over" ;;
      history|copilot-comments|review-comments) echo '[]' ;;
      summary|cost|plan|thread-usage) echo null ;;
      prune|idle-sweep|attach|pr-ready) ;;
      *) echo "fake-ctl: session $sub is not faked" >&2; exit 1 ;;
    esac ;;
  *) echo "fake-ctl: $cmd is not faked" >&2; exit 1 ;;
esac
