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

# CI: the check runs of a main commit decide whether promote tests again, waits, or refuses.
eval "$(sed -n '/^ci_state() {/,/^}/p;/^promote_new_errors() {/,/^}/p' "$(dirname "$0")/vm.sh")"
gh() { echo "$*" >> "$tmp/gh.log"; jq -r "${@: -1}" <<< "$RUNS"; }
git -C "$tmp/w" remote set-url origin git@github.com:example/fxa-thing.git
RUNS='{"check_runs":[{"conclusion":"success"},{"conclusion":"skipped"}]}'
check "ci: all passed is green, from the repo's own slug" "green|yes" "$(ci_state "$tmp/w" abc123)|$(grep -q 'repos/example/fxa-thing/commits/abc123/check-runs' "$tmp/gh.log" && echo yes)"
RUNS='{"check_runs":[{"conclusion":"success"},{"conclusion":"failure"}]}'
check "ci: one failure is red" "red" "$(ci_state "$tmp/w" abc123)"
RUNS='{"check_runs":[{"conclusion":null,"status":"in_progress"}]}'
check "ci: one still running is running" "running" "$(ci_state "$tmp/w" abc123)"
RUNS='{"check_runs":[]}'
check "ci: no runs is none" "none" "$(ci_state "$tmp/w" abc123)"
gh() { return 1; }
check "ci: gh fails is none (promote then tests as before)" "none" "$(ci_state "$tmp/w" abc123)"
check "errors: only signatures open after the promote and not before" "c3|d4" "$(promote_new_errors "$(printf 'a1\nb2\n')" "$(printf 'a1\nc3\nd4\n')" | tr '\n' '|' | sed 's/|$//')"
check "errors: none new is empty" "" "$(promote_new_errors "$(printf 'a1\n')" "$(printf 'a1\n')")"

# The deploy record: a promote that moved nothing writes no line; rollback reads its own output.
eval "$(sed -n '/^deploy_record_script() {/,/^}/p;/^rollback_targets() {/,/^}/p' "$(dirname "$0")/vm.sh")"
check "record: a promote that moved nothing writes no line" "" "$(deploy_record_script 'a b' 'a b')"
mkdir -p "$tmp/rec"; deploy_record_script 'a b' 'c b' | HOME="$tmp/rec" bash; deploy_record_script 'a b' 'c b' | HOME="$tmp/rec" bash
check "record: each promote that moved a commit appends one promote line" "2|promote a b c b" \
  "$(wc -l < "$tmp/rec/.fxa-deploys.log" | tr -d ' ')|$(tail -1 "$tmp/rec/.fxa-deploys.log" | cut -d' ' -f2-)"
check "record: no heads (a failed read) writes no line" "" "$(deploy_record_script '' 'c b')"
check "rollback: the commits it moved to, from its own output" "aaa1111 bbb2222" \
  "$(rollback_targets "$(printf 'fxa-sandbox-ctl: ccc3333 -> aaa1111\nfxa-agent-bot: ddd4444 -> bbb2222\n')")"
check "rollback: re-links the skills, as sync does" "yes" "$(rollback_script | grep -q 'ln -sfn' && echo yes)"
exit "$fail"
