#!/usr/bin/env bash
# Offline check for dev-smoke.sh: vm.sh and slack-drive.sh are stubs that log and answer from files.
#   bash skills/fxa-ctl-dev/dev-smoke.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/vm.sh" <<'S'
#!/bin/bash
echo "${FXA_DEV_FAKE:-real} $*" >> "$SMOKE_TMP/vm.log"
S
cat > "$tmp/drive.sh" <<'S'
#!/bin/bash
case "$1" in
  start) n=$(( $(cat "$SMOKE_TMP/n" 2>/dev/null || echo 0) + 1 )); echo $n > "$SMOKE_TMP/n"; echo "17.$n" ;;
  reply) echo "$3" >> "$SMOKE_TMP/replies" ;;
  wait) echo "== done after 3s (:$(cat "$SMOKE_TMP/react"):)"; cat "$SMOKE_TMP/thread" ;;
  show) cat "$SMOKE_TMP/thread" ;;
esac
S
chmod +x "$tmp/vm.sh" "$tmp/drive.sh"
export SMOKE_TMP="$tmp" SMOKE_VM="$tmp/vm.sh" SMOKE_DRIVE="$tmp/drive.sh"
printf '%s\n' '+0s me: smoke' '+1s bot: Fake turn 1: I changed one file.' '    buttons: [Diff] [Open PR] [Push branch]' '+40s bot: Session ended. 1 min.' > "$tmp/thread"
echo white_check_mark > "$tmp/react"
out="$(bash "$(dirname "$0")/dev-smoke.sh" 2>&1)"; rc=$?
check "all good: it passes, fake mode first, and it ends on the real controller" "0|1 dev|real dev" \
  "$rc|$(head -1 "$tmp/vm.log")|$(tail -1 "$tmp/vm.log")"
check "it sends !status and !stop in the fake session" '!status|!stop' "$(paste -sd'|' "$tmp/replies")"
: > "$tmp/vm.log"; : > "$tmp/replies"; echo 0 > "$tmp/n"
printf '%s\n' '+1s bot: Something went wrong. The details are in the dev log.' > "$tmp/thread"
out="$(bash "$(dirname "$0")/dev-smoke.sh" 2>&1)"; rc=$?
check "Something went wrong: it fails, names the thread, and still ends on the real controller" "1|yes|real dev" \
  "$rc|$(grep -q 'FAIL smoke: .*Something went wrong (thread 17.1)' <<< "$out" && echo yes)|$(tail -1 "$tmp/vm.log")"
: > "$tmp/vm.log"; echo 0 > "$tmp/n"; echo warning > "$tmp/react"
printf '%s\n' '+1s bot: Fake turn 1.' '    buttons: [Diff] [Open PR]' '+40s bot: Session ended.' > "$tmp/thread"
out="$(bash "$(dirname "$0")/dev-smoke.sh" 2>&1)"; rc=$?
check "a turn that ends with a warning reaction fails" "1|yes" "$rc|$(grep -q 'FAIL smoke' <<< "$out" && echo yes)"
printf '%s\n' '+1s bot: Fake turn 1.' '    reactions: :white_check_mark:' '    buttons: [Diff] [Open PR]' '+40s bot: Session ended.' > "$tmp/thread"
: > "$tmp/vm.log"; echo 0 > "$tmp/n"
out="$(bash "$(dirname "$0")/dev-smoke.sh" 2>&1)"; rc=$?
check "a warning on the last turn fails, even when an earlier message has a check mark" "1|yes" "$rc|$(grep -q 'FAIL smoke: !status' <<< "$out" && echo yes)"
exit "$fail"
