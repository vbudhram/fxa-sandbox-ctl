#!/bin/bash
# jira.sh — Fetch Jira issue context via acli and render it as markdown.
#
# Public API:
#   jira_fetch_context <ISSUE-KEY>   Prints a markdown context blob to stdout.
#   jira_slug_for <ISSUE-KEY>        Prints a lowercased slug from the issue summary.

[ -n "${_FXA_JIRA_LOADED:-}" ] && return 0
_FXA_JIRA_LOADED=1

# jq program that walks an Atlassian Document Format (ADF) tree and emits markdown.
# ADF is a nested JSON structure used by Jira for rich text fields (description, comments).
read -r -d '' _JIRA_ADF_JQ <<'JQ' || true
def adf:
  if type == "object" then
    if   .type == "text"        then (.text // "")
    elif .type == "hardBreak"   then "\n"
    elif .type == "paragraph"   then ((.content // []) | map(adf) | add // "") + "\n\n"
    elif .type == "heading"     then ("#" * (.attrs.level // 1)) + " " + ((.content // []) | map(adf) | add // "") + "\n\n"
    elif .type == "bulletList"  then ((.content // []) | map("- " + adf) | add // "") + "\n"
    elif .type == "orderedList" then ((.content // []) | map("1. " + adf) | add // "") + "\n"
    elif .type == "listItem"    then ((.content // []) | map(adf) | add // "") | sub("\n\n$"; "\n")
    elif .type == "codeBlock"   then "```" + (.attrs.language // "") + "\n" + ((.content // []) | map(adf) | add // "") + "\n```\n\n"
    elif .type == "blockquote"  then "> " + ((.content // []) | map(adf) | add // "") + "\n"
    elif .type == "rule"        then "\n---\n\n"
    elif .type == "mention"     then (.attrs.text // "")
    elif .type == "inlineCard"  then (.attrs.url // "")
    elif .type == "emoji"       then (.attrs.shortName // "")
    elif .type == "mediaSingle" or .type == "media" or .type == "mediaGroup" then ""
    else ((.content // []) | map(adf) | add // "")
    end
  elif type == "array" then (map(adf) | add // "")
  else "" end;

. as $issue
| $issue.fields as $f
| ($f.description | adf) as $desc
| ($f.comment.comments // []) as $comments

| "# \($issue.key): \($f.summary)\n\n"
+ "**Type:** \($f.issuetype.name // "Unknown")  \n"
+ "**Status:** \($f.status.name // "Unknown")  \n"
+ (if $f.priority then "**Priority:** \($f.priority.name)  \n" else "" end)
+ (if $f.assignee then "**Assignee:** \($f.assignee.displayName)  \n" else "" end)
+ (if ($f.labels // []) | length > 0 then "**Labels:** \($f.labels | join(", "))  \n" else "" end)
+ (if ($f.components // []) | length > 0 then "**Components:** \($f.components | map(.name) | join(", "))  \n" else "" end)
+ (if $f.parent then "**Parent:** \($f.parent.key) — \($f.parent.fields.summary // "")  \n" else "" end)
+ "\n"
+ (if ($desc | length) > 0 then "## Description\n\n\($desc)\n" else "" end)
+ (if ($f.issuelinks // []) | length > 0 then
    "## Linked Issues\n\n"
    + (($f.issuelinks // [])
       | map(
           (.type.outward // .type.inward // "relates to") as $rel
           | (.outwardIssue // .inwardIssue) as $li
           | if $li then "- **\($rel)**: \($li.key) — \($li.fields.summary // "")\n" else "" end
         )
       | add // "")
    + "\n"
   else "" end)
+ (if ($comments | length) > 0 then
    "## Comments (\($comments | length))\n\n"
    + ($comments
       | map(
           "### \(.author.displayName // "Unknown") — \(.created // "")\n\n"
           + (.body | adf)
           + "\n"
         )
       | add // "")
   else "" end)
JQ

# Read the workitem summary (used to derive a slug for branch / worktree names).
read -r -d '' _JIRA_SLUG_JQ <<'JQ' || true
.fields.summary
| ascii_downcase
| gsub("[^a-z0-9]+"; "-")
| gsub("^-+|-+$"; "")
| .[0:50]
| gsub("-+$"; "")
JQ

_jira_require_acli() {
  if ! command -v acli &>/dev/null; then
    echo "ERROR: acli is not installed. Install with: brew install --cask atlassian-cli" >&2
    return 1
  fi
  if ! command -v jq &>/dev/null; then
    echo "ERROR: jq is not installed. Install with: brew install jq" >&2
    return 1
  fi
}

# jira_fetch_raw <ISSUE-KEY> — fetch the issue JSON and cache it for the lifetime
# of the current shell so we don't hit the API twice when callers want both
# context and slug.
_JIRA_CACHE_DIR="${TMPDIR:-/tmp}/fxa-sandbox-ctl-jira-$$"
_jira_fetch_raw() {
  local key="$1"
  _jira_require_acli || return 1
  mkdir -p "${_JIRA_CACHE_DIR}"
  local cache="${_JIRA_CACHE_DIR}/${key}.json"
  if [ ! -s "$cache" ]; then
    if ! acli jira workitem view "$key" --json --fields "*all" > "${cache}.tmp" 2>/dev/null; then
      rm -f "${cache}.tmp"
      echo "ERROR: Failed to fetch ${key} from Jira. Check 'acli jira auth status'." >&2
      return 1
    fi
    mv "${cache}.tmp" "$cache"
  fi
  cat "$cache"
}

# jira_fetch_context <ISSUE-KEY> — emit a markdown context blob to stdout.
jira_fetch_context() {
  local key="${1:-}"
  if [ -z "$key" ]; then
    echo "ERROR: jira_fetch_context requires an issue key (e.g. FXA-1234)" >&2
    return 1
  fi
  local json
  json="$(_jira_fetch_raw "$key")" || return 1
  printf '%s' "$json" | jq -r "${_JIRA_ADF_JQ}"
}

# jira_slug_for <ISSUE-KEY> — emit a lowercased slug (max 50 chars) from the summary.
jira_slug_for() {
  local key="${1:-}"
  if [ -z "$key" ]; then
    echo "ERROR: jira_slug_for requires an issue key" >&2
    return 1
  fi
  local json
  json="$(_jira_fetch_raw "$key")" || return 1
  printf '%s' "$json" | jq -r "${_JIRA_SLUG_JQ}"
}

# jira_summary_for <ISSUE-KEY> — emit just the summary string.
jira_summary_for() {
  local key="${1:-}"
  if [ -z "$key" ]; then
    echo "ERROR: jira_summary_for requires an issue key" >&2
    return 1
  fi
  local json
  json="$(_jira_fetch_raw "$key")" || return 1
  printf '%s' "$json" | jq -r '.fields.summary'
}

# jira_normalize_key <KEY> — uppercase the project prefix, validate shape.
jira_normalize_key() {
  local key="${1:-}"
  key="$(printf '%s' "$key" | tr '[:lower:]' '[:upper:]')"
  if ! [[ "$key" =~ ^[A-Z]+-[0-9]+$ ]]; then
    echo "ERROR: '${1:-}' is not a valid Jira issue key (expected e.g. FXA-1234)" >&2
    return 1
  fi
  printf '%s\n' "$key"
}

# Clean up cache on shell exit
trap 'rm -rf "${_JIRA_CACHE_DIR}" 2>/dev/null' EXIT
