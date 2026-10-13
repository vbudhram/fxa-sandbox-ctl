#!/usr/bin/env bash
# Offline check that every queue and state read is limited to the profile's Jira project
# and to tickets with no security level, and that the reap leaves other projects' runners.
#   bash lib/jira-scope.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
eval "$(sed -n '/^pipeline_jira_scope() {/,/^}/p;/^pipeline_queue_jql() {/,/^}/p;/^pipeline_focus_marker() /p;/^pipeline_focus_key() /p;/^pipeline_key_in_scope() {/,/^}/p;/^pipeline_focus() {/,/^}/p' "$here/pipeline.sh")"
eval "$(sed -n '/^jira_keys_in_state() {/,/^}/p;/^jira_items_in_state() {/,/^}/p;/^jira_queue_keys() {/,/^}/p;/^jira_queue_items() /p' "$here/jira.sh")"
eval "$(sed -n '/^_reap_stray_vms() {/,/^}/p' "$here/../fxa-sandbox-ctl")"
pipeline_require() { :; }; pipeline_label_for() { echo "ai-fixme-$1"; }
_jira_keys_for_jql() { printf '%s\n' "$1"; }; jira_items_json() { printf '%s\n' "$1"; }
PIPE_STATE_DIR="$tmp" PIPE_QUEUE_JQL='labels = "ai-fixme" AND statusCategory != Done ORDER BY created ASC'

PIPE_PROFILE=fxa
check "fxa reads only FXA tickets with no security level" 'project = FXA AND level IS EMPTY' "$(pipeline_jira_scope)"
check "the scope goes in front, so ORDER BY stays last" \
  'project = FXA AND level IS EMPTY AND labels = "ai-fixme" AND statusCategory != Done ORDER BY created ASC' "$(pipeline_queue_jql)"
echo FXA-9 > "$tmp/FOCUS"
check "an epic focus keeps the scope" 'parent = FXA-9 AND project = FXA AND level IS EMPTY AND labels = "ai-fixme" AND statusCategory != Done ORDER BY created ASC' "$(pipeline_queue_jql)"
echo 'FXA-1 OR key = SEC-5 OR key = FXA-0' > "$tmp/FOCUS"
check "a focus marker that is not one key refuses the queue" "1" "$(pipeline_queue_jql >/dev/null 2>&1; echo $?)"
rm "$tmp/FOCUS"
check "focus refuses a JQL tail" "1|no" "$(pipeline_focus 'FXA-1 OR key = SEC-5' >/dev/null 2>&1; echo $?)|$([ -f "$tmp/FOCUS" ] && echo yes || echo no)"
check "focus takes one epic key" "FXA-9" "$(pipeline_focus FXA-9 >/dev/null; cat "$tmp/FOCUS")"; rm -f "$tmp/FOCUS"
_jira_keys_for_jql() { case "$1" in *"key = FXA-7") echo FXA-7 ;; esac; }
check "a key in the scope may launch" "0" "$(pipeline_key_in_scope FXA-7; echo $?)"
check "a key outside the scope (or with a security level) may not" "1" "$(pipeline_key_in_scope SEC-5; echo $?)"
check "a key with a JQL tail may not" "1" "$(pipeline_key_in_scope 'FXA-7 OR key = SEC-5'; echo $?)"
check "jira gates the launch outside --private" "1" "$(grep -c 'if \[ "\$private" != "true" \] && ! pipeline_key_in_scope "\$key"' "$here/../fxa-sandbox-ctl")"
_jira_keys_for_jql() { printf '%s\n' "$1"; }
check "a state read is scoped" 'project = FXA AND level IS EMPTY AND labels = "ai-fixme-inflight" ORDER BY created ASC' "$(jira_keys_in_state inflight)"
check "a state item read is scoped" 'project = FXA AND level IS EMPTY AND labels = "ai-fixme-done" ORDER BY created ASC' "$(jira_items_in_state done)"
check "a profile's own project wins" 'project = MNTOR AND level IS EMPTY' "$(PIPE_PROFILE=monitor PIPE_JIRA_PROJECT=MNTOR pipeline_jira_scope)"
check "a profile with no project has no queue" "1|" "$(PIPE_PROFILE=monitor pipeline_jira_scope 2>/dev/null; echo "$?|$(PIPE_PROFILE=monitor pipeline_queue_jql 2>/dev/null)")"
check "a profile with no project reads no queue, and says so with an error" "1|1|" \
  "$(PIPE_PROFILE=monitor jira_queue_keys 2>/dev/null; echo "$?|")$(PIPE_PROFILE=monitor jira_queue_items 2>/dev/null; echo "$?|")"
check "a project value that is not a key is refused" "1" "$(PIPE_JIRA_PROJECT='FXA OR project = X' pipeline_jira_scope >/dev/null 2>&1; echo $?)"

# The reap stops this project's stray runners and sessions' stray runners, never another project's.
jira_owning_keys() { echo FXA-1; }; session_live() { return 1; }; vm_gc() { :; }
worktree_key_for() { printf '%s\n' "$1" | tr '[:lower:]' '[:upper:]'; }
_worktree_each_active_agent() { printf '%s ws\n' fxa-1 fxa-2 mntor-3 agent-ab12; }
agent_stop() { echo "$1" >> "$tmp/stopped"; }
_reap_stray_vms >/dev/null
check "the reap leaves another project's runner" "fxa-2 agent-ab12" "$(paste -sd' ' "$tmp/stopped")"
: > "$tmp/stopped"
check "no project, no reap" "1|" "$(PIPE_PROFILE=monitor _reap_stray_vms >/dev/null 2>&1; echo "$?|$(cat "$tmp/stopped")")"

[ "$fail" = 0 ] && echo "all checks pass"; exit "$fail"
