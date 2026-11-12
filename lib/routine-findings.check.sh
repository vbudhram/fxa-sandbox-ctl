#!/usr/bin/env bash
# Offline check that a security review's findings become Jira tickets in the team's project, with no labels.
#   bash lib/routine-findings.check.sh
source "$(dirname "$0")/session-check-head.sh"
command -v sqlite3 >/dev/null || { echo "skip: needs sqlite3"; exit 0; }
here="$(cd "$(dirname "$0")" && pwd)"
export FXA_DB="$tmp/fxa.db" FXA_DB_BACKUP_URI="" FXA_TEAMS_DIR="$tmp/teams" FXA_LLM_PROXY_DIR="$tmp/proxy" FXA_BOT_ENV="$tmp/bot.env"
mkdir -p "$FXA_TEAMS_DIR"; echo '{"teams": {}}' > "$FXA_TEAMS_DIR/index.json"
source "$here/db.sh"; source "$here/routines.sh"
db_init >/dev/null
errors_record() { echo "$1|$2" >> "$tmp/errs"; }

# A report whose block lists a HIGH, a MEDIUM with an attack path, a MEDIUM without one, a LOW and a bad file.
fence='```'
cat > "$tmp/report.md" <<EOF
Reviewed 12 commits. Not reviewed: none.
${fence}fxa-findings
[{"severity": "high", "title": "Refresh grant widens scope", "file": "packages/fxa-auth-server/lib/oauth/grant.js:120", "symbol": "validateRefresh", "cwe": "CWE-285", "attack": "a client with a refresh token asks for a keyed scope it was never granted", "impact": "keys for sync", "fix": "intersect", "confidence": "high"},
 {"severity": "MEDIUM", "title": "Unverified session destroys another", "file": "packages/fxa-auth-server/lib/routes/session.js:88", "symbol": "destroy", "cwe": "CWE-306", "attack": "an unverified login session sends another session's handle", "impact": "logs a device out", "fix": "guard", "confidence": "medium"},
 {"severity": "MEDIUM", "title": "Vague worry", "file": "a/b.js:1", "cwe": "CWE-1", "attack": "maybe"},
 {"severity": "LOW", "title": "Style", "file": "a/b.js:2"},
 {"severity": "HIGH", "title": "No line", "file": "a/b.js"}]
${fence}
EOF
py() { python3 -c "import sys, json; sys.path.insert(0, '$here'); import routine; $1"; }
check "the block keeps the HIGH and the MEDIUM with an attack path, worst first, of the 5 it lists" "5|HIGH,MEDIUM" \
  "$(python3 "$here/routine.py" findings "$tmp/report.md" 7 "Security review" "mozilla/fxa-private" | jq -r '"\(.listed)|\([.tickets[].severity] | join(","))"')"
check "a code review keeps a MEDIUM with no attack path too" "HIGH,MEDIUM,MEDIUM" \
  "$(python3 "$here/routine.py" findings "$tmp/report.md" 7 R x code-review | jq -r '[.tickets[].severity] | join(",")')"
check "an id does not change when the line or the wording moves" "True" \
  "$(py "a = routine.findings(open('$tmp/report.md').read())[0][0]['id']; b = routine.findings(open('$tmp/report.md').read().replace(':120', ':140').replace('widens scope', 'expands scope'))[0][0]['id']; print(a == b)")"
check "the ticket text names the finding id, and the summary its severity" "[HIGH] Refresh grant widens scope|1" \
  "$(python3 "$here/routine.py" findings "$tmp/report.md" 7 R x | jq -r '.tickets[0] | "\(.summary)|\(.description | [scan("Finding id: fxasr[0-9a-f]{10}")] | length)"')"
printf 'No block here.\n' > "$tmp/none.md"
check "a report with no block fails, so the agent's report stays" "1" "$(python3 "$here/routine.py" findings "$tmp/none.md" 1 R x >/dev/null 2>&1; echo $?)"
cfg='{"name": "Sec", "template": "security-review", "prompt": "look", "mode": "tickets", "repos": ["mozilla/fxa-private"]}'
heads='{"mozilla/fxa-private": {"start": null, "head": "1111111111111111111111111111111111111111"}}'
echo "$cfg" > "$tmp/cfg.json"; echo "$heads" > "$tmp/heads.json"
check "a tickets-mode prompt has the host's findings rule; a report-mode one does not" "1|0" \
  "$(python3 "$here/routine.py" prompt "$tmp/cfg.json" "$tmp/heads.json" fxa-private abcdef012345 | grep -c 'opens with ```fxa-findings')|$(jq '.mode = "report"' "$tmp/cfg.json" > "$tmp/cfg2.json"; python3 "$here/routine.py" prompt "$tmp/cfg2.json" "$tmp/heads.json" fxa-private abcdef012345 | grep -c 'fxa-findings')"
check "a security review's first run reads 14 days back; another template's 24 hours" "1|1" \
  "$(python3 "$here/routine.py" prompt "$tmp/cfg.json" "$tmp/heads.json" fxa-private abcdef012345 | grep -c 'the commits of the last 14 days')|$(jq '.template = "code-review"' "$tmp/cfg.json" > "$tmp/cfg3.json"; python3 "$here/routine.py" prompt "$tmp/cfg3.json" "$tmp/heads.json" fxa-private abcdef012345 | grep -c 'the commits of the last 24 hours')"


# Filing, with Jira stubbed: a search finds FXA-49 closed and FXA-50 open for the MEDIUM's id, and nothing for the HIGH
# (or, with CLOSED_HIGH, FXA-40 closed).
mid="$(python3 "$here/routine.py" findings "$tmp/report.md" 1 R x | jq -r '.tickets[1].id')"
_jira_sa() { return 0; }
_jira_rest_json() {
  printf '%s %s %s\n' "$1" "$2" "$3" >> "$tmp/jira"
  case "$2" in
    */search/jql) case "$3" in
      (*"$mid"*) echo '{"issues": [{"key": "FXA-49", "fields": {"statusCategory": {"key": "done"}}}, {"key": "FXA-50", "fields": {"statusCategory": {"key": "indeterminate"}}}]}' ;;
      (*) [ -n "${SEARCH_FAILS:-}" ] && return 22
          [ -z "${SLOW_SEARCH:-}" ] || sleep 1
          if [ -n "${CLOSED_HIGH:-}" ]; then echo '{"issues": [{"key": "FXA-40", "fields": {"statusCategory": {"key": "done"}}}]}'; else echo '{"issues": []}'; fi ;;
    esac ;;
    */comment) echo '{}' ;;
    /rest/api/3/issue) [ -n "${CREATE_FAILS:-}" ] && return 22; echo '{"key": "FXA-51"}' ;;
  esac
}
PIPE_JIRA_PROJECT=FXA
out="$(_routine_file_findings 9 "$tmp/report.md" "$cfg")"
check "the HIGH is filed and the open MEDIUM gets a comment" "Filed FXA-51 (HIGH)|Found again: FXA-50 (MEDIUM), still open" \
  "$(grep -E '^(Filed|Found again)' <<< "$out" | paste -sd'|' -)"
create="$(grep '^POST /rest/api/3/issue {' "$tmp/jira" | cut -d' ' -f3-)"
check "the create sets the project, and adds no labels and no security level" "FXA|false|false|Bug" \
  "$(jq -r '.fields | "\(.project.key)|\(has("labels"))|\(has("security"))|\(.issuetype.name)"' <<< "$create")"
check "the search looks at the project's tickets in any status, by the finding id" "1" \
  "$(grep -c "search/jql .*\"project = FXA AND text ~ .*${mid}" "$tmp/jira")"
: > "$tmp/jira"
out="$(CLOSED_HIGH=1 _routine_file_findings 9 "$tmp/report.md" "$cfg")"
check "a finding already in a closed ticket is not filed again, and gets no comment" "1|0|0" \
  "$(grep -c '^Already filed: FXA-40 (HIGH), closed$' <<< "$out")|$(grep -c '^POST /rest/api/3/issue {' "$tmp/jira")|$(grep -c 'FXA-40/comment' "$tmp/jira")"
check "the report holds keys and severities, and no finding title or file" "0|0" \
  "$(grep -c 'Refresh grant' <<< "$out")|$(grep -c 'grant.js' <<< "$out")"
: > "$tmp/jira"; : > "$tmp/errs"
out="$(CREATE_FAILS=1 _routine_file_findings 9 "$tmp/report.md" "$cfg")"
check "a refused create is named in the report and recorded, with no second try" "1|1|1" \
  "$(grep -c 'Not filed: a HIGH finding (Jira refused the ticket)' <<< "$out")|$(grep -c 'jira_create_failed' "$tmp/errs")|$(grep -c '^POST /rest/api/3/issue {' "$tmp/jira")"
: > "$tmp/jira"
out="$(SEARCH_FAILS=1 _routine_file_findings 9 "$tmp/report.md" "$cfg")"
check "a failed search files nothing for that finding, so no duplicate" "1|0" \
  "$(grep -c 'Not filed: a HIGH finding (the Jira search failed)' <<< "$out")|$(grep -c '^POST /rest/api/3/issue {' "$tmp/jira")"
# Seven new findings: five tickets, and the other two counted by severity, worst first.
python3 - "$tmp/many.md" <<'PY'
import json, sys
f = [{"severity": s, "title": f"Finding {i}", "file": f"a/f{i}.js:{i + 1}", "symbol": f"s{i}", "cwe": "CWE-1",
      "attack": "an attacker sends a crafted request to the route"} for i, s in enumerate(["HIGH"] * 5 + ["CRITICAL", "MEDIUM"])]
open(sys.argv[1], "w").write("Counts only.\n```fxa-findings\n" + json.dumps(f) + "\n```\n")
PY
: > "$tmp/jira"
out="$(_routine_file_findings 9 "$tmp/many.md" "$cfg")"
check "a run files at most 5 new tickets, and counts the rest worst first" "5|Not filed: 2 more finding(s) over the cap of 5 new tickets a run (1 HIGH, 1 MEDIUM). A later run files them if they are still there." \
  "$(grep -c '^POST /rest/api/3/issue {' "$tmp/jira")|$(grep '^Not filed: 2 more' <<< "$out")"
: > "$tmp/jira"
out="$(ROUTINE_FILE_BUDGET_S=1 SLOW_SEARCH=1 _routine_file_findings 9 "$tmp/many.md" "$cfg")"
check "a slow Jira stops filing at the time budget and counts the rest, so done still writes the run row" "1|Not filed: 6 more finding(s), Jira was too slow to file them all in time. A later run files them if they are still there." \
  "$(grep -c '/search/jql' "$tmp/jira")|$(grep '^Not filed: 6 more' <<< "$out")"
check "no service account: nothing is filed" "1" "$(_jira_sa() { return 1; }; _routine_file_findings 9 "$tmp/report.md" "$cfg" >/dev/null 2>&1; echo $?)"

# routine done: the security review's report becomes the keys-only text, in the row and in the answer.
rr="$(db_value "INSERT INTO routines (team, data) VALUES ('fxa-private', json($(db_q "$(jq -c '. + {schedule: "weekly mon 06:00", zone: "America/New_York", channel: "C0OWN00", max_usd: 5, skip_no_commits: true, env: "live"}' <<< "$cfg")"))); SELECT last_insert_rowid();")"
run="$(db_value "INSERT INTO routine_runs (routine_id, period, state, session, started_at, config) VALUES ($rr, 'p1', 'started', 'agent-sec001', 1, json($(db_q "$(jq -c '. + {channel: "C0OWN00"}' <<< "$cfg")"))); SELECT last_insert_rowid();")"
: > "$tmp/jira"
a="$(routine_done "$run" --state report --session agent-sec001 --report-file "$tmp/report.md")"
check "done files the tickets, keeps only the keys, and the answer gives the bot that text" "true|true|1|0|1" \
  "$(jq -r '"\(.changed)|\(.post)|\(.report | contains("Filed FXA-51 (HIGH)") | if . then 1 else 0 end)"' <<< "$a")|$(db_value "SELECT count(*) FROM routine_runs WHERE id = $run AND report LIKE '%Refresh grant%';")|$(db_value "SELECT count(*) FROM routine_runs WHERE id = $run AND report LIKE '%FXA-51%';")"
check "a second done call files nothing more" "1" \
  "$(routine_done "$run" --state report --session agent-sec001 --report-file "$tmp/report.md" >/dev/null; grep -c '^POST /rest/api/3/issue {' "$tmp/jira")"
run2="$(db_value "INSERT INTO routine_runs (routine_id, period, state, session, started_at, config) VALUES ($rr, 'p2', 'started', 'agent-sec002', 1, json($(db_q "$(jq -c '. + {channel: "C0OWN00"}' <<< "$cfg")"))); SELECT last_insert_rowid();")"
check "with no Jira project, a security review keeps its report in History, off Slack, and files nothing" "false|1|1" \
  "$(PIPE_JIRA_PROJECT='' routine_done "$run2" --state report --session agent-sec002 --report-file "$tmp/report.md" | jq -r .post)|$(db_value "SELECT count(*) FROM routine_runs WHERE id = $run2 AND report LIKE '%Refresh grant%';")|$(grep -c '^POST /rest/api/3/issue {' "$tmp/jira")"
run3="$(db_value "INSERT INTO routine_runs (routine_id, period, state, session, started_at, config) VALUES ($rr, 'p3', 'started', 'agent-sec003', 1, json($(db_q "$(jq -c '. + {channel: "C0OWN00", mode: "report"}' <<< "$cfg")"))); SELECT last_insert_rowid();")"
check "a security review in report mode keeps its report and files nothing" "1|1" \
  "$(routine_done "$run3" --state report --session agent-sec003 --report-file "$tmp/report.md" >/dev/null; db_value "SELECT count(*) FROM routine_runs WHERE id = $run3 AND report LIKE '%Refresh grant%';")|$(grep -c '^POST /rest/api/3/issue {' "$tmp/jira")"
[ "$fail" = 0 ] && echo "all checks pass"; exit "$fail"
