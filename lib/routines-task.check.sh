#!/usr/bin/env bash
# Offline check of cmd_task --source routine (epic i168, slice 2): ctl trusts the claimed run row, not the caller.
#   bash lib/routines-task.check.sh
source "$(dirname "$0")/session-check-head.sh"
command -v sqlite3 >/dev/null || { echo "skip: needs sqlite3"; exit 0; }
export FXA_DB="$tmp/fxa.db" FXA_DB_BACKUP_URI=""
source "$(dirname "$0")/db.sh"; source "$(dirname "$0")/routines.sh"
db_init >/dev/null
nohup() { :; }
export FXA_VM_BACKEND=gce FXA_SESSION_MAX=20
A="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" B="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
cfg() { jq -cn --arg t "${1:-code-review}" '{name: "Code review", template: $t, prompt: "ADMIN-TEXT: review the commits.", schedule: "weekdays 09:00",
  zone: "America/New_York", repos: ["mozilla/PyFxA"], branch: "release-1", channel: "C0OWN00", mode: "report", max_usd: 7, skip_no_commits: true, env: "live"}'; }
heads() { jq -cn --arg s "${1:-$A}" --arg h "${2:-$B}" '{"mozilla/PyFxA": {start: $s, head: $h}}'; }
# run <team> <state> [template] [heads]   A routine and one run row; prints the run id.
run() {
  local rid; rid="$(db_value "INSERT INTO routines (team, data) VALUES ($(db_q "$1"), '{}'); SELECT last_insert_rowid();")"
  db_value "INSERT INTO routine_runs (routine_id, period, state, config, heads) VALUES ($rid, 'p$RANDOM$RANDOM', $(db_q "$2"), $(db_q "$(cfg "${3:-code-review}")"), $(db_q "${4:-$(heads)}")); SELECT last_insert_rowid();"
}
task() { PIPE_PROFILE="$1" PIPE_REPO_SLUG=mozilla/PyFxA cmd_task --source routine --id "$2" "${@:3}"; }
none() { [ -f "$tmp/$1.json" ] && echo "session $1" || echo none; }

r1="$(run pyfxa claimed)"
check "a routine run needs --routine-run, with no session" "ERROR: --source routine needs --routine-run|none" "$(task pyfxa agent-rt01 2>&1)|$(none agent-rt01)"
check "--routine-run needs --source routine" "ERROR: --routine-run needs --source routine" \
  "$(PIPE_PROFILE=pyfxa cmd_task --source slack --id agent-rt02 --owner U1 --prompt-file /dev/null --routine-run "$r1" 2>&1)"
check "a run of another team (--pipeline fxa) is refused, with no session, and the run stays claimed" "ERROR: routine run ${r1} is not a run of team fxa|none|claimed" \
  "$(task fxa agent-rt03 --routine-run "$r1" 2>&1)|$(none agent-rt03)|$(db_value "SELECT state FROM routine_runs WHERE id = $r1;")"
printf 'mine\n' > "$tmp/caller.md"
check "the caller cannot pass the prompt, the owner or the repos" "ERROR: a routine run takes its owner, prompt, repos and connectors from its row, not from options|none" \
  "$(task pyfxa agent-rt04 --routine-run "$r1" --prompt-file "$tmp/caller.md" 2>&1)|$(none agent-rt04)"
r2="$(run pyfxa started)"
check "a run that is not claimed is refused, with no session" "ERROR: routine run ${r2} is not claimed|none" "$(task pyfxa agent-rt05 --routine-run "$r2" 2>&1)|$(none agent-rt05)"
r3="$(run pyfxa claimed code-review '{"mozilla/PyFxA": {"start": null, "head": "$(rm -rf /)"}}')"
check "a run whose head is not a hex SHA is refused, with no session, and stays claimed" "ERROR: routine run ${r3} cannot start: its row is not valid|none|claimed" \
  "$(task pyfxa agent-rt06 --routine-run "$r3" 2>/dev/null; task pyfxa agent-rt06 --routine-run "$r3" 2>&1 | tail -1)|$(none agent-rt06)|$(db_value "SELECT state FROM routine_runs WHERE id = $r3;")"
check "no such run" "ERROR: no routine run 999" "$(task pyfxa agent-rt07 --routine-run 999 2>&1)"

# The good run: what it runs comes from the row.
rid1="$(db_value "SELECT routine_id FROM routine_runs WHERE id = $r1;")"
task pyfxa agent-rt10 --routine-run "$r1" --thread C0OWN00:1790000000.000100 >/dev/null 2>&1
check "the session is a routine session: owner routine:<team>/<id>, untrusted, the routine branch as base, the run and the cap" \
  "routine:pyfxa/${rid1}|routine|1|release-1|${r1}|7|report" \
  "$(jq -r '[.owner, .source, .untrusted, .base, .routine_run, .cap_usd, .routine_mode] | map(tostring) | join("|")' "$tmp/agent-rt10.json")"
check "the session keeps the routine's name for the Sessions page" "Code review" "$(jq -r .routine_name "$tmp/agent-rt10.json")"
check "the run is started by that session" "started|agent-rt10" "$(db_value "SELECT state || '|' || session FROM routine_runs WHERE id = $r1;")"
p="$tmp/agent-rt10.prompt.md"
open="$(grep -o '^<routine-[0-9a-f]\{12\}>$' "$p")"; close="$(grep -o '^</routine-[0-9a-f]\{12\}>$' "$p")"
check "the admin text is inside one nonce fence" "1|1|yes|ADMIN-TEXT: review the commits." \
  "$(grep -c '^<routine-' "$p")|$(grep -c '^</routine-' "$p")|$([ "${close#</}" = "${open#<}" ] && echo yes)|$(sed -n "/^${open}\$/,/^<\\/routine-/p" "$p" | sed -n 2p)"
check "the only commit text is the run's hex SHAs" "- mozilla/PyFxA, branch release-1: ${A}..${B}|0" \
  "$(grep '^- mozilla/PyFxA' "$p")|$(grep -oE '[0-9a-f]{40}' "$p" | grep -cvE "^(${A}|${B})\$")"
check "a code review keeps the team's watch rule and memory" "|" "$(jq -r '"\(.watch_narrow // "")|\(.memory // "")"' "$tmp/agent-rt10.json")"
check "a second caller with the same run is refused, with no session" "ERROR: routine run ${r1} is not claimed|none" \
  "$(task pyfxa agent-rt11 --routine-run "$r1" 2>&1)|$(none agent-rt11)"
# Two callers at once: both read the run while it is claimed; only the guarded UPDATE decides.
r6="$(run pyfxa claimed)"; seen="$(routine_run_read "$r6" pyfxa)"
task pyfxa agent-rt14 --routine-run "$r6" >/dev/null 2>&1
check "two callers at once: the second, whose read saw the run claimed, is refused by the claim, with no session" "ERROR: routine run ${r6} is not claimed|none|agent-rt14" \
  "$(routine_run_read() { printf '%s\n' "$seen"; }; task pyfxa agent-rt15 --routine-run "$r6" 2>&1)|$(none agent-rt15)|$(db_value "SELECT session FROM routine_runs WHERE id = $r6;")"
r4="$(run pyfxa claimed security-review)"
task pyfxa agent-rt12 --routine-run "$r4" >/dev/null 2>&1
check "a security review is narrowed: watch_narrow 1 and memory off" "1|off" "$(jq -r '"\(.watch_narrow)|\(.memory)"' "$tmp/agent-rt12.json")"
r5="$(run pyfxa claimed)"
check "a session that cannot start ends its run failed" "failed|the session could not start|none" \
  "$(task pyfxa agent-rt13 --routine-run "$r5" --runtime nope >/dev/null 2>&1; db_value "SELECT state || '|' || reason FROM routine_runs WHERE id = $r5;")|$(none agent-rt13)"

# A routine run is not continued: --resume-from, a fresh restart, or a tag in its thread that would carry its PR.
printf 'go on\n' > "$tmp/go.md"
MSG="ERROR: a routine run cannot be continued; tag me in a new thread with the PR link or the finding"
check "--resume-from a routine session is refused, with no session" "${MSG}|none" \
  "$(FXA_VM_BACKEND=gce cmd_task --source slack --id agent-rs01 --owner U1 --prompt-file "$tmp/go.md" --resume-from agent-rt12 2>&1)|$(none agent-rs01)"
check "a fresh restart of a routine session is refused, with no session" "${MSG}|none" \
  "$(gh() { echo OPEN; }; jq '.pr_url = "https://github.com/mozilla/PyFxA/pull/3"' "$tmp/agent-rt10.json" > "$tmp/x" && mv "$tmp/x" "$tmp/agent-rt10.json"
     FXA_VM_BACKEND=gce cmd_task --source slack --id agent-rs02 --owner U1 --prompt-file "$tmp/go.md" --resume-from agent-rt10 --fresh 2>&1)|$(none agent-rs02)"
thread_set C0OWN00:1790000000.000100 pr_url https://github.com/mozilla/PyFxA/pull/3 pr_session agent-rt10
check "a tag in a routine's thread that would carry its PR is refused, with no session" "${MSG}|none" \
  "$(FXA_VM_BACKEND=gce cmd_task --source slack --id agent-rs03 --owner U1 --prompt-file "$tmp/go.md" --thread C0OWN00:1790000000.000100 2>&1)|$(none agent-rs03)"
echo '{"key":"agent-sl01","state":"stopped","source":"slack"}' > "$tmp/agent-sl01.json"
check "a Slack session still resumes" "agent-rs04 starting" \
  "$(FXA_VM_BACKEND=gce cmd_task --source slack --id agent-rs04 --owner U1 --prompt-file "$tmp/go.md" --resume-from agent-sl01 2>/dev/null)"

# A routine run never takes the thread's PR: no resume_from, no fresh round, and not the Slack session's connectors (D7).
echo '{"key":"agent-slk9","state":"stopped","source":"slack","mcp":"slackonly","pr_url":"https://github.com/mozilla/PyFxA/pull/4"}' > "$tmp/agent-slk9.json"
thread_set C0OWN00:1790000000.000200 pr_url https://github.com/mozilla/PyFxA/pull/4 pr_session agent-slk9
r7="$(run pyfxa claimed)"
gh() { echo OPEN; }   # the thread's PR is open, so a carry would hold
task pyfxa agent-rt20 --routine-run "$r7" --thread C0OWN00:1790000000.000200 >/dev/null 2>&1
unset -f gh
check "a routine run in a thread with an open PR takes nothing from that thread's session" "agent-rt20|||" \
  "$(jq -r '"\(.key)|\(.resume_from // "")|\(.fresh // "")|\(.mcp // "")"' "$tmp/agent-rt20.json")"
# Its repos come only from its row: the team's default stack does not apply.
r8="$(run pyfxa claimed)"; : > "$tmp/trees-init"
trees_init() { echo "$2" >> "$tmp/trees-init"; }
PIPE_STACK_DEFAULT="mozilla/PyFxA mozilla/fxa" task pyfxa agent-rt21 --routine-run "$r8" >/dev/null 2>&1
check "a one-repo routine on the team repo is no stack, even with PIPE_STACK_DEFAULT" "agent-rt21|" "$(jq -r .key "$tmp/agent-rt21.json")|$(cat "$tmp/trees-init")"
unset -f trees_init
# A multi-repo routine has no branch: each repo is named at its default branch; a row with both is refused.
jq -cn '{name: "Code review", template: "code-review", prompt: "x", mode: "report", repos: ["mozilla/PyFxA", "mozilla/fxa"]}' > "$tmp/multi.json"
jq -cn --arg a "$A" --arg b "$B" '{"mozilla/PyFxA": {start: $a, head: $b}, "mozilla/fxa": {start: null, head: $b}}' > "$tmp/multi-heads.json"
check "a multi-repo routine names each repo at its default branch" "2|0" \
  "$(python3 -I "$SANDBOX_ROOT/lib/routine.py" prompt "$tmp/multi.json" "$tmp/multi-heads.json" pyfxa 0123456789ab | grep -c ', its default branch: ')|$(python3 -I "$SANDBOX_ROOT/lib/routine.py" prompt "$tmp/multi.json" "$tmp/multi-heads.json" pyfxa 0123456789ab | grep -c ', branch ')"
jq '.branch = "release-1"' "$tmp/multi.json" > "$tmp/multi-br.json"
check "a row with a branch and two repos is refused" "ERROR: the run's branch is not valid (a branch goes with exactly one repo)" \
  "$(python3 -I "$SANDBOX_ROOT/lib/routine.py" prompt "$tmp/multi-br.json" "$tmp/multi-heads.json" pyfxa 0123456789ab 2>&1 >/dev/null)"
# --resume-from a session that does not exist: the resume path's own error, not the routine one.
got="$(FXA_VM_BACKEND=gce cmd_task --source slack --id agent-rs09 --owner U1 --prompt-file "$tmp/go.md" --resume-from agent-nope99 2>&1)"
check "--resume-from a missing session is not reported as a routine run" "no|none" "$(grep -c 'routine run cannot be continued' <<< "$got" | sed 's/^0$/no/')|$(none agent-rs09)"
# No return path leaves a prompt temp file: a bad row, and a full session cap.
mkdir -p "$tmp/t"; r9="$(run pyfxa claimed code-review '{"mozilla/PyFxA": {"start": null, "head": "zz"}}')"; r10="$(run pyfxa claimed)"
TMPDIR="$tmp/t" task pyfxa agent-rt22 --routine-run "$r9" >/dev/null 2>&1
TMPDIR="$tmp/t" FXA_SESSION_MAX=0 task pyfxa agent-rt23 --routine-run "$r10" >/dev/null 2>&1
TMPDIR="$tmp/t" task pyfxa agent-rt10 --routine-run "$r10" >/dev/null 2>&1   # a key that exists: an early return
check "a refused routine run leaves no temp file, and the capped one stays claimed" "0|claimed" "$(ls -A "$tmp/t" | wc -l | tr -d ' ')|$(db_value "SELECT state FROM routine_runs WHERE id = $r10;")"

# A dependency fix run (heads.fix of a pr-label routine): the PR from the row, Claude, no connectors, narrowed, and the
# host frame alone in prompt.md. gh is the shared fake of lib/testdata/prfix.
PA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" PU=https://github.com/mozilla/fxa/pull/90001
cp -R "$SANDBOX_ROOT/lib/testdata/prfix" "$tmp/fx"; export PRFIX_DIR="$tmp/fx" PATH="$SANDBOX_ROOT/lib/testdata/prfix/bin:$PATH"
frid="$(db_value "INSERT INTO routines (team, data) VALUES ('fxa', '{}'); SELECT last_insert_rowid();")"
fixrun() { db_value "INSERT INTO routine_runs (routine_id, period, trigger, actor, state, config, heads) VALUES ($frid, 'pr-90001-$PA-$RANDOM', 'label', 'example-writer', 'claimed',
  $(db_q "$(jq -cn '{name: "Dep fix", template: "blank", on: "pr-label", mode: "pr", repos: ["mozilla/fxa"], channel: "C0OWN00", max_usd: 5,
    pr: {repo: "mozilla/fxa", authors: ["dependabot[bot]"], label: "agent-help"}}')"),
  $(db_q "$FH")); SELECT last_insert_rowid();"; }
FH="$(jq -cn --arg u "$PU" --arg h "$PA" '{fix: {pr: 90001, url: $u, head_sha: $h, packages: ["example-pkg", "bad name"]}}')"
ftask() { PIPE_PROFILE=fxa PIPE_REPO_SLUG=mozilla/fxa cmd_task --source routine --id "$1" --routine-run "$2"; }
f1="$(fixrun)"
check "A9: a fix run with no LLM proxy does not start: the run fails with why boot, and no session" \
  "ERROR: routine run ${f1} cannot start: a fix run needs the LLM proxy (FXA_LLM_PROXY_URL)|none|failed|a fix run needs the LLM proxy|boot" \
  "$(FXA_LLM_PROXY_URL="" ftask agent-fx01 "$f1" 2>&1)|$(none agent-fx01)|$(db_value "SELECT state || '|' || reason || '|' || json_extract(heads, '$.fix.why') FROM routine_runs WHERE id = $f1;")"
f2="$(fixrun)"
FXA_LLM_PROXY_URL=http://10.0.0.2:8080 FXA_SESSION_RUNTIME=codex PIPE_MCP=jira ftask agent-fx02 "$f2" >/dev/null 2>&1
check "A9: with FXA_SESSION_RUNTIME=codex the fix run is on claude, with no connectors, narrowed, and its fix fields" \
  "claude||1|off|90001|label|example-writer|$PA|$PU|$PU|0" \
  "$(jq -r '[.runtime, (.mcp // ""), .watch_narrow, .memory, .fix_pr, .fix_trigger, .fix_actor, .fix_head_sha, .review_pr, .checkout, .checkout_person] | map(tostring) | join("|")' "$tmp/agent-fx02.json" 2>&1)"
p="$tmp/agent-fx02.prompt.md"
check "prompt.md is the host frame: the PR, the head SHA and the checked package names only, not a schedule" \
  "1|1|0|0|0" \
  "$(grep -c "^- PR #90001 of mozilla/fxa, at its head commit ${PA}\$" "$p")|$(grep -c '^- the packages it updates: example-pkg$' "$p")|$(grep -c 'bad name' "$p")|$(grep -c 'on a schedule' "$p")|$(grep -oE '[0-9a-f]{40}' "$p" | grep -cv "^${PA}\$")"

# The boot of a fix run, with the runner and the host's clone stubbed: it boots at the claimed head, or not at all.
eval "$(sed -n '/^_cmd_session_boot() {/,/^}/p' "$SANDBOX_ROOT/fxa-sandbox-ctl")"
g init -q --bare "$tmp/origin.git"; g clone -q "$tmp/origin.git" "$tmp/root" 2>/dev/null
( cd "$tmp/root" && echo x > x && g add x && g commit -qm m && g push -q origin HEAD:main ) >/dev/null 2>&1
boot() { # boot <key>   _cmd_session_boot with stubs; agent_run records its pins in $tmp/booted
  : > "$tmp/booted"; : > "$tmp/secrets"
  ( session_run_dir() { echo "$tmp/run-$1"; }; runtime_load() { :; }; pipeline_ensure_clone() { :; }; worktree_repo_root() { echo "$tmp/root"; }
    _session_pack_media() { :; }; worktree_copy_secrets() { echo copied > "$tmp/secrets"; }; _session_ticket_context() { echo "TICKET" >> "$tmp/booted"; }
    circleci_digests() { :; }; _session_review() { echo "REVIEW-TEXT"; }; check_prerequisites() { :; }; _session_first_prompt() { echo FIRST; }
    _session_prompt_tail() { :; }; _session_wants_stack() { return 1; }; _session_boot_times() { echo null; }; agent_stop() { :; }
    agent_run() { printf 'pin %s %s\n%s\n' "$FXA_PIN_SHA" "$FXA_PIN_BASE_SHA" "$3" >> "$tmp/booted"; }
    _cmd_session_boot "$1" ) >/dev/null 2>&1
}
FXA_LLM_PROXY_URL=http://10.0.0.2:8080 boot agent-fx02
check "the boot pins the claimed head as sha and base, copies no secret file, and goes active" "pin $PA $PA||active" \
  "$(grep '^pin' "$tmp/booted")|$(cat "$tmp/secrets")|$(session_get agent-fx02 state)"
f3="$(fixrun)"; FXA_LLM_PROXY_URL=http://10.0.0.2:8080 ftask agent-fx03 "$f3" >/dev/null 2>&1
jq '.headRefOid = "3333333333333333333333333333333333333333"' "$tmp/fx/pr/90001.json" > "$tmp/x" && mv "$tmp/x" "$tmp/fx/pr/90001.json"
FXA_LLM_PROXY_URL=http://10.0.0.2:8080 boot agent-fx03
check "A8b: a PR head that moved between the claim and the boot: no runner boots, the run ends skipped with why new-commit, and the head is free" \
  "|stopped|skipped|new-commit|-x$f3" \
  "$(cat "$tmp/booted")|$(session_get agent-fx03 state)|$(db_value "SELECT state || '|' || json_extract(heads, '$.fix.why') FROM routine_runs WHERE id = $f3;")|$(db_value "SELECT substr(period, instr(period, '-x')) FROM routine_runs WHERE id = $f3;")"
FXA_LLM_PROXY_URL="" boot agent-fx02
check "a fix run's boot with no LLM proxy boots nothing" "|failed" "$(cat "$tmp/booted")|$(session_get agent-fx02 state)"

# The cap: the run's own, at most the host's (D21); a bad one fails.
echo '{"cap_usd": 7}' > "$tmp/agent-cap1.json"; echo '{"cap_usd": 70}' > "$tmp/agent-cap2.json"; echo '{}' > "$tmp/agent-cap3.json"; echo '{"cap_usd": "x"}' > "$tmp/agent-cap4.json"
check "the run cap is min(the run's, the host's), the host's when none, and a bad one fails" "7|50|50|1" \
  "$(_session_run_cap agent-cap1)|$(_session_run_cap agent-cap2)|$(_session_run_cap agent-cap3)|$(_session_run_cap agent-cap4 >/dev/null 2>&1; echo $?)"

exit "$fail"
