#!/usr/bin/env bash
# bq_export [--dry-run]   Load FxAgent metrics to BigQuery for the yardstick dashboard.
# Each table is an allowlist of fields: never a question, prompt, summary, Slack name or id, email or owner.

FXA_BQ_DATASET="${FXA_BQ_DATASET:-${FXA_GCE_PROJECT:+${FXA_GCE_PROJECT}:fxagent_metrics}}"

# <table>|<bq schema>, in load order.
# "at" is a reserved word in BigQuery: the time column is ts.
_BQ_TABLES='work|ts:TIMESTAMP,src:STRING,team:STRING,key:STRING,kind:STRING,pr_repo:STRING,pr_number:INTEGER,usd:FLOAT,minutes:FLOAT,model:STRING,outcome:STRING
prs|repo:STRING,number:INTEGER,key:STRING,src:STRING,team:STRING,state:STRING,created:TIMESTAMP,merged:TIMESTAMP,closed:TIMESTAMP,attempts:INTEGER,feedback_rounds:INTEGER,admin_rounds:INTEGER,rebases:INTEGER
runs|recorded_at:TIMESTAMP,key:STRING,kind:STRING,model:STRING,cost_usd:FLOAT,wall_seconds:FLOAT,pr_url:STRING,files_changed:INTEGER,source:STRING
sessions|key:STRING,team:STRING,source:STRING,env:STRING,dryrun:BOOLEAN,state:STRING,stop_reason:STRING,runtime:STRING,agent_model:STRING,created:TIMESTAMP,stopped_at:TIMESTAMP,busy_s:FLOAT,runner_s:FLOAT,boot_s:FLOAT,compute_usd:FLOAT,turns:INTEGER,verify_runs:INTEGER,verify_fail_runs:INTEGER,pr_url:STRING,routine_run:STRING,resume_from:STRING
routine_runs|id:INTEGER,routine_id:INTEGER,team:STRING,name:STRING,mode:STRING,env:STRING,period:STRING,trigger:STRING,state:STRING,fix:BOOLEAN,session:STRING,pr_url:STRING,cost_usd:FLOAT,started_at:TIMESTAMP,ended_at:TIMESTAMP
job_costs|ts:TIMESTAMP,job:STRING,cost_usd:FLOAT,turns:INTEGER,duration_ms:INTEGER,is_error:BOOLEAN
answers|ts:TIMESTAMP,env:STRING,cost_usd:FLOAT,secs:FLOAT,turns:INTEGER,error:BOOLEAN,upgraded:BOOLEAN
llm_daily|day:DATE,model:STRING,calls:INTEGER,usd:FLOAT,usd_cache_write:FLOAT'

_bq_ts() { printf "strftime('%%Y-%%m-%%dT%%H:%%M:%%SZ', %s, 'unixepoch')" "$1"; }

# _bq_db <sql>   Rows as NDJSON from a read-only store.
_bq_db() { _db -readonly -json "$1" | jq -c '.[]?'; }

_bq_routine_runs_sql() {
  # LEFT JOIN: a deleted routine keeps its runs and their cost.
  echo "SELECT rr.id, rr.routine_id, coalesce(r.team, 'unknown') AS team, json_extract(r.data, '\$.name') AS name,
    json_extract(r.data, '\$.mode') AS mode, coalesce(r.env, 'live') AS env,
    rr.period, rr.trigger, rr.state, json_extract(rr.heads, '\$.fix') IS NOT NULL AS fix, rr.session, rr.pr_url, rr.cost_usd,
    $(_bq_ts rr.started_at) AS started_at, $(_bq_ts rr.ended_at) AS ended_at
    FROM routine_runs rr LEFT JOIN routines r ON r.id = rr.routine_id ORDER BY rr.id"
}

# One row per unit of work, from the Stats page's rows so both count the same way.
# A routine's session moves to src routine (or depfix); a routine run with no session gets its own row.
# A dependency fix is depfix, as on the Stats page. outcome: the PR state when the PR list has it.
_BQ_PRKEY='def prkey($r; $n): "\($r)#\($n)";
  def prurl: [strings | capture("github.com/(?<r>[^/]+/[^/]+)/pull/(?<n>[0-9]+)") | {r, n: (.n | tonumber)}] | first // null;'
_BQ_WORK="$_BQ_PRKEY"'
  ($rr | map(select(.env == "live"))) as $live
  | ($live | map(select(.session != null) | {key: .session, value: .}) | from_entries) as $rm
  | ((.prs // []) | map({key: prkey(.repo // $repo; .n), value: (.state | ascii_downcase)}) | from_entries) as $ps
  | ((.rows // [])[] | ($rm[.key] // null) as $r | ($r.pr_url | prurl) as $u
     | (if .prn != null then {r: .prr, n: .prn} else $u end) as $p
     | { ts: .at, src: (if $r == null then .src elif $r.fix == 1 then "depfix" else "routine" end), team: (.profile // "unknown"),
         key, kind: (if $r != null then $r.name else .kind end), pr_repo: $p.r, pr_number: $p.n, usd: (.usd // 0), minutes: .min, model: (.model // ""),
         outcome: (if $p != null then ($ps[prkey($p.r; $p.n)] // "pr") elif $r != null then $r.state
                   elif .src == "pipeline" then "no_pr" elif .src == "slack" or .src == "depfix" then (.stop // "running") else .kind end) }),
    ($live[] | select(.session == null) | (.pr_url | prurl) as $u
     | { ts: .started_at, src: (if .fix == 1 then "depfix" else "routine" end), team, key: "routine-\(.id)", kind: .name,
         pr_repo: $u.r, pr_number: $u.n, usd: (.cost_usd // 0), minutes: null, model: "", outcome: .state })'

# One row per PR of every team, with the source from its branch (a ticket branch is pipeline, so a session
# that continues a pipeline PR leaves it pipeline), the ticket's rounds, and the team the Stats feed gives it.
# A PR that a live routine run opened is routine (or depfix), as in work.
_BQ_PRS="$_BQ_PRKEY"'
  ($rr | map(select(.env == "live") | (.pr_url | prurl) as $u | select($u != null)
     | {key: prkey($u.r; $u.n), value: (if .fix == 1 then "depfix" else "routine" end)}) | from_entries) as $rs
  | (.tickets // {}) as $t
  | ((.rows // []) | map(select(.kind == "rebase")) | group_by(.key) | map({key: .[0].key, value: length}) | from_entries) as $rb
  | (.prs // [])[] | { repo: (.repo // $repo), number: .n, key, src: ($rs[prkey(.repo // $repo; .n)] // .src), team: (.team // $me), state: (.state | ascii_downcase),
      created, merged, closed, attempts: ($t[.key].attempts // 0), feedback_rounds: ($t[.key].feedback_rounds // 0),
      admin_rounds: ($t[.key].admin_rounds // 0), rebases: ($rb[.key] // 0) }'

# _bq_rows <table> <stats json file>   NDJSON for one table.
_bq_rows() {
  local a="${PIPE_STATE_DIR:-}/answers.jsonl"
  case "$1" in
    work) jq -c --slurpfile rr <(_bq_db "$(_bq_routine_runs_sql)" | jq -sc .) --arg repo "${PIPE_REPO_SLUG:-mozilla/fxa}" \
            '$rr[0] as $rr | '"$_BQ_WORK" "$2" ;;
    prs) jq -c --slurpfile rr <(_bq_db "$(_bq_routine_runs_sql)" | jq -sc .) --arg repo "${PIPE_REPO_SLUG:-mozilla/fxa}" \
            --arg me "${PIPE_PROFILE:-fxa}" '$rr[0] as $rr | '"$_BQ_PRS" "$2" ;;
    runs) _bq_db "SELECT recorded_at, issue AS key, kind, model, cost_usd, wall_seconds, json_extract(data, '\$.pr') AS pr_url,
            CAST(json_extract(data, '\$.files_changed') AS INTEGER) AS files_changed, json_extract(data, '\$.source') AS source FROM runs ORDER BY id" ;;
    sessions) _bq_db "SELECT key, coalesce(json_extract(data, '\$.profile'), 'fxa') AS team, json_extract(data, '\$.source') AS source,
            json_extract(data, '\$.env') AS env, owner = 'U-DRYRUN' AS dryrun, state, json_extract(data, '\$.stop_reason') AS stop_reason,
            json_extract(data, '\$.runtime') AS runtime, json_extract(data, '\$.agent_model') AS agent_model,
            $(_bq_ts created) AS created, $(_bq_ts "json_extract(data, '\$.stopped_at')") AS stopped_at,
            CAST(json_extract(data, '\$.busy_s') AS REAL) AS busy_s, CAST(json_extract(data, '\$.runner_s') AS REAL) AS runner_s,
            CAST(json_extract(data, '\$.boot_s') AS REAL) AS boot_s, CAST(json_extract(data, '\$.compute_usd') AS REAL) AS compute_usd,
            CAST(json_extract(data, '\$.turns') AS INTEGER) AS turns, CAST(json_extract(data, '\$.verify_runs') AS INTEGER) AS verify_runs,
            CAST(json_extract(data, '\$.verify_fail_runs') AS INTEGER) AS verify_fail_runs, json_extract(data, '\$.pr_url') AS pr_url,
            CAST(json_extract(data, '\$.routine_run') AS TEXT) AS routine_run, json_extract(data, '\$.resume_from') AS resume_from FROM sessions ORDER BY key" \
            | jq -c '.dryrun = (.dryrun == 1)' ;;
    routine_runs) _bq_db "$(_bq_routine_runs_sql)" | jq -c '.fix = (.fix == 1)' ;;
    job_costs) _bq_db "SELECT at AS ts, job, cost_usd, turns, duration_ms, is_error FROM job_costs ORDER BY id" | jq -c '.is_error = (.is_error == 1)' ;;
    answers) [ ! -s "$a" ] || jq -c '{ts: .at, env: (.env // "live"), cost_usd, secs, turns, error: ((.error // false) != false), upgraded: (.upgrade != null)}' "$a" ;;
    llm_daily) _bq_db "SELECT day, model, calls, usd, usd_cache_write FROM llm_daily ORDER BY day, model" ;;
  esac
}

bq_export() {
  local dry="" t stats line name schema n
  [ "${1:-}" = --dry-run ] && dry=1
  [ -n "$dry" ] || [ -n "$FXA_BQ_DATASET" ] || { echo "bq-export: set FXA_BQ_DATASET or FXA_GCE_PROJECT" >&2; return 1; }
  [ -s "$FXA_DB" ] || { echo "bq-export: no store at $FXA_DB" >&2; return 1; }
  t="$(mktemp -d "${TMPDIR:-/tmp}/bq-export.XXXXXX")"
  stats="$t/stats.json"
  snapshot_stats_json > "$stats" || { rm -rf "$t"; return 1; }
  [ "$(cat "$stats")" != null ] || echo '{}' > "$stats"
  while IFS= read -r line; do
    name="${line%%|*}" schema="${line#*|}"
    _bq_rows "$name" "$stats" > "$t/$name.ndjson" || { echo "bq-export: $name failed" >&2; rm -rf "$t"; return 1; }
    n="$(wc -l < "$t/$name.ndjson" | tr -d ' ')"
    if [ -n "$dry" ]; then printf '%s\t%s\t%s\n' "$name" "$n" "$(head -1 "$t/$name.ndjson")"
    else
      # --replace: each load is the whole history, so a rerun is safe.
      bq load --quiet --replace --source_format=NEWLINE_DELIMITED_JSON "${FXA_BQ_DATASET}.${name}" "$t/$name.ndjson" "$schema" >/dev/null \
        || { echo "bq-export: load of $name failed" >&2; rm -rf "$t"; return 1; }
      printf '%s\t%s\n' "$name" "$n"
    fi
  done <<< "$_BQ_TABLES"
  rm -rf "$t"
}
