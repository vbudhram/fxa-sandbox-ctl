#!/bin/bash
# turn-words.sh: a team admin's own words, for each turn. The host acts outside the session's own scope only
# when the words of the turn that asked name the action and the exact target. The agent reads untrusted text
# (PR comments, CI logs, Jira), so nothing it writes counts. The bot passes only a Slack-signed message from a
# team admin or the operator (--admin-words-file), and the file stays on the host.
#   <key>.admin-words.jsonl    {turn, user, ts, text}, append only
#   <key>.admin-words.q.jsonl  rows for a queued message, which get the turn id when the queue goes out
#   <key>.words-used           the clause hashes that allowed an action: one clause, one use

# words_add <key> <file> <turn or q>   Append the bot's row ({user, ts, text}) for that turn.
words_add() {
  local f="${SESSION_DIR}/${1}.admin-words.jsonl"
  [ -n "${2:-}" ] && [ -s "$2" ] || return 0
  [ "$3" = q ] && f="${SESSION_DIR}/${1}.admin-words.q.jsonl"
  jq -c --arg t "$3" '{turn: (if $t == "q" then null else ($t | tonumber) end), user: (.user // "" | tostring),
    ts: (.ts // "" | tostring), text: (.text // "" | tostring | .[0:8000])}' "$2" >> "$f" 2>/dev/null || return 1
}

# words_queue <key> take | ok <turn> | back   Follows the message queue: take it before the turn starts (a steer
#   meanwhile queues for the next turn), give its rows the turn id once the turn started, or put them back.
words_queue() {
  local q="${SESSION_DIR}/${1}.admin-words.q.jsonl"
  case "$2" in
    take) [ ! -s "$q" ] || mv "$q" "${q}.sending" ;;
    ok) [ ! -s "${q}.sending" ] || jq -c --argjson t "$3" '.turn = $t' "${q}.sending" >> "${SESSION_DIR}/${1}.admin-words.jsonl"; rm -f "${q}.sending" ;;
    back) [ ! -s "${q}.sending" ] || cat "${q}.sending" >> "$q"; rm -f "${q}.sending" ;;
  esac
}

# words_turn <key>   The id of the turn that runs now (the boot turn is 0).
words_turn() { local n; n="$(session_get "$1" turns 2>/dev/null || true)"; [[ "$n" =~ ^[0-9]+$ ]] && echo "$n" || echo 0; }

# words_match <key> <turn> <action> <token>...   Prints "<user> <clause hash>" and records the use when one
#   admin clause of that turn starts with a verb of the action and holds one of the exact target tokens, and
#   its message has no negation. Fails otherwise: the caller then refuses, or asks for a tap.
#   A token is literal (a PR URL, owner/repo#N, "#N", "PR N", "branch <name>"): the caller decides which
#   tokens count for the session (#N only with one work repo).
words_match() {
  local key="$1" turn="$2" action="$3" f="${SESSION_DIR}/${1}.admin-words.jsonl" verbs hit
  shift 3
  [ -s "$f" ] && [ $# -gt 0 ] || return 1
  case "$action" in
    target) verbs='work on|switch to|move to|check out|checkout|take over|continue on|put|push|cherry-pick|apply|open' ;;
    rerun) verbs='rerun|retry' ;;
    review) verbs='ask|request review|ping|tag' ;;
    ready) verbs='mark' ;;
    draft) verbs='move' ;;
    comment) verbs='comment on|reply on|post on' ;;
    add-repo) verbs='add|include' ;;
    *) return 1 ;;
  esac
  hit="$(jq -r --argjson turn "$turn" --arg verbs "$verbs" --argjson toks "$(printf '%s\n' "$@" | jq -R . | jq -cs 'map(select(. != "") | ascii_downcase)')" '
    select(.turn == $turn) | .user as $u
    # Drop quoted lines and code; a long message with a URL is a paste.
    | (.text | gsub("```[^`]*```"; " ") | gsub("`[^`]*`"; " ")) as $raw
    | ($raw | split("\n") | map(select(test("^\\s*(>|&gt;)") | not) | gsub("<(?<u>[^|>]+)\\|[^>]*>"; "\(.u)") | gsub("[<>]"; " "))) as $lines
    | select(($lines | length) <= 3 or ($raw | test("https?://") | not))
    | ($lines | join("\n") | ascii_downcase) as $t
    | select($t | test("\\b(not|don.?t|do not|never|no|without|stop)\\b") | not)
    | $t | splits("[;!?\n]|\\.(\\s|$)")
    | select(test("^\\s*(@\\S+\\s+)?(please\\s+|can you\\s+|could you\\s+)?(" + $verbs + ")\\b"))
    | . as $c | (" " + ($c | gsub(":(\\s|$)"; " ") | gsub("[\\s,()]+"; " ")) + " ") as $p | select(any($toks[]; . as $k | $p | contains(" " + $k + " ")))
    | "\($u)\t\($c | gsub("\\s+"; " ") | ltrimstr(" ") | rtrimstr(" "))"' "$f" 2>/dev/null | head -1)"
  [ -n "$hit" ] || return 1
  local user="${hit%%$'\t'*}" h
  h="$(printf '%s|%s|%s' "$turn" "$action" "${hit#*$'\t'}" | shasum -a 256 | cut -c1-16)"
  touch "${SESSION_DIR}/${key}.words-used"
  grep -qxF "$h" "${SESSION_DIR}/${key}.words-used" && return 1
  echo "$h" >> "${SESSION_DIR}/${key}.words-used"
  printf '%s %s\n' "$user" "$h"
}
