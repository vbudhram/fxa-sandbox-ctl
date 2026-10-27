#!/usr/bin/env bash
# Offline checks for vm.sh's ssh errors and vm.sh dev fn.
#   bash skills/fxa-manager/vm.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
eval "$(sed -n '/^on_vm() {/,/^}/p;/^dev_fn_script() {/,/^}/p;/^dev_prune() {/,/^}/p;/^dev_stop_bots() {/,/^}/p' "$(dirname "$0")/vm.sh")"
VM=fxa-manager Z=z P=p
hostname() { echo laptop; }
# No shared connection, so the gcloud stub below answers: a live one on this laptop must never be used.
HOME="$tmp"; MUX=down
ssh() { case " $* " in *" -O check "*) [ "$MUX" = up ] ;; *) cat >/dev/null; echo "via-mux"; return 0 ;; esac; }
# gcloud fails the way an expired login does, the way a lost connection does, or the remote command fails.
gcloud() { cat >/dev/null; case "$MODE" in
  login) echo "ERROR: (gcloud.compute.ssh) There was a problem refreshing your current auth tokens: Reauthentication failed. cannot prompt during non-interactive execution." >&2; return 1 ;;
  ssh) echo "Existing host keys found"; echo "ssh: connect to host fxa-manager port 22: Connection timed out" >&2; return 255 ;;
  remote) echo "Existing host keys found in /home/x" >&2; echo out; return 3 ;; esac; }
MODE=login; err="$(echo true | on_vm 2>&1 >/dev/null)"; rc=$?
check "an expired gcloud login: nonzero, and it says how to log in" "1|yes" "$rc|$(grep -q 'gcloud login expired: run ! gcloud auth login' <<< "$err" && echo yes)"
MODE=ssh; err="$(echo true | on_vm 2>&1 >/dev/null)"; rc=$?
check "a failed ssh: 255, and its error is shown" "255|yes" "$rc|$(grep -q 'Connection timed out' <<< "$err" && echo yes)"
MODE=remote; err="$(echo true | on_vm 2>&1 >/dev/null)"; rc=$?
check "a failed remote command: its status, and gcloud's noise stays hidden" "3|" "$rc|$err"
MUX=up; out="$(echo true | on_vm 2>/dev/null)"
check "a shared connection that is up: plain ssh over it, no gcloud" "via-mux" "$out"

# dev fn: the dev controller's functions, the GCE backend and FXA_FC_HOST, then the commands.
D="$tmp/dev"; mkdir -p "$D/fxa-sandbox-ctl/lib" "$D/fxa-agent-bot"
printf '%s\n' '#!/bin/bash' 'set -euo pipefail' 'SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"' 'source "$SCRIPT_DIR/lib/config.sh"' "trap 'echo crash-recorded' ERR" 'probe() { echo "probe ran"; }' 'main() { echo "main ran"; }' 'main "$@"; exit $?' > "$D/fxa-sandbox-ctl/fxa-sandbox-ctl"
echo 'gce_fn() { echo "gce loaded"; }' > "$D/fxa-sandbox-ctl/lib/vm-gce.sh"; echo 'cfg=1' > "$D/fxa-sandbox-ctl/lib/config.sh"
echo 'FXA_FC_HOST=10.0.0.9' > "$D/fxa-agent-bot/.env.devhost"
out="$( { echo "D=$D"; dev_fn_script 'probe; false; gce_fn; echo "host=$FXA_FC_HOST"; echo err >&2'; } | bash 2>/dev/null)"
check "dev fn: functions load, main does not run, a failure does not stop it or record a crash, stderr is merged" \
  "probe ran|gce loaded|host=10.0.0.9|err" "$(printf '%s\n' "$out" | tr '\n' '|' | sed 's/|$//')"
echo 'OTHER=1' > "$D/fxa-agent-bot/.env.devhost"
out="$( { echo "D=$D"; dev_fn_script 'echo "host=${FXA_FC_HOST:-unset}"'; } | bash 2>&1)"
check "dev fn: a devhost file without FXA_FC_HOST leaves it unset and prints no environment" "host=unset|0" \
  "$(printf '%s\n' "$out" | tail -1)|$(printf '%s\n' "$out" | grep -c 'declare -x')"
# dev_tar: the trees go under the VM's names whatever the local folders are called (a worktree, FXA_DEV_BOT_ROOT).
eval "$(sed -n '/^dev_tar() {/,/^}/p' "$(dirname "$0")/vm.sh")"
T3="$tmp/devtar"; mkdir -p "$T3/my-ctl" "$T3/other-bot"
for r in my-ctl other-bot; do git -C "$T3/$r" init -q; echo x > "$T3/$r/a.txt"; done; echo secret > "$T3/other-bot/.env.dev"; echo .env.dev > "$T3/other-bot/.gitignore"; echo y > "$T3/my-ctl/new.sh"
git -C "$T3/my-ctl" add a.txt; git -C "$T3/other-bot" add a.txt .gitignore
check "dev_tar names each tree as the VM expects, with new files and the dev env" "fxa-agent-bot/.env.dev fxa-agent-bot/.gitignore fxa-agent-bot/a.txt fxa-sandbox-ctl/a.txt fxa-sandbox-ctl/new.sh" \
  "$(dev_tar "$T3/my-ctl" "$T3/other-bot" | tar -tzf - | sort | paste -sd' ' -)"
# dev up: the dev ctl tree's sibling bot .env is the real one, so the routine tick can read the access rules.
# The dev bot loads the live .env first; the last env file it loads must set ROUTINES_ENV=dev, or it ticks live routines.
check "dev up gives the dev bot ROUTINES_ENV=dev in its last env file" "1|1" "$(grep -c "printf '.*ROUTINES_ENV=dev.*' .* > fxa-agent-bot/.env.devhost" "$(dirname "$0")/vm.sh")|$(grep -c -- '--env-file=.env.devhost src/app.js >>' "$(dirname "$0")/vm.sh")"
check "dev up links the real bot .env next to the dev ctl" "1" "$(grep -cx 'ln -sfn $R/fxa-agent-bot/.env fxa-agent-bot/.env' "$(dirname "$0")/vm.sh")"
# dev prune: a file the last deploy copied and this one did not goes; a file no deploy copied stays.
P2="$tmp/prune"; mkdir -p "$P2/src/r" "$P2/dst"; (cd "$P2/src" && echo a > r/keep && echo b > r/gone && tar -czf ../t1 r/keep r/gone)
rm "$P2/src/r/gone"; (cd "$P2/src" && tar -czf ../t2 r/keep)
( cd "$P2/dst" && tar -xzf ../t1 && dev_prune ../t1 && echo x > r/local && tar -xzf ../t2 && dev_prune ../t2 && : > ../bad && dev_prune ../bad )
check "dev prune: removed file goes, kept and local files stay, a bad tarball changes nothing" "r/keep r/local|r/keep" \
  "$(cd "$P2/dst" && find r -type f | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')|$(cat "$P2/dst/.dev-files")"
# dev stop: every dev bot stops, also one that bot.pid does not name; the live bot (no .env.devhost) runs on.
( exec -a "node --env-file=.env.dev --env-file=.env.devhost src/app.js" sleep 30 ) & d1=$!
( exec -a "node --env-file=.env.dev --env-file=.env.devhost src/app.js" sleep 30 ) & d2=$!
( exec -a "node --env-file=.env src/app.js" sleep 30 ) & lv=$!
disown "$d1" "$d2" "$lv"; sleep 0.3; dev_stop_bots; sleep 0.3
check "dev stop: both dev bots stop, the live bot runs on" "gone gone up" \
  "$(for p in $d1 $d2 $lv; do kill -0 "$p" 2>/dev/null && printf 'up ' || printf 'gone '; done | sed 's/ $//')"
kill "$d1" "$d2" "$lv" 2>/dev/null

# vm.sh dev on an expired login: the login line, no tar traceback, nonzero. gcloud, ssh and hostname are stubs on PATH.
mkdir -p "$tmp/pbin" "$tmp/bot"; touch "$tmp/bot/.env.dev"; git -C "$tmp/bot" init -q
printf '#!/bin/sh\ncat >/dev/null\necho "ERROR: (gcloud.compute.ssh) There was a problem refreshing your current auth tokens: Reauthentication failed." >&2\nexit 1\n' > "$tmp/pbin/gcloud"
printf '#!/bin/sh\nexit 255\n' > "$tmp/pbin/ssh"; printf '#!/bin/sh\necho laptop\n' > "$tmp/pbin/hostname"; chmod +x "$tmp/pbin"/*
out="$(PATH="$tmp/pbin:$PATH" HOME="$tmp" FXA_DEV_BOT_ROOT="$tmp/bot" bash "$(dirname "$0")/vm.sh" dev 2>&1)"; rc=$?
check "vm.sh dev on an expired login: says so, prints no traceback, exits nonzero" "yes|0|1" \
  "$(grep -q 'gcloud login expired' <<< "$out" && echo yes)|$(grep -c 'Traceback\|BrokenPipe' <<< "$out")|$([ "$rc" != 0 ] && echo 1)"
# The dev record lives in the controller's .git whatever directory vm.sh runs from.
ctl="$(cd "$(dirname "$0")/../.." && pwd -P)"
check "the dev record path is the controller's, from another directory" "$(git -C "$ctl" rev-parse --path-format=absolute --git-common-dir)/fxa-dev-deployed" \
  "$(cd "$tmp" && CTL_ROOT="$ctl" && eval "$(grep '^DEV_RECORD=' "$ctl/skills/fxa-manager/vm.sh")" && echo "$DEV_RECORD")"
exit "$fail"
