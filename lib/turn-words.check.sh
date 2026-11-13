#!/usr/bin/env bash
# Offline check for lib/turn-words.sh: a table of normal and hostile phrases, the turn scope, one use for each clause.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want [$2] got [$3]"; fail=1; fi; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export SESSION_DIR="$tmp"
session_get() { [ "$2" = turns ] && cat "$tmp/turns" 2>/dev/null || true; }
# shellcheck source=lib/turn-words.sh
. "$here/turn-words.sh"
# say <text> [turn]   A fresh session with one admin row; prints the key. The count is in a file: $(say) is a subshell.
say() {
  local n; n=$(( $(cat "$tmp/n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$tmp/n"; local k="agent-w$n"
  jq -nc --arg t "$1" '{user: "UA1", ts: "1.1", text: $t}' > "$tmp/in.json"
  words_add "$k" "$tmp/in.json" "${2:-3}"; echo "$k"
}
m() { local k="$1"; shift; words_match "$k" 3 "$@" >/dev/null && echo match || echo no; }
pr='https://github.com/mozilla/syncstorage-rs/pull/2738'
one=("$pr" 'mozilla/syncstorage-rs#2738' '#2738' 'pr 2738')   # the tokens for a one-repo session
two=("$pr" 'mozilla/syncstorage-rs#2738')                      # a two-repo session: #N does not count

check "put the offset-limit-0 commit on PR 2738" match "$(m "$(say 'put the offset-limit-0 commit on PR 2738')" target "${one[@]}")"
check "a Slack mention, please, and a URL in <...|...>" match "$(m "$(say "<@U0BOT> please work on <$pr|PR 2738>")" target "${one[@]}")"
check "rerun CI on owner/repo#N" match "$(m "$(say 'rerun CI on mozilla/syncstorage-rs#2738')" rerun "${two[@]}")"
check "do not comment on #2738: a negation" no "$(m "$(say 'do not comment on #2738')" comment "${one[@]}")"
check "Jane will work on PR 2738: the verb does not start the clause" no "$(m "$(say 'Jane will work on PR 2738')" target "${one[@]}")"
check "tell me what #2738 does: tell is not a verb" no "$(m "$(say 'tell me what #2738 does')" comment "${one[@]}")"
check "rerun it: no exact target" no "$(m "$(say 'rerun it')" rerun "${one[@]}")"
check "2738 ms: a bare number" no "$(m "$(say 'put it on 2738 ms')" target "${one[@]}")"
check "a quoted > work on PR 2738 line" no "$(m "$(say "> work on PR 2738
thanks")" target "${one[@]}")"
check "work on PR 2738 in inline code" no "$(m "$(say 'see `work on PR 2738`')" target "${one[@]}")"
log="$(printf 'line %s\n' 1 2 3 4 5 6 7 8 9)"
check "a 10-line pasted CI log with a URL" no "$(m "$(say "work on PR 2738
${log}
https://circleci.com/x")" target "${one[@]}")"
check "comment on #2738 in a two-repo session: #N does not count" no "$(m "$(say 'comment on #2738')" comment "${two[@]}")"
check "PR 27380 is not PR 2738" no "$(m "$(say 'work on PR 27380')" target "${one[@]}")"
check "a target the PR text named, not the admin" no "$(m "$(say 'work on PR 2799')" target "${one[@]}")"
k="$(say 'work on PR 2738')"
check "the first use of a clause matches" match "$(m "$k" target "${one[@]}")"
check "the same clause used twice: the second does not" no "$(m "$k" target "${one[@]}")"
k="$(say 'work on PR 2738' 2)"
check "words from an earlier turn do not count" no "$(m "$k" target "${one[@]}")"
# The queue: rows get the turn id when the queue goes out. (The first use already spent "switch to PR 2738".)
jq -nc '{user: "UA1", ts: "2.2", text: "switch to PR 2738"}' > "$tmp/in.json"
words_add agent-q "$tmp/in.json" q
check "a queued row counts for no turn before the queue goes out" no "$(m agent-q target "${one[@]}")"
words_queue agent-q take; words_queue agent-q back
check "a queue that did not go out keeps its row for the next turn" no "$(m agent-q target "${one[@]}")"
words_queue agent-q take
jq -nc '{user: "UA1", ts: "2.3", text: "take over PR 2738"}' > "$tmp/in.json"; words_add agent-q "$tmp/in.json" q
words_queue agent-q ok 3
check "a queued row counts for the turn the queue starts" match "$(m agent-q target "${one[@]}")"
check "a row queued while that turn started waits for the next turn" "1|no" \
  "$(grep -c 'take over' "$tmp/agent-q.admin-words.q.jsonl")|$(words_match agent-q 3 target 'pr 2738' >/dev/null && echo match || echo no)"
check "the match prints the admin's user id" UA1 "$(words_match "$(say 'check out PR 2738')" 3 target "${one[@]}" | cut -d' ' -f1)"
check "a resume (a new key) has no rows" no "$(m agent-new target "${one[@]}")"
check "words_turn reads the turn counter" 4 "$(echo 4 > "$tmp/turns"; words_turn agent-x)"
exit "$fail"
