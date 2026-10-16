#!/usr/bin/env bash
# Offline check for the team store (lib/teams.sh): create, set with a generation, status, delete
# and sync, against the local cache and against a fake bucket; clashes with other teams.
#   bash lib/teams.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
root="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home" SANDBOX_ROOT="$root" FXA_TEAMS_DIR="$tmp/cache" FXA_TEAM_ACTOR=owner@example.com
mkdir -p "$HOME/.ssh"
SESSION_DIR="$tmp/sessions"; mkdir -p "$SESSION_DIR"
source "$root/lib/pipeline.sh"
FXA_TEAMS_URI=""; source "$root/lib/teams.sh"
rec() { printf '{ "schema": 1, "name": "%s", "label": "%s", "repos": [ { "slug": "example/%s", "role": "work" } ], "prompts": { "goal_md": "Run make test." }%s }' "$1" "$2" "$1" "${3:-}" > "$tmp/$1.json"; echo "$tmp/$1.json"; }
gen() { cat "$FXA_TEAMS_DIR/$1.gen"; }

# The local store (no bucket).
check "create writes the record at generation 1, stamped, with an index entry" "1|owner@example.com|Rusty" \
  "$(teams_create "$(rec rusty Rusty)" >/dev/null; gen rusty)|$(jq -r .created.by "$FXA_TEAMS_DIR/rusty.json")|$(jq -r '.teams.rusty.label' "$FXA_TEAMS_DIR/index.json")"
check "a second create of the same name is refused" "2" "$(teams_create "$(rec rusty Again)" >/dev/null 2>&1; echo $?)"
check "set with the cached generation writes, keeps created, moves the generation" "0|2|Rusty Two|owner@example.com" \
  "$(FXA_TEAM_ACTOR=other@example.com teams_set rusty "$(rec rusty 'Rusty Two')" >/dev/null; echo $?)|$(gen rusty)|$(jq -r .label "$FXA_TEAMS_DIR/rusty.json")|$(jq -r .created.by "$FXA_TEAMS_DIR/rusty.json")"
check "set with a stale generation is refused and changes nothing" "2|Rusty Two" \
  "$(teams_set rusty "$(rec rusty Stale)" 1 >/dev/null 2>&1; echo $?)|$(jq -r .label "$FXA_TEAMS_DIR/rusty.json")"
check "a record cannot rename a team" "1" "$(teams_set rusty "$(rec other Other)" >/dev/null 2>&1; echo $?)"
check "disable sets the status, in the record and the index" "disabled|disabled" \
  "$(teams_status rusty disabled >/dev/null; jq -r .status "$FXA_TEAMS_DIR/rusty.json")|$(jq -r .teams.rusty.status "$FXA_TEAMS_DIR/index.json")"
check "a record that fails its own rules is refused" "1" "$(teams_create "$(rec bad 'Bad$(x)')" >/dev/null 2>&1; echo $?)"
check "a record cannot take a built-in team's Jira project" "1" \
  "$(teams_create "$(rec jira1 Jira ', "jira": { "project": "FXA" }')" 2>&1 | grep -c 'FXA belongs to team fxa')"
teams_create "$(rec chan1 Chan ', "access": { "channels": ["C0123ABCD"] }, "jira": { "project": "CHAN" }')" >/dev/null
check "a channel or Jira project of another record is refused" "1|1" \
  "$(teams_create "$(rec chan2 Chan ', "access": { "channels": ["C0123ABCD"] }')" 2>&1 | grep -c 'channel C0123ABCD belongs to team chan1')|$(teams_create "$(rec chan3 Chan ', "jira": { "project": "CHAN" }')" 2>&1 | grep -c 'CHAN belongs to team chan1')"
printf '{"profile":"rusty","state":"paused"}' > "$SESSION_DIR/agent-r1.json"
check "delete is refused while a session of the team can resume" "1" "$(teams_delete rusty >/dev/null 2>&1; echo $?)"
printf '{"profile":"rusty","state":"stopped"}' > "$SESSION_DIR/agent-r1.json"
check "delete removes the record, its prompts and its index entry" "0|no|null" \
  "$(teams_delete rusty >/dev/null; echo $?)|$([ -e "$FXA_TEAMS_DIR/rusty.json" ] && echo yes || echo no)|$(jq -r .teams.rusty "$FXA_TEAMS_DIR/index.json")"
check "a built-in team cannot be deleted" "1" "$(teams_delete monitor >/dev/null 2>&1; echo $?)"
check "profile lint passes with records and the index in the cache" "profiles: ok" \
  "$(teams_create "$(rec linted Linted)" >/dev/null; cd "$root" && ./fxa-sandbox-ctl profile lint 2>&1 | tail -1)"
check "the index is not a team, and no record can be named index" "0|1" \
  "$(pipeline_profile_names | grep -cx index)|$(teams_create "$(rec index Index)" 2>&1 | grep -c reserved)"

# The bucket: a fake gcloud keeps each object and its generation under $B.
B="$tmp/bucket"; mkdir -p "$B"; FXA_TEAMS_URI="gs://test/teams"; rm -rf "$FXA_TEAMS_DIR"; next=100
gcloud() {
  shift; local verb="$1"; shift; local a want="" uri="" src=""
  for a in "$@"; do case "$a" in --if-generation-match=*) want="${a#*=}" ;; --format=*|-q) ;; gs://*) uri="$a" ;; *) src="$a" ;; esac; done
  local o="${uri##*/}"; o="${o%%#*}"
  case "$verb" in
    ls) ls "$B"/*.json >/dev/null 2>&1 || { echo "ERROR: One or more URLs matched no objects." >&2; return 1; }
        for a in "$B"/*.json; do echo "gs://test/teams/${a##*/}"; done ;;
    # The real bucket keeps old versions: list names them (and deleted teams), describe gives the live one.
    objects) [ "$1" = describe ] && cat "$B/$o.gen" 2>/dev/null
             [ "$1" = list ] && { echo "teams/gone.json"; echo 1; cat "$B/$o.gen" 2>/dev/null; } ;;
    cat) [ "${uri##*#}" = "$(cat "$B/$o.gen" 2>/dev/null)" ] && cat "$B/$o" ;;
    cp) [ "$want" = "$(cat "$B/$o.gen" 2>/dev/null || echo 0)" ] || { echo "ERROR: HTTPError 412: Precondition Failed" >&2; return 1; }
        next=$((next + 1)); cp "$src" "$B/$o"; echo "$next" > "$B/$o.gen" ;;
    rm) [ "$want" = "$(cat "$B/$o.gen" 2>/dev/null)" ] && rm -f "$B/$o" "$B/$o.gen" ;;
  esac
}
check "sync of an empty store succeeds" "0" "$(teams_sync >/dev/null 2>&1; echo $?)"
check "create in the bucket: the cache gets the object's generation" "101|101" "$(teams_create "$(rec web Web)" >/dev/null; gen web)|$(cat "$B/web.json.gen")"
check "a write after another host's change is refused (412), and the cache keeps the old copy" "2|Web" \
  "$(cp "$B/web.json" "$B/web.tmp"; jq '.label = "Theirs"' "$B/web.tmp" > "$B/web.json"; echo 150 > "$B/web.json.gen"; teams_set web "$(rec web Mine)" >/dev/null 2>&1; echo $?)|$(jq -r .label "$FXA_TEAMS_DIR/web.json")"
check "sync brings the other host's change and its generation" "Theirs|150" "$(teams_sync >/dev/null; jq -r .label "$FXA_TEAMS_DIR/web.json")|$(gen web)"
check "set after the sync writes" "0|Mine" "$(teams_set web "$(rec web Mine)" >/dev/null 2>&1; echo $?)|$(jq -r .label "$B/web.json")"
rm -f "$B/web.json" "$B/web.json.gen"
check "sync removes a team that left the store" "no|null" "$(teams_sync >/dev/null; [ -e "$FXA_TEAMS_DIR/web.json" ] && echo yes || echo no)|$(jq -r .teams.web "$FXA_TEAMS_DIR/index.json")"

[ "$fail" = 0 ] && echo "all checks pass"; exit "$fail"
