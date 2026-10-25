#!/usr/bin/env bash
# Offline check that precheck moves a blocked ticket whose PR a person merged or closed.
#   bash lib/precheck-blocked.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
command -v jq >/dev/null || { echo "skip: needs jq"; exit 0; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
eval "$(sed -n '/^cmd_precheck() {/,/^}/p' "$(dirname "$0")/../fxa-sandbox-ctl")"
PIPE_LOCK_DIR="$tmp/pass.lock" PIPE_STATE_DIR="$tmp"
pipeline_lock() { :; }; pipeline_unlock() { :; }; db_ingest() { :; }
cmd_reconcile() { :; }; cmd_drain() { :; }; cmd_reap() { :; }
jira_done_keys() { :; }; jira_inflight_keys() { :; }; jira_queue_keys() { :; }
pipeline_holding_new() { return 1; }; pipeline_focus_key() { :; }
jira_login_ok() { :; }
jira_keys_in_state() { [ "$1" = blocked ] && printf 'FXA-1\nFXA-2\nFXA-3\n'; }
gh_pr_state() { case "$1" in FXA-1) echo "FXA-1 11 MERGED ok=1";; FXA-2) echo "FXA-2 12 CLOSED ok=1";; *) echo "FXA-3 13 OPEN ok=1";; esac; }
cmd_label() { echo "$1 $2" >> "$tmp/labels"; }
out="$(cmd_precheck 2>&1)"
check "a merged PR moves the ticket to merged, a closed one to rejected, an open one stays" "FXA-1 merged|FXA-2 rejected" "$(paste -sd'|' "$tmp/labels")"
check "the quiet line counts them" "yes" "$(grep -q '1 merged, 1 rejected' <<<"$out" && echo yes)"
# A secret team: its repo gate runs once in the pass's own shell; a repo not confirmed private stops the pass.
: > "$tmp/labels"; errors_record() { echo "$5" >> "$tmp/errors"; }
pipeline_jira_scope() { echo x >> "$tmp/scope"; [ -z "${GATE_FAIL:-}" ] || { echo "ERROR: fxa-private: mozilla/fxa-private is not confirmed private" >&2; return 1; }; G_OK=1; echo scope; }
cmd_reconcile() { echo r >> "$tmp/rec"; }
out="$(PIPE_SECRET_TICKETS=1 PIPE_PROFILE=fxa-private GATE_FAIL=1 cmd_precheck 2>&1)"
check "a secret team whose repo is not confirmed private pauses before any read, with one error row" "paused: team fxa-private's work repo is not confirmed private; see errors (pipeline/private)|0|1|0" \
  "$out|$(cat "$tmp/rec" 2>/dev/null | grep -c .)|$(grep -c 'not confirmed private' "$tmp/errors")|$(grep -c . "$tmp/labels")"
: > "$tmp/scope"
check "with the repo confirmed, the gate ran in the pass's shell (its yes reaches the reads below)" "1" \
  "$( (PIPE_SECRET_TICKETS=1 PIPE_PROFILE=fxa-private cmd_precheck >/dev/null 2>&1; echo "${G_OK:-0}") )"

# ── A blocked refused_ship key with a saved ship: an approver's label requeues it ──
here="$(cd "$(dirname "$0")" && pwd)"
eval "$(sed -n '/^worktree_saved_ship() {/,/^}/p;/^worktree_saved_ship_retire() {/,/^}/p' "$here/worktree.sh")"
eval "$(sed -n '/^jira_tooling_label_adder() {/,/^}/p;/^_jira_tooling_match() {/,/^}/p' "$here/jira.sh")"
_retry() { "$@"; }
PIPE_TOOLING_LABEL=ai-fixme-allow-tooling PIPE_JIRA_BASIC=u:t PIPE_TOOLING_APPROVERS="Boss Person:acct-boss"
unset PIPE_SECRET_TICKETS; pipeline_jira_scope() { :; }; cmd_reconcile() { :; }
# A reap line is work, so the pass prints its info lines too.
cmd_reap() { echo 'stray x'; }
jira_keys_in_state() { [ "$1" = blocked ] && echo FXA-7; }
gh_pr_state() { echo "${PRSTATE:-FXA-7 none - -}"; }
gh_pr_none() { return "${PRNONE:-0}"; }
# Jira: the label, and a changelog where ADDER added it. Each read is counted.
_jira_rest_get() {
  case "$1" in
    *fields=labels) echo l >> "$tmp/reads"; [ -z "${LABEL_FAILS:-}" ] || return 22
      if [ -n "${ADDER:-}" ]; then echo '{"fields":{"labels":["ai-fixme-blocked","ai-fixme-allow-tooling"]}}'; else echo '{"fields":{"labels":["ai-fixme-blocked"]}}'; fi ;;
    *changelog*) echo c >> "$tmp/reads"; [ -z "${LOG_FAILS:-}" ] || return 22
      printf '{"isLast":true,"total":1,"values":[{"author":{"accountId":"%s"},"items":[{"field":"labels","fromString":"ai-fixme-blocked","toString":"ai-fixme-blocked ai-fixme-allow-tooling"}]}]}\n' "$ADDER" ;;
  esac
}
jira_comment() { printf '%s\n' "$2" >> "$tmp/jira"; }
errors_record() { jq -nc --arg k "$2" --arg w "$4" --arg m "$5" '{kind: $k, where: $w, message: $m}' >> "$tmp/errors"; }
# setup   FXA-7 blocked refused_ship with a saved set, and no notes.
setup() { rm -f "$tmp"/FXA-7.* "$tmp"/{labels,jira,errors,reads}; printf '1\trefused_ship\t\n' > "$tmp/FXA-7.blocked-why"
  for f in patch done.json base; do echo x > "$tmp/FXA-7.leftover-100.$f"; done; }
pc() { cmd_precheck 2>&1; }
cnt() { [ -e "$tmp/$1" ] || { echo 0; return 0; }; grep -c -- "${2:-.}" "$tmp/$1" || true; }
setup; out="$(ADDER=acct-boss pc)"
check "an approver's label: label public, the reship line, one label and one changelog read" \
  "FXA-7 public|1|1|1" "$(cat "$tmp/labels")|$(grep -c '^reship: FXA-7 refused_ship, tooling label approved by Boss Person; back in the queue, the saved change ships with no new run$' <<< "$out")|$(cnt reads l)|$(cnt reads c)"
setup; rm "$tmp/FXA-7.leftover-100.base" "$tmp/FXA-7.leftover-100.done.json"
check "an old leftover with no .base or .done.json: no requeue" 0 "$(ADDER=acct-boss pc >/dev/null; cnt labels)"
setup; echo stale > "$tmp/FXA-7.leftover-100.retired"
check "a set with a tombstone: no requeue over three passes (no loop)" 0 "$(for i in 1 2 3; do ADDER=acct-boss pc >/dev/null; done; cnt labels)"
setup
check "an open PR: no requeue, and no Jira read" "0|0" "$(PRSTATE='FXA-7 9 OPEN ok=1' ADDER=acct-boss pc >/dev/null; cnt labels)|$(cnt reads)"
setup
check "PIPE_PR_OPEN=0: no requeue" 0 "$(PIPE_PR_OPEN=0 ADDER=acct-boss pc >/dev/null; cnt labels)"
setup; printf '1\tstalled\t\n' > "$tmp/FXA-7.blocked-why"
check "another blocked kind: no requeue" 0 "$(ADDER=acct-boss pc >/dev/null; cnt labels)"
setup
check "no label: no requeue, nothing posted" "0|0|0" "$(pc >/dev/null; cnt labels)|$(cnt jira)|$(cnt errors)"
setup; pipeline_holding_new() { return 0; }
out="$(ADDER=acct-boss pc; ADDER=acct-boss pc)"
check "newtickets off: no requeue, the info line, and one held comment over two passes" \
  "0|2|1" "$(cnt labels)|$(grep -c '^reship of FXA-7 waits for newtickets on$' <<< "$out")|$(cnt jira '^🤖 Tooling label approved by Boss Person. The saved change ships when the operator turns new tickets back on.$')"
pipeline_holding_new() { return 1; }
exit "$fail"
