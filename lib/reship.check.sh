#!/usr/bin/env bash
# Offline check for the reship of a saved tooling ship (epic i519): the strict PR read, the
# reship on a temporary repo with an origin, and the fallback. No network.
#   bash lib/reship.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
command -v jq >/dev/null || { echo "skip: needs jq"; exit 0; }
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$tmp"' EXIT

# ── gh_pr_none: 0 no PR, 1 a PR, 2 gh failed; gh_pr_state still says none on a failure ──
eval "$(sed -n '/^gh_pr_none() {/,/^}/p;/^gh_pr_state() {/,/^}/p' "$here/github.sh")"
pipeline_require() { :; }; _retry() { "$@"; }; worktree_branch_for() { printf '%s\n' "$1" | tr 'A-Z' 'a-z'; }
PIPE_REPO_SLUG=mozilla/fxa _GH_ROLLUP_JQ='{ok: 0, fail: 0, run: 0}'
gh() { case "${GH:-}" in none) echo '[]' ;; one) echo '[{"number":9,"state":"CLOSED"}]' ;; *) return 1 ;; esac; }
none_rc() { GH="$1" gh_pr_none FXA-7 >/dev/null 2>&1; echo $?; }
check "gh_pr_none: no PR 0, a PR 1, a failed gh 2" "0 1 2" "$(none_rc none) $(none_rc one) $(none_rc fail)"
check "gh_pr_state still prints none when gh fails" "FXA-7 none - -" "$(GH=fail gh_pr_state FXA-7)"

# ── _jira_reship on a repo with an origin ──
g() { git -c user.email=user@example.com -c user.name=t -c init.defaultBranch=main -c protocol.file.allow=always "$@"; }
export LOG_DIR="$tmp/logs" PIPE_STATE_DIR="$tmp/state" FXA_REPO="$tmp/fxa" FXA_WORKTREE_BASE=main
mkdir -p "$LOG_DIR" "$PIPE_STATE_DIR/tooling" "$tmp/outside"
g init -q --bare "$tmp/origin.git"; g init -q "$tmp/seed"
echo '{"name":"p","scripts":{"a":"x"}}' > "$tmp/seed/package.json"; g -C "$tmp/seed" add -A; g -C "$tmp/seed" commit -qm base
g -C "$tmp/seed" push -q "$tmp/origin.git" HEAD:refs/heads/main
g clone -q "$tmp/origin.git" "$FXA_REPO"; W="$tmp/fxa-auto-2"; g -C "$FXA_REPO" worktree add -q --detach "$W" origin/main
B="$(git -C "$W" rev-parse HEAD)"
g -C "$FXA_REPO" checkout -q -b side; echo s > "$FXA_REPO/s.txt"; g -C "$FXA_REPO" add s.txt; g -C "$FXA_REPO" commit -qm side; C="$(git -C "$FXA_REPO" rev-parse HEAD)"
vm_is_running() { return 1; }
source "$here/worktree.sh"
eval "$(sed -n '/^_finish_claim()/p;/^_finish_release()/p' "$here/finish.sh")"
eval "$(sed -n '/^_jira_reship() {/,/^}/p' "$here/../fxa-sandbox-ctl")"
jira_comment() { printf '%s\n' "$2" >> "$tmp/jira"; }
echo 'scripts acct-boss Boss Person' > "$PIPE_STATE_DIR/tooling/FXA-7"
# A saved ship made the way the release makes it: the slot's change as a patch, at B.
g -C "$W" -c core.hooksPath=/dev/null checkout -q -f -B fxa-7 "$B"
echo '{"name":"p","scripts":{"a":"y"}}' > "$W/package.json"; g -C "$W" diff --binary HEAD > "$tmp/good.patch"; g -C "$W" checkout -q -- .
P="$PIPE_STATE_DIR/FXA-7.leftover-100"
# saved <patch file> [sha] [issue] [branch]   Write the set (hash of the patch as is).
saved() { cp "$1" "$P.patch"; printf '{"issue":"%s","branch":"%s","pr_title":"feat(x): y"}\n' "${3:-FXA-7}" "${4:-fxa-7}" > "$P.done.json"
  printf '%s %s\n' "${2:-$B}" "$(git hash-object --no-filters "$P.patch")" > "$P.base"; }
# prep   The slot as cmd_jira leaves it: fxa-7 from origin/main, clean.
prep() { g -C "$W" -c core.hooksPath=/dev/null checkout -q -f -B fxa-7 "$B"; g -C "$W" clean -qfdx; rm -f "$PIPE_STATE_DIR/FXA-7.reship-err" "$PIPE_STATE_DIR/FXA-7.reship-noted" "$tmp/jira" "$LOG_DIR"/*.finishing; }
rs() { local o rc=0; o="$(_jira_reship FXA-7 "$W" "$P.base" 2>/dev/null)" || rc=$?; printf '%s %s' "$rc" "$o"; }
at_prep() { [ "$(git -C "$W" rev-parse HEAD)" = "$B" ] && [ -z "$(git -C "$W" status --porcelain | grep -v '^?? \.fxa-')" ] && echo prep || echo moved; }

prep; saved "$tmp/good.patch"
check "a good set: 0, the change on fxa-7 at the saved sha, the handoff written, the slot claimed" "0 |fxa-7|$B|1|FXA-7|1" \
  "$(rs)|$(git -C "$W" symbolic-ref --short HEAD)|$(git -C "$W" rev-parse HEAD)|$(git -C "$W" diff | grep -c '^+.*"a":"y"')|$(jq -r .issue "$W/.fxa-auto-done.json")|$(ls "$LOG_DIR" | grep -c 'fxa-auto-2.finishing')"
check "one start comment that names the approver, and once per set" "🤖 Shipping the saved change from the refused run. Scripts allowed by Boss Person. No new agent run.|1" \
  "$(head -1 "$tmp/jira")|$(prep; rs >/dev/null; echo "$P.base" > "$PIPE_STATE_DIR/FXA-7.reship-noted"; g -C "$W" checkout -q -- .; rm -f "$tmp/jira"; rs >/dev/null; [ -e "$tmp/jira" ] && echo 2 || echo 1)"
prep; saved "$tmp/good.patch"; echo '{"name":"p","scripts":{"a":"y"}}' > "$W/package.json"
check "a dirty slot at the sha that already holds the change skips the apply (a retry)" "0 |1" "$(rs)|$(git -C "$W" diff | grep -c '^+.*"a":"y"')"
prep; saved "$tmp/good.patch"; echo other > "$W/other.txt"
check "a dirty slot with other changes: dirty, and its tree stays" "1 dirty|other" "$(rs)|$(cat "$W/other.txt")"
prep; saved "$tmp/good.patch"; echo "x" >> "$P.patch"
check "a patch that changed since the save: hash, back at the prepared commit" "1 hash|prep" "$(rs)|$(at_prep)"
prep; saved "$tmp/good.patch" "$C"
check "a sha reachable on another ref but not on origin/main: base" "1 base|prep" "$(rs)|$(at_prep)"
prep; saved "$tmp/good.patch"; g -C "$tmp/seed" push -q "$tmp/origin.git" HEAD:refs/heads/fxa-7
check "origin already has the branch: branch, and its commit stays" "1 branch|prep|$B" "$(rs)|$(at_prep)|$(git -C "$tmp/origin.git" rev-parse fxa-7)"
git -C "$tmp/origin.git" update-ref -d refs/heads/fxa-7
prep; saved "$tmp/good.patch"; git -C "$FXA_REPO" remote set-url origin "$tmp/no-such.git"
check "a failed ls-remote: branch" "1 branch|prep" "$(rs)|$(at_prep)"
git -C "$FXA_REPO" remote set-url origin "$tmp/origin.git"
prep; saved "$tmp/good.patch" "$B" FXA-8
check "a saved handoff for FXA-8: handoff" "1 handoff|prep" "$(rs)|$(at_prep)"
prep; saved "$tmp/good.patch" "$B" FXA-7 other
check "a saved handoff for branch other: handoff, and no checkout of other" "1 handoff|prep|1" "$(rs)|$(at_prep)|$(git -C "$FXA_REPO" show-ref -q refs/heads/other; echo $?)"
# A9: runner-written patches that reach outside the slot or into .git.
printf 'diff --git a/../outside/x b/../outside/x\nnew file mode 100644\n--- /dev/null\n+++ b/../outside/x\n@@ -0,0 +1 @@\n+x\n' > "$tmp/out.patch"
printf 'diff --git a/.git/hooks/pre-commit b/.git/hooks/pre-commit\nnew file mode 100755\n--- /dev/null\n+++ b/.git/hooks/pre-commit\n@@ -0,0 +1 @@\n+x\n' > "$tmp/hook.patch"
printf 'diff --git a/lnk b/lnk\nnew file mode 120000\n--- /dev/null\n+++ b/lnk\n@@ -0,0 +1 @@\n+%s\n\\ No newline at end of file\ndiff --git a/lnk/x b/lnk/x\nnew file mode 100644\n--- /dev/null\n+++ b/lnk/x\n@@ -0,0 +1 @@\n+x\n' "$tmp/outside" > "$tmp/link.patch"
for p in out hook link; do
  prep; saved "$tmp/$p.patch"
  check "the $p patch: apply, nothing outside or in .git, back at the prepared commit" "1 apply|prep|0|0" \
    "$(rs)|$(at_prep)|$(ls "$tmp/outside" | grep -c .)|$(find "$FXA_REPO/.git" -name pre-commit | grep -c .)"
done
check "the patch paths are only in the .reship-err file" "1" "$(grep -c 'lnk' "$PIPE_STATE_DIR/FXA-7.reship-err" | awk '{print ($1 > 0)}')"

# ── cmd_jira --reship, with the steps before the slot stubbed ──
eval "$(sed -n '/^cmd_jira() {/,/^}/p' "$here/../fxa-sandbox-ctl")"
eval "$(sed -n '/^_finish_tooling_guard() {/,/^}/p;/^_finish_tooling_scope_of() {/,/^}/p' "$here/finish.sh")"
DEFAULT_VM_CPU=2 DEFAULT_VM_MEMORY_MB=4096 PIPE_PROFILE=fxa PIPE_NAME=fxa-ai-fixme
jira_normalize_key() { printf '%s\n' "$1" | tr 'a-z' 'A-Z'; }
runtime_load() { :; }; pipeline_ensure_clone() { :; }; pipeline_key_in_scope() { :; }; _jira_private_gone() { :; }
jira_summary_for() { echo "Add a task script"; }; jira_fetch_context() { echo "the ticket"; }
_jira_render_prompt() { echo prompt; }; runtime_prompt_max_chars() { echo 0; }; _run_model() { :; }; _jira_name_clash() { :; }
memory_ticket_md() { :; }; check_prerequisites() { :; }; agent_prewarm_stack() { :; }; finish_attach_and_wait() { return 1; }
memory_collect() { :; }; finish_notify() { :; }; finish_watch_ci() { :; }; _jira_launch_failed() { :; }
telemetry_record() { echo t >> "$tmp/telemetry"; }
agent_run() { echo "scope=${FXA_ALLOW_TOOLING_SCOPE:-}" >> "$tmp/agent"; }
errors_record() { jq -nc --arg k "$2" --arg key "$3" --arg w "$4" --arg m "$5" --arg l "$6" '{kind: $k, key: $key, where: $w, message: $m, log: $l}' >> "$tmp/errors"; }
# The slot as worktree_prepare_for_issue leaves it; KEEP_SLOT=1 keeps the tree of the last run (a retry).
worktree_prepare_for_issue() { [ -n "${KEEP_SLOT:-}" ] || { g -C "$W" -c core.hooksPath=/dev/null checkout -q -f -B fxa-7 "$B"; g -C "$W" clean -qfdx; }; echo "$W"; }
# finish's guard and push, on the real repo: the label counts only while LABEL=on.
jira_tooling_approver() { [ "${LABEL:-on}" = on ] && echo "acct-boss Boss Person"; }
finish_push_and_pr() {
  printf '%s|%s|%s\n' "${FXA_ALLOW_TOOLING_EDITS:-}" "${FXA_ALLOW_TOOLING_SCOPE:-}" "${FXA_SHIP_CHECK:-}" >> "$tmp/finish-env"
  g -C "$1" add -A -- . ':(exclude).fxa-*' && _finish_tooling_guard "$1" || return 1
  g -C "$1" commit -qm "feat(x): y" || return 1
  [ ! -e "$tmp/push-fails" ] || { rm "$tmp/push-fails"; echo "ERROR: the push failed" >&2; return 1; }
  g -C "$1" push -q -f origin HEAD:refs/heads/fxa-7 && echo "PR opened: https://github.com/mozilla/fxa/pull/9" >&2 && echo "https://github.com/mozilla/fxa/pull/9"
}
# run_jira [env...]   One cmd_jira --reship of the live set; its stderr is the launch log.
run_jira() { env "$@" bash -c 'cmd_jira FXA-7 --create-pr --worktree fxa-auto-2 --reship "$1"' _ "${RESHIP:-$(worktree_saved_ship FXA-7)}" \
  > "$tmp/out" 2> "$tmp/launch.log"; echo $?; }
export -f cmd_jira _jira_reship worktree_saved_ship worktree_saved_ship_retire worktree_branch_for worktree_filtered_status \
  worktree_git_ok worktree_repo_root _worktree_pull_if_remote worktree_finishing worktree_shared_path slot_write g _finish_claim _finish_release \
  _finish_tooling_guard _finish_tooling_scope_of worktree_key_for jira_normalize_key runtime_load pipeline_ensure_clone pipeline_key_in_scope \
  _jira_private_gone jira_summary_for jira_fetch_context _jira_render_prompt runtime_prompt_max_chars _run_model _jira_name_clash \
  memory_ticket_md check_prerequisites agent_prewarm_stack finish_attach_and_wait memory_collect finish_notify finish_watch_ci \
  _jira_launch_failed telemetry_record agent_run errors_record worktree_prepare_for_issue jira_tooling_approver finish_push_and_pr jira_comment
export tmp W B DEFAULT_VM_CPU DEFAULT_VM_MEMORY_MB PIPE_PROFILE PIPE_NAME
fresh() { rm -f "$PIPE_STATE_DIR"/FXA-7.leftover-* "$PIPE_STATE_DIR"/FXA-7.reship-* "$tmp"/{agent,errors,jira,telemetry,finish-env,push-fails}
  git -C "$tmp/origin.git" update-ref -d refs/heads/fxa-7 2>/dev/null; prep; saved "$tmp/good.patch"; }
fresh
check "--reship with a file that is not the key's saved ship: an ERROR line, and no agent run" "1|1|0" \
  "$(RESHIP="$tmp/good.patch" run_jira)|$(grep -c '^ERROR: --reship good.patch is not the saved ship of FXA-7' "$tmp/launch.log")|$(grep -c . "$tmp/agent" 2>/dev/null || echo 0)"
eval "$(sed -n '/^_jira_reship_ship() {/,/^}/p' "$here/../fxa-sandbox-ctl")"; export -f _jira_reship_ship
n_of() { [ -e "$tmp/$1" ] || { echo 0; return; }; grep -c "${2:-.}" "$tmp/$1" || true; }
pushed() { git -C "$tmp/origin.git" diff "$B" fxa-7 2>/dev/null | grep '^[+-][^+-]' | tr '\n' ' '; }
want_diff="$(grep '^[+-][^+-]' "$tmp/good.patch" | tr '\n' ' ')"
fresh; echo 'old run' > "$W/.fxa-auto-session.jsonl"
check "a reship: one PR whose diff is the patch, no agent run, finish with both tooling vars empty" "0|$want_diff|0|||FXA-7" \
  "$(run_jira FXA_ALLOW_TOOLING_SCOPE=scripts)|$(pushed)|$(n_of agent)|$(cat "$tmp/finish-env")"
check "the set is retired as shipped, one start comment, no run recorded, and no transcript left for done" "shipped|1|0|0" \
  "$(cat "$P.retired")|$(n_of jira 'Shipping the saved change')|$(n_of telemetry)|$(wc -c < "$W/.fxa-auto-session.jsonl" | tr -d ' ')"
check "the log has no line that starts with 'Shipping '" 0 "$(n_of launch.log '^Shipping ')"
# A10: the label is gone at the finish. The launch env had the scope, or every path allowed.
for e in FXA_ALLOW_TOOLING_SCOPE=scripts FXA_ALLOW_TOOLING_EDITS=1; do
  fresh
  check "the label removed after the launch ($e in the env): the guard refuses, nothing is pushed" "1|1|" \
    "$(run_jira LABEL=off "$e")|$(n_of launch.log '^ERROR: refusing to ship: the change touches CI or host tooling: ')|$(pushed)"
done
# A15: the push fails once, then the same set runs again on the slot it left.
fresh; : > "$tmp/push-fails"
check "a failed push keeps the set" "1|$P.base" "$(run_jira)|$(worktree_saved_ship FXA-7)"
check "the retry ships it once, with one start comment and no agent run" "0|$want_diff|1|0|shipped" \
  "$(run_jira KEEP_SLOT=1)|$(pushed)|$(n_of jira 'Shipping the saved change')|$(n_of agent)|$(cat "$P.retired")"

# A7, A9: a set that cannot ship as saved falls back to one scoped agent run, in fixed words.
# fallback <word> <phrase>   After the case's setup: tombstone|errors row|comment|agent|log lines|slot.
fallback() {
  run_jira FXA_ALLOW_TOOLING_SCOPE=scripts >/dev/null
  printf '%s|%s|%s|%s|%s|%s|%s' "$(cat "$P.retired" 2>/dev/null)" \
    "$(jq -c 'select(.kind == "reship")' "$tmp/errors" 2>/dev/null | jq -r '"\(.key) \(.where) \(.message) \(.log)"' | paste -sd'#' -)" \
    "$(paste -sd'#' "$tmp/jira" 2>/dev/null)" "$(paste -sd'#' "$tmp/agent" 2>/dev/null)" \
    "$(n_of launch.log "^Reship fallback: $1; a new agent run starts.\$")" "$(n_of launch.log '^ERROR\|fatal:\|rejected')" "$(at_prep)"
}
fb_want() { printf 'stale %s|FXA-7 launch FXA-7: saved change not shipped (%s); a new agent run started. %s|🤖 The saved change did not ship: %s. A new agent run started with the approved tooling label.|scope=scripts|1|0|%s' \
  "$1" "$1" "$PIPE_STATE_DIR/FXA-7.reship-err" "$2" "${3:-prep}"; }
fresh; echo x >> "$P.patch"
check "fallback: hash" "$(fb_want hash 'the saved patch file changed')" "$(fallback hash)"
fresh; saved "$tmp/good.patch" "$C"
check "fallback: base" "$(fb_want base 'its base commit is not on main')" "$(fallback base)"
fresh; g -C "$tmp/seed" push -q "$tmp/origin.git" HEAD:refs/heads/fxa-7
check "fallback: branch, and the origin branch's commit stays" "$(fb_want branch 'a branch for this ticket already exists on GitHub')|$B" "$(fallback branch)|$(git -C "$tmp/origin.git" rev-parse fxa-7)"
fresh; git -C "$FXA_REPO" remote set-url origin "$tmp/no-such.git"
check "fallback: a failed ls-remote is branch" "$(fb_want branch 'a branch for this ticket already exists on GitHub')" "$(fallback branch)"
git -C "$FXA_REPO" remote set-url origin "$tmp/origin.git"
fresh; saved "$tmp/good.patch" "$B" FXA-8
check "fallback: a handoff for FXA-8" "$(fb_want handoff 'the saved handoff could not be used')" "$(fallback handoff)"
fresh; saved "$tmp/good.patch" "$B" FXA-7 other
check "fallback: a handoff for branch other" "$(fb_want handoff 'the saved handoff could not be used')" "$(fallback handoff)"
fresh; echo other > "$W/other.txt"
check "fallback: dirty keeps the tree, and the agent resumes it" "$(fb_want dirty 'the slot holds other unsaved changes' moved)|other|1" \
  "$(KEEP_SLOT=1 fallback dirty)|$(cat "$W/other.txt")|$(n_of launch.log 'Slot holds work from an earlier run')"
for p in out hook link; do
  fresh; saved "$tmp/$p.patch"
  check "fallback: the $p patch is apply, and no host text names its paths" "$(fb_want apply 'git could not apply it')|0" \
    "$(fallback apply)|$(cat "$tmp/jira" "$tmp/errors" "$tmp/launch.log" | grep -c 'outside\|hooks/pre-commit\|lnk')"
done

exit "$fail"
