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
set -euo pipefail
DIR="${FAKE_CTL_DIR:-$HOME/.fxa-fake-ctl}"
CI_S="${FAKE_CI_S:-60}"
PR_URL="https://github.com/mozilla/fxa/pull/999999"
[ "${1:-}" = --backend ] && shift 2
now() { date +%s; }
get() { cat "$DIR/$1/$2" 2>/dev/null || true; }

# The session's script as JSON: every event with its time, and the state now.
# Steps go to watch only; turn_end, pr and pushed go to events.
script() {
  local k="$1" t; t="$(now)"
  jq -n --argjson now "$t" --argjson t0 "$(get "$k" t0)" --arg turns "$(get "$k" turns)" \
    --arg fin "$(get "$k" fin)" --arg mode "$(get "$k" mode)" --arg over "$(get "$k" over)" --arg pr "$PR_URL" '
    ($turns | split("\n") | map(select(. != "") | tonumber)) as $ts
    | ($fin | if . == "" then null else tonumber end) as $f
    | [ $ts | to_entries[] | .value as $T | .key as $n
        | {at: ($T + 1), ev: {type: "step", text: "Reading packages/fxa-settings/src/index.tsx"}},
          {at: ($T + 3), ev: {type: "step", text: "Running grep -rn useAccount packages/fxa-settings/src"}},
          {at: ($T + 5), ev: {type: "step", text: "Editing packages/fxa-settings/src/index.tsx"}},
          {at: ($T + 6), ev: {type: "diffstat", files: [{file: "a.ts", added: 3, removed: 1}, {file: "b.ts", added: 2, removed: 0}, {file: "c.ts", added: 1, removed: 1}]}},
          {at: ($T + 7), ev: {type: "step", text: "Running yarn test index"}},
          {at: ($T + 10), ev: ({type: "turn_end", status: "ready", changes: 1, cost: (0.1 * ($n + 1)),
            text: "Fake turn \($n + 1): I changed one file and the test passes. Tap Open PR, or reply to steer."}
            + (if $f != null and $f < $T then {pr: $pr} else {} end))} ]
      + (if $f == null then [] elif $mode == "push" then
          [{at: ($f + 12), ev: {type: "pushed", branch: "agent-fake", url: "https://github.com/mozilla/fxa/compare/main...agent-fake?expand=1", notes: []}}]
        else [{at: ($f + 12), ev: {type: "pr", url: $pr, updated: false, notes: [], summary: null}}] end)
    | map(select(.at <= $now)) | sort_by(.at) as $evs
    | ($ts | map(select(. <= $now and $now < . + 10)) | length > 0) as $inturn
    | (if $over != "" then $over elif $now < $t0 + 5 then "starting"
       elif $f != null and $now < $f + 12 then "wrapping" else "active" end) as $state
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

prstatus() {
  local f; f="$(get "$1" fin)"
  [ -n "$f" ] && [ "$(get "$1" mode)" != push ] && [ "$(now)" -ge $(( f + 12 )) ] || { echo null; return; }
  jq -n --arg u "$PR_URL" --argjson ci "$(( $(now) - f - 12 < CI_S ? 0 : 1 ))" \
    '{state: "OPEN", draft: true, url: $u, ci: (if $ci == 1 then "pass" else "running" end), running: ($ci == 0),
      reviews: [], mergeable: "MERGEABLE", failing: [], infra: [], links: [], jira: null}'
}

opt() { local want="$1"; shift; while [ $# -gt 0 ]; do [ "$1" = "$want" ] && { echo "${2:-}"; return; }; shift; done; }

cmd="${1:-}"; shift || true
case "$cmd" in
  task) k="$(opt --id "$@")"; [[ "$k" =~ ^agent-[a-z0-9]+$ ]] || { echo "fake-ctl: task needs --id" >&2; exit 1; }
    mkdir -p "$DIR/$k"; t="$(now)"; echo "$t" > "$DIR/$k/t0"; echo $(( t + 5 )) > "$DIR/$k/turns"; echo "started $k (fake)" ;;
  steer) k="$1"; now >> "$DIR/$k/turns"; rm -f "$DIR/$k/over" ;;
  events) events "$@" ;;
  watch) k="$1"; n=0
    # Like the real watch: it stays open between turns, and each step prints once.
    for _ in $(seq 1 1800); do
      out="$(script "$k" | jq -c '[.evs[] | select(.ev.type == "step" or .ev.type == "diffstat" or .ev.type == "turn_end") | if .ev.type == "turn_end" then {type: "result"} else .ev end]')"
      jq -c --argjson n "$n" '.[$n:][]' <<< "$out"; n="$(jq length <<< "$out")"
      sleep 1
    done ;;
  finish) k="$(opt --session "$@")"; [ -f "$DIR/$k/t0" ] || { echo "ERROR: no session $k" >&2; exit 1; }
    [ -n "$(get "$k" fin)" ] && { echo "ERROR: the fake opens one PR per session" >&2; exit 1; }
    now > "$DIR/$k/fin"; case " $* " in *" --no-pr "*) echo push > "$DIR/$k/mode" ;; esac ;;
  stop) echo stopped > "$DIR/$1/over" ;;
  interrupt) ;;
  diff) printf -- '--- a/packages/fxa-settings/src/index.tsx\n+++ b/packages/fxa-settings/src/index.tsx\n@@ -1 +1 @@\n-old line\n+new line (fake)\n' ;;
  media) ;;
  answer) exit 3 ;;
  jira-card) echo null ;;
  errors) case "${1:-}" in --json) echo '[]' ;; esac ;;
  session) sub="${1:-}"; shift || true
    case "$sub" in
      pr-status) prstatus "$1" ;;
      pause) echo paused > "$DIR/$1/over" ;;
      history|copilot-comments|review-comments) echo '[]' ;;
      summary|cost|plan|thread-usage) echo null ;;
      prune|idle-sweep|attach|pr-ready) ;;
      *) echo "fake-ctl: session $sub is not faked" >&2; exit 1 ;;
    esac ;;
  *) echo "fake-ctl: $cmd is not faked" >&2; exit 1 ;;
esac
