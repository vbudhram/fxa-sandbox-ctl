#!/usr/bin/env bash
# slack-drive.sh: talk to the dev bot (fxa-agent-dev) in its private test channel, as the
# person whose user token is in fxa-agent-bot/.env.dev. It posts only in ALLOWED_CHANNELS
# from that file.
#
#   slack-drive.sh start "<request>"        @mention the dev bot in a new thread; prints the thread ts
#   slack-drive.sh reply <ts> "<text>"      a reply in the thread
#   slack-drive.sh wait <ts> [seconds]      wait until the bot finishes with the last message (✅ or ⚠️), then show
#   slack-drive.sh show <ts>                the thread: seconds from the request, who, text, buttons, reactions
#
# Buttons cannot be pressed through the API: answer a question with a reply.
set -euo pipefail
ENV="${FXA_DEV_ENV:-$(cd "$(dirname "$0")/../../.." && pwd)/fxa-agent-bot/.env.dev}"
get() { grep -E "^$1=" "$ENV" | cut -d= -f2- | sed 's/[[:space:]]*#.*//; s/[[:space:]]*$//'; }
USER_TOKEN="$(get SLACK_USER_TOKEN)"; BOT_TOKEN="$(get SLACK_BOT_TOKEN)"; CH="$(get ALLOWED_CHANNELS | cut -d, -f1)"
[ -n "$USER_TOKEN" ] && [ -n "$CH" ] || { echo "slack-drive: SLACK_USER_TOKEN and ALLOWED_CHANNELS must be in $ENV" >&2; exit 2; }

api() { # api <token> <method> [curl args]
  local t="$1" m="$2"; shift 2
  curl -sS -H "Authorization: Bearer $t" "$@" "https://slack.com/api/$m"
}
post() { # post <text> [thread ts]
  local r; r="$(api "$USER_TOKEN" chat.postMessage -H 'Content-Type: application/json; charset=utf-8' \
    -d "$(jq -n --arg c "$CH" --arg t "$1" --arg th "${2:-}" '{channel: $c, text: $t} + (if $th != "" then {thread_ts: $th} else {} end)')")"
  jq -e .ok >/dev/null <<< "$r" || { echo "slack-drive: $(jq -r .error <<< "$r")" >&2; exit 1; }
  jq -r .ts <<< "$r"
}
replies() { api "$USER_TOKEN" conversations.replies -G --data-urlencode "channel=$CH" --data-urlencode "ts=$1" --data-urlencode limit=200; }

show() {
  local me bot; me="$(api "$USER_TOKEN" auth.test | jq -r .user_id)"; bot="$(api "$BOT_TOKEN" auth.test | jq -r .user_id)"
  replies "$1" | jq -r --arg me "$me" --arg bot "$bot" --argjson t0 "${1%%.*}" '
    def btext: if .type == "rich_text" then [.. | objects | select(.type == "text" or .type == "link" or .type == "emoji") | if .type == "emoji" then ":\(.name):" else (.text // .url) end] | join("")
      else [.. | objects | select(.type == "mrkdwn" or .type == "plain_text" or .type == "markdown") | .text? // empty | strings] | join(" ") end;
    .messages[] |
    "+\(((.ts | tonumber) - $t0) | floor)s \(if .user == $me then "me" elif (.user == $bot or .bot_id) then "bot" else .user end)\(if .edited then " (edited)" else "" end): \(.text // "" | gsub("\n"; " ⏎ ") | .[0:600])",
    # The text of a bot message is a one-line fallback: the reply is in the blocks.
    (select(.user != $me) | (.text // "" | gsub("[_*`]"; "")) as $t | (.blocks // []) | map(select(.type != "actions") | btext | select(. != "")) | join(" / ")
      | if . != "" and . != $t then "    blocks: \(gsub("\n"; " ⏎ ") | .[0:1500])" else empty end),
    ((.blocks // []) | map(select(.type == "actions") | .elements[] | "[\(.text.text // .action_id)]") | if length > 0 then "    buttons: \(join(" "))" else empty end),
    ((.reactions // []) | map(":\(.name):") | if length > 0 then "    reactions: \(join(" "))" else empty end)'
}

case "${1:-}" in
  start) [ -n "${2:-}" ] || { echo "usage: slack-drive.sh start \"<request>\"" >&2; exit 2; }
    post "<@$(api "$BOT_TOKEN" auth.test | jq -r .user_id)> $2" ;;
  reply) [ -n "${3:-}" ] || { echo "usage: slack-drive.sh reply <ts> \"<text>\"" >&2; exit 2; }
    post "$3" "$2" ;;
  show) show "$2" ;;
  wait)
    # The bot puts 👀 on each message it takes, and swaps it for ✅ or ⚠️ when it is done with it.
    me="$(api "$USER_TOKEN" auth.test | jq -r .user_id)"; end=$(( $(date +%s) + ${3:-1800} )); t0=$(date +%s)
    while :; do
      r="$(jq -r --arg me "$me" '[.messages[] | select(.user == $me)] | last | [(.reactions // [])[].name] | join(",")' <<< "$(replies "$2")")"
      case ",$r," in *,white_check_mark,*|*,warning,*) echo "== done after $(( $(date +%s) - t0 ))s (:${r//,/: :}:)"; break ;; esac
      [ "$(date +%s)" -lt "$end" ] || { echo "== still working after ${3:-1800}s (reactions: ${r:-none})"; break; }
      sleep 10
    done
    show "$2" ;;
  *) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
esac
