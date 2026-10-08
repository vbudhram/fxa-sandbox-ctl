#!/bin/bash
# sentry.sh: one Sentry issue as JSON, for the bot's Work Object card (fxa-agent-bot unfurl.js).
# The token is the MCP gateway's (fxa-sentry-token, written by fxa-secrets); the card is seen by
# the whole channel, so it carries the issue, never an event's user, and emails become [email].

# sentry_card <issue id | short id>   {id, shortId, title, culprit, status, level, project, count,
#   userCount, firstSeen, lastSeen, permalink, release, hourly}; null when the issue cannot be read.
sentry_card() {
  local ref="${1:-}" tok base id out
  [[ "$ref" =~ ^([0-9]+|[A-Za-z0-9]+(-[A-Za-z0-9]+)+)$ ]] || { echo "ERROR: '${ref}' is not a Sentry issue id or short id" >&2; return 1; }
  tok="$(sed -n 's/^SENTRY_ACCESS_TOKEN=//p' "${FXA_SENTRY_TOKEN_FILE:-$HOME/.config/fxa/mcp-gateway.env}" 2>/dev/null || true)"
  [ -n "$tok" ] || { echo null; return 0; }
  base="${FXA_SENTRY_API:-https://us.sentry.io/api/0}/organizations/${FXA_SENTRY_ORG:-mozilla}"
  id="$ref"
  if ! [[ "$ref" =~ ^[0-9]+$ ]]; then
    id="$(curl -sf -m 15 -H "Authorization: Bearer ${tok}" "${base}/shortids/$(printf '%s' "$ref" | tr '[:lower:]' '[:upper:]')/" \
      | jq -r '.groupId // empty' 2>/dev/null || true)"
  fi
  [[ "$id" =~ ^[0-9]+$ ]] && out="$(curl -sf -m 15 -H "Authorization: Bearer ${tok}" "${base}/issues/${id}/" | jq -c '
      def scrub: tostring | gsub("[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\\.[A-Za-z0-9-]+)*\\.[A-Za-z]{2,}"; "[email]");
      {id, shortId, title: (.title | scrub), culprit: (.culprit // "" | scrub), status, level, project: .project.slug,
       count: (.count | tonumber? // 0), userCount, firstSeen, lastSeen, permalink, release: (.lastRelease.version // null),
       hourly: [.stats["24h"][]?[1]]}' 2>/dev/null)" || true
  printf '%s\n' "${out:-null}"
}
