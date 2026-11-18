#!/usr/bin/env bash
# The dev tools' default bot tree (bot-tree.sh): fxa-agent-bot-main beside the controller, else fxa-agent-bot,
# and from a worktree under .claude/worktrees, beside its main checkout.
#   bash skills/fxa-ctl-dev/worktree-paths.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
here="$(cd "$(dirname "$0")" && pwd)" src="$(cd "$here/../.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
root="$(cd "$tmp" && pwd -P)"; main="$root/fxa-sandbox-ctl"
mkdir -p "$main/skills/fxa-ctl-dev" "$main/.claude/worktrees/w/skills/fxa-ctl-dev" "$root/fxa-agent-bot" "$root/fxa-agent-bot-main" \
  "$root/improve/fxa-sandbox-ctl" "$root/improve/fxa-agent-bot" "$root/lone/fxa-sandbox-ctl"
for d in "$main" "$main/.claude/worktrees/w"; do cp "$src/skills/fxa-ctl-dev/slack-drive.sh" "$src/skills/fxa-ctl-dev/bot-tree.sh" "$d/skills/fxa-ctl-dev/"; done
wt="$main/.claude/worktrees/w"

bt() { bash "$src/skills/fxa-ctl-dev/bot-tree.sh" "$1"; }
check "the main checkout takes the clean main bot tree" "$root/fxa-agent-bot-main" "$(bt "$main")"
check "a worktree under .claude/worktrees takes its main checkout's" "$root/fxa-agent-bot-main" "$(bt "$wt")"
check "a tree with only fxa-agent-bot beside it (improve/) takes that one" "$root/improve/fxa-agent-bot" "$(bt "$root/improve/fxa-sandbox-ctl")"
check "with no bot tree beside it, the path is still named" "$root/lone/fxa-agent-bot" "$(bt "$root/lone/fxa-sandbox-ctl")"

# Each bot's .env.dev names its own channel; a stub curl logs the channel that slack-drive asks for.
printf 'SLACK_USER_TOKEN=xoxp-t\nSLACK_BOT_TOKEN=xoxb-t\nALLOWED_CHANNELS=CWORK\n' > "$root/fxa-agent-bot/.env.dev"
printf 'SLACK_USER_TOKEN=xoxp-t\nSLACK_BOT_TOKEN=xoxb-t\nALLOWED_CHANNELS=CMAINBOT\n' > "$root/fxa-agent-bot-main/.env.dev"
mkdir -p "$tmp/bin"
printf '#!/usr/bin/env bash\ncat >/dev/null; echo "$*" >> "%s/curl.log"; echo %s\n' "$tmp" "'{\"ok\": true, \"user_id\": \"U1\", \"messages\": []}'" > "$tmp/bin/curl"
chmod +x "$tmp/bin/curl"
channel() { : > "$tmp/curl.log"; env -u FXA_DEV_ENV -u FXA_DEV_BOT_ROOT PATH="$tmp/bin:$PATH" "$@" bash "$wt/skills/fxa-ctl-dev/slack-drive.sh" show 1 >/dev/null 2>&1
  grep -o 'channel=C[A-Z]*' "$tmp/curl.log" | head -1; }
check "slack-drive in a worktree reads the main bot tree beside the main checkout" channel=CMAINBOT "$(channel)"
check "slack-drive reads the .env.dev of the bot tree that dev ran" channel=CWORK "$(channel FXA_DEV_BOT_ROOT="$root/fxa-agent-bot")"

for f in skills/fxa-ctl-dev/dev-smoke.sh skills/fxa-ctl-dev/ship.sh skills/fxa-ctl-dev/test.sh skills/fxa-manager/vm.sh skills/fxa-session-debug/symptoms.check.sh; do
  check "$f builds its default bot tree from bot-tree.sh" yes "$(grep -q 'bot-tree.sh' "$src/$f" && echo yes)"
done
[ "$fail" = 0 ] && echo "all checks pass"; exit "$fail"
