#!/usr/bin/env bash
# Offline check for the host's defences against a slot the agent wrote.
#   bash lib/host-safety.check.sh
set -u
fail=0
check() { # check <name> <want> <got>
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi
}
tmp="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$tmp"' EXIT
here="$(cd "$(dirname "$0")" && pwd -P)"
eval "$(sed -n '/^worktree_git_ok() {/,/^}/p;/^slot_write() /p' "$here/worktree.sh")"
eval "$(sed -n '/^_finish_tooling_guard() {/,/^}/p' "$here/finish.sh")"
g() { git -c init.defaultBranch=main -c core.hooksPath=/dev/null -c user.name=t -c user.email=t@example.com "$@"; }

# slot_write never writes through a planted link.
echo keep > "$tmp/victim"; ln -s "$tmp/victim" "$tmp/slotfile"
echo new | slot_write "$tmp/slotfile"
check "slot_write replaces a link" "keep|new|no" "$(cat "$tmp/victim")|$(cat "$tmp/slotfile")|$([ -L "$tmp/slotfile" ] && echo yes || echo no)"

# worktree_git_ok accepts the pointer git wrote and refuses a rewritten one.
g init -q "$tmp/repo" && g -C "$tmp/repo" commit -q --allow-empty -m init && g -C "$tmp/repo" worktree add -q "$tmp/slot" 2>/dev/null
worktree_repo_root() { printf '%s\n' "$tmp/repo"; }
check "real pointer passes" "$tmp/repo/.git/worktrees/slot" "$(worktree_git_ok "$tmp/slot" 2>/dev/null)"
cp "$tmp/slot/.git" "$tmp/pointer"
mkdir -p "$tmp/slot/.g"; printf 'gitdir: %s/slot/.g\n' "$tmp" > "$tmp/slot/.git"
check "pointer into the slot refused" "no" "$(worktree_git_ok "$tmp/slot" >/dev/null 2>&1 && echo yes || echo no)"
printf 'gitdir: %s/repo/.git/worktrees/../../x\n' "$tmp" > "$tmp/slot/.git"
check "dotdot pointer refused" "no" "$(worktree_git_ok "$tmp/slot" >/dev/null 2>&1 && echo yes || echo no)"
rm "$tmp/slot/.git"; mkdir "$tmp/slot/.git"
check ".git directory refused" "no" "$(worktree_git_ok "$tmp/slot" >/dev/null 2>&1 && echo yes || echo no)"
rmdir "$tmp/slot/.git"; ln -s "$tmp/pointer" "$tmp/slot/.git"
check ".git link refused" "no" "$(worktree_git_ok "$tmp/slot" >/dev/null 2>&1 && echo yes || echo no)"
rm "$tmp/slot/.git"; cp "$tmp/pointer" "$tmp/slot/.git"

# The tooling guard covers yarn and npm config, which run code on the host.
for f in .yarnrc.yml packages/x/.npmrc .yarn/plugins/p.cjs; do
  mkdir -p "$tmp/slot/$(dirname "$f")"; echo x > "$tmp/slot/$f"; g -C "$tmp/slot" add -f -- "$f"
  check "guard refuses $f" "no" "$(_finish_tooling_guard "$tmp/slot" 2>/dev/null && echo yes || echo no)"
  check "the ERROR line names $f" "1" "$(_finish_tooling_guard "$tmp/slot" 2>&1 | grep -c "^ERROR: refusing to ship: .*: ${f}$")"
  g -C "$tmp/slot" rm -q --cached -- "$f"
done
echo x > "$tmp/slot/a.ts"; g -C "$tmp/slot" add a.ts
check "guard passes plain code" "yes" "$(_finish_tooling_guard "$tmp/slot" 2>/dev/null && echo yes || echo no)"

# The sandbox gets only the allowlisted sections of the operator's CLAUDE.md.
mkdir -p "$tmp/home"
printf '# Global\nintro line\n## Writing Style\nshort sentences\n### ASD-STE100 in practice\nuse, not utilize\n## FxA Triage\nhttps://internal.example.com/secret-page\n## Git Commits\nscoped commits\n' > "$tmp/home/CLAUDE.md"
eval "$(sed -n '/^VM_RULE_SECTIONS=/p;/^_vm_operator_rules() {/,/^}/p' "$here/agent.sh")"
out="$(CLAUDE_HOME_DIR="$tmp/home" _vm_operator_rules)"
check "rules keep allowlisted sections" "3" "$(grep -cE '^(short sentences|use, not utilize|scoped commits)$' <<< "$out")"
check "rules drop other sections and the preamble" "0" "$(grep -cE 'internal.example.com|intro line|FxA Triage' <<< "$out")"
check "no CLAUDE.md, no rules" "" "$(CLAUDE_HOME_DIR="$tmp/none" _vm_operator_rules)"

[ "$fail" = 0 ] && echo "all ok"
exit "$fail"
