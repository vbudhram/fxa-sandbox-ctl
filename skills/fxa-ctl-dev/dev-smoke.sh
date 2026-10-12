#!/usr/bin/env bash
# dev-smoke.sh: the dev bot's smoke check before a promote, in the test channel.
#   bash skills/fxa-ctl-dev/dev-smoke.sh      (also: vm.sh dev smoke)
# Fake mode (fake-ctl: no runner, no cost): a session ends its turn with its buttons, !status is
# answered, !stop posts the end card. Then the real controller: a quick answer to "hi".
# A thread that ends with ⚠️ or shows "Something went wrong" fails. It always ends with the dev
# bot on the real controller, so a later real question never gets the canned fake answer.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
H="${SMOKE_VM:-$here/../fxa-manager/vm.sh}" D="${SMOKE_DRIVE:-$here/slack-drive.sh}"
bad=0
fail() { echo "FAIL smoke: $1 (thread $2)"; bad=1; }
# done_ok <ts> <what> [secs]   The bot finished with my last message, with ✅.
done_ok() { local w; w="$("$D" wait "$1" "${3:-120}" 2>&1)"
  case "$(head -1 <<< "$w")" in *warning*) ;; *white_check_mark*) return 0 ;; esac; fail "$2: it did not end with a check mark ($(head -1 <<< "$w"))" "$1"; return 1; }
# shows <ts> <what> <regex>...   Within SMOKE_SHOW_S (60) s the thread shows each regex, and never "Something went wrong".
shows() { local ts="$1" what="$2" out re miss end=$(( $(date +%s) + ${SMOKE_SHOW_S:-60} )); shift 2
  while :; do out="$("$D" show "$ts" 2>&1)" miss=""
    if grep -q 'Something went wrong' <<< "$out"; then fail "$what: Something went wrong" "$ts"; return 1; fi
    for re in "$@"; do grep -qE -- "$re" <<< "$out" || { miss="$re"; break; }; done
    [ -n "$miss" ] || break
    [ "$(date +%s)" -lt "$end" ] || { fail "$what: no match for '$miss'" "$ts"; return 1; }; sleep 5
  done; echo "ok   smoke: $what"; }
real() { "$H" dev >/dev/null 2>&1 || { echo "FAIL smoke: the dev bot did not go back to the real controller"; bad=1; }; }
trap 'real; exit $bad' EXIT

FXA_DEV_FAKE=1 "$H" dev >/dev/null 2>&1 || { echo "FAIL smoke: the fake-mode deploy failed"; bad=1; exit; }
if ts="$("$D" start "smoke: fix a typo in the README")"; then
  done_ok "$ts" "a fake session" && shows "$ts" "a session ends its turn with its buttons" '\[Diff\]' '\[Open PR\]'
  # The bot answers a ! command without a reaction, so these wait for the answer itself.
  "$D" reply "$ts" '!status' >/dev/null && shows "$ts" '!status is answered' 'bot: Session is'
  "$D" reply "$ts" '!stop' >/dev/null && shows "$ts" '!stop posts the end card' 'Session ended'
else fail "the fake session did not start" "-"; fi

real; trap 'exit $bad' EXIT
if ts="$("$D" start "hi")"; then
  done_ok "$ts" "a quick answer on the real controller" 180 && shows "$ts" "a quick answer on the real controller"
else fail "the quick answer did not start" "-"; fi
[ "$bad" = 0 ] && echo "smoke: all pass"
