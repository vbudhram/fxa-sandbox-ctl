#!/usr/bin/env bash
# Offline check of the pre-ship scope check (pipeline_ship_ok, lib/pipeline.sh): a ticket that left its
# team's Jira scope during the run, or a scope that cannot be read, never pushes, in cmd_jira and in finish.
#   bash lib/ship-scope.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
command -v jq >/dev/null || { echo "skip: needs jq"; exit 0; }
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
eval "$(sed -n '/^pipeline_ship_ok() {/,/^}/p' "$here/pipeline.sh")"
eval "$(sed -n '/^_finish_push_and_pr() {/,/^}/p' "$here/finish.sh")"
FXA_SHIP_RETRY_S=0 PIPE_PROFILE=fxa FXA_DONE_FILENAME=.fxa-auto-done.json
pipeline_jira_scope() { [ -z "${SCOPE_FAIL:-}" ] || return 1; echo 'project = FXA AND level IS EMPTY'; }
pipeline_jira_project() { echo FXA; }
pipeline_secret_team() { echo "${STEAM:-}"; }
errors_record() { echo "$3 $5" >> "$tmp/errors"; }
_jira_keys_for_jql() { echo x >> "$tmp/reads"; [ -z "${READ_FAIL:-}" ] || return 1; [ -n "${LEFT:-}" ] || echo FXA-3; }
finish_done_file_path() { echo "$1/$FXA_DONE_FILENAME"; }
git() { echo "git $*" >> "$tmp/calls"; }
gh() { echo "gh $*" >> "$tmp/calls"; }
ship() { : > "$tmp/calls"; : > "$tmp/errors"; : > "$tmp/reads"; ( "$@" ) 2>&1; echo "rc=$?"; }
mkdir -p "$tmp/fxa-auto-2"; echo '{"issue":"FXA-3","branch":"fxa-3"}' > "$tmp/fxa-auto-2/.fxa-auto-done.json"

check "a key still in scope may ship" "rc=0" "$(ship pipeline_ship_ok FXA-3 "$tmp/fxa-auto-2")"
o="$(LEFT=1 STEAM=fxa-private ship pipeline_ship_ok FXA-3 "$tmp/fxa-auto-2")"
check "a key that left the scope does not ship, names the secret team, and records an error with the key" \
  "ERROR: FXA-3 left team fxa's Jira scope; no push. Relabel it for team fxa-private.|rc=1|1|1" \
  "$(printf '%s' "$o" | tr '\n' '|')|$(grep -c '^FXA-3 ' "$tmp/errors")|$(grep -c . "$tmp/reads")"
check "with no secret team, the generic next step" "1" "$(LEFT=1 ship pipeline_ship_ok FXA-3 x | grep -c 'Relabel it for the team that takes it.')"
o="$(READ_FAIL=1 ship pipeline_ship_ok FXA-3 "$tmp/fxa-auto-2")"
check "a failed read tries 3 times, then refuses with the recovery command" \
  "ERROR: could not read Jira or GitHub to confirm FXA-3's scope; no push. Retry: fxa-sandbox-ctl --pipeline fxa finish --worktree fxa-auto-2 --create-pr|rc=1|3" \
  "$(printf '%s' "$o" | tr '\n' '|')|$(grep -c . "$tmp/reads")"
check "a scope that fails (a secret team's repo gate) refuses too" "rc=1" "$(SCOPE_FAIL=1 ship pipeline_ship_ok FXA-3 x | tail -1)"
check "no key in the handoff refuses" "rc=1" "$(ship pipeline_ship_ok '' x | tail -1)"
# The finish path: with the ship check on, a ticket out of scope makes no git and no gh call.
o="$(LEFT=1 FXA_SHIP_CHECK=1 ship _finish_push_and_pr "$tmp/fxa-auto-2" true)"
check "finish with the ship check: out of scope, refused before any git or gh call" "1|rc=1|0" \
  "$(grep -c 'left team fxa' <<< "$o")|$(tail -1 <<< "$o")|$(grep -c . "$tmp/calls")"
c="$here/../fxa-sandbox-ctl"
# One VM name for a key, whichever team runs it: a launch refuses while another team's pool runs it.
eval "$(sed -n '/^_slot_in_pool() /p;/^_jira_name_clash() {/,/^}/p' "$c")"
_worktree_each_active_agent() { printf '%s\n' "fxa-3 /w/fxa-auto-2" "fxa-4 /w/fxa-private-auto-1" "fxa-6 /w/fxa-6"; }
clash() { ( PIPE_POOL_NAME="$1"; _jira_name_clash "$2" ) 2>&1; echo "rc=$?"; }
check "a key that runs in another team's pool refuses, with the next step" "ERROR: fxa-3 runs for team fxa; a person stops it first.|rc=1" \
  "$(clash fxa-private-auto fxa-3 | tr '\n' '|' | sed 's/|$//')"
check "its own pool, a hand run and a key that runs nowhere may launch" "rc=0|rc=0|rc=0" \
  "$(clash fxa-auto fxa-3)|$(clash fxa-private-auto fxa-6)|$(clash fxa-auto fxa-9)"
check "cmd_jira runs the clash check before it takes a slot" "1" "$(sed -n '/^cmd_jira() {/,/^}/p' "$c" | grep -c '_jira_name_clash "\$name" || return 1')"
check "cmd_jira and cmd_finish turn the check on; cmd_jira checks before a diff-only finish" "1|1|1" \
  "$(sed -n '/^cmd_jira() {/,/^}/p' "$c" | grep -c 'FXA_SHIP_CHECK=1 finish_push_and_pr')|$(sed -n '/^cmd_finish() {/,/^}/p' "$c" | grep -c 'FXA_SHIP_CHECK=1 finish_push_and_pr')|$(sed -n '/^cmd_jira() {/,/^}/p' "$c" | grep -c 'pipeline_ship_ok "\$key" "\$worktree_path" || return 1')"
[ "$fail" = 0 ] && echo "all checks pass"; exit "$fail"
