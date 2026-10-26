#!/usr/bin/env bash
# Offline check for the per-ticket tooling opt-in: the guard's scripts scope, the approver check
# on the Jira label, the launch that passes the scope on, and `label` keeping the label.
#   bash lib/tooling-label.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$tmp"' EXIT
eval "$(sed -n '/^_finish_tooling_guard() {/,/^}/p;/^_finish_tooling_scope_of() {/,/^}/p' "$here/finish.sh")"
eval "$(sed -n '/^jira_tooling_approver() {/,/^}/p;/^jira_label_set() {/,/^}/p' "$here/jira.sh")"
eval "$(sed -n '/^jira_tooling_label_adder() {/,/^}/p;/^_jira_tooling_match() {/,/^}/p' "$here/jira.sh")"
eval "$(sed -n '/^pipeline_label_for() {/,/^}/p;/^pipeline_states() {/p' "$here/pipeline.sh")"
worktree_key_for() { printf '%s\n' "${1:-}" | tr '[:lower:]' '[:upper:]'; }
_retry() { "$@"; }
g() { git -c init.defaultBranch=main -c user.name=t -c user.email=t@example.com "$@"; }

# ── The guard ──
g init -q "$tmp/wt"; g -C "$tmp/wt" checkout -q -b fxa-7
mkdir -p "$tmp/wt/_scripts" "$tmp/wt/.circleci" "$tmp/wt/.github/workflows" "$tmp/wt/pkg"
echo '{"name":"p","scripts":{"a":"x"},"lint-staged":{"*.js":"eslint"}}' > "$tmp/wt/pkg/package.json"
: > "$tmp/wt/_scripts/x.sh"; : > "$tmp/wt/.circleci/config.yml"; : > "$tmp/wt/.github/workflows/x.yml"
g -C "$tmp/wt" add -A; g -C "$tmp/wt" commit -qm base
stage() { g -C "$tmp/wt" reset -q --hard; "$@"; g -C "$tmp/wt" add -A; }
guard() { _finish_tooling_guard "$tmp/wt" >/dev/null 2>&1 && echo pass || echo refused; }
scripts_edit() { echo '{"name":"p","scripts":{"a":"y"},"lint-staged":{"*.js":"eslint"}}' > "$tmp/wt/pkg/package.json"; }
lint_edit() { echo '{"name":"p","scripts":{"a":"x"},"lint-staged":{"*.js":"rm -rf /"}}' > "$tmp/wt/pkg/package.json"; }
unset FXA_ALLOW_TOOLING_EDITS FXA_ALLOW_TOOLING_SCOPE; PIPE_STATE_DIR="$tmp/state"

stage scripts_edit;                              check "no scope: a package.json scripts change is refused" refused "$(guard)"
stage sh -c "echo y > '$tmp/wt/_scripts/x.sh'";  check "no scope: a _scripts change is refused" refused "$(guard)"
export FXA_ALLOW_TOOLING_SCOPE=scripts
stage scripts_edit;                              check "scripts scope: a package.json scripts change passes" pass "$(guard)"
stage sh -c "echo y > '$tmp/wt/_scripts/x.sh'";  check "scripts scope: a _scripts/x.sh change passes" pass "$(guard)"
stage sh -c "echo y > '$tmp/wt/.circleci/config.yml'"; check "scripts scope: a .circleci change is refused" refused "$(guard)"
stage sh -c "echo y > '$tmp/wt/.github/workflows/x.yml'"; check "scripts scope: a .github workflow change is refused" refused "$(guard)"
stage lint_edit;                                 check "scripts scope: a package.json lint-staged change is refused" refused "$(guard)"
hook() { echo '{"name":"p","scripts":{"a":"x","'"$1"'":"curl example.com"},"lint-staged":{"*.js":"eslint"}}' > "$tmp/wt/pkg/package.json"; }
check "scripts scope: an npm lifecycle hook is refused (CI runs it in the install)" "refused" \
  "$(for h in postinstall preinstall prepare prepack prepublishOnly publish postversion dependencies; do stage hook "$h"; guard; done | sort -u | tr '\n' ' ' | sed 's/ $//')"
stage hook postinstall
check "the refusal names the hook, so the label is not added again for nothing" 1 "$(_finish_tooling_guard "$tmp/wt" 2>&1 | grep -c 'the tooling label does not cover these')"
# A _scripts/ file that a hook at HEAD runs (FxA's preinstall) is install code too.
echo '{"name":"root","scripts":{"preinstall":"_scripts/check-pm.sh"}}' > "$tmp/wt/package.json"; : > "$tmp/wt/_scripts/check-pm.sh"
g -C "$tmp/wt" add -A; g -C "$tmp/wt" commit -qm hook
stage sh -c "echo y > '$tmp/wt/_scripts/check-pm.sh'"; check "scripts scope: a _scripts file a hook runs is refused" refused "$(guard)"
stage sh -c "echo y > '$tmp/wt/_scripts/x.sh'";        check "scripts scope: another _scripts file still passes" pass "$(guard)"
g -C "$tmp/wt" reset -q --hard HEAD~1
stage hook pretest;                              check "scripts scope: a pre hook of a task script passes, like the task" pass "$(guard)"
unset FXA_ALLOW_TOOLING_SCOPE
mkdir -p "$tmp/state/tooling"; echo 'scripts acct-1' > "$tmp/state/tooling/FXA-7"
stage scripts_edit
check "a recovery finish keeps the recorded scope only while the label has an approver" "pass|refused" \
  "$( (jira_tooling_approver() { echo "acct-1 One"; }; guard) )|$( (jira_tooling_approver() { return 1; }; guard) )"
echo 'scripts acct-1' > "$tmp/state/tooling/FXA-8"; rm "$tmp/state/tooling/FXA-7"
check "another key's record does not count" refused "$( (jira_tooling_approver() { echo "acct-1 One"; }; guard) )"
g -C "$tmp/wt" reset -q --hard

# ── The approver check ──
PIPE_TOOLING_LABEL=ai-fixme-allow-tooling PIPE_TOOLING_APPROVERS="Boss Person:acct-boss, Lead Person:acct-lead,acct-bare" PIPE_JIRA_BASIC=u:t PIPE_JIRA_SITE=https://jira.example
add() { printf '{"author":{"accountId":"%s"},"items":[{"field":"labels","fromString":"%s","toString":"%s"}]}' "$1" "$2" "$3"; }
labels='{"fields":{"labels":["ai-fixme","ai-fixme-allow-tooling"]}}'
log_by() { printf '{"isLast":true,"total":2,"values":[%s,%s]}' "$(add acct-x '' ai-fixme)" "$(add "$1" ai-fixme 'ai-fixme ai-fixme-allow-tooling')"; }
_jira_rest_get() {
  case "$1" in
    *fields=labels) [ -n "${READ_FAILS:-}" ] && return 22; printf '%s' "$labels" ;;
    *changelog*) [ -n "${LOG_FAILS:-}" ] && return 22; printf '%s' "$changelog" ;;
  esac
}
approver() { jira_tooling_approver "$1" 2>/dev/null || echo none; }
changelog="$(log_by acct-lead)"; check "the label added by an approver counts, with the name from the list" "acct-lead Lead Person" "$(approver FXA-7)"
changelog="$(log_by acct-bare)"; check "an approver listed by ID alone shows the ID as the name" "acct-bare acct-bare" "$(approver FXA-7)"
changelog="$(log_by "Lead Person")"; check "an author whose ID is a listed name does not count" none "$(approver FXA-7)"
changelog="$(log_by acct-other)"; check "the label added by another account does not count" none "$(approver FXA-7)"
# A long ticket: the first page is not the last, so the reader asks for the last 100 changes (startAt=total-100).
_jira_rest_get() {
  case "$1" in
    *fields=labels) printf '%s' "$labels" ;;
    *startAt=150) printf '{"isLast":true,"total":250,"values":[%s]}' "$(add acct-lead ai-fixme 'ai-fixme ai-fixme-allow-tooling')" ;;
    *changelog*) printf '{"isLast":false,"total":250,"values":[%s]}' "$(add acct-other ai-fixme 'ai-fixme ai-fixme-allow-tooling')" ;;
  esac
}
check "on a long ticket the last page decides who added the label" "acct-lead Lead Person" "$(approver FXA-7)"
_jira_rest_get() {
  case "$1" in
    *fields=labels) [ -n "${READ_FAILS:-}" ] && return 22; printf '%s' "$labels" ;;
    *changelog*) [ -n "${LOG_FAILS:-}" ] && return 22; printf '%s' "$changelog" ;;
  esac
}
changelog="$(log_by 557058:aa11)"; check "a legacy account ID with a colon matches, by name or alone" "557058:aa11 Old Lead|557058:bb22 557058:bb22" \
  "$(PIPE_TOOLING_APPROVERS="Old Lead:557058:aa11" approver FXA-7)|$(changelog="$(log_by 557058:bb22)"; PIPE_TOOLING_APPROVERS="557058:bb22" approver FXA-7)"
changelog="$(log_by aa11)"; check "the tail of a legacy ID alone does not match it" none "$(PIPE_TOOLING_APPROVERS="Old Lead:557058:aa11" approver FXA-7)"
changelog="$(log_by bb22)"; check "nor does it match a legacy ID listed alone" none "$(PIPE_TOOLING_APPROVERS="557058:bb22" approver FXA-7)"
changelog="$(log_by acct-lead)"
check "a failed changelog read does not count" none "$(LOG_FAILS=1 approver FXA-7)"
check "a failed label read does not count" none "$(READ_FAILS=1 approver FXA-7)"
check "no approvers set: nothing counts" none "$(PIPE_TOOLING_APPROVERS= approver FXA-7)"
labels='{"fields":{"labels":["ai-fixme"]}}'
check "no label on the ticket: nothing counts, even with an old approved add" none "$(approver FXA-7)"
labels='{"fields":{"labels":["ai-fixme","ai-fixme-allow-tooling"]}}'
changelog="$(printf '{"isLast":true,"total":3,"values":[%s,%s,%s]}' "$(add acct-lead '' ai-fixme-allow-tooling)" \
  "$(add acct-x ai-fixme-allow-tooling '')" "$(add acct-other '' ai-fixme-allow-tooling)")"
check "removed and added again by another account: the newest add decides" none "$(approver FXA-7)"
changelog="$(printf '{"isLast":true,"total":1,"values":[%s]}' "$(add acct-lead ai-fixme-allow-tooling-x 'ai-fixme-allow-tooling-x')")"
check "a label that only starts with the name does not count" none "$(approver FXA-7)"

# ── The split: who added the label (0, 1 no label, 2 cannot read), and the approver match ──
adder() { local o rc=0; o="$(jira_tooling_label_adder "$1" 2>/dev/null)" || rc=$?; printf '%s %s' "$rc" "$o"; }
changelog="$(log_by acct-other)"
check "adder: a good read prints the newest adder's ID, approver or not" "0 acct-other" "$(adder FXA-7)"
labels='{"fields":{"labels":["ai-fixme"]}}'
check "adder: no label on a good read exits 1" "1 " "$(adder FXA-7)"
labels='{"fields":{"labels":["ai-fixme","ai-fixme-allow-tooling"]}}'
check "adder: a failed changelog read exits 2" "2 " "$(LOG_FAILS=1 adder FXA-7)"
check "adder: a failed label read exits 2" "2 " "$(READ_FAILS=1 adder FXA-7)"
check "adder: no login exits 2" "2 " "$(PIPE_JIRA_BASIC= adder FXA-7)"
check "adder: the approver list does not matter" "0 acct-other" "$(PIPE_TOOLING_APPROVERS= adder FXA-7)"
match() { _jira_tooling_match "$1" 2>/dev/null || echo none; }
check "match: a Name:ID entry" "acct-lead Lead Person" "$(match acct-lead)"
check "match: a bare ID" "acct-bare acct-bare" "$(match acct-bare)"
check "match: a legacy ID by name" "557058:aa11 Old Lead" "$(PIPE_TOOLING_APPROVERS="Old Lead:557058:aa11" match 557058:aa11)"
check "match: not the tail of a legacy ID" none "$(PIPE_TOOLING_APPROVERS="Old Lead:557058:aa11" match aa11)"
check "match: an empty list matches nothing" none "$(PIPE_TOOLING_APPROVERS= match acct-lead)"
check "match: another account" none "$(match acct-other)"

# ── The launch passes the scope to its child ──
cat > "$tmp/fakectl" <<'EOF'
#!/bin/bash
printf '%s\n' "${FXA_ALLOW_TOOLING_SCOPE:-none}" > "$CHILD_OUT"
EOF
chmod +x "$tmp/fakectl"
sed -n '/^cmd_launch() {/,/^}/p' "$here/../fxa-sandbox-ctl" > "$tmp/cmd_launch.sh"
# Each launch has its own child file: the child runs in the background, and a late one from the run before
# could write the shared file after this run cleared it (a pool flake: 'got scripts').
launch() {
  local out="$tmp/child.${APPROVED:-0}"
  rm -f "$out" "$tmp/state/FXA-7.launch.log"
  CHILD_OUT="$out" bash -c '
    set -euo pipefail
    source "$2/cmd_launch.sh"
    PIPE_STATE_DIR="$2/state" PIPE_NAME=fxa-ai-fixme PIPE_REPO="$2" PIPE_MIN_FREE_GB=1 PIPE_TOOLING_LABEL=ai-fixme-allow-tooling
    _SESSION_STAMP_PL="while (<STDIN>) {}"
    _launch_slot_for() { echo "$2"; }; pipeline_free_gb() { echo 99; }; pipeline_launches_24h() { :; }; pipeline_holding_new() { return 1; }
    pipeline_launch_log() { printf "%s/%s.launch.log\n" "$PIPE_STATE_DIR" "$1"; }
    worktree_repo_root() { echo /; }; worktree_key_for() { echo; }; telemetry_record() { :; }; pipeline_skip_clear() { :; }
    jira_tooling_approver() { [ -n "${APPROVED:-}" ] && echo "acct-lead Lead Person"; }; worktree_saved_ship() { return 1; }
    cmd_launch FXA-7 fxa-1 >/dev/null
  ' "$tmp/fakectl" "$here" "$tmp"
  for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$out" ] && break; sleep 0.3; done
  printf '%s|%s|%s' "$(cat "$out" 2>/dev/null)" \
    "$(grep -c '^tooling: scripts allowed by Lead Person \[acct-lead\] (label ai-fixme-allow-tooling)$' "$tmp/state/FXA-7.launch.log")" \
    "$(cat "$tmp/state/tooling/FXA-7" 2>/dev/null || echo -)"
}
check "an approved label: the child gets the scope, the log says who, the key records it" "scripts|1|scripts acct-lead Lead Person" "$(APPROVED=1 launch)"
check "no approved label: no scope, no log line, no record" "none|0|-" "$(launch)"
# The context file asks for the Android runner with one line, as it does for the functional tests.
cat > "$tmp/fakectl" <<'EOF2'
#!/bin/bash
printf '%s\n' "$*" > "$CHILD_OUT"
EOF2
printf 'Ground truth.\nLaunch with --android\n' > "$tmp/ctx.md"
args_of() { rm -f "$tmp/child"; CHILD_OUT="$tmp/child" bash -c '
    set -euo pipefail; source "$2/cmd_launch.sh"
    PIPE_STATE_DIR="$2/state" PIPE_NAME=fxa-ai-fixme PIPE_REPO="$2" PIPE_MIN_FREE_GB=1 _SESSION_STAMP_PL="while (<STDIN>) {}"
    _launch_slot_for() { echo "$2"; }; pipeline_free_gb() { echo 99; }; pipeline_launches_24h() { :; }; pipeline_holding_new() { return 1; }
    pipeline_launch_log() { printf "%s/%s.launch.log\n" "$PIPE_STATE_DIR" "$1"; }
    worktree_repo_root() { echo /; }; worktree_key_for() { echo; }; telemetry_record() { :; }; pipeline_skip_clear() { :; }
    jira_tooling_approver() { return 1; }
    cmd_launch FXA-7 fxa-1 "$3" >/dev/null 2>&1' "$tmp/fakectl" "$here" "$tmp" "$1"
  for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$tmp/child" ] && break; sleep 0.3; done; cat "$tmp/child" 2>/dev/null; }
check "a context line Launch with --android passes --android to the run" 1 "$(args_of "$tmp/ctx.md" | grep -c -- ' --android')"
printf 'Ground truth.\n' > "$tmp/ctx2.md"
check "no line: no --android" 0 "$(args_of "$tmp/ctx2.md" | grep -c -- '--android')"

# ── progress shows the scope ──
eval "$(sed -n '/^pipeline_progress() {/,/^}/p' "$here/pipeline.sh")"
pipeline_require() { :; }; pipeline_launch_log() { printf '%s/%s.launch.log\n' "$tmp/state" "$1"; }
printf 'Launched at: 1\ntooling: scripts allowed by acct-lead (label ai-fixme-allow-tooling)\nPR opened: https://github.com/mozilla/fxa/pull/9\n' > "$tmp/state/FXA-7.launch.log"
check "progress ends with tooling=scripts after an approved launch" "FXA-7 pr https://github.com/mozilla/fxa/pull/9 tooling=scripts" "$(pipeline_progress FXA-7)"
printf 'Launched at: 1\nPR opened: https://github.com/mozilla/fxa/pull/9\n' > "$tmp/state/FXA-7.launch.log"
check "progress has no field after a plain launch" "FXA-7 pr https://github.com/mozilla/fxa/pull/9" "$(pipeline_progress FXA-7)"

# ── label keeps the opt-in label ──
PIPE_LABEL_PREFIX=ai-fixme; pipeline_require() { :; }
acli() { printf '%s\n' "$*" > "$tmp/acli"; }
jira_label_set FXA-7 done >/dev/null
removed="$(grep -o -- '--remove-labels [^ ]*' "$tmp/acli" | cut -d' ' -f2)"
check "label inflight -> done removes ai-fixme-inflight" 1 "$(tr ',' '\n' <<< "$removed" | grep -cx ai-fixme-inflight)"
check "label inflight -> done keeps ai-fixme-allow-tooling" 0 "$(tr ',' '\n' <<< "$removed" | grep -cx ai-fixme-allow-tooling)"

# The 24 h budget refuses a launch, with the ledger read by the real pipeline_launches_24h.
mkdir -p "$tmp/budget"; for n in 1 2 3; do echo "$(date +%s) FXA-$n s" >> "$tmp/budget/launches.log"; done
plh="$(sed -n '/^pipeline_launches_24h() {/,/^}/p' "$here/pipeline.sh")"
out="$(bash -c '
  set -euo pipefail
  source "$2/cmd_launch.sh"; eval "$3"
  PIPE_STATE_DIR="$1/budget" PIPE_NAME=fxa-ai-fixme PIPE_REPO="$1" PIPE_MIN_FREE_GB=1 PIPE_MAX_LAUNCHES_PER_DAY=3
  _launch_slot_for() { echo s; }; pipeline_free_gb() { echo 99; }; pipeline_holding_new() { return 1; }; jira_tooling_approver() { :; }
  pipeline_launch_log() { echo "$PIPE_STATE_DIR/x.log"; }; worktree_repo_root() { echo /; }; worktree_key_for() { echo; }; telemetry_record() { :; }; pipeline_skip_clear() { :; }
  cmd_launch FXA-7 s' _ "$tmp" "$tmp" "$plh" 2>&1; echo "rc=$?")"
check "a full 24 h budget refuses the launch with the budget text" "1|rc=1" "$(grep -c 'refusing to launch FXA-7: 3 launches in 24 h, budget 3' <<< "$out")|$(tail -1 <<< "$out")"

# ── The reship gate in cmd_launch: a saved ship goes out with no agent run only with an approver's label and no PR ──
cat > "$tmp/fakectl" <<'EOF3'
#!/bin/bash
printf '%s|%s\n' "$*" "${FXA_ALLOW_TOOLING_SCOPE:-none}" > "$CHILD_OUT"
EOF3
wsh="$(sed -n '/^worktree_saved_ship() {/,/^}/p;/^worktree_saved_ship_retire() {/,/^}/p' "$here/worktree.sh")"
mkdir -p "$tmp/rs/feedback"; : > "$tmp/rs/ctx.md"; : > "$tmp/rs/feedback/ctx.md"
# gate [VAR=value...]   A launch of FXA-7 with a saved set. APPROVED=1: an approver's label; ADDER=<rc> for
#   the label read when it is not; PRNONE=<rc>; CTX=<file>. Prints rc|echo|child|log Reship lines|tombstone|ledger|tooling|labels.
gate() {
  local S="$tmp/rs/state"; rm -rf "$S" "$tmp/child" "$tmp/rs/labels"; mkdir -p "$S"
  for f in patch done.json base; do echo x > "$S/FXA-7.leftover-100.$f"; done
  local out rc=0
  out="$(env "$@" CHILD_OUT="$tmp/child" bash -c '
    set -euo pipefail; source "$1/cmd_launch.sh"; eval "$3"
    PIPE_STATE_DIR="$2/state" PIPE_NAME=fxa-ai-fixme PIPE_REPO="$2" PIPE_MIN_FREE_GB=1 PIPE_TOOLING_LABEL=ai-fixme-allow-tooling _SESSION_STAMP_PL="while (<STDIN>) {}"
    _launch_slot_for() { echo fxa-1; }; pipeline_free_gb() { echo 99; }; pipeline_launches_24h() { :; }; pipeline_holding_new() { return 1; }
    pipeline_launch_log() { printf "%s/%s.launch.log\n" "$PIPE_STATE_DIR" "$1"; }
    worktree_repo_root() { echo /; }; worktree_key_for() { echo; }; telemetry_record() { :; }; pipeline_skip_clear() { :; }
    jira_tooling_approver() { [ -n "${APPROVED:-}" ] && echo "acct-boss Boss Person"; }
    jira_tooling_label_adder() { [ "${ADDER:-1}" = 0 ] && echo acct-other; return "${ADDER:-1}"; }
    gh_pr_none() { return "${PRNONE:-0}"; }
    LBL="$2/labels"; cmd_label() { echo "$*" >> "$LBL"; }
    cmd_launch FXA-7 fxa-1 ${CTX:-}' "$tmp/fakectl" "$tmp" "$tmp/rs" "$wsh" 2>&1)" || rc=$?
  printf '%s\n' "$out" > "$tmp/rs/out"
  [ "$rc" = 0 ] && for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$tmp/child" ] && break; sleep 0.3; done
  cnt() { [ -e "$2" ] || { echo "${3:-0}"; return 0; }; grep -c -- "$1" "$2" || true; }
  printf '%s|%s|%s|%s|%s|%s|%s|%s' "$rc" "$(grep -c 'reship=FXA-7.leftover-100.patch' <<< "$out" || true)" \
    "$(cnt "--reship $S/FXA-7.leftover-100.base" "$tmp/child" none)" \
    "$(cnt '^Reship: shipping the saved change of the refused run (FXA-7.leftover-100.patch); no agent run.$' "$S/FXA-7.launch.log")" \
    "$(cat "$S/FXA-7.leftover-100.retired" 2>/dev/null || echo -)" "$(cnt . "$S/launches.log")" \
    "$([ -e "$S/tooling/FXA-7" ] && echo tooling || echo -)" "$(cat "$tmp/rs/labels" 2>/dev/null || echo -)"
}
check "an approver's label and no PR: the launch reships, with the scope, and says so" "0|1|1|1|-|1|tooling|-" "$(gate APPROVED=1)"
check "and the child keeps the scope for a fallback run" "scripts" "$(cut -d'|' -f2 "$tmp/child")"
check "no label on a good read: the set is retired stale, and a normal run starts" "0|0|0|0|stale|1|-|-" "$(gate ADDER=1)"
check "a label from someone who is not an approver: the set stays, and a normal run starts" "0|0|0|0|-|1|-|-" "$(gate ADDER=0)"
check "a feedback context: retired stale, a normal run" "0|0|0|0|stale|1|tooling|-" "$(gate APPROVED=1 CTX="$tmp/rs/feedback/ctx.md")"
check "a PR (open, or from a manual finish): retired stale, a normal run" "0|0|0|0|stale|1|tooling|-" "$(gate APPROVED=1 PRNONE=1)"
check "FXA_ALLOW_TOOLING_EDITS=1: retired stale, a full run" "0|0|0|0|stale|1|tooling|-" "$(gate APPROVED=1 FXA_ALLOW_TOOLING_EDITS=1)"
fr="1|0|none|0|-|0|-|FXA-7 blocked refused_ship"
check "a failed label read: the ERROR line, no ledger line, no tooling record, blocked again, the set kept" "$fr|1" \
  "$(gate ADDER=2)|$(grep -c '^ERROR: cannot read the tooling label or PR of FXA-7; the saved change waits for the next pass$' "$tmp/rs/out")"
check "a failed gh read: the same" "$fr|1" "$(gate APPROVED=1 PRNONE=2)|$(grep -c '^ERROR: cannot read the tooling label or PR of FXA-7' "$tmp/rs/out")"

exit "$fail"
