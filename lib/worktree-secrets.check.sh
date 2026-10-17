#!/usr/bin/env bash
# Offline check for worktree_copy_secrets: which host files reach the slot.
#   bash lib/worktree-secrets.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
here="$(cd "$(dirname "$0")" && pwd)"
eval "$(sed -n '/^worktree_secret_files() {/,/^}/p;/^worktree_copy_secrets() {/,/^}/p' "$here/worktree.sh")"
worktree_repo_root() { echo "$tmp/repo"; }
# Monitor tracks .env; FxA keeps secrets.json untracked.
git init -q "$tmp/repo" && echo old > "$tmp/repo/.env" && git -C "$tmp/repo" add .env && echo s > "$tmp/repo/secrets.json"
mkdir "$tmp/slot"; worktree_copy_secrets "$tmp/slot" 2>/dev/null
check "a tracked file is not copied, an untracked secret is" "secrets.json" "$(cd "$tmp/slot" && ls -A | tr '\n' ' ' | sed 's/ $//')"
exit "$fail"
