#!/usr/bin/env bash
# Offline check of `routine tick` and `routine run-now` through the real CLI (set -euo pipefail), with the
# team pause read for real: a status capture that set -e ends would answer nothing here.
#   bash lib/routines-cli.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
command -v sqlite3 >/dev/null || { echo "skip: needs sqlite3"; exit 0; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
root="$(cd "$(dirname "$0")/.." && pwd)"
# The CLI loads .env for any variable that is empty here: a developer's .env could point it at real buckets.
[ ! -f "$root/.env" ] || { echo "skip: $root/.env exists, and the CLI would read it"; exit 0; }
mkdir -p "$tmp/bin" "$tmp/teams" "$tmp/sessions" "$tmp/proxy/teams" "$tmp/state" "$tmp/home"
# GitHub: the branch head of any repo.
printf '#!/bin/sh\necho 2222222222222222222222222222222222222222\n' > "$tmp/bin/gh"; chmod +x "$tmp/bin/gh"
: > "$tmp/bot.env"
T=1792414800   # Monday 2026-10-19 09:00 in New York
ctl() { ( cd "$root" && env PATH="$tmp/bin:$PATH" HOME="$tmp/home" FXA_DB="$tmp/fxa.db" FXA_DB_BACKUP_URI="" FXA_TEAMS_DIR="$tmp/teams" \
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
exit "$fail"
