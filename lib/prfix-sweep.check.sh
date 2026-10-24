#!/usr/bin/env bash
# Offline check of the dependency PR sweep (prfix_sweep in lib/routines.sh): the shared fixture lib/testdata/prfix and
# its fake gh, copies of it (PRFIX_DIR) for the extra cases, and a fixed clock (FXA_ROUTINE_NOW).
#   bash lib/prfix-sweep.check.sh
source "$(dirname "$0")/session-check-head.sh"
command -v sqlite3 >/dev/null || { echo "skip: needs sqlite3"; exit 0; }
export FXA_DB="$tmp/fxa.db" FXA_DB_BACKUP_URI="" FXA_TEAMS_DIR="$tmp/teams" FXA_LLM_PROXY_DIR="$tmp/proxy" FXA_BOT_ENV="$tmp/bot.env"
mkdir -p "$FXA_TEAMS_DIR" "$FXA_LLM_PROXY_DIR/teams"; echo "PROFILE_CHANNELS=C0OWN00:fxa" > "$FXA_BOT_ENV"; echo '{"teams": {}}' > "$FXA_TEAMS_DIR/index.json"
source "$(dirname "$0")/db.sh"; source "$(dirname "$0")/routines.sh"
db_init >/dev/null
_SESSIONS_PAUSE_URI=""
pipeline_folder_teams() { echo fxa; }
errors_record() { echo "$1|$2|$3|$5" >> "$tmp/errs"; }
_teams_actor() { printf '%s' "${FXA_TEAM_ACTOR:-}"; }
_teams_audit_note() { :; }
_routine_head() { echo 1111111111111111111111111111111111111111; }
_routine_team_paused() { return 1; }
_routine_profile() { echo '{"private": false, "read_only": false, "repos": [{"slug": "mozilla/fxa", "role": "work"}]}'; }
_routine_free_slots() { echo 5; }
github_app_enabled() { true; }
# The App's writes, stubbed: each call, with the fix rows the store holds at that moment.
prfix_comment() { echo "comment $2 $3" >> "$tmp/pc"; [ -z "${PC_FAILS:-}" ]; }
prfix_label() { echo "label $2 $3 $4 rows=$(db_value "SELECT count(*) FROM routine_runs WHERE json_extract(heads, '$.fix.pr') = $2;")" >> "$tmp/pc"; }
session_stop() { echo "$1" >> "$tmp/stopped"; }
fx="$SANDBOX_ROOT/lib/testdata/prfix"
export PATH="$fx/bin:$PATH" PRFIX_GH_LOG="$tmp/log"
iso() { jq -n --arg t "$1" '$t | fromdateiso8601'; }
N="$(iso 2026-10-24T11:00:00Z)"   # 07:00 in New York
PA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa PB=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb PD=dddddddddddddddddddddddddddddddddddddddd
rid="$(db_value "INSERT INTO routines (team, data) VALUES ('fxa', json($(db_q "$(jq -cn '{name: "Dep fix", on: "pr-label", mode: "pr", repos: ["mozilla/fxa"],
  channel: "C0OWN00", max_usd: 5, env: "live", pr: {repo: "mozilla/fxa", authors: ["dependabot[bot]", "mozilla-blender[bot]"], blender_mention: "@example-fxa-agent"}}')"))); SELECT last_insert_rowid();")"
tick() { FXA_ROUTINE_NOW="$1" routine_tick --env live 2>>"$tmp/err"; }
# sweep [now]   A fresh sweep at that time: the routine's sweep state and the call log cleared first.
sweep() { db_exec "UPDATE routines SET swept_at = NULL, sweep_pr = NULL WHERE id = $rid;"; : > "$tmp/log"; : > "$tmp/pc"; FXA_ROUTINE_NOW="${1:-$N}" prfix_sweep live "${1:-$N}" >>"$tmp/out" 2>>"$tmp/err"; }
reads() { sed -nE 's#^api repos/mozilla/fxa/commits/(.).*#\1#p' "$tmp/log" | paste -sd, -; }
dir() { rm -rf "$tmp/$1"; cp -R "$fx" "$tmp/$1"; echo "$tmp/$1"; }

# i555: red in both check shapes, pending waits, and one budget for the sweep.
check "red by a check run, red by a status, pending, green, red by a time-out and a cancel" "red|red|pending|green|red|red" \
  "$(for n in 90001 90002 90003 90004 90005 90006; do _prfix_red "$(cat "$fx/pr/$n.json")"; done | paste -sd'|' -)"
sweep
check "the sweep lists each author's open PRs and reads the head of each red or labelled PR in number order; a labelled pending PR waits with no read" \
  "2|a,b,d,e,f|$N|" "$(grep -c '^pr list' "$tmp/log")|$(reads)|$(db_value "SELECT swept_at || '|' || coalesce(sweep_pr, '') FROM routines WHERE id = $rid;")"
db_exec "DELETE FROM routine_runs WHERE routine_id = $rid;"
: > "$tmp/log"; tick $((N + 60)) >/dev/null
check "a tick within sweep_min of the last full sweep makes no GitHub call" "0" "$(grep -c . "$tmp/log")"
tick $((N + 301)) >/dev/null
check "a tick past sweep_min sweeps again" "2" "$(grep -c '^pr list' "$tmp/log")"
db_exec "DELETE FROM routine_runs WHERE routine_id = $rid;"

# A40: a slow GitHub. 20 red PRs, each call 1 s, a budget of 4 s: the tick still answers its claimed run, the sweep stops at
# its budget and keeps sweep_pr, and the next tick continues after it. (The live values are 90 s and 30 s for each call.)
d="$(dir slow)"; rm -f "$d"/pr/*.json
for i in $(seq 1 20); do jq --argjson n $((91000 + i)) --arg h "$(printf '%040d' $((91000 + i)))" '.number = $n | .headRefOid = $h | .url = "https://github.com/mozilla/fxa/pull/\($n)"' "$fx/pr/90002.json" > "$d/pr/$((91000 + i)).json"; done
rs="$(db_value "INSERT INTO routines (team, data) VALUES ('fxa', json($(db_q "$(jq -cn '{name: "Review", template: "code-review", prompt: "x", schedule: "daily 07:00", zone: "America/New_York",
  repos: ["mozilla/fxa"], channel: "C0OWN00", mode: "report", max_usd: 5, skip_no_commits: false, env: "live"}')"))); SELECT last_insert_rowid();")"
db_exec "UPDATE routines SET swept_at = NULL, sweep_pr = NULL WHERE id = $rid;"; : > "$tmp/log"
s0=$SECONDS; out="$(_PRFIX_SWEEP_S=4 _PRFIX_CALL_S=3 PRFIX_GH_SLEEP=1 PRFIX_DIR="$d" tick "$N")"; el=$((SECONDS - s0))
cur="$(db_value "SELECT coalesce(sweep_pr, 0) || '|' || coalesce(swept_at, 0) FROM routines WHERE id = $rid;")"
check "A40: the tick answers its claimed run, ends within the budget and one call, keeps sweep_pr and leaves swept_at" "1|1|1|0" \
  "$(jq --argjson r "$rs" '[.runs[] | select(.routine == $r)] | length' <<< "$out")|$([ "$el" -le 8 ] && echo 1)|$([ "${cur%|*}" -ge 91001 ] && [ "${cur%|*}" -lt 91020 ] && echo 1)|${cur#*|}"
: > "$tmp/log"; _PRFIX_SWEEP_S=90 PRFIX_DIR="$d" tick $((N + 60)) >/dev/null
check "the next tick continues after sweep_pr, and a full pass clears it" "$(printf '%040d' $((${cur%|*} + 1)))||$((N + 60))" \
  "$(sed -nE 's#^api repos/mozilla/fxa/commits/([0-9a-f]{40}).*#\1#p' "$tmp/log" | head -1)|$(db_value "SELECT coalesce(sweep_pr, '') || '|' || swept_at FROM routines WHERE id = $rid;")"
db_exec "UPDATE routine_runs SET state = 'stopped' WHERE routine_id = $rs; DELETE FROM routines WHERE id = $rs;"
s0=$SECONDS; db_exec "UPDATE routines SET swept_at = NULL WHERE id = $rid;"
( _PRFIX_SWEEP_S=2 _PRFIX_CALL_S=1 PRFIX_GH_SLEEP=30 PRFIX_DIR="$d" tick $((N + 120)) >/dev/null ); el=$((SECONDS - s0))
check "a GitHub that does not answer: each call ends at its limit, the sweep at its budget, and nothing queues" "1|0" \
  "$([ "$el" -le 6 ] && echo 1)|$(db_value "SELECT count(*) FROM routine_runs WHERE routine_id = $rid;")"

# rows   The fix rows the sweep wrote, as '<pr> <state> <trigger> <actor>', then clears them for the next case.
rows() { db_value "SELECT json_extract(heads, '$.fix.pr') || ' ' || state || coalesce(' ' || trigger || ' ' || actor, '') FROM routine_runs WHERE routine_id = $rid ORDER BY id;" | paste -sd, -
  db_exec "DELETE FROM routine_runs WHERE routine_id = $rid;"; }
writer_at="$(iso 2026-10-24T10:00:00Z)"

# i556 A20, A21: the label signal.
sweep
check "A20: the writer's agent-help on page 2 of the timeline queues one run on the head, with heads.fix, and the comment says Queued" \
  "pr-90001-$PA|90001|$PA|$writer_at|example-pkg|comment 90001 Queued: the fix starts when a runner is free.|90001 queued label example-writer" \
  "$(db_value "SELECT period || '|' || json_extract(heads, '$.fix.pr') || '|' || json_extract(heads, '$.fix.head_sha') || '|' || json_extract(heads, '$.fix.signal_at') || '|' || json_extract(heads, '$.fix.packages[0]') FROM routine_runs WHERE routine_id = $rid;")|$(grep 90001 "$tmp/pc")|$(rows)"
d="$(dir p1)"; rm "$d/api/repos/mozilla/fxa/issues/90001/timeline.page2.json"
check "A21: a triage user adds agent-help, then a writer adds 'dependencies': no run" "" "$(PRFIX_DIR="$d" sweep; rows)"
d="$(dir p2)"; jq '.[0].actor.login = "example-outsider"' "$fx/api/repos/mozilla/fxa/issues/90001/timeline.page2.json" > "$d/api/repos/mozilla/fxa/issues/90001/timeline.page2.json"
check "a 404 on the permission read: no run and no comment" "|" "$(PRFIX_DIR="$d" sweep; rows)|$(grep 90001 "$tmp/pc")"
d="$(dir p3)"; echo 'not json' > "$d/api/repos/mozilla/fxa/collaborators/example-writer/permission.json"
check "bad JSON on the permission read: no run" "" "$(PRFIX_DIR="$d" sweep; rows)"
mkdir -p "$tmp/slowbin"; printf '#!/usr/bin/env bash\ncase "$*" in *permission*) sleep 5 </dev/null >/dev/null 2>&1 ;; esac\nexec "%s/bin/gh" "$@"\n' "$fx" > "$tmp/slowbin/gh"; chmod +x "$tmp/slowbin/gh"
check "a permission read that times out: no run" "" "$(PATH="$tmp/slowbin:$PATH" _PRFIX_CALL_S=1 sweep; rows)"
d="$(dir p4)"; jq '.commit.committer.date = "2026-10-24T10:30:00Z"' "$fx/api/repos/mozilla/fxa/commits/$PA.json" > "$d/api/repos/mozilla/fxa/commits/$PA.json"
check "a label older than the head commit: no run" "" "$(PRFIX_DIR="$d" sweep; rows)"
db_exec "INSERT INTO routine_runs (routine_id, period, state, heads, ended_at) VALUES ($rid, 'pr-90001-old-x1', 'failed', json('{\"fix\":{\"pr\":90001}}'), $((writer_at + 60)));"
check "a label older than the end of the last run on the PR: no new run" "90001 failed" "$(sweep; rows)"

exit "$fail"
