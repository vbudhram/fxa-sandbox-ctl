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
v() { # v <team> <profile> <override json> [count]   the validator's first stderr line for the base routine plus the override, or "ok"
  jq -cn --argjson b "$base" --argjson x "$3" '$b + $x' > "$tmp/r.json"
  python3 -I "$here/routine.py" validate "$tmp/r.json" "$1" --profile "$tmp/$2" --index "$tmp/index.json" --bot-env "$tmp/none" --count "${4:-0}" 2>&1 >/dev/null | head -1 | grep . || echo ok; }
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
check "a valid routine on the team's own channel passes" "ok" "$(v secret priv.json '{}')"
jq -cn --argjson b "$base" '$b + {channel: "https://example.slack.com/archives/C0OWN00"}' > "$tmp/r.json"
check "a pasted channel link is stored as the channel ID" "C0OWN00" \
  "$(python3 -I "$here/routine.py" validate "$tmp/r.json" secret --profile "$tmp/priv.json" --index "$tmp/index.json" | jq -r .channel)"
# Weekdays 09:00 in New York from Saturday 2026-10-17: Monday, Tuesday, Wednesday. From Friday 2026-10-30 11:00,
# across the DST end on 1 November: Monday 09:00 at the new offset.
printf '%s' "$base" > "$tmp/r.json"
check "the next three weekday 09:00 times in the routine's zone" "2026-10-19T09:00:00-04:00 2026-10-20T09:00:00-04:00 2026-10-21T09:00:00-04:00" \
  "$(python3 -I "$here/routine.py" next "$tmp/r.json" --from 1792260000 | tr '\n' ' ' | sed 's/ $//')"
check "after the DST change, still 09:00 local" "2026-11-02T09:00:00-05:00" "$(python3 -I "$here/routine.py" next "$tmp/r.json" --from 1793372400 --n 1)"
check "the period is the local date" "2026-10-19" "$(python3 -I "$here/routine.py" period "$tmp/r.json" 1792414800)"

# The built-in templates: four, and the security review is locked to report.
check "routine templates lists four templates, and security-review is locked to report" "code-review perf-review security-review ux-review|report|report" \
  "$(python3 -I "$here/routine.py" templates | jq -r '[.[].template] | join(" ")')|$(python3 -I "$here/routine.py" templates | jq -r '.[] | select(.template == "security-review") | "\(.mode)|\(.locked_mode)"')"
check "each template has a prompt and a skip flag" "4" "$(python3 -I "$here/routine.py" templates | jq '[.[] | select((.prompt | length) > 100 and (.skip_no_commits | type) == "boolean")] | length')"

exit "$fail"
