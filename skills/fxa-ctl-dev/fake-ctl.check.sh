#!/usr/bin/env bash
# Offline check for fake-ctl.sh, the controller stand-in of the dev bot and the e2e harness.
#   bash skills/fxa-ctl-dev/fake-ctl.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
F="$(cd "$(dirname "$0")" && pwd)/fake-ctl.sh"
export FAKE_CTL_DIR="$tmp/s" FAKE_NOW_FILE="$tmp/now" FAKE_CTL_LOG="$tmp/log" FAKE_CI_S=0
echo 1000 > "$FAKE_NOW_FILE"
f() { bash "$F" "$@"; }
st() { f events "$1" | jq -r '.state'; }

echo "fix the blur" > "$tmp/p.md"
f --backend gce task --id agent-aa1 --owner UA --prompt-file "$tmp/p.md" >/dev/null
check "the call log keeps the prompt file's text" "task|fix the blur" "$(jq -r '"\(.argv[0])|\(.files["prompt-file"] | rtrimstr("\n"))"' "$tmp/log")"
check "the clock is frozen: still starting" "starting" "$(st agent-aa1)"
echo 1005 > "$FAKE_NOW_FILE"
check "setup ends at +5 s" "active" "$(st agent-aa1)"
check "no turn_end before the turn ends" "0" "$(f events agent-aa1 | jq '.events | length')"
echo 1015 > "$FAKE_NOW_FILE"
check "the turn ends at +10 s" "turn_end|ready" "$(f events agent-aa1 | jq -r '.events[0] | "\(.type)|\(.status)"')"
echo "use approach 2" > "$tmp/m.md"
f steer agent-aa1 --message-file "$tmp/m.md" >/dev/null
check "a steer is logged with its text" "use approach 2" "$(tail -1 "$tmp/log" | jq -r '.files["message-file"] | rtrimstr("\n")')"
f finish --session agent-aa1 >/dev/null
check "finish wraps up" "wrapping" "$(st agent-aa1)"
echo 1030 > "$FAKE_NOW_FILE"
check "then a PR event" "pr" "$(f events agent-aa1 | jq -r '.events[-1].type')"
check "a second finish is refused" "1" "$(f finish --session agent-aa1 >/dev/null 2>&1; echo $?)"

f --pipeline pyfxa-team task --id agent-bb2 --owner UA --repos mozilla/PyFxA,mozilla/fxa --prompt-file "$tmp/p.md" >/dev/null
echo 1045 > "$FAKE_NOW_FILE"
check "a stack's turn_end has a row for each repo" "pyfxa:diff fxa:pr" "$(f events agent-bb2 | jq -r '[.events[0].trees[] | "\(.name):\(.out)"] | join(" ")')"
f finish --session agent-bb2 --repo mozilla/fxa >/dev/null; echo 1060 > "$FAKE_NOW_FILE"
check "a stack's PR names its repo" "mozilla/fxa" "$(f events agent-bb2 | jq -r '.events[-1].repo')"
check "find-pr: the newest session with that PR, live" "agent-bb2|true" "$(f session find-pr https://github.com/mozilla/fxa/pull/999999 | jq -r '"\(.key)|\(.live)"')"
f stop agent-bb2
f task --id agent-cc3 --owner UA --resume-from agent-bb2 --prompt-file "$tmp/p.md" >/dev/null
check "a resume carries the repos and the PR, unannounced" "mozilla/PyFxA,mozilla/fxa|pr-c" "$(cat "$FAKE_CTL_DIR/agent-cc3/repos")|$(awk '{print $2}' "$FAKE_CTL_DIR/agent-cc3/fins")"
echo 2000 > "$FAKE_NOW_FILE"
f task --id agent-dd4 --owner UA --prompt-file "$tmp/p.md" >/dev/null
echo 2007 > "$FAKE_NOW_FILE"
check "a steer during a turn is queued" "queued" "$(f steer agent-dd4 --message-file "$tmp/m.md")"
check "an interrupt during a turn says so" "interrupted" "$(f interrupt agent-dd4)"
echo 2015 > "$FAKE_NOW_FILE"
check "the queued turn starts when the first ends, not beside it" "1" "$(f events agent-dd4 | jq '[.events[] | select(.type == "turn_end")] | length')"
echo 2025 > "$FAKE_NOW_FILE"
check "then it ends 10 s later" "2" "$(f events agent-dd4 | jq '[.events[] | select(.type == "turn_end")] | length')"
check "a steer after the turns is not queued" "" "$(f steer agent-dd4 --message-file "$tmp/m.md")"
cat > "$tmp/tape.json" <<'T'
{"sessions": [{"turns": [
  {"steps": ["Reading a.ts", "Running yarn test a"], "diff": [{"file": "a.ts", "added": 2, "removed": 1}], "end": {"status": "ready", "text": "Recorded reply one."}},
  {"end": {"type": "question", "text": "Which one?", "options": ["X (recommended)", "Y"]}},
  {"end": {"status": "ready", "text": "No new files this turn."}}]},
 {"turns": [{"end": {"status": "needs-input", "text": "Second session reply."}}]}]}
T
export FAKE_TAPE="$tmp/tape.json"; echo 3000 > "$FAKE_NOW_FILE"
rm -rf "$FAKE_CTL_DIR"
check "the first task with a tape succeeds" "0" "$(f task --id agent-ee5 --owner UA --prompt-file "$tmp/p.md" >/dev/null; echo $?)"; echo 3015 > "$FAKE_NOW_FILE"
check "a tape turn ends with the recorded reply, with changes" "turn_end|ready|1|Recorded reply one." "$(f events agent-ee5 | jq -r '.events[0] | "\(.type)|\(.status)|\(.changes)|\(.text)"')"
f steer agent-ee5 --message-file "$tmp/m.md" >/dev/null; echo 3025 > "$FAKE_NOW_FILE"
check "the second turn is the recorded question" "question|Which one?|2" "$(f events agent-ee5 | jq -r '.events[1] | "\(.type)|\(.text)|\(.options | length)"')"
f steer agent-ee5 --message-file "$tmp/m.md" >/dev/null; echo 3035 > "$FAKE_NOW_FILE"
check "a later turn with no diff of its own still has the branch's changes" "No new files this turn.|1" "$(f events agent-ee5 | jq -r '.events[2] | "\(.text)|\(.changes)"')"
f steer agent-ee5 --message-file "$tmp/m.md" >/dev/null; echo 3045 > "$FAKE_NOW_FILE"
check "past the tape: a canned turn, logged" "Fake turn 4|1" "$(f events agent-ee5 | jq -r '.events[3].text[0:11]')|$(grep -c replay_exhausted "$FAKE_CTL_LOG")"
f task --id agent-ff6 --owner UA --resume-from agent-ee5 --prompt-file "$tmp/p.md" >/dev/null; echo 3060 > "$FAKE_NOW_FILE"
check "the next task plays the tape's next session" "needs-input|Second session reply." "$(f events agent-ff6 | jq -r '.events[0] | "\(.status)|\(.text)"')"
unset FAKE_TAPE
check "the quick look is busy by default" "3" "$(f answer ask --id q1 --prompt-file "$tmp/p.md" --stream >/dev/null; echo $?)"
check "FAKE_ANSWER: the quick look answers, after a step" "step|answer|It was removed." "$(FAKE_ANSWER='It was removed.' f answer ask --id q1 --prompt-file "$tmp/p.md" --stream | jq -r '.type' | paste -sd'|' -)|$(FAKE_ANSWER='It was removed.' f answer ask --id q1 --stream | tail -1 | jq -r .answer)"
[ "$fail" = 0 ] && echo "all checks pass"; exit "$fail"
