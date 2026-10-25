#!/usr/bin/env bash
# Offline check that a service-account Jira login sends acli's calls to the API gateway.
#   bash lib/jira-sa.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
command -v jq >/dev/null || { echo "skip: needs jq"; exit 0; }
root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/jira-sa.XXXXXX")"; export TMPDIR="$tmp"
source "$root/lib/config.sh"; source "$root/lib/jira.sh"
trap 'rm -rf "$tmp"' EXIT
CID=d8febd08-0000-4c03-9c13-db37c2369ce5 G="https://api.atlassian.com/ex/jira/d8febd08-0000-4c03-9c13-db37c2369ce5"
# The stub logs "METHOD URL DATA" and the login it read on stdin, and answers by URL.
curl() {
  local m=GET d="" u="" login=""
  while [ $# -gt 0 ]; do case "$1" in -X) m="$2"; shift ;; --data|--data-urlencode) d="$2"; shift ;; -K) login="$(cat)" ;; -H|--max-time|-o|-w) shift ;; -*) ;; *) u="$1" ;; esac; shift; done
  printf '%s %s %s\n' "$m" "$u" "$d" >> "$tmp/log"; printf '%s\n' "$login" >> "$tmp/logins"
  case "$m $u" in
    *_edge/tenant_info) echo . >> "$tmp/tenant"; echo "{\"cloudId\":\"$CID\"}" ;;
    "GET $G/rest/api/3/myself") echo '{"displayName":"svc"}' ;;
    "GET $G/rest/api/3/issue/FXA-1?fields=issuetype,summary,status,description") echo '{"key":"FXA-1","fields":{"issuetype":{"name":"Bug"},"summary":"Fix it","status":{"name":"New"},"description":{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"a"},{"type":"hardBreak"},{"type":"text","text":"b"}]},{"type":"paragraph","content":[{"type":"mention","attrs":{"text":"@Dev"}}]}]}}}' ;;
    "GET $G/rest/api/3/issue/FXA-1?fields=labels,status") echo '{"key":"FXA-1","fields":{"labels":["x"]}}' ;;
    "GET $G/rest/api/3/issue/FXA-1/comment?maxResults=50") echo '{"startAt":0,"maxResults":50,"total":1,"comments":[{"id":"7","author":{"displayName":"Dev One"},"body":{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"🤖 hi"}]}]}}]}' ;;
    "POST $G/rest/api/3/search/jql")
      if [[ "$d" == *nextPageToken* ]]; then echo '{"issues":[{"key":"FXA-3"}]}'; else echo '{"issues":[{"key":"FXA-1"},{"key":"FXA-2"}],"nextPageToken":"t2"}'; fi ;;
    "GET $G/rest/api/3/issue/FXA-1/transitions") echo '{"transitions":[{"id":"11","name":"Start","to":{"name":"In Progress"}},{"id":"31","name":"Close","to":{"name":"Done"}}]}' ;;
    "GET $G/rest/api/3/user/search") echo '[{"accountId":"acc-1"}]' ;;
    "GET $G/rest/agile/1.0/board/225/sprint?state=active") echo '{"values":[{"id":5,"name":"FxA 1"}],"isLast":true,"maxResults":50,"startAt":0}' ;;
    "POST $G/rest/api/3/issue") echo '{"id":"9","key":"FXA-9"}' ;;
    "POST "*|"PUT "*) echo '{}' ;;
    *) return 22 ;;
  esac
}
command() { [ "$1" = acli ] && { echo "real acli ran" >> "$tmp/log"; return 1; }; builtin command "$@"; }
export PIPE_JIRA_BASIC="svc-x@serviceaccount.atlassian.com:tok-secret"

check "auth status says Authenticated" "1" "$(jira_login_ok && echo 1)"
check "the text view is acli's" "Key: FXA-1|Type: Bug|Summary: Fix it|Status: New|Description: a|b|@Dev" "$(acli jira workitem view FXA-1 | tr '\n' '|' | sed 's/|$//')"
check "a json view asks for the fields" '["x"]' "$(acli jira workitem view FXA-1 --fields labels,status --json | jq -c .fields.labels)"
check "comments come back as acli's text" '{"author":"Dev One","body":"🤖 hi","id":"7"}' "$(acli jira workitem comment list --key FXA-1 --json | jq -c '.comments[0] | {author, body, id}')"
check "search follows pages up to the limit" "FXA-1 FXA-2 FXA-3" "$(_jira_keys_for_jql 'project = FXA' | tr '\n' ' ' | sed 's/ $//')"
: > "$tmp/log"; acli jira workitem search --jql 'q' --limit 2 --fields key,summary --json >/dev/null
check "a limit that one page fills reads one page" "1" "$(grep -c search/jql "$tmp/log")"
check "the search sends its fields" '["key","summary"]' "$(sed -n 's/.*search\/jql //p' "$tmp/log" | jq -c .fields)"
: > "$tmp/log"; acli jira workitem edit -k FXA-1 --remove-labels "a,b" -l c -y
check "a label swap removes then adds" '[{"remove":"a"},{"remove":"b"},{"add":"c"}]' "$(sed -n "s|^PUT $G/rest/api/3/issue/FXA-1 ||p" "$tmp/log" | jq -c .update.labels)"
: > "$tmp/log"; acli jira workitem edit -k FXA-1 --assignee "dev@example.com" -y
check "an assignee by email is set by account ID" '{"accountId":"acc-1"}' "$(sed -n "s|^PUT $G/rest/api/3/issue/FXA-1/assignee ||p" "$tmp/log")"
: > "$tmp/log"; acli jira workitem transition --key FXA-1 --status Done -y
check "a transition to Done uses its ID" '{"transition":{"id":"31"}}' "$(sed -n "s|^POST $G/rest/api/3/issue/FXA-1/transitions ||p" "$tmp/log")"
check "a status with no transition fails" "1" "$(acli jira workitem transition --key FXA-1 --status Nope -y 2>/dev/null; echo $?)"
: > "$tmp/log"; pipeline_require() { :; }; jira_comment FXA-1 $'🤖 one\ntwo'
check "a comment is one paragraph, as acli posts it" '[{"type":"paragraph","content":[{"type":"text","text":"🤖 one\ntwo"}]}]' "$(sed -n "s|^POST $G/rest/api/3/issue/FXA-1/comment ||p" "$tmp/log" | jq -c .body.content)"
printf 'the PR\nline 2\n' > "$tmp/desc"
check "create prints the new key" "FXA-9" "$(acli jira workitem create --project FXA --type Task --summary S --description-file "$tmp/desc" --label agent-session --json | jq -r .key)"
check "create sends project, type, label and description" 'FXA|Task|["agent-session"]|the PR\nline 2' "$(sed -n "s|^POST $G/rest/api/3/issue ||p" "$tmp/log" | jq -r '[.fields.project.key, .fields.issuetype.name, (.fields.labels | tostring), (.fields.description.content[0].content[0].text | gsub("\n"; "\\n"))] | join("|")')"
check "the active sprints read as acli's" '[{"id":5,"name":"FxA 1"}]' "$(acli jira board list-sprints --id 225 --state active --json | jq -c '[.sprints[] | {id, name}]')"
check "an unknown subcommand fails" "1" "$(acli jira project list >/dev/null 2>&1; echo $?)"
check "real acli never ran" "0" "$(grep -c 'real acli' "$tmp/log")"
check "every call went to the gateway or the tenant info" "0" "$(grep -v "$G\|_edge/tenant_info" "$tmp/log" | grep -c .)"
check "the login went on stdin, never in a URL or body" "0|1" "$(grep -c tok-secret "$tmp/log")|$(grep -q 'user = "svc-x@serviceaccount.atlassian.com:tok-secret"' "$tmp/logins" && echo 1)"
check "the cloud ID is read once" "1" "$(grep -c . "$tmp/tenant")"

# A normal account keeps acli and the site.
export PIPE_JIRA_BASIC="dev@example.com:tok"
check "a user login keeps the site" "https://mozilla-hub.atlassian.net" "$(_jira_api)"
: > "$tmp/log"; acli jira workitem view FXA-1 >/dev/null
check "a user login runs real acli" "1" "$(grep -c 'real acli' "$tmp/log")"
exit "$fail"
