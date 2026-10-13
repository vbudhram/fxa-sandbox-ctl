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

# package.json: only scripts, lint-staged and husky count. A missing side is {}.
g -C "$tmp/slot" rm -q --cached a.ts
mkdir -p "$tmp/slot/libs/old" "$tmp/slot/libs/gone"
echo '{"name":"root","scripts":{"t":"jest"},"dependencies":{"a":"1"}}' > "$tmp/slot/package.json"
echo '{"name":"gone","version":"0.0.0"}' > "$tmp/slot/libs/gone/package.json"
g -C "$tmp/slot" add package.json libs/gone/package.json && g -C "$tmp/slot" commit -q -m pkg
guard() { _finish_tooling_guard "$tmp/slot" 2>/dev/null && echo yes || echo no; }
pkg() { # pkg <name> <want> <path> <json>   stage the file, run the guard, then reset to HEAD
  mkdir -p "$tmp/slot/$(dirname "$3")"; printf '%s\n' "$4" > "$tmp/slot/$3"; g -C "$tmp/slot" add -- "$3"
  check "$1" "$2" "$(guard)"
  g -C "$tmp/slot" reset -q; g -C "$tmp/slot" checkout -q -- . 2>/dev/null; g -C "$tmp/slot" clean -qfd
}
pkg "a new lib's package.json passes" yes libs/x/package.json '{"name":"x","version":"0.0.0"}'
pkg "a new package.json with scripts is refused" no libs/y/package.json '{"name":"y","scripts":{"postinstall":"curl x"}}'
pkg "a changed scripts value is refused" no package.json '{"name":"root","scripts":{"t":"curl x"},"dependencies":{"a":"1"}}'
pkg "a dependency bump passes" yes package.json '{"name":"root","scripts":{"t":"jest"},"dependencies":{"a":"2"}}'
g -C "$tmp/slot" rm -q libs/gone/package.json
check "a deleted package.json with no scripts passes" yes "$(guard)"
g -C "$tmp/slot" reset -q; g -C "$tmp/slot" checkout -q -- .

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
