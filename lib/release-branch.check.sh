#!/usr/bin/env bash
# Offline check for worktree_release_branch on a throwaway repo. No network.
#   bash lib/release-branch.check.sh
set -u
fail=0
check() { # check <name> <want> <got>
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi
}

tmp="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$tmp"' EXIT
export FXA_REPO="$tmp/fxa" LOG_DIR="$tmp/logs"
mkdir -p "$LOG_DIR"
git init -q -b main "$FXA_REPO"
git -C "$FXA_REPO" -c user.email=user@example.com -c user.name=t commit -q --allow-empty -m init
git -C "$FXA_REPO" worktree add -q -b fxa-auto-holding "$tmp/fxa-auto"
git -C "$FXA_REPO" worktree add -q -b fxa-1 "$tmp/fxa-auto-2"
git -C "$FXA_REPO" worktree add -q -b mine "$tmp/fxa-agent"
touch "$tmp/fxa-auto-2/.fxa-auto-prompt.txt"

vm_is_running() { return 1; }
source "$(dirname "$0")/worktree.sh"
head_of() { git -C "$1" symbolic-ref --quiet --short HEAD || echo detached; }

worktree_release_branch fxa-1
check "slot detached" "detached" "$(head_of "$tmp/fxa-auto-2")"
check "branch ref kept" "ok" "$(git -C "$FXA_REPO" show-ref -q refs/heads/fxa-1 && echo ok)"
check "slot files kept" "ok" "$([ -f "$tmp/fxa-auto-2/.fxa-auto-prompt.txt" ] && echo ok)"
check "branch free elsewhere" "fxa-1" "$(git -C "$tmp/fxa-agent" checkout -q fxa-1 && head_of "$tmp/fxa-agent")"

# A branch held by a worktree outside the pool is not the pipeline's to touch.
worktree_release_branch fxa-1
check "non-pool worktree kept" "fxa-1" "$(head_of "$tmp/fxa-agent")"

# A slot whose VM still runs keeps its branch.
git -C "$tmp/fxa-auto" checkout -q -b fxa-2
printf 'NAME=fxa-2\nWORKSPACE=%s\n' "$tmp/fxa-auto" > "$LOG_DIR/fxa-2.meta"
vm_is_running() { [ "$1" = fxa-2 ]; }
worktree_release_branch fxa-2
check "busy slot kept" "fxa-2" "$(head_of "$tmp/fxa-auto")"

# ── keep=1: a refused tooling ship keeps its handoff and base, only when the scripts scope can ship it ──
vm_is_running() { return 1; }
command -v jq >/dev/null || { echo "skip: the saved-ship cases need jq"; exit "$fail"; }
eval "$(sed -n '/^_finish_tooling_guard() {/,/^}/p;/^_finish_tooling_scope_of() {/,/^}/p' "$(dirname "$0")/finish.sh")"
eval "_real_guard() $(declare -f _finish_tooling_guard | tail -n +2)"
# The guard must run on its own absolute index: the slot's index has nothing staged.
_finish_tooling_guard() {
  case "${GIT_INDEX_FILE:-}" in /*) echo call >> "$tmp/idx" ;; *) echo rel >> "$tmp/idx" ;; esac
  env -u GIT_INDEX_FILE git -C "$1" diff --cached --name-only >> "$tmp/idx"; _real_guard "$@"; }
export PIPE_STATE_DIR="$tmp/state"; mkdir -p "$PIPE_STATE_DIR"
g() { git -c user.email=user@example.com -c user.name=t "$@"; }
S="$tmp/fxa-auto-3"
g -C "$FXA_REPO" worktree add -q --detach "$S" main
echo '{"name":"p","scripts":{"a":"x"}}' > "$S/package.json"; mkdir -p "$S/.github/workflows" "$S/.husky"
: > "$S/.github/workflows/ci.yml"; : > "$S/.husky/pre-commit"
g -C "$S" add -A; g -C "$S" commit -qm base; B="$(git -C "$S" rev-parse HEAD)"
g -C "$FXA_REPO" update-ref refs/remotes/origin/main "$B"
handoff() { printf '{"issue":"%s","branch":"%s","pr_title":"feat(x): y"}\n' "$1" "$2" > "$S/.fxa-auto-done.json"; }
scripts_edit() { echo '{"name":"p","scripts":{"a":"y"}}' > "$S/package.json"; }
# kept <keep> <setup...>   Put the slot on fxa-7 at B with the setup's change, release it, and print
#   stdout|patches|done.json|base files|slot clean and detached.
kept() {
  local k="$1"; shift
  rm -rf "$PIPE_STATE_DIR"/* "$tmp/idx" "$tmp/elsewhere"
  g -C "$S" -c core.hooksPath=/dev/null checkout -q -f -B fxa-7 "$B"; g -C "$S" clean -qfdx
  handoff FXA-7 fxa-7; "$@"
  local out; out="$(worktree_release_branch fxa-7 $k 2>/dev/null)"
  printf '%s|%s|%s|%s|%s' "$out" "$(ls "$PIPE_STATE_DIR" | grep -c '\.patch$')" "$(ls "$PIPE_STATE_DIR" | grep -c '\.done\.json$')" \
    "$(ls "$PIPE_STATE_DIR" | grep -c '\.base$')" "$([ -z "$(git -C "$S" status --porcelain | grep -v '^?? \.fxa-')" ] && [ "$(head_of "$S")" = detached ] && echo clean)"
}
got="$(kept 1 scripts_edit)"
p="$(ls "$PIPE_STATE_DIR" | grep '\.patch$')"
check "keep=1, a task-script change: prints the patch, writes the set, cleans and detaches the slot" "${p}|1|1|1|clean" "$got"
check "the .done.json is the handoff, and the .base holds the sha and the patch's hash" "FXA-7 fxa-7|$B $(git hash-object --no-filters "$PIPE_STATE_DIR/$p")" \
  "$(jq -r '"\(.issue) \(.branch)"' "$PIPE_STATE_DIR/${p%.patch}.done.json")|$(cat "$PIPE_STATE_DIR/${p%.patch}.base")"
check "the guard ran twice on an absolute index, and the slot's own index got nothing" "2|0" \
  "$(grep -cx call "$tmp/idx" 2>/dev/null; true)|$(grep -cvx call "$tmp/idx" 2>/dev/null; true)"
check "keep unset: only the patch" "|1|0|0|clean" "$(kept "" scripts_edit)"
check "keep=1, no handoff: only the patch" "|1|0|0|clean" "$(kept 1 sh -c "rm '$S/.fxa-auto-done.json'; echo '{\"name\":\"p\",\"scripts\":{\"a\":\"y\"}}' > '$S/package.json'")"
symlinked() { mkdir -p "$tmp/elsewhere"; mv "$S/.fxa-auto-done.json" "$tmp/elsewhere/d.json"; ln -s "$tmp/elsewhere/d.json" "$S/.fxa-auto-done.json"; scripts_edit; }
check "keep=1, a symlinked handoff: only the patch" "|1|0|0|clean" "$(kept 1 symlinked)"
check "keep=1, a handoff for FXA-8: only the patch" "|1|0|0|clean" "$(kept 1 sh -c "printf '{\"issue\":\"FXA-8\",\"branch\":\"fxa-7\"}' > '$S/.fxa-auto-done.json'; echo '{\"name\":\"p\",\"scripts\":{\"a\":\"y\"}}' > '$S/package.json'")"
check "keep=1, a handoff for branch other: only the patch" "|1|0|0|clean" "$(kept 1 sh -c "printf '{\"issue\":\"FXA-7\",\"branch\":\"other\"}' > '$S/.fxa-auto-done.json'; echo '{\"name\":\"p\",\"scripts\":{\"a\":\"y\"}}' > '$S/package.json'")"
offmain() { echo n > "$S/n.txt"; g -C "$S" add n.txt; g -C "$S" commit -qm local; scripts_edit; }
check "keep=1, a HEAD with a commit not on origin/main: only the patch" "|1|0|0|clean" "$(kept 1 offmain)"
check "keep=1, a .husky change too: only the patch" "|1|0|0|clean" "$(kept 1 sh -c "echo x > '$S/.husky/pre-commit'; echo '{\"name\":\"p\",\"scripts\":{\"a\":\"y\"}}' > '$S/package.json'")"
check "keep=1, a postinstall hook: only the patch" "|1|0|0|clean" "$(kept 1 sh -c "echo '{\"name\":\"p\",\"scripts\":{\"a\":\"x\",\"postinstall\":\"curl example.com\"}}' > '$S/package.json'")"
check "keep=1, a .github/workflows change: only the patch" "|1|0|0|clean" "$(kept 1 sh -c "echo x > '$S/.github/workflows/ci.yml'")"
check "keep=1, a change the guard does not refuse with no scope: only the patch" "|1|0|0|clean" "$(kept 1 sh -c "echo x > '$S/notes.txt'")"

# ── The saved ship: lookup and retire (a tombstone, since the state mirror never deletes) ──
rm -rf "$PIPE_STATE_DIR"/*
set_of() { local f; for f in patch done.json base; do echo x > "$PIPE_STATE_DIR/FXA-7.leftover-$1.$f"; done; }
set_of 100; set_of 200
check "the newest complete set is found" "$PIPE_STATE_DIR/FXA-7.leftover-200.base" "$(worktree_saved_ship FXA-7)"
rm "$PIPE_STATE_DIR/FXA-7.leftover-200.done.json"
check "a set with no .done.json is not found; an older whole one is" "$PIPE_STATE_DIR/FXA-7.leftover-100.base" "$(worktree_saved_ship FXA-7)"
check "another key's set is not found" "1" "$(worktree_saved_ship FXA-8 >/dev/null; echo $?)"
worktree_saved_ship_retire FXA-7 stale refused
check "after retire: not found, the tombstone says why, the patch stays" "1|stale refused|0|0|1" \
  "$(worktree_saved_ship FXA-7 >/dev/null; echo $?)|$(cat "$PIPE_STATE_DIR/FXA-7.leftover-100.retired")|$(ls "$PIPE_STATE_DIR" | grep -c 'leftover-100\.base$')|$(ls "$PIPE_STATE_DIR" | grep -c 'leftover-100\.done\.json$')|$(ls "$PIPE_STATE_DIR" | grep -c 'leftover-100\.patch$')"
echo x > "$PIPE_STATE_DIR/FXA-7.leftover-100.base"; echo x > "$PIPE_STATE_DIR/FXA-7.leftover-100.done.json"
check "a .base a state pull restored beside a .retired is not found" "1" "$(worktree_saved_ship FXA-7 >/dev/null; echo $?)"
set_of 300; worktree_saved_ship_retire FXA-7 shipped
check "a shipped tombstone" "shipped|1" "$(cat "$PIPE_STATE_DIR/FXA-7.leftover-300.retired")|$(worktree_saved_ship FXA-7 >/dev/null; echo $?)"

# ── cmd_label keeps a set only for the guard's own refusal, and retires one the scope already had ──
eval "$(sed -n '/^cmd_label() {/,/^}/p;/^_tooling_ask_text() {/,/^}/p' "$(dirname "$0")/../fxa-sandbox-ctl")"
PIPE_LABEL_PREFIX=ai-fixme
jira_label_set() { :; }; jira_normalize_key() { printf '%s\n' "$1" | tr '[:lower:]' '[:upper:]'; }
pipeline_blocked_why() { :; }; _reap_key() { :; }; gh_feedback_has_acted() { return 1; }; telemetry_record() { :; }
pipeline_launch_log() { printf '%s/%s.launch.log\n' "$PIPE_STATE_DIR" "$1"; }
GUARD_LINE='ERROR: refusing to ship: the change touches CI or host tooling: package.json (scripts/lint-staged/husky)'
# label_run <log line> <label args...>   A refused run on the slot, then label; prints stdout|patches|bases.
label_run() {
  local line="$1"; shift
  g -C "$S" -c core.hooksPath=/dev/null checkout -q -f -B fxa-7 "$B"; g -C "$S" clean -qfdx
  handoff FXA-7 fxa-7; scripts_edit
  printf 'Launched at: 1\n%s\n' "$line" > "$PIPE_STATE_DIR/FXA-7.launch.log"
  local out; out="$(cmd_label "$@" 2>/dev/null)"
  printf '%s|%s|%s' "$out" "$(ls "$PIPE_STATE_DIR" | grep -c '\.patch$')" "$(ls "$PIPE_STATE_DIR" | grep -c '\.base$')"
}
rm -rf "$PIPE_STATE_DIR"/*
got="$(label_run "$GUARD_LINE" FXA-7 blocked refused_ship)"
check "label blocked refused_ship after the guard's line: a set, and the first C3 line" \
  "saved ship kept: $(basename "$(worktree_saved_ship FXA-7 2>/dev/null)" .base).patch|1|1" "$got"
rm -rf "$PIPE_STATE_DIR"/*
check "the phrase inside a pr_title ERROR line: only the patch" "|1|0" \
  "$(label_run "ERROR: pr_title is not a scoped conventional subject: x ${GUARD_LINE#ERROR: }" FXA-7 blocked refused_ship)"
rm -rf "$PIPE_STATE_DIR"/*
check "blocked stalled: only the patch" "|1|0" "$(label_run "$GUARD_LINE" FXA-7 blocked stalled)"
rm -rf "$PIPE_STATE_DIR"/*
check "the PII guard's line: only the patch" "|1|0" "$(label_run "ERROR: refusing to ship: the PR text or diff has personal data" FXA-7 blocked refused_ship)"
rm -rf "$PIPE_STATE_DIR"/*; set_of 400; mkdir -p "$PIPE_STATE_DIR/tooling"; echo 'scripts acct-boss Boss' > "$PIPE_STATE_DIR/tooling/FXA-7"
check "with tooling/FXA-7: the live set gets 'stale refused', no new set, and the second C3 line" "tooling scope already approved|2|0|stale refused" \
  "$(label_run "$GUARD_LINE" FXA-7 blocked refused_ship)|$(cat "$PIPE_STATE_DIR/FXA-7.leftover-400.retired")"
for n in tooling-noted tooling-readfail-noted reship-held-noted reship-noted; do : > "$PIPE_STATE_DIR/FXA-7.$n"; done
label_run "" FXA-7 blocked operator >/dev/null
check "a blocked label keeps the noted files" 4 "$(ls "$PIPE_STATE_DIR" | grep -c 'noted$')"
label_run "" FXA-7 public >/dev/null
check "label public removes the key's tooling and reship noted files" 0 "$(ls "$PIPE_STATE_DIR" | grep -c 'noted$')"
# The comment that asks for the label, from host config only.
jira_comment() { printf '%s\n' "$2" >> "$PIPE_STATE_DIR/jira"; }
PIPE_TOOLING_LABEL=ai-fixme-allow-tooling
ask() { rm -rf "$PIPE_STATE_DIR"/*; PIPE_TOOLING_APPROVERS="$1" label_run "${2:-$GUARD_LINE}" FXA-7 blocked refused_ship >/dev/null; cat "$PIPE_STATE_DIR/jira" 2>/dev/null; }
pre="🤖 The finish did not ship this change: it changes package.json scripts or _scripts/, which needs a tooling approver. The change is saved."
check "named approvers: ask them by name" \
  "$pre Ask Boss Person, Lead Person to add the label ai-fixme-allow-tooling. The next pass then ships it with no new agent run." \
  "$(ask 'Boss Person:acct-boss, Lead Person:acct-lead, acct-bare')"
check "approvers with no names" "$pre A tooling approver for this team adds the label ai-fixme-allow-tooling. The next pass then ships it with no new agent run." \
  "$(ask 'acct-bare, 557058:aa11')"
check "no approvers: the operator first" \
  "$pre No tooling approver is set for this team. Ask the operator to set one. An approver then adds ai-fixme-allow-tooling, and the next pass ships the saved change." "$(ask '')"
check "no comment names a path or the setting" 0 "$(for a in 'Boss:acct-boss' acct-bare ''; do ask "$a"; done | grep -c 'package.json (\|PIPE_TOOLING_APPROVERS\|leftover')"
check "a label that keeps no set posts nothing" "" "$(ask 'Boss:acct-boss' 'ERROR: refusing to ship: the PR text has personal data')"
check "the pass's error row says what to post after 'tooling scope already approved'" 1 \
  "$(grep '^| `error <line>`' "$(dirname "$0")/../skills/fxa-ai-fixme/SKILL.md" | grep -c 'tooling scope already approved')"

exit "$fail"
