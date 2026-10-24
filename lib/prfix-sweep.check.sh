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

# rows [pr]   The fix rows (of that PR) as '<pr> <state> <trigger> <actor>', then clears every row for the next case.
rows() { db_value "SELECT json_extract(heads, '$.fix.pr') || ' ' || state || coalesce(' ' || trigger || ' ' || actor, '') FROM routine_runs WHERE routine_id = $rid
    AND json_extract(heads, '$.fix.pr') = coalesce(${1:-NULL}, json_extract(heads, '$.fix.pr')) ORDER BY id;" | paste -sd, -
  db_exec "DELETE FROM routine_runs WHERE routine_id = $rid;"; }
writer_at="$(iso 2026-10-24T10:00:00Z)"

# i556 A20, A21: the label signal.
sweep
check "A20: the writer's agent-help on page 2 of the timeline queues one run on the head, with heads.fix, and the comment says Queued" \
  "pr-90001-$PA|90001|$PA|$writer_at|example-pkg|comment 90001 Queued: the fix starts when a runner is free.|90001 queued label example-writer" \
  "$(db_value "SELECT period || '|' || json_extract(heads, '$.fix.pr') || '|' || json_extract(heads, '$.fix.head_sha') || '|' || json_extract(heads, '$.fix.signal_at') || '|' || json_extract(heads, '$.fix.packages[0]') FROM routine_runs WHERE routine_id = $rid AND json_extract(heads, '$.fix.pr') = 90001;")|$(grep '^comment 90001' "$tmp/pc")|$(rows 90001)"
d="$(dir p1)"; rm "$d/api/repos/mozilla/fxa/issues/90001/timeline.page2.json"
check "A21: a triage user adds agent-help, then a writer adds 'dependencies': no run" "" "$(PRFIX_DIR="$d" sweep; rows 90001)"
d="$(dir p2)"; jq '.[0].actor.login = "example-outsider"' "$fx/api/repos/mozilla/fxa/issues/90001/timeline.page2.json" > "$d/api/repos/mozilla/fxa/issues/90001/timeline.page2.json"
check "a 404 on the permission read: no run and no comment" "|" "$(PRFIX_DIR="$d" sweep; rows 90001)|$(grep '^comment 90001' "$tmp/pc")"
d="$(dir p3)"; echo 'not json' > "$d/api/repos/mozilla/fxa/collaborators/example-writer/permission.json"
check "bad JSON on the permission read: no run" "" "$(PRFIX_DIR="$d" sweep; rows 90001)"
mkdir -p "$tmp/slowbin"; printf '#!/usr/bin/env bash\ncase "$*" in *permission*) sleep 5 </dev/null >/dev/null 2>&1 ;; esac\nexec "%s/bin/gh" "$@"\n' "$fx" > "$tmp/slowbin/gh"; chmod +x "$tmp/slowbin/gh"
check "a permission read that times out: no run" "" "$(PATH="$tmp/slowbin:$PATH" _PRFIX_CALL_S=1 sweep; rows 90001)"
d="$(dir p4)"; jq '.commit.committer.date = "2026-10-24T10:30:00Z"' "$fx/api/repos/mozilla/fxa/commits/$PA.json" > "$d/api/repos/mozilla/fxa/commits/$PA.json"
check "a label older than the head commit: no run" "" "$(PRFIX_DIR="$d" sweep; rows 90001)"
db_exec "INSERT INTO routine_runs (routine_id, period, state, heads, ended_at) VALUES ($rid, 'pr-90001-old-x1', 'failed', json('{\"fix\":{\"pr\":90001}}'), $((writer_at + 60)));"
check "a label older than the end of the last run on the PR: no new run" "90001 failed" "$(sweep; rows 90001)"

# i557 A22, A24: the BLEnder signal.
sweep
check "A22: the BLEnder Bot comment queues a run with its comment id, and the row exists before the App adds agent-help" \
  "90001 queued label example-writer,90002 queued blender mozilla-blender[bot]|7002|label 90002 add agent-help rows=1" \
  "$(db_value "SELECT json_extract(heads, '$.fix.blender_comment_id') FROM routine_runs WHERE routine_id = $rid AND json_extract(heads, '$.fix.pr') = 90002;" > "$tmp/c"; rows)|$(cat "$tmp/c")|$(grep '^label 90002' "$tmp/pc")"
d="$(dir b1)"; jq 'map(select(.id != 7002))' "$fx/api/repos/mozilla/fxa/issues/90002/comments.json" > "$d/api/repos/mozilla/fxa/issues/90002/comments.json"
check "A22: the same text from a User does nothing" "90001 queued label example-writer" "$(PRFIX_DIR="$d" sweep; rows)"
at930="$(iso 2026-10-24T09:30:00Z)"
db_exec "INSERT INTO routine_runs (routine_id, period, state, heads, ended_at) VALUES ($rid, 'pr-90001-9999', 'ok', json('{\"fix\":{\"pr\":90001,\"new_sha\":\"$PA\"}}'), $at930),
  ($rid, 'pr-90002-9999', 'ok', json('{\"fix\":{\"pr\":90002,\"new_sha\":\"$PB\"}}'), $at930);"
check "A24: on the App's fix commit a writer's label queues one run, and a BLEnder comment does nothing" "90001 ok,90002 ok,90001 queued label example-writer" "$(sweep; rows)"

# i558: drops, the dedupe, and the row before the writes.
pc() { grep "^$1 $2" "$tmp/pc" | cut -d' ' -f3- | paste -sd'#' -; }
sweep
check "two red PRs give two rows, and the second says In line behind" "Queued: the fix starts when a runner is free.|In line behind #90001. The fix starts after that run ends." \
  "$(pc comment 90001)|$(pc comment 90002)"
check "A23: a labelled PR with running checks waits with no comment; a labelled green PR gets the not-red text and loses the label" \
  "|Not started: CI passes on ddddddd. Add agent-help again if CI fails.|remove agent-help rows=0|90001 queued label example-writer,90002 queued blender mozilla-blender[bot]" \
  "$(grep 90003 "$tmp/pc")|$(pc comment 90004)|$(pc label 90004)|$(rows)"
d="$(dir r1)"; jq '.statusCheckRollup[0] |= (.status = "COMPLETED" | .conclusion = "FAILURE")' "$fx/pr/90003.json" > "$d/pr/90003.json"
check "A23: when its checks fail, the waiting PR queues" "90003 queued label example-writer" "$(PRFIX_DIR="$d" sweep; rows 90003)"
d="$(dir r2)"; rm "$d/api/repos/mozilla/fxa/issues/90001/timeline.page2.json"
check "A20: the triage user's label gets the write-access text, and the App removes it" \
  "Not started: the label needs a person with write access. Ask a person with write access to add agent-help.|remove agent-help rows=0|" \
  "$(PRFIX_DIR="$d" sweep; pc comment 90001)|$(pc label 90001)|$(rows 90001)"
d="$(dir r3)"; jq '.[1].actor.login = "example-writer"' "$fx/api/repos/mozilla/fxa/issues/90006/timeline.json" > "$d/api/repos/mozilla/fxa/issues/90006/timeline.json"
jq '.headRefName = "release/2026.10"' "$fx/pr/90004.json" | jq '.statusCheckRollup[0].conclusion = "FAILURE"' > "$d/pr/90004.json"
check "a writer's label on a fork PR and on a release branch get their texts" \
  "Not started: the PR is from a fork. Fix it by hand.|Not started: the PR branch is a base or release branch. Fix it by hand.|" \
  "$(PRFIX_DIR="$d" sweep; pc comment 90006)|$(pc comment 90004)|$(rows 90006)$(rows 90004)"
db_exec "INSERT INTO routine_runs (routine_id, period, state, heads, ended_at) VALUES ($rid, 'pr-90001-$PA', 'ok', json('{\"fix\":{\"pr\":90001}}'), $at930),
  ($rid, 'pr-90002-$PB', 'nochange', json('{\"fix\":{\"pr\":90002}}'), $at930);"
check "A27: a label on a head whose run ended gets the used text and no run; the BLEnder comment there does nothing" \
  "Not started: a run on aaaaaaa already ended. A new commit allows a new run.|remove agent-help rows=1||90001 ok,90002 nochange" \
  "$(sweep; pc comment 90001)|$(pc label 90001)|$(pc comment 90002)|$(rows)"
db_exec "INSERT INTO routine_runs (routine_id, period, state, heads) VALUES ($rid, 'pr-90001-other', 'started', json('{\"fix\":{\"pr\":90001}}'));"
check "a PR with a live fix row or a live session gets no new row and no comment" "90001 started||" \
  "$(_session_records() { echo '{"key":"agent-live01","state":"active","review_pr":"https://github.com/mozilla/fxa/pull/90002"}'; }; sweep; rows)|$(pc comment 90001)|$(pc comment 90002)"
PC_FAILS=1 sweep
check "a kill after the INSERT (the comment write fails) leaves the row, and the tick's repair writes its comment" "queued||Queued: the fix starts when a runner is free." \
  "$(db_value "SELECT state || '|' || coalesce(json_extract(heads, '$.fix.comment'), '') FROM routine_runs WHERE routine_id = $rid AND json_extract(heads, '$.fix.pr') = 90001;")|$(: > "$tmp/pc"; _prfix_repair live "$N"; pc comment 90001)"
rows >/dev/null

# i559 A25, A26: the live-run stop, guarded on the push claim.
live() { # live <pr> <trigger> [fix keys json]   A started fix row on the PR; prints its id.
  db_value "INSERT INTO routine_runs (routine_id, period, trigger, state, session, heads, started_at) VALUES ($rid, 'pr-$1-live', '$2', 'started', 'agent-fx$1',
    json($(db_q "$(jq -cn --argjson n "$1" --argjson x "${3:-null}" '{fix: ({pr: $n, url: "https://github.com/mozilla/fxa/pull/\($n)"} + ($x // {}))}')")), $N); SELECT last_insert_rowid();"; }
l1="$(live 90002 blender)"; l2="$(live 90004 manual)"; : > "$tmp/stopped"; sweep
check "A25: a BLEnder run whose label a person removed stops with its session, and the comment says so; a Run now run needs no label" \
  "stopped|label|agent-fx90002|Stopped: the agent-help label was removed. Nothing was pushed.|started" \
  "$(db_value "SELECT state || '|' || json_extract(heads, '$.fix.why') FROM routine_runs WHERE id = $l1;")|$(cat "$tmp/stopped")|$(pc comment 90002)|$(db_value "SELECT state FROM routine_runs WHERE id = $l2;")"
d="$(dir s1)"; jq '.number = 90009 | .state = "MERGED" | .url = "https://github.com/mozilla/fxa/pull/90009"' "$fx/pr/90001.json" > "$d/pr/90009.json"
db_exec "UPDATE routine_runs SET state = 'stopped' WHERE id = $l2;"; l3="$(live 90009 label)"
check "a run on a PR that was merged stops with why merged" "stopped|merged" "$(PRFIX_DIR="$d" sweep; db_value "SELECT state || '|' || json_extract(heads, '$.fix.why') FROM routine_runs WHERE id = $l3;")"
P7=9999999999999999999999999999999999999999
l4="$(live 90002 blender '{"pushing": 1792836000, "pending_sha": "'$P7'"}')"; : > "$tmp/err"; sweep
check "A26: a stop while the fix is pushed is skipped and logged" "started|routine run $l4 not stopped: The fix is being pushed. Try again after it ends." \
  "$(db_value "SELECT state FROM routine_runs WHERE id = $l4;")|$(grep "run $l4" "$tmp/out" | tail -1)"
_prfix_set "$l4" '.new_sha = $s' --arg s "$P7"; : > "$tmp/pc"
check "A26: then the push lands, and the run ends ok with Pushed" "ok|Pushed 9999999. Next: review the fix commit, then approve the functional tests gate." \
  "$(FXA_ROUTINE_NOW=$N routine_done "$l4" --state ok --session agent-fx90002 | jq -r .state)|$(pc comment 90002)"

exit "$fail"
