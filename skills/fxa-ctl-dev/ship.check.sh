#!/usr/bin/env bash
# Offline check for ship.sh: it pushes a rebased controller commit, fast-forwards the bot tree,
# deploys with that bot tree, and refuses a dirty tree before it pushes anything.
#   bash skills/fxa-ctl-dev/ship.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
src="$(cd "$(dirname "$0")" && pwd)/ship.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export GIT_CONFIG_GLOBAL="$tmp/gitconfig"; git config --global user.email user@example.com; git config --global user.name t; git config --global init.defaultBranch main
for r in ctl bot; do git init -q --bare "$tmp/$r.git"; git clone -q "$tmp/$r.git" "$tmp/seed-$r" 2>/dev/null
  (cd "$tmp/seed-$r" && echo a > f && git add f && git commit -qm base && git push -q origin HEAD:main); done
git clone -q "$tmp/ctl.git" "$tmp/w/ctl"; git clone -q "$tmp/bot.git" "$tmp/w/fxa-agent-bot-main"
mkdir -p "$tmp/w/ctl/skills/fxa-ctl-dev"; cp "$src" "$tmp/w/ctl/skills/fxa-ctl-dev/"
(cd "$tmp/w/ctl" && echo 'skills/' > .git/info/exclude)
printf '#!/bin/bash\necho "vm $* bot=$FXA_DEV_BOT_ROOT" >> %q\n' "$tmp/vm.log" > "$tmp/vm.sh"
# main moves on in both repos after the trees were cloned.
for r in ctl bot; do (cd "$tmp/seed-$r" && echo b > g && git add g && git commit -qm later && git push -q origin HEAD:main); done
(cd "$tmp/w/ctl" && echo mine > m && git add m && git commit -qm mine)
run() { FXA_SHIP_VM="$tmp/vm.sh" bash "$tmp/w/ctl/skills/fxa-ctl-dev/ship.sh" "$@" > "$tmp/out" 2>&1; echo $?; }
check "ships: exit 0" "0" "$(run)"
check "the controller commit is on main, on top of the newer main" "mine|later" "$(git -C "$tmp/ctl.git" log --format=%s -2 main | paste -sd'|' -)"
check "the bot tree is at the bot's main, and nothing was pushed from it" "yes|2" \
  "$([ "$(git -C "$tmp/w/fxa-agent-bot-main" rev-parse HEAD)" = "$(git -C "$tmp/bot.git" rev-parse main)" ] && echo yes)|$(git -C "$tmp/bot.git" rev-list --count main)"
check "vm.sh dev ran with that bot tree" "vm dev bot=$(cd "$tmp/w/fxa-agent-bot-main" && pwd)" "$(cat "$tmp/vm.log")"
check "it ends with the plain promote command" "  bash skills/fxa-manager/vm.sh promote" "$(tail -1 "$tmp/out")"
: > "$tmp/vm.log"; (cd "$tmp/w/ctl" && echo more > m2 && git add m2 && git commit -qm second && echo dirty > m)
check "a dirty tree: refused, nothing pushed, no deploy" "1|mine|" \
  "$(run)|$(git -C "$tmp/ctl.git" log --format=%s -1 main)|$(cat "$tmp/vm.log")"
check "--smoke deploys through dev smoke" "vm dev smoke" "$( (cd "$tmp/w/ctl" && git checkout -q m); run --smoke >/dev/null; cut -d' ' -f1-3 "$tmp/vm.log")"
exit "$fail"
