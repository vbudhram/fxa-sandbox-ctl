#!/usr/bin/env bash
# Offline check of routine done for an investigation run (_inv_done in lib/routines.sh): the host parses the agent's block,
# keeps only real repo paths, runs the PII guard, and posts one comment; anything else fails the run and posts nothing.
#   bash lib/routines-inv-done.check.sh
source "$(dirname "$0")/session-check-head.sh"
command -v sqlite3 >/dev/null || { echo "skip: needs sqlite3"; exit 0; }
export FXA_DB="$tmp/fxa.db" FXA_DB_BACKUP_URI=""
source "$(dirname "$0")/db.sh"; source "$(dirname "$0")/routines.sh"
db_init >/dev/null
errors_record() { :; }; _routine_session_cost() { :; }
export PIPE_PROFILE=fxa PIPE_JIRA_SITE=https://jira.example.net
pipeline_key_in_scope() { [ -z "${OUT_OF_SCOPE:-}" ]; }
_jira_sa() { return 0; }
jira_comment() { [ -z "${JIRA_DOWN:-}" ] || return 1; printf '%s\n' "$2" > "$tmp/comment.$1"; echo "$1" >> "$tmp/posted"; }
jira_attach() { [ -z "${ATTACH_DOWN:-}" ] || return 1; cp "$2" "$tmp/attach.$1"; echo "$1 ${2##*/}" >> "$tmp/attached"; }
# The work repo's default branch, as the host's clone holds it.
g init -q --bare "$tmp/origin.git"; g clone -q "$tmp/origin.git" "$tmp/src" 2>/dev/null
( cd "$tmp/src" && mkdir -p packages/a && echo x > packages/a/b.ts && echo y > packages/a/b.spec.ts && g add . && g commit -qm m && g push -q origin HEAD:main ) >/dev/null 2>&1
g clone -q "$tmp/origin.git" "$tmp/clone" 2>/dev/null
pipeline_host_clone() { echo "$tmp/clone"; }
cfg='{"name":"Investigate","on":"jira-label","template":"investigate","mode":"report","channel":"C0OWN00","repos":["mozilla/fxa"],"max_usd":10}'
rid="$(db_value "INSERT INTO routines (team, data) VALUES ('fxa', json($(db_q "$cfg"))); SELECT last_insert_rowid();")"
# run <key> [team]   A started investigation run of session agent-iv01; prints its id.
run() { local h; h="$(jq -nc --arg k "$1" '{investigate: {key: $k, by: "acc-a1", url: "https://jira.example.net/browse/\($k)"}}')"
  db_value "INSERT INTO routine_runs (routine_id, period, trigger, state, session, config, heads, started_at) VALUES ($rid, 'jira-$1-$RANDOM', 'jira-label', 'started', 'agent-iv01',
  json($(db_q "$cfg")), json($(db_q "$h")), 1); SELECT last_insert_rowid();"; }
done_() { routine_done "$1" --state "${3:-report}" --session agent-iv01 ${2:+--report-file "$2"} 2>>"$tmp/err"; }
row() { db_value "SELECT state || '|' || coalesce(reason, '') FROM routine_runs WHERE id = $1;"; }
block() { printf 'Notes.\n```fxa-investigation\n%s\n```\n' "$1" > "$tmp/$2.md"; }

block '{"ask": "Fix login", "cause": "The retry at https://evil.example/steal skips the guard; see [this](http://evil.example/x)",
  "confidence": "high", "evidence": ["git log -S guard"], "since_last": null,
  "fix": {"summary": "Add the guard", "steps": [{"file": "packages/a/b.ts", "lines": "10-12", "change": "Guard it"}, {"file": "packages/missing.ts", "lines": "3", "change": "Drop it"}],
          "tests": [{"file": "packages/a/b.spec.ts", "case": "retries once"}], "verify": "yarn test"},
  "acceptance": ["login works"], "risks": [], "not_checked": ["Sentry"], "related": ["FXA-9"]}' good
r1="$(run FXA-1)"; a="$(done_ "$r1" "$tmp/good.md")"; c="$tmp/comment.FXA-1"
check "a good block: the run is a report, the answer says posted with the key and link" "true|report|true|FXA-1|https://jira.example.net/browse/FXA-1|true" \
  "$(jq -r '[.changed, .state, .post, .investigate.key, .investigate.url, .investigate.posted] | map(tostring) | join("|")' <<< "$a")"
check "one comment, led by the robot, with no injected URL or link" "1|🤖 Investigation of FXA-1 (run ${r1})  ·  confidence: high|0|0" \
  "$(grep -c . "$tmp/posted")|$(head -1 "$c")|$(grep -c evil "$c")|$(grep -c 'http://' "$c")"
check "a path in the repo keeps its lines; a missing one is dropped" '1. `packages/a/b.ts:10-12`: Guard it|2. Drop it|- `packages/a/b.spec.ts`: retries once' \
  "$(grep -E '^([0-9]\. |- `)' "$c" | paste -sd'|' -)"
check "the row keeps the comment as its report and the cleaned result for the next run" "1|Add the guard|null" \
  "$(db_value "SELECT report = $(db_q "$(cat "$c")") FROM routine_runs WHERE id = $r1;")|$(db_value "SELECT json_extract(heads, '$.investigate.result.fix.summary') || '|' || coalesce(json_extract(heads, '$.investigate.result.fix.steps[1].file'), 'null') FROM routine_runs WHERE id = $r1;")"
check "a second done changes nothing and posts nothing more" "false|1" "$(done_ "$r1" "$tmp/good.md" | jq -r .changed)|$(grep -c . "$tmp/posted")"
check "the notes attach as one file, and the comment names it before the ai-fixme line" "FXA-1 investigation-FXA-1-run-${r1}.md|1|Details: investigation-FXA-1-run-${r1}.md (attached)" \
  "$(cat "$tmp/attached")|$(grep -c '^Notes\.$' "$tmp/attach.FXA-1")|$(tail -2 "$c" | head -1)"

printf 'I read https://evil.example/x and [it](http://evil.example/y).\n```fxa-investigation\n{"ask": "a", "cause": "c"}\n```\n' > "$tmp/url.md"
r9="$(run FXA-9)"; done_ "$r9" "$tmp/url.md" >/dev/null
check "the attached notes hold no URL" "0|1" "$(grep -c 'evil' "$tmp/attach.FXA-9")|$(grep -c '^I read  and it\.$' "$tmp/attach.FXA-9")"
printf 'The user pat.doe@gmail.com saw it.\n```fxa-investigation\n{"ask": "a", "cause": "c"}\n```\n' > "$tmp/pnotes.md"
r10="$(run FXA-10)"; done_ "$r10" "$tmp/pnotes.md" >/dev/null
check "personal data in the notes: the comment posts, with no file and no Details line" "report|0|0" \
  "$(row "$r10" | cut -d'|' -f1)|$([ -e "$tmp/attach.FXA-10" ] && echo 1 || echo 0)|$(grep -c '^Details:' "$tmp/comment.FXA-10")"
r11="$(run FXA-11)"; ATTACH_DOWN=1 done_ "$r11" "$tmp/good.md" >/dev/null
check "Jira refuses the file: the comment posts with no Details line" "report|0" "$(row "$r11" | cut -d'|' -f1)|$(grep -c '^Details:' "$tmp/comment.FXA-11")"

printf 'I could not find it.\n' > "$tmp/none.md"; r2="$(run FXA-2)"; a="$(done_ "$r2" "$tmp/none.md")"
check "no block: the run fails, nothing posts" "failed|investigation not posted: the report has no fxa-investigation block|false|false|0" \
  "$(row "$r2")|$(jq -r .post <<< "$a")|$(jq -r .investigate.posted <<< "$a")|$([ -e "$tmp/comment.FXA-2" ] && echo 1 || echo 0)"
block '{"ask": "Fix login for pat.doe@gmail.com", "cause": "c"}' pii; r3="$(run FXA-3)"; done_ "$r3" "$tmp/pii.md" >/dev/null
check "personal data in the comment: the run fails, nothing posts" "failed|investigation not posted: the comment may hold personal data or a secret, so it is not posted|0" \
  "$(row "$r3")|$([ -e "$tmp/comment.FXA-3" ] && echo 1 || echo 0)"
r4="$(run FXA-4)"; JIRA_DOWN=1 done_ "$r4" "$tmp/good.md" >/dev/null
check "Jira refuses the comment: the run fails" "failed|investigation not posted: Jira refused the comment on FXA-4" "$(row "$r4")"
r5="$(run FXA-5)"; OUT_OF_SCOPE=1 done_ "$r5" "$tmp/good.md" >/dev/null
check "a ticket that left the public scope: the run fails, nothing posts" "failed|investigation not posted: FXA-5 is not in the team's public Jira scope now|0" \
  "$(row "$r5")|$([ -e "$tmp/comment.FXA-5" ] && echo 1 || echo 0)"
r6="$(run FXA-6)"; a="$(routine_done "$r6" --state failed --session agent-iv01 --reason 'stopped at its cost limit' 2>>"$tmp/err")"
check "the bot's own failure stays as it is, with no comment" "failed|stopped at its cost limit|false|0" \
  "$(row "$r6")|$(jq -r .investigate.posted <<< "$a")|$([ -e "$tmp/comment.FXA-6" ] && echo 1 || echo 0)"
r7="$(run FXA-7)"; PIPE_PROFILE=other done_ "$r7" "$tmp/good.md" >/dev/null
check "a run of another team than the loaded one fails" "failed|investigation not posted: the run's team is not the loaded one" "$(row "$r7")"
# No host clone: one GitHub tree read decides the paths.
pipeline_host_clone() { echo "$tmp/none"; }
mkdir -p "$tmp/bin"; printf '#!/bin/sh\necho "gh $*" >> "%s/gh"\nprintf "packages/missing.ts\\n"\n' "$tmp" > "$tmp/bin/gh"; chmod +x "$tmp/bin/gh"; PATH="$tmp/bin:$PATH"
r8="$(run FXA-8)"; done_ "$r8" "$tmp/good.md" >/dev/null
check "with no clone, one GitHub tree read keeps the paths it lists" '1|1. Guard it|2. `packages/missing.ts:3`: Drop it' \
  "$(grep -c 'git/trees/HEAD?recursive=1' "$tmp/gh")|$(grep -E '^[0-9]\. ' "$tmp/comment.FXA-8" | paste -sd'|' -)"
exit "$fail"
