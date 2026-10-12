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
npm() { echo "npm $*" >> "$tmp/npm.log"; [ "$1" != "${NPM_FAIL:-}" ] || { echo "boom"; return 1; }; echo "3/3 pass"; }
t="$(worktree_tree "$tmp/w")"
check "the trees dev ran: the tests run and pass" "0|2|3/3 pass" \
  "$(promote_tests "$tmp/w" "$t" "$tmp/w" "$t" > "$tmp/out" 2>&1; echo $?)|$(wc -l < "$tmp/npm.log" | tr -d ' ')|$(grep -o '3/3 pass' "$tmp/out")"
: > "$tmp/npm.log"; echo edit > "$tmp/w/d.txt"
check "a local edit since the dev deploy: refuse, and run no test" "1|0" \
  "$(promote_tests "$tmp/w" "$t" "$tmp/w" "$t" >/dev/null 2>&1; echo $?)|$(wc -l < "$tmp/npm.log" | tr -d ' ')"
rm "$tmp/w/d.txt"
log="$(NPM_FAIL=run promote_tests "$tmp/w" "$t" "$tmp/w" "$t" 2>&1 | sed -n 's/.*(log: \(.*\)).*/\1/p')"
check "a failed e2e: refuse, with a private log of its own" "yes|no|yes" \
  "$([ -n "$log" ] && echo yes)|$([ "$log" = /tmp/fxa-promote-test.log ] && echo yes || echo no)|$(grep -q boom "$log" && echo yes)"
rm -f "$log"
exit "$fail"
