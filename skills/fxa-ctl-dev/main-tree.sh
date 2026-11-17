#!/usr/bin/env bash
# main-tree.sh <dir>: the main checkout of the repo that holds <dir>, also from a worktree under .claude/worktrees.
# The bot trees sit beside the main checkout, so a default bot path starts here. Not a git tree: <dir> itself.
d="$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" && [ "${d%/.git}" != "$d" ] && echo "${d%/.git}" || (cd "$1" && pwd)
