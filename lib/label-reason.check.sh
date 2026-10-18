#!/usr/bin/env bash
# Offline check of the blocked reason: label KEY blocked [kind] [reason] keeps why the ticket is blocked
# for the Board, any other state clears it, and nothing here can fail the label.
#   bash lib/label-reason.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
here="$(cd "$(dirname "$0")" && pwd)"
eval "$(sed -n '/^_PIPE_BLOCKED_KINDS=/p;/^_pipeline_one_line() {/,/^}/p;/^pipeline_blocked_why() {/,/^}/p' "$here/pipeline.sh")"
eval "$(sed -n '/^cmd_label() {/,/^}/p' "$here/../fxa-sandbox-ctl")"
PIPE_STATE_DIR="$tmp"; PIPE_LABEL_PREFIX=ai-fixme
# cmd_label's other work, stubbed: the Jira write fails when $tmp/jirafail exists.
jira_label_set() { [ ! -e "$tmp/jirafail" ]; }
jira_normalize_key() { printf '%s\n' "$1" | tr '[:lower:]' '[:upper:]'; }
_reap_key() { :; }; pipeline_launch_log() { echo /nonexistent; }; worktree_release_branch() { :; }; worktree_branch_for() { :; }
w() { cat "$tmp/$1.blocked-why" 2>/dev/null | cut -f2-; }

cmd_label FXA-1 blocked stalled 2>/dev/null
check "a blocked label keeps the kind, with an empty reason" "stalled|" "$(w FXA-1 | tr '\t' '|')"
cmd_label fxa-2 blocked operator "$(printf 'wait for the\tSRE\nchange')" 2>/dev/null
check "a lower-case key, the kind and a one-line reason" "operator|wait for the SRE change" "$(w FXA-2 | tr '\t' '|')"
cmd_label FXA-3 blocked "the reporter must answer" 2>/dev/null
check "no kind word: kind other, the whole reason kept" "other|the reporter must answer" "$(w FXA-3 | tr '\t' '|')"
out="$(cmd_label FXA-4 blocked dead_vms twice 2>&1)"
check "a near kind word warns, is other, and stays in the reason" "1|other|dead_vms twice" "$(grep -c 'not a blocked kind' <<< "$out")|$(w FXA-4 | tr '\t' '|')"
echo "1000	stalled	" > "$tmp/FXA-1.blocked-why"; cmd_label FXA-1 blocked stalled 2>/dev/null
check "a repeat with the same kind keeps the first time" "1000" "$(cut -f1 "$tmp/FXA-1.blocked-why")"
cmd_label FXA-1 blocked operator 2>/dev/null
check "a new kind starts a new time" "yes" "$([ "$(cut -f1 "$tmp/FXA-1.blocked-why")" != 1000 ] && echo yes || echo no)"
cmd_label FXA-2 public 2>/dev/null
check "any other state clears the reason" "no" "$([ -e "$tmp/FXA-2.blocked-why" ] && echo yes || echo no)"
touch "$tmp/jirafail"; cmd_label FXA-5 blocked stalled 2>/dev/null
check "a failed Jira write fails the label and keeps no reason" "no" "$([ -e "$tmp/FXA-5.blocked-why" ] && echo yes || echo no)"
rm -f "$tmp/jirafail"
out="$(cmd_label ../x blocked stalled 2>&1; echo "rc=$?")"
check "a key that is not a ticket key keeps no file and does not fail the label" "rc=0|0" "$(tail -1 <<< "$out")|$(ls "$tmp" | grep -c 'x.blocked-why')"
# root writes into a read-only folder, so this case runs only as another user.
if [ "$(id -u)" != 0 ]; then
  chmod 500 "$tmp"; out="$(cmd_label FXA-6 blocked stalled 2>&1; echo "rc=$?")"; chmod 700 "$tmp"
  check "a write that fails is a WARN, and the label still succeeds" "rc=0|1" "$(tail -1 <<< "$out")|$(grep -c 'could not keep' <<< "$out")"
fi
exit "$fail"
