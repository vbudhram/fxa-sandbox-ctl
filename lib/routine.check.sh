#!/usr/bin/env bash
# Offline check for routines (epic i168): the tables, the validator, the templates and the CRUD commands.
#   bash lib/routine.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
command -v sqlite3 >/dev/null || { echo "skip: needs sqlite3"; exit 0; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export FXA_DB="$tmp/fxa.db" FXA_DB_BACKUP_URI=""
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/db.sh"

# The tables: db_init creates them, and one (routine, period) is claimed once.
db_init >/dev/null
check "db_init creates the three routine tables" "routine_runs routine_tick routines" \
  "$(db_value "SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'routine%' ORDER BY name;" | tr '\n' ' ' | sed 's/ $//')"
db_exec "INSERT OR IGNORE INTO routine_runs (routine_id, period) VALUES (1, '2026-10-20'); INSERT OR IGNORE INTO routine_runs (routine_id, period) VALUES (1, '2026-10-20');"
check "a second claim of one (routine, period) is ignored" "1" "$(db_value "SELECT count(*) FROM routine_runs;")"
db_exec "DELETE FROM routine_runs;"

# The validator: one line that names the field for each refusal, and a valid routine passes.
cat > "$tmp/ro.json" <<'J'
{"profile":"pyfxa","read_only":true,"private":false,"repos":[{"slug":"mozilla/PyFxA","role":"work"}]}
J
cat > "$tmp/priv.json" <<'J'
{"profile":"secret","read_only":false,"private":true,"repos":[{"slug":"mozilla/secret","role":"work"},{"slug":"mozilla/fxa","role":"dep"}]}
J
cat > "$tmp/index.json" <<'J'
{"schema":1,"teams":{"secret":{"status":"active","access":{"channels":["C0OWN00"]}},"second":{"status":"active","access":{"channels":["C0SECOND"]}}}}
J
# The bot's access rules: team envy is an env-access team (PROFILE_CHANNELS), with its own channel.
printf 'PROFILE_CHANNELS=C0ENVY0:envy\nPROFILE_OPEN=envy\n' > "$tmp/bot.env"
v() { # v <team> <profile> <override json> [count]   the validator's first stderr line for the base routine plus the override, or "ok"
  jq -cn --argjson b "$base" --argjson x "$3" '$b + $x' > "$tmp/r.json"
  python3 -I "$here/routine.py" validate "$tmp/r.json" "$1" --profile "$tmp/$2" --index "$tmp/index.json" --bot-env "$tmp/bot.env" --count "${4:-0}" 2>&1 >/dev/null | head -1 | grep . || echo ok; }
base='{"name":"Code review","template":"code-review","prompt":"Review the commits.","schedule":"weekdays 09:00","zone":"America/New_York","mode":"report","repos":["mozilla/secret"],"channel":"C0OWN00"}'
check "a pr mode on a diff-only team" "mode: Draft PR is not possible: this team gets diffs only, so a routine can only report" \
  "$(v pyfxa ro.json '{"repos":["mozilla/PyFxA"],"channel":"C0ANY00","mode":"pr"}')"
check "a channel another team binds" "channel: Channel C0SECOND belongs to team second" "$(v secret priv.json '{"channel":"C0SECOND"}')"
check "a private-repo team on a channel it does not bind" "channel: A team with a private repo posts only to one of this team's channels" \
  "$(v secret priv.json '{"channel":"C0OTHER"}')"
check "a schedule outside the fixed format" "schedule: Use daily HH:MM, weekdays HH:MM or weekly <mon..sun> HH:MM" "$(v secret priv.json '{"schedule":"every 5 minutes"}')"
big="$(head -c 5000 /dev/zero | tr '\0' a)"
check "a 5 KB prompt" "prompt: The prompt is over 4 KB" "$(v secret priv.json "$(jq -cn --arg p "$big" '{prompt: $p}')")"
check "a name with a Slack mention" "name: Use letters, digits, spaces and . _ ( ) - in the name, at most 40 characters" "$(v secret priv.json '{"name":"<!channel> review"}')"
check "a branch with two repos" "branch: A branch needs exactly one repo" "$(v secret priv.json '{"repos":["mozilla/secret","mozilla/fxa"],"branch":"main"}')"
check "a pr mode with two repos" "mode: A draft PR mode needs exactly one work repo" "$(v secret priv.json '{"repos":["mozilla/secret","mozilla/fxa"],"mode":"pr"}')"
check "a security review in pr mode" "mode: A security review only reports; it never opens a PR" "$(v secret priv.json '{"template":"security-review","mode":"pr"}')"
check "a ninth routine" "routine: A team has at most 8 routines" "$(v secret priv.json '{}' 8)"
check "a zone that is not a zone, not a silent UTC" "zone: 'Mars/Base' is not a time zone, such as America/New_York" "$(v secret priv.json '{"zone":"Mars/Base"}')"
check "a cost limit over the ceiling" "max_usd: The cost limit must be more than 0 and at most 50 USD" "$(v secret priv.json '{"max_usd":500}')"
check "a repo the team does not have" "repos: Repo mozilla/x is not one of this team's repos" "$(v secret priv.json '{"repos":["mozilla/x"]}')"
echo '{"profile":"second","read_only":false,"private":false,"repos":[{"slug":"mozilla/two","role":"work"}]}' > "$tmp/open.json"
check "a security review on a record team, on a channel it does not bind" "channel: A security review posts only to one of this team's channels" \
  "$(v second open.json '{"template":"security-review","repos":["mozilla/two"],"channel":"C0PUBLIC"}')"
check "a code review on that team's other channel passes" "ok" "$(v second open.json '{"repos":["mozilla/two"],"channel":"C0PUBLIC"}')"
check "an unknown field" "colour: is not a routine field" "$(v secret priv.json '{"colour":"red"}')"
check "a bad template" "template: must be one of code-review, ux-review, perf-review, security-review, blank" "$(v secret priv.json '{"template":"x"}')"
check "an empty prompt" "prompt: The prompt is empty" "$(v secret priv.json '{"prompt":"  "}')"
check "no repos" "repos: Pick at least one of this team's repos" "$(v secret priv.json '{"repos":[]}')"
for b in '-x' 'a..b' 'a b'; do
  check "a bad branch ($b)" "branch: Use letters, digits and . _ / - in the branch, at most 60 characters" "$(v secret priv.json "$(jq -cn --arg b "$b" '{branch: $b}')")"
done
check "a bad mode" "mode: must be report, pr or pr+notes" "$(v secret priv.json '{"mode":"merge"}')"
check "a malformed channel" "channel: Use a Slack channel ID (C0123ABCD) or a link to the channel" "$(v secret priv.json '{"channel":"#general"}')"
check "a pr mode on the team's dep repo, not its work repo (D27)" "mode: A draft PR mode needs exactly one work repo" "$(v secret priv.json '{"repos":["mozilla/fxa"],"mode":"pr"}')"
echo '{"profile":"envy","read_only":false,"private":false,"repos":[{"slug":"mozilla/envy","role":"work"}]}' > "$tmp/envy.json"
check "an env-access team: a security review on a channel it does not own is refused" "channel: A security review posts only to one of this team's channels" \
  "$(v envy envy.json '{"template":"security-review","repos":["mozilla/envy"],"channel":"C0PUBLIC"}')"
check "an env-access team: its PROFILE_CHANNELS channel counts as its own" "ok" "$(v envy envy.json '{"template":"security-review","repos":["mozilla/envy"],"channel":"C0ENVY0"}')"
check "another team cannot use an env-access team's channel" "channel: Channel C0ENVY0 belongs to team envy" "$(v secret priv.json '{"channel":"C0ENVY0"}')"
jq -cn --argjson b "$base" '$b' > "$tmp/r.json"
check "an unreadable bot .env fails closed" "channel: cannot read the bot access rules" \
  "$(python3 -I "$here/routine.py" validate "$tmp/r.json" secret --profile "$tmp/priv.json" --index "$tmp/index.json" --bot-env "$tmp/missing.env" 2>&1 >/dev/null)"
check "a valid routine on the team's own channel passes" "ok" "$(v secret priv.json '{}')"
jq -cn --argjson b "$base" '$b + {channel: "https://example.slack.com/archives/C0OWN00"}' > "$tmp/r.json"
check "a pasted channel link is stored as the channel ID" "C0OWN00" \
  "$(python3 -I "$here/routine.py" validate "$tmp/r.json" secret --profile "$tmp/priv.json" --index "$tmp/index.json" --bot-env "$tmp/bot.env" | jq -r .channel)"
# Weekdays 09:00 in New York from Saturday 2026-10-17: Monday, Tuesday, Wednesday. From Friday 2026-10-30 11:00,
# across the DST end on 1 November: Monday 09:00 at the new offset.
printf '%s' "$base" > "$tmp/r.json"
check "the next three weekday 09:00 times in the routine's zone" "2026-10-19T09:00:00-04:00 2026-10-20T09:00:00-04:00 2026-10-21T09:00:00-04:00" \
  "$(python3 -I "$here/routine.py" next "$tmp/r.json" --from 1792260000 | tr '\n' ' ' | sed 's/ $//')"
check "after the DST change, still 09:00 local" "2026-11-02T09:00:00-05:00" "$(python3 -I "$here/routine.py" next "$tmp/r.json" --from 1793372400 --n 1)"
check "the period is the local date, not the UTC one (23:30 in New York is the next day in UTC)" "2026-10-19" "$(python3 -I "$here/routine.py" period "$tmp/r.json" 1792467000)"
# A time in the hour a DST start skips (02:30 on Sunday 2027-03-14 in New York) runs once, at 03:30 local.
jq -c '.schedule = "daily 02:30"' "$tmp/r.json" > "$tmp/gap.json"
check "a time in the DST gap runs once that day, at the wall clock it lands on" "2027-03-13T02:30:00-05:00 2027-03-14T03:30:00-04:00 2027-03-15T02:30:00-04:00" \
  "$(python3 -I "$here/routine.py" next "$tmp/gap.json" --from 1804914000 | tr '\n' ' ' | sed 's/ $//')"

# The built-in templates: four, and the security review is locked to report.
check "routine templates lists four templates, and security-review is locked to report" "code-review perf-review security-review ux-review|report|report" \
  "$(python3 -I "$here/routine.py" templates | jq -r '[.[].template] | join(" ")')|$(python3 -I "$here/routine.py" templates | jq -r '.[] | select(.template == "security-review") | "\(.mode)|\(.locked_mode)"')"
check "each template has a prompt and a skip flag" "4" "$(python3 -I "$here/routine.py" templates | jq '[.[] | select((.prompt | length) > 100 and (.skip_no_commits | type) == "boolean")] | length')"

# The CRUD commands, with the real store and the team profile stubbed.
SANDBOX_ROOT="$(cd "$here/.." && pwd)" FXA_GCE_PROJECT="" FXA_TEAMS_URI="" SESSION_DIR="$tmp/sessions" FXA_TEAMS_DIR="$tmp/teams"
mkdir -p "$SESSION_DIR" "$FXA_TEAMS_DIR"; cp "$tmp/index.json" "$FXA_TEAMS_DIR/index.json"
source "$here/teams.sh"; source "$here/routines.sh"
pipeline_folder_teams() { echo fxa; }
_routine_profile() { cat "$tmp/priv.json"; }
export FXA_TEAM_ACTOR=admin@example.com FXA_BOT_ENV="$tmp/bot.env"
jq -cn --argjson b "$base" '$b + {prompt: "SECRET-PROMPT-TEXT review"}' > "$tmp/new.json"
check "an admin creates a routine" "created routine 1" "$(routine_set secret "$tmp/new.json" 2>&1)"
check "the list has it, active, with its next three run times" "1|0|3" "$(routine_list secret | jq -r '.[0] | "\(.id)|\(.paused)|\(.next | length)"')"
check "the create audit row names the admin and the routine, not the prompt" "admin@example.com|routine-create|routine 1|0" \
  "$(db_value "SELECT actor || '|' || action || '|' || changed FROM team_audit ORDER BY id DESC LIMIT 1;")|$(db_value "SELECT count(*) FROM team_audit WHERE changed LIKE '%SECRET-PROMPT%';")"
jq -c '.name = "Code review 2" | .prompt = "SECRET-PROMPT-TEXT two"' "$tmp/new.json" > "$tmp/edit.json"
check "an edit at the current version saves version 2" "saved routine 1 (version 2)" "$(routine_set secret "$tmp/edit.json" 1 1 2>&1)"
got="$(routine_set secret "$tmp/edit.json" 1 1 2>&1)"; rc=$?
check "a second edit at version 1 is stale: exit 2 and the stale text" "2|ERROR: Someone changed this routine since you opened it. Load it again to see their change." "$rc|$got"
check "the edit audit row names the changed fields, never the prompt" "routine 1: name,prompt|0" \
  "$(db_value "SELECT changed FROM team_audit WHERE action = 'routine-set';")|$(db_value "SELECT count(*) FROM team_audit WHERE changed LIKE '%SECRET-PROMPT%';")"
got="$( db_value() { case "$1" in (UPDATE*) return 1 ;; (*) _db -list "$1" ;; esac; }; routine_set secret "$tmp/edit.json" 1 2 2>&1)"; rc=$?
check "a store that fails on the update is a store error, not a stale version" "1|ERROR: the routine store did not answer (busy or failed); nothing changed, try again|2" \
  "$rc|$got|$(db_value "SELECT version FROM routines WHERE id = 1;")"
jq -c '.channel = "C0SECOND"' "$tmp/new.json" > "$tmp/bad.json"
got="$(routine_set secret "$tmp/bad.json" 2>&1)"; rc=$?
check "a refused save: exit 1, the field line, and no row" "1|channel: Channel C0SECOND belongs to team second|1" "$rc|$got|$(db_value "SELECT count(*) FROM routines;")"
check "an edit of another team's routine is refused" "ERROR: team second has no routine 1" "$(routine_set second "$tmp/edit.json" 1 2 2>&1)"
# Eight routines exist, and the count the validator read was stale (another save raced it): the INSERT refuses.
db_exec "INSERT INTO routines (team, data) VALUES ('secret','{}'),('secret','{}'),('secret','{}'),('secret','{}'),('secret','{}'),('secret','{}'),('secret','{}');"
got="$( db_value() { case "$1" in ("SELECT count(*) FROM routines WHERE team"*) echo 0 ;; (*) _db -list "$1" ;; esac; }; routine_set secret "$tmp/new.json" 2>&1)"; rc=$?
check "the 8-routine cap holds in the INSERT, even after a stale count" "1|routine: A team has at most 8 routines|8" "$rc|$got|$(db_value "SELECT count(*) FROM routines WHERE team = 'secret';")"
db_exec "DELETE FROM routines WHERE id > 1;"
check "pause, then resume" "1|0" "$(routine_state secret 1 pause >/dev/null; db_value "SELECT paused FROM routines WHERE id = 1;")|$(routine_state secret 1 resume >/dev/null; db_value "SELECT paused FROM routines WHERE id = 1;")"
check "pause, delete and history of another team's routine are refused" "ERROR: team second has no routine 1|ERROR: team second has no routine 1|ERROR: team second has no routine 1|0|1" \
  "$(routine_state second 1 pause 2>&1)|$(routine_state second 1 delete 2>&1)|$(routine_history second 1 2>&1)|$(db_value "SELECT paused FROM routines WHERE id = 1;")|$(db_value "SELECT count(*) FROM routines;")"
# The dashboard sends --id then --version; the other order works the same.
check "cmd_routine set takes --id and --version in either order" "saved routine 1 (version 5)|saved routine 1 (version 6)" \
  "$(cmd_routine set secret "$tmp/edit.json" --id 1 --version 4 2>&1)|$(cmd_routine set secret "$tmp/edit.json" --version 5 --id 1 2>&1)"
db_exec "INSERT INTO routine_runs (routine_id, period, state) VALUES (1, '2026-10-19', 'started');"
check "delete is refused while a run is live" "ERROR: a run of routine 1 is in progress; stop it first|1" "$(routine_state secret 1 delete 2>&1)|$(db_value "SELECT count(*) FROM routines;")"
db_exec "UPDATE routine_runs SET state = 'ok';"
check "delete removes the routine and keeps its history" "0|1|routine-delete" \
  "$(routine_state secret 1 delete >/dev/null; db_value "SELECT count(*) FROM routines;")|$(db_value "SELECT count(*) FROM routine_runs;")|$(db_value "SELECT action FROM team_audit ORDER BY id DESC LIMIT 1;")"
# teams_delete takes the team's routines with it, with an audit row.
echo '{"name":"rusty"}' > "$FXA_TEAMS_DIR/rusty.json"
db_exec "INSERT INTO routines (team, data) VALUES ('rusty', '{}'), ('rusty', '{}');"
teams_index() { :; }
teams_delete rusty >/dev/null 2>&1
check "teams_delete leaves no routine of the team, and audits it" "0|all 2 routines, with the team" \
  "$(db_value "SELECT count(*) FROM routines WHERE team = 'rusty';")|$(db_value "SELECT changed FROM team_audit WHERE team = 'rusty' AND action = 'routine-delete';")"

exit "$fail"
