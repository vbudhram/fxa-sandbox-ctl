#!/usr/bin/env bash
# Ship committed work to main and the dev bot in one command, from a controller worktree:
#   bash skills/fxa-ctl-dev/ship.sh [--bot <bot tree>] [--smoke]
# Each tree (this one, and the bot tree: --bot, else ../fxa-agent-bot-main) must be clean. Each is
# rebased on origin/main and pushed when it has commits; then vm.sh dev (or dev smoke) deploys both.
# The promote stays a separate step, from the main checkout, so its allow rule matches.
set -euo pipefail
CTL="$(cd "$(dirname "$0")/../.." && pwd)"
BOT="$CTL/../fxa-agent-bot-main" smoke=0
while [ $# -gt 0 ]; do
  case "$1" in --bot) BOT="${2:?--bot takes a tree}"; shift ;; --smoke) smoke=1 ;;
    *) echo "usage: ship.sh [--bot <bot tree>] [--smoke]" >&2; exit 2 ;; esac; shift
done
BOT="$(cd "$BOT" && pwd)"

# ship_tree <tree>   Clean, rebased on origin/main, and pushed when ahead.
ship_tree() {
  local t="$1" n
  [ -z "$(git -C "$t" status --porcelain)" ] || { echo "ship.sh: $t has uncommitted changes; commit them or stash them first" >&2; git -C "$t" status --short | head -5 >&2; return 1; }
  # dev_tar skips ignored files, so a node_modules link would not ship, but the dev bot then runs no packages.
  [ ! -L "$t/node_modules" ] || { echo "ship.sh: $t/node_modules is a link; remove it before a deploy" >&2; return 1; }
  git -C "$t" fetch -q origin main
  git -C "$t" rebase -q origin/main || { git -C "$t" rebase --abort 2>/dev/null; echo "ship.sh: $t does not rebase cleanly on origin/main; rebase it by hand" >&2; return 1; }
  n="$(git -C "$t" rev-list --count origin/main..HEAD)"
  if [ "$n" -gt 0 ]; then
    git -C "$t" push -q origin HEAD:main || { echo "ship.sh: the push from $t failed (main moved?); run ship.sh again" >&2; return 1; }
    echo "$(basename "$t"): pushed $n commit(s), main is $(git -C "$t" rev-parse --short HEAD)"
  else echo "$(basename "$t"): nothing to push, at main $(git -C "$t" rev-parse --short HEAD)"; fi
}
ship_tree "$CTL"; ship_tree "$BOT"

vm="${FXA_SHIP_VM:-$CTL/skills/fxa-manager/vm.sh}"
if [ "$smoke" = 1 ]; then FXA_DEV_BOT_ROOT="$BOT" SMOKE_BOT_ROOT="$BOT" bash "$vm" dev smoke; else FXA_DEV_BOT_ROOT="$BOT" bash "$vm" dev; fi
cat <<EOF
Next: promote from the main checkout, as this exact command (the allow rule matches only it):
  bash skills/fxa-manager/vm.sh promote
EOF
