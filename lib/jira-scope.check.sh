#!/usr/bin/env bash
# Offline check that every queue and state read is limited to the profile's Jira project
# and to tickets with no security level, and that the reap leaves other projects' runners.
#   bash lib/jira-scope.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
eval "$(sed -n '/^_pipeline_secret_labels() {/,/^}/p;/^pipeline_jira_project() {/,/^}/p;/^pipeline_secret_team() {/,/^}/p;/^pipeline_jira_scope() {/,/^}/p;/^pipeline_queue_jql() {/,/^}/p;/^pipeline_focus_marker() /p;/^pipeline_focus_key() /p;/^pipeline_key_in_scope() {/,/^}/p;/^pipeline_focus() {/,/^}/p' "$here/pipeline.sh")"
eval "$(sed -n '/^jira_keys_in_state() {/,/^}/p;/^jira_items_in_state() {/,/^}/p;/^jira_queue_keys() {/,/^}/p;/^jira_queue_items() /p;/^jira_secured_keys() {/,/^}/p' "$here/jira.sh")"
eval "$(sed -n '/^_slot_in_pool() /p;/^_reap_stray_vms() {/,/^}/p' "$here/../fxa-sandbox-ctl")"
pipeline_require() { :; }; pipeline_label_for() { echo "ai-fixme-$1"; }
_jira_keys_for_jql() { printf '%s\n' "$1"; }; jira_items_json() { printf '%s\n' "$1"; }
PIPE_STATE_DIR="$tmp" PIPE_QUEUE_JQL='labels = "ai-fixme" AND statusCategory != Done ORDER BY created ASC'

PIPE_PROFILE=fxa
check "fxa reads only FXA tickets with no security level and no secret label" 'project = FXA AND level IS EMPTY AND (labels IS EMPTY OR labels NOT IN ("security", "hackerone"))' "$(pipeline_jira_scope)"
check "the scope goes in front, so ORDER BY stays last" \
  'project = FXA AND level IS EMPTY AND (labels IS EMPTY OR labels NOT IN ("security", "hackerone")) AND (labels = "ai-fixme" AND statusCategory != Done) ORDER BY created ASC' "$(pipeline_queue_jql)"
echo FXA-9 > "$tmp/FOCUS"
check "an epic focus keeps the scope" 'parent = FXA-9 AND project = FXA AND level IS EMPTY AND (labels IS EMPTY OR labels NOT IN ("security", "hackerone")) AND (labels = "ai-fixme" AND statusCategory != Done) ORDER BY created ASC' "$(pipeline_queue_jql)"
echo 'FXA-1 OR key = SEC-5 OR key = FXA-0' > "$tmp/FOCUS"
check "a focus marker that is not one key refuses the queue" "1" "$(pipeline_queue_jql >/dev/null 2>&1; echo $?)"
rm "$tmp/FOCUS"
check "focus refuses a JQL tail" "1|no" "$(pipeline_focus 'FXA-1 OR key = SEC-5' >/dev/null 2>&1; echo $?)|$([ -f "$tmp/FOCUS" ] && echo yes || echo no)"
check "focus takes one epic key" "FXA-9" "$(pipeline_focus FXA-9 >/dev/null; cat "$tmp/FOCUS")"; rm -f "$tmp/FOCUS"
_jira_keys_for_jql() { case "$1" in *"key = FXA-7") echo FXA-7 ;; esac; }
check "a key in the scope may launch" "0" "$(pipeline_key_in_scope FXA-7; echo $?)"
check "a key outside the scope (or with a security level) may not" "1" "$(pipeline_key_in_scope SEC-5; echo $?)"
check "a key with a JQL tail may not" "1" "$(pipeline_key_in_scope 'FXA-7 OR key = SEC-5'; echo $?)"
check "jira gates every launch on the scope" "1" "$(grep -c '^  if ! pipeline_key_in_scope "\$key"; then' "$here/../fxa-sandbox-ctl")"
# --private is gone: a secret team runs these tickets. The flag names the command, before any worktree.
eval "$(sed -n '/^_jira_private_gone() {/,/^}/p' "$here/../fxa-sandbox-ctl")"
mkdir -p "$tmp/pt"; echo '{"teams":{"fxa-private":{"status":"active","secret":true,"jira":"FXA"}}}' > "$tmp/pt/index.json"
check "--private names the secret team's command, or says to sync the index" \
  "ERROR: --private is gone. Run: fxa-sandbox-ctl --pipeline fxa-private jira FXA-10|1|1" \
  "$(FXA_TEAMS_DIR="$tmp/pt" _jira_private_gone FXA-10 2>&1)|$(FXA_TEAMS_DIR="$tmp/none" _jira_private_gone FXA-10 2>&1 | grep -c "No team in this host's teams index takes FXA's secret tickets. Run fxa-sandbox-ctl profile sync, then try again. If no team exists, create one (README: Private pipeline teams).")|$(FXA_TEAMS_DIR="$tmp/pt" _jira_private_gone FXA-10 >/dev/null 2>&1; echo $?)"
check "cmd_jira stops on --private before it loads a runtime or clones, and nothing reads FXA_PRIVATE_REPO" "1|0" \
  "$(sed -n '/^cmd_jira() {/,/^}/p' "$here/../fxa-sandbox-ctl" | grep -c '\[ "\$private" = "true" \] && { _jira_private_gone "\$key"; return 1; }')|$(ls "$here"/*.sh | grep -v '\.check\.sh$' | xargs cat "$here/../fxa-sandbox-ctl" "$here/../.env.example" | grep -c 'FXA_PRIVATE_REPO\|fxa-auto-private')"
_jira_keys_for_jql() { printf '%s\n' "$1"; }
check "a top-level OR in the profile's JQL stays inside the scope" 'project = FXA AND level IS EMPTY AND (labels IS EMPTY OR labels NOT IN ("security", "hackerone")) AND (labels = "a" OR labels = "b") ORDER BY created ASC' \
  "$(PIPE_QUEUE_JQL='labels = "a" OR labels = "b" ORDER BY created ASC' pipeline_queue_jql)"
echo FXA-9 > "$tmp/FOCUS"
check "the whole queue ignores the focus" 'project = FXA AND level IS EMPTY AND (labels IS EMPTY OR labels NOT IN ("security", "hackerone")) AND (labels = "ai-fixme" AND statusCategory != Done) ORDER BY created ASC' "$(pipeline_queue_jql all)"
rm "$tmp/FOCUS"
pipeline_states() { printf '%s\n' inflight done; }
check "a pipeline ticket that got a security level or a secret label is found, in the project, with a secret team's labels when no team takes them" 'project = FXA AND (level IS NOT EMPTY OR labels IN ("security", "hackerone")) AND labels in ("ai-fixme-inflight", "ai-fixme-private-inflight", "ai-fixme-done", "ai-fixme-private-done")' "$(FXA_TEAMS_DIR="$tmp/none" jira_secured_keys)"
check "precheck reports it once, and the pass gets an info line (public team, with and without a secret team)" "1|1|2" \
  "$(grep -c 'for sk in $(jira_secured_keys' "$here/../fxa-sandbox-ctl")|$(grep -c 'secured-noted" \] && continue' "$here/../fxa-sandbox-ctl")|$(grep -c '_info "security level or label: ' "$here/../fxa-sandbox-ctl")"
check "a state read is scoped" 'project = FXA AND level IS EMPTY AND (labels IS EMPTY OR labels NOT IN ("security", "hackerone")) AND labels = "ai-fixme-inflight" ORDER BY created ASC' "$(jira_keys_in_state inflight)"
check "a state item read is scoped" 'project = FXA AND level IS EMPTY AND (labels IS EMPTY OR labels NOT IN ("security", "hackerone")) AND labels = "ai-fixme-done" ORDER BY created ASC' "$(jira_items_in_state done)"
check "a profile's own project wins" 'project = MNTOR AND level IS EMPTY AND (labels IS EMPTY OR labels NOT IN ("security", "hackerone"))' "$(PIPE_PROFILE=monitor PIPE_JIRA_PROJECT=MNTOR pipeline_jira_scope)"
check "a profile with no project has no queue" "1|" "$(PIPE_PROFILE=monitor pipeline_jira_scope 2>/dev/null; echo "$?|$(PIPE_PROFILE=monitor pipeline_queue_jql 2>/dev/null)")"
check "a profile with no project reads no queue, and says so with an error" "1|1|" \
  "$(PIPE_PROFILE=monitor jira_queue_keys 2>/dev/null; echo "$?|")$(PIPE_PROFILE=monitor jira_queue_items 2>/dev/null; echo "$?|")"
check "a project value that is not a key is refused" "1" "$(PIPE_JIRA_PROJECT='FXA OR project = X' pipeline_jira_scope >/dev/null 2>&1; echo $?)"

# A secret team takes exactly what the public scope leaves out, while GitHub confirms its repos private.
github_repo_confirmed_private() { [ -z "${GATE_FAIL:-}" ] || { echo "could not confirm that $1 is private (GitHub answered HTTP 503)" >&2; return 1; }; }
sec() { ( PIPE_PROFILE=fxa-private PIPE_JIRA_PROJECT=FXA PIPE_SECRET_TICKETS=1 PIPE_WORK_ROWS=("mozilla/fxa-private /home/agent/fxa"); "$@" ); }
check "the two scopes split the project, with the host's extra secret labels" \
  'project = FXA AND level IS EMPTY AND (labels IS EMPTY OR labels NOT IN ("security", "hackerone", "embargo"))|project = FXA AND (level IS NOT EMPTY OR labels IN ("security", "hackerone", "embargo"))' \
  "$(PIPE_SECRET_LABELS=embargo pipeline_jira_scope)|$(PIPE_SECRET_LABELS=embargo sec pipeline_jira_scope)"
_jira_keys_for_jql() { echo "$1" >> "$tmp/jql"; echo FXA-7; }; : > "$tmp/jql"
check "a repo GitHub does not confirm private stops the secret queue: no JQL, no key in scope" "1|1|1|0|1" \
  "$(GATE_FAIL=1 sec pipeline_jira_scope 2>&1 | grep -c 'mozilla/fxa-private is not confirmed private')|$(GATE_FAIL=1 sec jira_queue_keys >/dev/null 2>&1; echo $?)|$(GATE_FAIL=1 sec pipeline_key_in_scope FXA-7 2>/dev/null; echo $?)|$(grep -c . "$tmp/jql")|$(GATE_FAIL=1 sec jira_secured_keys >/dev/null 2>&1; echo $?)"
_jira_keys_for_jql() { printf '%s\n' "$1"; }
mkdir -p "$tmp/teams"; echo '{"teams":{"fxa-private":{"status":"active","secret":true,"jira":"FXA"},"old":{"status":"disabled","secret":true,"jira":"MNTOR"}}}' > "$tmp/teams/index.json"
pipeline_states() { printf '%s\n' public inflight done; }
lab() { ( eval "$(sed -n '/^pipeline_label_for() {/,/^}/p' "$here/pipeline.sh")"; PIPE_LABEL_PREFIX="${PFX:-ai-fixme}"; PIPE_QUEUE_LABEL=ai-fixme; FXA_TEAMS_DIR="$tmp/teams"; "$@" ); }
check "with an active secret team, the public report leaves out a queued secret ticket and that team's labels" \
  'project = FXA AND (level IS NOT EMPTY OR labels IN ("security", "hackerone")) AND labels in ("ai-fixme-inflight", "ai-fixme-done")' "$(lab jira_secured_keys)"
check "a disabled secret team takes nothing; a bad index counts as none" 'project = MNTOR AND (level IS NOT EMPTY OR labels IN ("security", "hackerone")) AND labels in ("ai-fixme", "ai-fixme-inflight", "ai-fixme-private-inflight", "ai-fixme-done", "ai-fixme-private-done")|fxa-private|' \
  "$(PIPE_JIRA_PROJECT=MNTOR lab jira_secured_keys)|$(FXA_TEAMS_DIR="$tmp/teams" pipeline_secret_team FXA)|$(echo '{bad' > "$tmp/bad.json"; mkdir -p "$tmp/badt"; cp "$tmp/bad.json" "$tmp/badt/index.json"; FXA_TEAMS_DIR="$tmp/badt" pipeline_secret_team FXA)"
check "the secret team reports its own tickets that lost the secret label" \
  'project = FXA AND level IS EMPTY AND (labels IS EMPTY OR labels NOT IN ("security", "hackerone")) AND labels in ("ai-fixme-private-inflight", "ai-fixme-private-done")' "$(PFX=ai-fixme-private lab sec jira_secured_keys)"
unset -f github_repo_confirmed_private

# A secret team's states have their own prefix; the queue label stays ai-fixme for every team.
eval "$(sed -n '/^jira_label_set() {/,/^}/p' "$here/jira.sh")"
acli() { echo "$*" >> "$tmp/acli"; }
lset() { ( eval "$(sed -n '/^pipeline_label_for() {/,/^}/p;/^pipeline_states() /p' "$here/pipeline.sh")"; PIPE_LABEL_PREFIX="$1"; PIPE_QUEUE_LABEL=ai-fixme; : > "$tmp/acli"; jira_label_set FXA-1 "$2" >/dev/null; cat "$tmp/acli" ); }
check "a secret team's inflight drops ai-fixme and every public state" \
  "jira workitem edit -k FXA-1 --remove-labels ai-fixme,ai-fixme-private-done,ai-fixme-private-blocked,ai-fixme-private-merged,ai-fixme-private-rejected,ai-fixme-private-diff -l ai-fixme-private-inflight -y" "$(lset ai-fixme-private inflight)"
check "public (or the full ai-fixme label) puts ai-fixme back and drops the private states" "-l ai-fixme -y|-l ai-fixme -y" \
  "$(lset ai-fixme-private public | grep -o -- '-l ai-fixme -y')|$(lset ai-fixme-private ai-fixme | grep -o -- '-l ai-fixme -y')"
check "the full private label is accepted; the public team's labels do not change" "-l ai-fixme-private-done -y|-l ai-fixme-inflight -y" \
  "$(lset ai-fixme-private ai-fixme-private-done | grep -o -- '-l [a-z-]* -y')|$(lset ai-fixme inflight | grep -o -- '-l [a-z-]* -y')"
unset -f acli

# The reap stops this project's stray runners and sessions' stray runners, never another project's.
jira_owning_keys() { echo FXA-1; }; session_live() { return 1; }; vm_gc() { :; }
worktree_key_for() { printf '%s\n' "$1" | tr '[:lower:]' '[:upper:]'; }
_worktree_each_active_agent() { printf '%s ws\n' fxa-1 fxa-2 mntor-3 agent-ab12; }
agent_stop() { echo "$1" >> "$tmp/stopped"; }
_reap_stray_vms >/dev/null
check "the reap leaves another project's runner" "fxa-2 agent-ab12" "$(paste -sd' ' "$tmp/stopped")"
: > "$tmp/stopped"
check "no project, no reap" "1|" "$(PIPE_PROFILE=monitor _reap_stray_vms >/dev/null 2>&1; echo "$?|$(cat "$tmp/stopped")")"
check "no project: the reap says why under set -e and pipefail" "1|1" \
  "$( (set -eo pipefail; PIPE_PROFILE=monitor _reap_stray_vms) >/dev/null 2>"$tmp/reap.err"; echo "$?|$(grep -c 'refusing to stop any VM' "$tmp/reap.err")")"
# Both teams have FXA keys, so the pool slot says whose runner it is.
_worktree_each_active_agent() { printf '%s\n' "fxa-9 /w/fxa-private-auto-2" "fxa-8 /w/fxa-auto-2" "fxa-6 /w/fxa-6" "fxa-5 /w/fxa-auto"; }
jira_owning_keys() { echo "${OWNED:-}"; }
: > "$tmp/stopped"; PIPE_POOL_NAME=fxa-auto _reap_stray_vms >/dev/null
check "the FxA reap stops its own pool's strays and a hand run, and leaves a private team's slot" "fxa-8 fxa-6 fxa-5" "$(paste -sd' ' "$tmp/stopped")"
: > "$tmp/stopped"; github_repo_confirmed_private() { :; }
sreap() { ( PIPE_PROFILE=fxa-private PIPE_JIRA_PROJECT=FXA PIPE_SECRET_TICKETS=1 PIPE_POOL_NAME=fxa-private-auto
  PIPE_WORK_ROWS=("mozilla/fxa-private /home/agent/fxa"); _reap_stray_vms >/dev/null ); }
OWNED=FXA-9 sreap
check "a secret team reaps only its own pool: its in-flight run stays, FxA's and hand runs are not its own" "" "$(paste -sd' ' "$tmp/stopped")"
: > "$tmp/stopped"
sreap
check "a secret team reaps its own stray" "fxa-9" "$(paste -sd' ' "$tmp/stopped")"
unset -f github_repo_confirmed_private

[ "$fail" = 0 ] && echo "all checks pass"; check "a team adds its own secret labels; security and hackerone always stay" 'project = PAY AND level IS EMPTY AND (labels IS EMPTY OR labels NOT IN ("security", "hackerone", "sec-high"))' \
  "$(PIPE_PROFILE=pay PIPE_JIRA_PROJECT=PAY PIPE_SECRET_LABELS="sec-high security" pipeline_jira_scope)"
check "a secret label that could break the JQL fails the read" "1|" "$(PIPE_SECRET_LABELS='x") OR (1' pipeline_jira_scope 2>/dev/null; echo "$?|")"
exit "$fail"
