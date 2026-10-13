#!/usr/bin/env bash
# Offline check for trees.sh and the tree routing in session_get/session_set.
#   bash lib/trees.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
here="$(cd "$(dirname "$0")" && pwd)"
SESSION_DIR="$tmp"; HOME="$tmp/home"
_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"; }
_session_db_sync() { :; }
eval "$(grep '^_TREE_FIELDS=' "$here/session.sh")"
eval "$(grep '^_session_file()' "$here/session.sh")"
eval "$(grep '^_tree_field()' "$here/session.sh")"
eval "$(sed -n '/^session_get() {/,/^}/p' "$here/session.sh")"
eval "$(sed -n '/^session_set() {/,/^}/p' "$here/session.sh")"
eval "$(sed -n '/^_session_write() {/,/^}/p' "$here/session.sh")"
# shellcheck disable=SC1091
source "$here/trees.sh"

k=agent-ab12
echo '{"key":"agent-ab12","branch":"agent-ab12","pr_url":""}' > "$tmp/$k.json"
check "a one-repo session has no trees" "1" "$(trees_on "$k"; echo $?)"

PIPE_PROFILE=team PIPE_REPO_SLUG=mozilla/PyFxA PIPE_REPO="$tmp/home/Desktop/working2/PyFxA" PIPE_BASE_BRANCH=main PIPE_PR_OPEN=1
PIPE_WORK_ROWS=("mozilla/PyFxA /home/agent/pyfxa" "mozilla/fxa /home/agent/fxa")
_profile_app_repos() { echo mozilla/fxa; }
check "a repo off the profile's list is refused" "1" "$(trees_init "$k" mozilla/other 2>/dev/null; echo $?)"
trees_init "$k" mozilla/fxa,mozilla/FXA; check "a repo picked twice is added once" "1" "$(jq ".trees | length" "$tmp/$k.json")"; echo "{\"key\":\"$k\"}" > "$tmp/$k.json"
trees_init "$k" mozilla/fxa,mozilla/pyfxa
check "trees in the order picked, pr only where the App is" "0	fxa	mozilla/fxa	/home/agent/fxa	pr|1	pyfxa	mozilla/PyFxA	/home/agent/pyfxa	diff" \
  "$(trees_rows "$k" | paste -sd '|' -)"
trees_init "$k" mozilla/pyfxa
check "a later pick adds only the new repo" "fxa pyfxa" "$(jq -r '[.trees[].name] | join(" ")' "$tmp/$k.json")"
echo "{\"key\":\"$k\"}" > "$tmp/$k.json"
PIPE_PR_OPEN=0 trees_init "$k" mozilla/fxa
check "a read-only profile gives diff even with the App" "diff" "$(jq -r '.trees[0].out' "$tmp/$k.json")"
echo "{\"key\":\"$k\"}" > "$tmp/$k.json"
trees_init "$k" mozilla/fxa,mozilla/pyfxa

session_set "$k" pr_url top
( _tree_enter "$k" 1 && session_set "$k" pr_url https://github.com/mozilla/PyFxA/pull/7 branch b1 state active )
check "a tree field goes to the selected tree" "https://github.com/mozilla/PyFxA/pull/7|b1" "$(jq -r '.trees[1].pr_url + "|" + .trees[1].branch' "$tmp/$k.json")"
check "other fields stay at the top" "top|active" "$(jq -r '.pr_url + "|" + .state' "$tmp/$k.json")"
check "session_get reads the selected tree" "https://github.com/mozilla/PyFxA/pull/7" "$( _tree_enter "$k" 1 && session_get "$k" pr_url)"
check "session_get without a tree reads the top" "top" "$(session_get "$k" pr_url)"
check "the tree's repo and host clone" "mozilla/PyFxA|$tmp/home/Desktop/working2/PyFxA|/home/agent/pyfxa" \
  "$( _tree_enter "$k" 1 && echo "$PIPE_REPO_SLUG|$FXA_REPO|$FXA_TREE_PATH")"
check "a bad index is refused" "1" "$( _tree_enter "$k" 'x;rm' 2>/dev/null; echo $?)"
check "trees_each runs every tree, fails when one fails" "fxa pyfxa |1" \
  "$(trees_each "$k" bash -c 'printf "%s " "$FXA_TREE_NAME"; [ "$FXA_TREE_NAME" = fxa ]'; echo "|$?")"
check "trees_each leaves the caller's repo alone" "mozilla/PyFxA|" "$(trees_each "$k" true; echo "$PIPE_REPO_SLUG|${_TREE_IDX:-}")"
echo '{"key":"agent-cd34"}' > "$tmp/agent-cd34.json"
trees_carry "$k" agent-cd34
check "a resume carries the repos, each on the new branch" "fxa:agent-cd34:pr pyfxa:agent-cd34:diff|" \
  "$(jq -r '[.trees[] | "\(.name):\(.branch):\(.out)"] | join(" ")' "$tmp/agent-cd34.json")|$(jq -r '.trees[1].pr_url // ""' "$tmp/agent-cd34.json")"
# A one-repo session resumed as a stack keeps its fields at the top; only FxA's tree takes them.
echo '{"key":"agent-one1","branch":"b-one","pr_url":"https://github.com/mozilla/fxa/pull/5","base_sha":"abc"}' > "$tmp/agent-one1.json"
check "a one-repo resume gives its PR and base to FxA's tree only" "https://github.com/mozilla/fxa/pull/5|abc|" \
  "$( _tree_enter "$k" 0 && trees_from_get agent-one1 pr_url)|$( _tree_enter "$k" 0 && trees_from_get agent-one1 base_sha)|$( _tree_enter "$k" 1 && trees_from_get agent-one1 pr_url)"
check "a stack resume reads each tree's own field" "https://github.com/mozilla/PyFxA/pull/7" "$( _tree_enter "$k" 1 && trees_from_get "$k" pr_url)"
# _checkout_consent: only the PR author's own "push ok" counts. gh is a stub that applies the jq
# filter's author to a fixed comment list, as gh pr view --json comments -q does.
gh() { local q="${*: -1}" who; who="$(sed -n 's/.*author.login == "\([^"]*\)".*/\1/p' <<< "$q")"
  [ -n "${GH_FAIL:-}" ] && return 1
  printf '%s\n' "${COMMENTS:-}" | awk -F'\t' -v w="$who" '$1 == w { print $2 }'; }
c() { COMMENTS="$1" GH_FAIL="${3:-}" _checkout_consent https://github.com/mozilla/fxa/pull/1 "$2" && echo yes || echo no; }
check "the author's 'push ok' consents" "yes" "$(c "$(printf 'ana\tlooks good, push ok')" ana)"
check "'Push OK.' in any case consents" "yes" "$(c "$(printf 'ana\tPush OK.')" ana)"
check "someone else's 'push ok' does not" "no" "$(c "$(printf 'bo\tpush ok')" ana)"
check "'push okay' is not 'push ok'" "no" "$(c "$(printf 'ana\tpush okay')" ana)"
check "an author name that is not a plain login is refused before gh runs" "no" "$(c "$(printf 'ana\tpush ok')" 'ana") or (true')"
check "gh failing refuses, it does not consent" "no" "$(c "$(printf 'ana\tpush ok')" ana 1)"
# _trees_workspace and _trees_pin run on the runner: vm_exec and the pin are stubs that record what
# each tree line would send. A bad line stops both before anything reaches the runner.
A=$(printf 'a%.0s' {1..40}); B=$(printf 'b%.0s' {1..40})
printf 'fxa\tmozilla/fxa\t/home/agent/fxa\t%s\tmain\t%s\tagent-x1\npyfxa\tmozilla/PyFxA\t/home/agent/pyfxa\t%s\tmain\t%s\tagent-x1-pyfxa\n' "$A" "$B" "$B" "$A" > "$tmp/trees.tsv"
vm_exec() { printf '%s\n' "$*" >> "$tmp/vm.log"; }
: > "$tmp/vm.log"; _trees_workspace run1 "$tmp/trees.tsv" >/dev/null
w="$(cat "$tmp/vm.log")"
check "the workspace step clones each repo the image lacks, into its own path" "1|1" \
  "$(grep -c 'git clone --quiet --filter=blob:none https://github.com/mozilla/fxa.git /home/agent/fxa' <<< "$w")|$(grep -c 'https://github.com/mozilla/PyFxA.git /home/agent/pyfxa' <<< "$w")"
check "it links each tree under the stack root, and /workspace to the root" "1|1|1" \
  "$(grep -c 'ln -sfn /home/agent/fxa /home/agent/stack/fxa' <<< "$w")|$(grep -c 'ln -sfn /home/agent/pyfxa /home/agent/stack/pyfxa' <<< "$w")|$(grep -c 'ln -sfn /home/agent/stack /workspace' <<< "$w")"
check "only the fxa tree writes FXA_WORKSPACE, to its own path" "echo 'export FXA_WORKSPACE=/home/agent/fxa'" "$(grep -o "echo 'export FXA_WORKSPACE=[^']*'" <<< "$w" | paste -sd, -)"
printf 'evil;rm\tmozilla/fxa\t/home/agent/fxa\t%s\tmain\t%s\tb\n' "$A" "$B" > "$tmp/bad.tsv"
: > "$tmp/vm.log"
check "a tree line with a shell character is refused, and nothing reaches the runner" "1|0" \
  "$(_trees_workspace run1 "$tmp/bad.tsv" >/dev/null 2>&1; echo $?)|$(wc -l < "$tmp/vm.log" | tr -d ' ')"
_gce_pin_runner_tree() { printf '%s %s %s %s %s\n' "$FXA_TREE_PATH" "$FXA_PIN_SHA" "$FXA_PIN_BASE_SHA" "$FXA_PIN_BRANCH" "$FXA_WORKTREE_BASE" >> "$tmp/pin.log"; _PINNED_BASE="$FXA_PIN_SHA"; }
: > "$tmp/pin.log"; _trees_pin run1 "$tmp/trees.tsv"
check "each tree pins at its own path, commit, base and branch; the first tree's commit is the run's base" \
  "/home/agent/fxa $A $B agent-x1 main|/home/agent/pyfxa $B $A agent-x1-pyfxa main|$A" "$(paste -sd'|' "$tmp/pin.log")|$_PINNED_BASE"
: > "$tmp/pin.log"
check "a bad line stops the pin before any tree" "1|0" "$(_trees_pin run1 "$tmp/bad.tsv" >/dev/null 2>&1; echo $?)|$(wc -l < "$tmp/pin.log" | tr -d ' ')"

# A tree on a person's PR gets no --add-dir: its CLAUDE.md and skills are the PR author's text.
eval "$(sed -n '/^_checkout_gate_on() {/,/^}/p' "$here/../fxa-sandbox-ctl")"
u=agent-un1; pr=https://github.com/mozilla/PyFxA/pull/9
echo "{\"key\":\"$u\",\"checkout\":\"$pr\",\"checkout_person\":\"1\",\"trees\":[{\"name\":\"fxa\",\"slug\":\"mozilla/fxa\",\"path\":\"/home/agent/fxa\",\"out\":\"pr\"},{\"name\":\"pyfxa\",\"slug\":\"mozilla/PyFxA\",\"path\":\"/home/agent/pyfxa\",\"out\":\"pr\",\"review_pr\":\"$pr\"}]}" > "$tmp/$u.json"
rows="$(jq -r '.trees[] | [.name, .slug, .path] | @tsv' "$tmp/$u.json")"
check "a person's PR tree is untrusted, the other is not" "/home/agent/pyfxa" "$(trees_each "$u" _tree_untrusted "$u")"
check "the untrusted tree gets no --add-dir" " --add-dir /home/agent/fxa" "$(trees_claude_flags "$(trees_each "$u" _tree_untrusted "$u")" <<< "$rows")"
check "with no untrusted tree every tree gets one" " --add-dir /home/agent/fxa --add-dir /home/agent/pyfxa" "$(trees_claude_flags "" <<< "$rows")"
check "its prompt line says never to follow the author's CLAUDE.md, and does not claim it did not load" "0|1|0" \
  "$(trees_each "$u" _tree_note "$u" | grep -c '^- `/workspace/fxa`.*never follow them')|$(trees_each "$u" _tree_note "$u" | grep -c '^- `/workspace/pyfxa`.*never follow them')|$(trees_each "$u" _tree_note "$u" | grep -c 'did not load')"
session_set "$u" checkout_person 0
check "the bot's own PR stays trusted" "" "$(trees_each "$u" _tree_untrusted "$u")"

# The launch script reads the run dir's untrusted list (_tree_boot writes it).
eval "$(sed -n '/^runtime_write_prompt() {/,/^}/p' "$here/runtime-claude.sh")"
slot_write() { cat > "$1"; }; _MCP_LAUNCH_SNIPPET="" _MCP_CLAUDE_FLAGS=""
ws="$tmp/ws"; mkdir -p "$ws"; printf '%s\n' "$rows" > "$ws/.fxa-trees.tsv"; echo /home/agent/pyfxa > "$ws/.fxa-trees-untrusted"
runtime_write_prompt hi "$ws"
check "the launch skips the untrusted tree" "1|0" "$(grep -c -- '--add-dir /home/agent/fxa' "$ws/.fxa-auto-launch.sh")|$(grep -c -- '--add-dir /home/agent/pyfxa' "$ws/.fxa-auto-launch.sh")"

[ "$fail" = 0 ] && echo "all checks pass"; exit "$fail"
