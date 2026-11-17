#!/usr/bin/env bash
# From a worktree under .claude/worktrees, the dev tools find the bot trees beside the main checkout, not beside the worktree.
#   bash skills/fxa-ctl-dev/worktree-paths.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
here="$(cd "$(dirname "$0")" && pwd)" src="$(cd "$here/../.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
root="$(cd "$tmp" && pwd -P)"; main="$root/fxa-sandbox-ctl"
mkdir -p "$main/skills/fxa-ctl-dev" "$root/fxa-agent-bot" "$root/fxa-agent-bot-main" "$root/plain"
cp "$src/skills/fxa-ctl-dev/slack-drive.sh" "$src/skills/fxa-ctl-dev/main-tree.sh" "$main/skills/fxa-ctl-dev/"
git -C "$main" init -q && git -C "$main" add -A && git -C "$main" -c user.name=t -c user.email=t@example.com commit -qm init
git -C "$main" worktree add -q "$main/.claude/worktrees/w" -b w
wt="$main/.claude/worktrees/w"

mt() { bash "$src/skills/fxa-ctl-dev/main-tree.sh" "$1"; }
check "main-tree of the main checkout" "$main" "$(mt "$main/skills")"
check "main-tree of a worktree is the main checkout" "$main" "$(mt "$wt/skills/fxa-ctl-dev")"
check "main-tree outside git is the folder itself" "$root/plain" "$(mt "$root/plain")"

# Each bot's .env.dev names its own channel; a stub curl logs the channel that slack-drive asks for.
printf 'SLACK_USER_TOKEN=xoxp-t\nSLACK_BOT_TOKEN=xoxb-t\nALLOWED_CHANNELS=CSIBLING\n' > "$root/fxa-agent-bot/.env.dev"
printf 'SLACK_USER_TOKEN=xoxp-t\nSLACK_BOT_TOKEN=xoxb-t\nALLOWED_CHANNELS=CMAINBOT\n' > "$root/fxa-agent-bot-main/.env.dev"
mkdir -p "$tmp/bin"
printf '#!/usr/bin/env bash\ncat >/dev/null; echo "$*" >> "%s/curl.log"; echo %s\n' "$tmp" "'{\"ok\": true, \"user_id\": \"U1\", \"messages\": []}'" > "$tmp/bin/curl"
chmod +x "$tmp/bin/curl"
channel() { : > "$tmp/curl.log"; env -u FXA_DEV_ENV -u FXA_DEV_BOT_ROOT PATH="$tmp/bin:$PATH" "$@" bash "$wt/skills/fxa-ctl-dev/slack-drive.sh" show 1 >/dev/null 2>&1
  grep -o 'channel=C[A-Z]*' "$tmp/curl.log" | head -1; }
check "slack-drive in a worktree reads the bot beside the main checkout" channel=CSIBLING "$(channel)"
check "slack-drive reads the .env.dev of the bot tree that dev ran" channel=CMAINBOT "$(channel FXA_DEV_BOT_ROOT="$root/fxa-agent-bot-main")"

for f in skills/fxa-ctl-dev/dev-smoke.sh skills/fxa-ctl-dev/ship.sh skills/fxa-manager/vm.sh; do
  check "$f builds its default bot tree from main-tree.sh" yes "$(grep -q 'main-tree.sh' "$src/$f" && echo yes)"
done
[ "$fail" = 0 ] && echo "all checks pass"; exit "$fail"
