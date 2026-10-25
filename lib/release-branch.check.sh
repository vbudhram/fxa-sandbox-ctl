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

exit "$fail"
