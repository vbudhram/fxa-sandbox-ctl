#!/usr/bin/env bash
# Offline check for vm.sh promote's comparison: the recorded dev tree against origin/main.
#   bash skills/fxa-manager/promote.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
eval "$(sed -n '/^worktree_tree() {/,/^}/p;/^promote_diff() {/,/^}/p;/^promote_tests() {/,/^}/p' "$(dirname "$0")/vm.sh")"
g() { git -C "$tmp/w" -c user.email=user@example.com -c user.name=t "$@"; }
git init -q --bare "$tmp/remote.git"; git init -q -b main "$tmp/w"
echo a > "$tmp/w/a.txt"; echo node_modules > "$tmp/w/.gitignore"; g add -A; g commit -qm one
g remote add origin "$tmp/remote.git"; g push -q origin main; g fetch -q origin
check "a clean tree that is main: promote" "0" "$(promote_diff "$tmp/w" "$(worktree_tree "$tmp/w")" >/dev/null; echo $?)"
echo b > "$tmp/w/b.txt"; mkdir -p "$tmp/w/node_modules"; echo x > "$tmp/w/node_modules/x"
t="$(worktree_tree "$tmp/w")"
check "an untracked file was deployed but is not on main: refuse, and name it" "1|yes" \
  "$(promote_diff "$tmp/w" "$t" >/dev/null; echo $?)|$(promote_diff "$tmp/w" "$t" | grep -q 'b.txt' && echo yes)"
check "ignored files do not count, and the real index is untouched" "no|??" \
  "$(promote_diff "$tmp/w" "$t" | grep -q node_modules && echo yes || echo no)|$(g status --porcelain b.txt | cut -c1-2)"
g add b.txt; g commit -qm two; g push -q origin main; g fetch -q origin
check "after committing and pushing what was tested: promote" "0" "$(promote_diff "$tmp/w" "$t" >/dev/null; echo $?)"
echo c > "$tmp/w/c.txt"; g add c.txt; g commit -qm three; g push -q origin main; g fetch -q origin
check "a commit nobody ran on dev reached main: refuse" "1" "$(promote_diff "$tmp/w" "$t" >/dev/null; echo $?)"

# The test gate: npm is a stub that logs its calls; one tree stands in for both repos.
npm() { echo "npm $* ctl=${FXA_CTL_REPO:-}" >> "$tmp/npm.log"; [ "$1" != "${NPM_FAIL:-}" ] || { echo "boom"; return 1; }; echo "3/3 pass"; }
t="$(worktree_tree "$tmp/w")"
check "the trees dev ran: the tests run and pass" "0|2|3/3 pass" \
  "$(promote_tests "$tmp/w" "$t" "$tmp/w" "$t" > "$tmp/out" 2>&1; echo $?)|$(wc -l < "$tmp/npm.log" | tr -d ' ')|$(grep -o '3/3 pass' "$tmp/out")"
check "the e2e runs the ctl tree that was checked" "2" "$(grep -c "ctl=$tmp/w$" "$tmp/npm.log")"
: > "$tmp/npm.log"; echo edit > "$tmp/w/d.txt"
check "a local edit since the dev deploy: refuse, and run no test" "1|0" \
  "$(promote_tests "$tmp/w" "$t" "$tmp/w" "$t" >/dev/null 2>&1; echo $?)|$(wc -l < "$tmp/npm.log" | tr -d ' ')"
rm "$tmp/w/d.txt"
log="$(NPM_FAIL=run promote_tests "$tmp/w" "$t" "$tmp/w" "$t" 2>&1 | sed -n 's/.*(log: \(.*\)).*/\1/p')"
check "a failed e2e: refuse, with a private log of its own" "yes|no|yes" \
  "$([ -n "$log" ] && echo yes)|$([ "$log" = /tmp/fxa-promote-test.log ] && echo yes || echo no)|$(grep -q boom "$log" && echo yes)"
rm -f "$log"

# Rollback: the live checkouts in a scratch HOME, npm and the controller stubbed.
eval "$(sed -n '/^deploy_heads_script() {/,/^}/p;/^rollback_script() {/,/^}/p' "$(dirname "$0")/vm.sh")"
H="$tmp/home"; mkdir -p "$H/Desktop/working2" "$tmp/bin"; printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/npm"; chmod +x "$tmp/bin/npm"
for r in fxa-sandbox-ctl fxa-agent-bot; do
  d="$H/Desktop/working2/$r"; git init -q -b main "$d"
  printf '#!/bin/sh\nexit 0\n' > "$d/fxa-sandbox-ctl"; chmod +x "$d/fxa-sandbox-ctl"
  git -C "$d" add -A; git -C "$d" -c user.email=user@example.com -c user.name=t commit -qm old
  echo 2 > "$d/v"; git -C "$d" add v; git -C "$d" -c user.email=user@example.com -c user.name=t commit -qm new
done
live() { HOME="$H" PATH="$tmp/bin:$PATH" bash -s; }
heads() { git -C "$H/Desktop/working2/fxa-sandbox-ctl" rev-parse "$1"; git -C "$H/Desktop/working2/fxa-agent-bot" rev-parse "$1"; }
check "no promote recorded: rollback stops" "1" "$(rollback_script | live >/dev/null; echo $?)"
check "deploy_heads_script prints both live heads" "$(heads HEAD | tr '\n' ' ' | sed 's/ $//')" "$(deploy_heads_script | live)"
echo "2026-10-12T00:00:00Z promote $(heads HEAD~1 | tr '\n' ' ')$(heads HEAD | tr '\n' ' ')" > "$H/.fxa-deploys.log"
old="$(heads HEAD~1 | tr '\n' ' ')"
check "rollback moves both checkouts to what the promote replaced, keeps main a branch, and logs it" "0|$old|main|1" \
  "$(rollback_script | live >/dev/null; echo $?)|$(heads HEAD | tr '\n' ' ')|$(git -C "$H/Desktop/working2/fxa-agent-bot" symbolic-ref --short HEAD)|$(grep -c ' rollback ' "$H/.fxa-deploys.log")"
check "a second rollback stops: the checkouts are no longer at that promote" "1|$old|1" \
  "$(rollback_script | live >/dev/null; echo $?)|$(heads HEAD | tr '\n' ' ')|$(grep -c ' rollback ' "$H/.fxa-deploys.log")"
for r in fxa-sandbox-ctl fxa-agent-bot; do git -C "$H/Desktop/working2/$r" reset -q --hard main@{1}; done
echo edit > "$H/Desktop/working2/fxa-agent-bot/v"
check "a local edit on the VM: rollback stops and changes nothing" "1|edit" \
  "$(rollback_script | live >/dev/null; echo $?)|$(cat "$H/Desktop/working2/fxa-agent-bot/v")"

# CI: main's runs of a commit decide whether promote tests again, waits, or refuses.
eval "$(sed -n '/^ci_state() {/,/^}/p;/^promote_new_errors() {/,/^}/p;/^open_sigs() {/,/^}/p' "$(dirname "$0")/vm.sh")"
gh() { echo "$*" >> "$tmp/gh.log"; jq -r "${@: -1}" <<< "$RUNS"; }
git -C "$tmp/w" remote set-url origin git@github.com:example/fxa-thing.git
RUNS='{"workflow_runs":[{"status":"completed","conclusion":"success"},{"status":"completed","conclusion":"skipped"}]}'
check "ci: all passed is green, from the repo's own slug and main's runs only" "green|yes" "$(ci_state "$tmp/w" abc123)|$(grep -q 'repos/example/fxa-thing/actions/runs?head_sha=abc123&branch=main' "$tmp/gh.log" && echo yes)"
RUNS='{"workflow_runs":[{"status":"completed","conclusion":"success"},{"status":"completed","conclusion":"failure"}]}'
check "ci: one failure is red" "red" "$(ci_state "$tmp/w" abc123)"
RUNS='{"workflow_runs":[{"conclusion":null,"status":"in_progress"}]}'
check "ci: one still running is running" "running" "$(ci_state "$tmp/w" abc123)"
RUNS='{"workflow_runs":[]}'
check "ci: no runs is none" "none" "$(ci_state "$tmp/w" abc123)"
gh() { return 1; }
check "ci: gh fails is none (promote then tests as before)" "none" "$(ci_state "$tmp/w" abc123)"
check "errors: only signatures open after the promote and not before" "c3|d4" "$(promote_new_errors "$(printf 'a1\nb2\n')" "$(printf 'a1\nc3\nd4\n')" | tr '\n' '|' | sed 's/|$//')"
check "open_sigs: the open signatures of a list" "0|a1|c3" "$(open_sigs <<< '[{"sig":"a1","status":"open"},{"sig":"b2","status":"resolved"},{"sig":"c3"}]' > "$tmp/s"; echo $?)|$(paste -sd'|' "$tmp/s")"
check "open_sigs: an empty list is a good read" "0|" "$(open_sigs <<< '[]' > "$tmp/s"; echo $?)|$(cat "$tmp/s")"
check "open_sigs: a failed read (empty, or an error object) fails, so promote skips the watch" "fail|fail" "$(open_sigs < /dev/null >/dev/null && echo ok || echo fail)|$(open_sigs <<< '{"error":"502"}' >/dev/null && echo ok || echo fail)"
eval "$(sed -n '/^promote_watch() {/,/^}/p' "$(dirname "$0")/vm.sh")"
errs_api() { echo '[{"sig":"a1","status":"open"},{"sig":"c3","status":"open","source":"bot","kind":"crash","message":"boom"}]'; }
check "watch: a new open error fails, and names it" "1|yes" "$(promote_watch a1 2> "$tmp/watch.out" >/dev/null; echo $?)|$(grep -q 'c3 bot/crash: boom' "$tmp/watch.out" && echo yes)"
check "watch: nothing new passes" "0|  no new errors on live" "$(promote_watch "$(printf 'a1\nc3')" > "$tmp/watch.out" 2>/dev/null; echo $?)|$(cat "$tmp/watch.out")"
errs_api() { return 22; }
check "watch: a failed read after the watch fails, with the rollback hint" "1|yes" "$(promote_watch a1 2> "$tmp/watch.out" >/dev/null; echo $?)|$(grep -q 'failed after the promote.*rollback' "$tmp/watch.out" && echo yes)"
errs_api() { echo '{"error":"502"}'; }
check "watch: an error object after the watch fails too" "1" "$(promote_watch a1 >/dev/null 2>&1; echo $?)"
check "errors: none new is empty" "" "$(promote_new_errors "$(printf 'a1\n')" "$(printf 'a1\n')")"

# The deploy record: a promote that moved nothing writes no line; rollback reads its own output.
eval "$(sed -n '/^deploy_record_script() {/,/^}/p;/^rollback_targets() {/,/^}/p' "$(dirname "$0")/vm.sh")"
check "record: a promote that moved nothing writes no line" "" "$(deploy_record_script 'a b' 'a b')"
mkdir -p "$tmp/rec"; deploy_record_script 'a b' 'c b' | HOME="$tmp/rec" bash; deploy_record_script 'a b' 'c b' | HOME="$tmp/rec" bash
check "record: each promote that moved a commit appends one promote line" "2|promote a b c b" \
  "$(wc -l < "$tmp/rec/.fxa-deploys.log" | tr -d ' ')|$(tail -1 "$tmp/rec/.fxa-deploys.log" | cut -d' ' -f2-)"
check "record: no heads (a failed read) writes no line" "" "$(deploy_record_script '' 'c b')"
check "rollback: the commits it moved to, from its own output" "aaa1111|bbb2222" \
  "$(rollback_targets "$(printf 'fxa-sandbox-ctl: ccc3333 -> aaa1111\nfxa-agent-bot: ddd4444 -> bbb2222\n')" | paste -sd'|' -)"
{ read -r c; read -r b; } <<< "$(rollback_targets "$(printf 'fxa-agent-bot: ddd4444 -> bbb2222\n')")"
check "rollback: only the bot moved, so its sha stays the bot's" "|bbb2222" "$c|$b"
# ci_state reads only main's runs: a flaky red run on the improve branch of the same commit does not count.
eval "$(sed -n '/^ci_state() {/,/^}/p' "$(dirname "$0")/vm.sh")"
git init -q "$tmp/ci" && git -C "$tmp/ci" remote add origin https://github.com/o/r.git
gh() { [ "$1" = api ] || return 1; printf '%s\n' "$2" > "$tmp/gh-url"; jq -r "$4" "$tmp/runs.json"; }
runs() { printf '{"workflow_runs":[%s]}' "$1" > "$tmp/runs.json"; ci_state "$tmp/ci" abc123; }
check "ci_state asks for main's runs of the commit" "green|repos/o/r/actions/runs?head_sha=abc123&branch=main" \
  "$(runs '{"status":"completed","conclusion":"success"}')|$(cat "$tmp/gh-url")"
check "ci_state: running, red, none" "running|red|none" \
  "$(runs '{"status":"in_progress","conclusion":null}')|$(runs '{"status":"completed","conclusion":"failure"}')|$(runs '')"
unset -f gh
eval "$(sed -n '/^promote_ci() {/,/^}/p' "$(dirname "$0")/vm.sh")"
check "promote_ci: red anywhere refuses, before running" "red|red" "$(promote_ci red running)|$(promote_ci green red)"
check "promote_ci: running refuses, green in both skips the tests, no result tests" "running|skip-tests|test|test" \
  "$(promote_ci running green)|$(promote_ci green green)|$(promote_ci green none)|$(promote_ci none none)"
check "rollback: re-links the skills, as sync does" "yes" "$(rollback_script | grep -q 'ln -sfn' && echo yes)"
exit "$fail"
