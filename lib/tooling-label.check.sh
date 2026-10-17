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
unset FXA_ALLOW_TOOLING_SCOPE
mkdir -p "$tmp/state/tooling"; echo 'scripts acct-1' > "$tmp/state/tooling/FXA-7"
stage scripts_edit;                              check "a recovery finish reads the scope the launch recorded" pass "$(guard)"
echo 'scripts acct-1' > "$tmp/state/tooling/FXA-8"; rm "$tmp/state/tooling/FXA-7"
check "another key's record does not count" refused "$(guard)"
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

# ── The launch passes the scope to its child ──
cat > "$tmp/fakectl" <<'EOF'
#!/bin/bash
printf '%s\n' "${FXA_ALLOW_TOOLING_SCOPE:-none}" > "$CHILD_OUT"
EOF
chmod +x "$tmp/fakectl"
sed -n '/^cmd_launch() {/,/^}/p' "$here/../fxa-sandbox-ctl" > "$tmp/cmd_launch.sh"
launch() {
  rm -f "$tmp/child" "$tmp/state/FXA-7.launch.log"
  CHILD_OUT="$tmp/child" bash -c '
    set -euo pipefail
    source "$2/cmd_launch.sh"
    PIPE_STATE_DIR="$2/state" PIPE_NAME=fxa-ai-fixme PIPE_REPO="$2" PIPE_MIN_FREE_GB=1 PIPE_TOOLING_LABEL=ai-fixme-allow-tooling
    _SESSION_STAMP_PL="while (<STDIN>) {}"
    _launch_slot_for() { echo "$2"; }; pipeline_free_gb() { echo 99; }; pipeline_holding_new() { return 1; }
    pipeline_launch_log() { printf "%s/%s.launch.log\n" "$PIPE_STATE_DIR" "$1"; }
    worktree_repo_root() { echo /; }; worktree_key_for() { echo; }; telemetry_record() { :; }; pipeline_skip_clear() { :; }
    jira_tooling_approver() { [ -n "${APPROVED:-}" ] && echo "acct-lead Lead Person"; }
    cmd_launch FXA-7 fxa-1 >/dev/null
  ' "$tmp/fakectl" "$here" "$tmp"
  for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$tmp/child" ] && break; sleep 0.3; done
  printf '%s|%s|%s' "$(cat "$tmp/child" 2>/dev/null)" \
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
    _launch_slot_for() { echo "$2"; }; pipeline_free_gb() { echo 99; }; pipeline_holding_new() { return 1; }
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

exit "$fail"
