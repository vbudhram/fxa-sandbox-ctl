#!/usr/bin/env bash
# Offline check of `routine tick` and `routine run-now` through the real CLI (set -euo pipefail), with the
# team pause read for real: a status capture that set -e ends would answer nothing here.
#   bash lib/routines-cli.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
command -v sqlite3 >/dev/null || { echo "skip: needs sqlite3"; exit 0; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
src="$(cd "$(dirname "$0")/.." && pwd)" root="$tmp/tree"
# The CLI loads .env for any variable that is empty here, so it runs from a copy of the tree with no .env:
# the tracked and new files, without the ignored ones (.env is one).
mkdir -p "$root"
if ( cd "$src" && git ls-files -co --exclude-standard -z ) > "$tmp/files" 2>/dev/null && [ -s "$tmp/files" ]; then
  ( cd "$src" && xargs -0 tar cf - < "$tmp/files" ) | ( cd "$root" && tar xf - )
else cp -R "$src/." "$root/"; fi
rm -f "$root/.env"
[ ! -f "$root/.env" ] || { echo "FAIL the copied tree still has a .env"; exit 1; }
mkdir -p "$tmp/bin" "$tmp/teams" "$tmp/sessions" "$tmp/proxy/teams" "$tmp/state" "$tmp/home"
# GitHub: the branch head of any repo.
printf '#!/bin/sh\necho 2222222222222222222222222222222222222222\n' > "$tmp/bin/gh"; chmod +x "$tmp/bin/gh"
# The GitHub API, offline: each repo is public (or private while $tmp/private exists), and the App is installed.
cat > "$tmp/bin/curl" <<EOF
#!/bin/sh
for a; do url="\$a"; done
case "\$url" in
  */installation) printf 200 ;;   # teams.sh reads only the HTTP code
  https://api.github.com/repos/*) if [ -e "$tmp/private" ]; then printf 404; else printf 200; fi ;;
  *) exit 7 ;;
esac
EOF
chmod +x "$tmp/bin/curl"
# _retry waits 3 s and 9 s between tries of a GitHub call that fails: no wait here.
printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/sleep"; chmod +x "$tmp/bin/sleep"
: > "$tmp/bot.env"; echo '{"teams": {}}' > "$tmp/teams/index.json"
T=1792414800   # Monday 2026-10-19 09:00 in New York
ctl() { ( cd "$root" && env PATH="$tmp/bin:$PATH" TMPDIR="$tmp" HOME="$tmp/home" FXA_DB="$tmp/fxa.db" FXA_DB_BACKUP_URI="" FXA_TEAMS_DIR="$tmp/teams" \
  FXA_SESSION_DIR="$tmp/sessions" FXA_LLM_PROXY_DIR="$tmp/proxy" FXA_FIXME_STATE="$tmp/state" FXA_BOT_ENV="$tmp/bot.env" \
  FXA_ERRORS_FILE="$tmp/errors.jsonl" FXA_GCE_PROJECT="" FXA_SESSIONS_PAUSE_URI="" FXA_SESSION_STORE_URI="" FXA_SESSION_BACKUP_URI="" \
  FXA_TEAM_ACTOR=admin@example.com FXA_ROUTINE_NOW="${NOW:-$T}" ./fxa-sandbox-ctl "$@" ); }
ctl db init >/dev/null 2>&1
mk() { sqlite3 "$tmp/fxa.db" "INSERT INTO routines (team, data) VALUES ('fxa', json('$(jq -cn --arg s "$1" '{name: "Code review", template: "code-review",
  prompt: "x", schedule: $s, zone: "America/New_York", repos: ["mozilla/fxa"], channel: "C0OWN00", mode: "report", max_usd: 5, skip_no_commits: true, env: "live"}')')); SELECT last_insert_rowid();"; }

r1="$(mk "daily 09:00")"
out="$(NOW=$((T + 30)) ctl routine tick --env live 2>"$tmp/err")"; rc=$?
check "the CLI tick, a team that is not paused: exit 0 and the run in its JSON" "0|1" "$rc|$(jq --argjson r "$r1" '[.runs[] | select(.routine == $r)] | length' <<< "$out" 2>/dev/null)"
r2="$(mk "daily 09:00")"; echo "deploy in progress" > "$tmp/state/PAUSED"
out="$(NOW=$((T + 60)) ctl routine tick --env live 2>"$tmp/err")"; rc=$?
check "the CLI tick, a paused team: exit 0 and the skip with the pause reason" "0|the team is paused: deploy in progress" \
  "$rc|$(jq -r --argjson r "$r2" '.skips[] | select(.routine == $r) | .reason' <<< "$out" 2>/dev/null)"
rm -f "$tmp/state/PAUSED"
r3="$(mk "daily 09:00")"; ctl sessions pause "spend review" >/dev/null 2>&1
out="$(NOW=$((T + 90)) ctl routine tick --env live 2>"$tmp/err")"; rc=$?
check "the CLI tick while sessions are paused: the skip says so" "0|agent sessions are paused: spend review" \
  "$rc|$(jq -r --argjson r "$r3" '.skips[] | select(.routine == $r) | .reason' <<< "$out" 2>/dev/null)"
ctl sessions resume >/dev/null 2>&1
r4="$(mk "weekly sat 23:00")"
out="$(NOW=$((T + 120)) ctl routine run-now fxa "$r4" 2>&1)"; rc=$?
check "the CLI run-now, a team that is not paused: exit 0 and the queued run" "0|queued" "$rc|$(sed -E 's/^(queued) run [0-9]+.*/\1/' <<< "$out")"
r5="$(mk "weekly sat 23:00")"; echo "deploy in progress" > "$tmp/state/PAUSED"
out="$(NOW=$((T + 150)) ctl routine run-now fxa "$r5" 2>&1)"; rc=$?
check "the CLI run-now, a paused team: exit 1 and why" "1|ERROR: routine ${r5} cannot run now: the team is paused: deploy in progress" "$rc|$out"
rm -f "$tmp/state/PAUSED"
# GitHub does not answer: the head cannot be read. The tick skips and answers; run-now refuses with why.
printf '#!/bin/sh\nexit 1\n' > "$tmp/bin/gh"
r6="$(mk "daily 09:00")"
out="$(NOW=$((T + 180)) ctl routine tick --env live 2>"$tmp/err")"; rc=$?
check "the CLI tick, a head that cannot be read: exit 0 and the skip" "0|cannot read the branch head" "$rc|$(jq -r --argjson r "$r6" '.skips[] | select(.routine == $r) | .reason' <<< "$out" 2>/dev/null)"
r7="$(mk "weekly sat 23:00")"
out="$(NOW=$((T + 210)) ctl routine run-now fxa "$r7" 2>&1)"; rc=$?
check "the CLI run-now, a head that cannot be read: exit 1 and why" "1|ERROR: routine ${r7} cannot run now: cannot read the branch head" "$rc|$out"
# done under set -euo pipefail, with a routine whose schedule cannot be read: the result is still stored.
printf '#!/bin/sh\necho 2222222222222222222222222222222222222222\n' > "$tmp/bin/gh"
rz="$(sqlite3 "$tmp/fxa.db" "INSERT INTO routines (team, data) VALUES ('fxa', json('{\"name\":\"x\",\"schedule\":\"daily 09:00\",\"zone\":\"Mars/Base\"}')); SELECT last_insert_rowid();")"
run="$(sqlite3 "$tmp/fxa.db" "INSERT INTO routine_runs (routine_id, period, state, session, started_at) VALUES ($rz, 'p1', 'started', 'agent-cli001', $T); SELECT last_insert_rowid();")"
out="$(NOW=$((T + 240)) ctl routine done "$run" --state nochange --session agent-cli001 2>&1)"; rc=$?
check "the CLI done with a schedule that cannot be read: exit 0, the result stored, no next run" "0|nochange|null" \
  "$rc|$(sqlite3 "$tmp/fxa.db" "SELECT state FROM routine_runs WHERE id = $run;")|$(jq -r .next <<< "$out" 2>/dev/null)"
# A repo GitHub hides (404) makes the team private: the real CLI keeps the run out of a channel it does not bind.
rp="$(mk "daily 10:00")"; touch "$tmp/private"; rm -f "$tmp"/fxa-github-vis.*   # the 200 answers above are cached for a day
out="$(NOW=$((T + 3600 + 30)) ctl routine tick --env live 2>"$tmp/err")"; rc=$?
check "the CLI tick, a repo GitHub hides: exit 0 and the channel refusal, not posted" "0|channel|false" \
  "$rc|$(jq -r --argjson r "$rp" '.skips[] | select(.routine == $r) | "\(.reason | ltrimstr("the routine no longer passes its checks: ") | split(":")[0])|\(.post)"' <<< "$out" 2>/dev/null)"
rm -f "$tmp/private"
exit "$fail"
