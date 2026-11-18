#!/usr/bin/env bash
# bot-tree.sh <ctl root>: the default bot tree for that controller tree.
# A worktree under .claude/worktrees has no bot beside it, so start at its main checkout. Beside it,
# fxa-agent-bot-main (a clean main) wins over fxa-agent-bot (a work tree). Prints the path even when it is missing.
d="$(cd "$1" && pwd)"; d="${d%%/.claude/worktrees/*}"
for b in fxa-agent-bot-main fxa-agent-bot; do [ -d "$d/../$b" ] && { (cd "$d/../$b" && pwd); exit 0; }; done
echo "$(dirname "$d")/fxa-agent-bot"
