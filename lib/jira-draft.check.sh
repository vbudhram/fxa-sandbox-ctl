#!/usr/bin/env bash
# Offline check that a Jira draft from a session is checked, frozen, and filed once, only with the sha shown.
#   bash lib/jira-draft.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
command -v jq >/dev/null && command -v python3 >/dev/null || { echo "skip: needs jq and python3"; exit 0; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
here="$(cd "$(dirname "$0")" && pwd)"
eval "$(sed -n '/^_session_jira_project() {/,/^}/p' "$here/session.sh")"
eval "$(sed -n '/^_SESSION_JIRA_DRAFTS_MAX=/,/^# session_review_ack/p' "$here/session.sh" | sed '$d')"
SESSION_DIR="$tmp" SANDBOX_ROOT="$here/.." FXA_JIRA_DRAFTS=1 PIPE_PROFILE=fxa
session_get() { jq -r --arg f "$2" '.[$f] // empty' "$tmp/$1.json" 2>/dev/null; }
session_set() { [ -f "$tmp/$1.json" ] || echo '{}' > "$tmp/$1.json"; jq --arg k "$2" --arg v "$3" '.[$k] = $v' "$tmp/$1.json" > "$tmp/s" && mv "$tmp/s" "$tmp/$1.json"; }
worktree_branch_for() { echo "$1"; }
vm_exec_as_agent() { printf '%s' "${DRAFT:-}"; }
_jira_sa() { return 1; }
_session_history_add() { echo "$3" >> "$tmp/history"; }
errors_record() { :; }
_acli_once() {
  echo "$*" >> "$tmp/acli"
  case "$*" in
    *"workitem create"*) [ -n "${CREATE_FAILS:-}" ] && return 1; cp "$(sed -n 's/.*--description-file \([^ ]*\).*/\1/p' <<< "$*")" "$tmp/desc"; echo '{"key":"FXA-900"}' ;;
    *"workitem search"*) echo '[{"key":"FXA-1","fields":{"summary":"Sign-in timeout on slow networks"}}]' ;;
    *"--status Won't Do"*) return 1 ;;
  esac
}
creates() { grep -c 'workitem create' "$tmp/acli" 2>/dev/null || true; }
good='{"type":"Bug","summary":"Sign-in times out on slow networks","description":"The auth client waits 5 s (lib/x.ts:12)."}'

out="$(DRAFT="$good" session_jira_draft agent-a1)"
sha="$(jq -r .sha <<< "$out")"
check "a good draft is frozen with its project, a sha and the likely duplicates" "FXA|Bug|yes|FXA-1" \
  "$(jq -r '[.project, .type] | join("|")' <<< "$out")|$([[ "$sha" =~ ^[0-9a-f]{64}$ ]] && echo yes)|$(jq -r '.dups[0].key' <<< "$out")"
check "a person's edit on stdin is checked the same way" "Task" \
  "$(printf '%s' '{"type":"Task","summary":"Keep the email field","description":"x"}' | session_jira_draft agent-e1 --stdin | jq -r .type)"
refused() { DRAFT="$1" session_jira_draft "agent-r$2" >/dev/null 2>&1 && echo filed || echo refused; }
check "bad drafts are refused" "refused|refused|refused|refused|refused|refused|refused" \
  "$(refused '{"type":"Epic","summary":"abc def","description":""}' 1)|$(refused "{\"type\":\"Task\",\"summary\":\"$(printf 'x%.0s' $(seq 201))\"}" 2)|$(refused '{"type":"Task","summary":"ok summary","description":"a\u0007b"}' 3)|$(refused '{"type":"Task","summary":"leak","description":"token ghp_abcdefghijklmnop"}' 4)|$(refused '{"type":"Task","summary":"leak","description":"fxl_abcdefghijklmnop"}' 5)|$(refused '{"type":"Task","summary":"forged","description":"x\nFiled from Slack by Someone Else."}' 6)|$(refused 'not json' 7)"
check "a secret team, drafts turned off, and no project refuse" "refused|refused|refused" \
  "$(PIPE_SECRET_TICKETS=1 refused "$good" 8)|$(FXA_JIRA_DRAFTS= refused "$good" 9)|$(PIPE_PROFILE=other refused "$good" 10)"
for i in 1 2 3 4 5; do DRAFT="$good" session_jira_draft agent-r-cap >/dev/null 2>&1; done
check "a session makes at most 5 drafts" "refused" "$(refused "$good" -cap)"

check "a wrong sha files nothing, and keeps the draft" "1|0|yes" \
  "$(session_jira_file agent-a1 "$(printf 'f%.0s' $(seq 64))" U1 'Pat Doe' >/dev/null 2>&1; echo $?)|$(creates)|$([ -f "$tmp/agent-a1.jira-draft.json" ] && echo yes)"
check "the right sha files once, as the person, and records it" "FXA-900|1|FXA-900|yes" \
  "$(session_jira_file agent-a1 "$sha" U1 'Pat Doe' pat@example.com)|$(creates)|$(session_get agent-a1 jira)|$(tail -1 "$tmp/desc" | grep -qx 'Filed from Slack by Pat Doe.' && echo yes)"
check "a second tap files nothing" "1|1" "$(session_jira_file agent-a1 "$sha" U1 'Pat Doe' >/dev/null 2>&1; echo $?)|$(creates)"
check "the labels: agent-session, and ai-fixme only when asked" "yes|yes" \
  "$(grep 'workitem create' "$tmp/acli" | tail -1 | grep -q -- '--label agent-session --json' && echo yes)|$(sha2="$(DRAFT="$good" session_jira_draft agent-q1 | jq -r .sha)"; session_jira_file agent-q1 "$sha2" U1 Pat --fixme >/dev/null; grep 'workitem create' "$tmp/acli" | tail -1 | grep -q -- '--label agent-session,ai-fixme' && echo yes)"
sha3="$(DRAFT="$good" session_jira_draft agent-f1 | jq -r .sha)"
check "a failed create says so and records nothing" "1|no" \
  "$(CREATE_FAILS=1 session_jira_file agent-f1 "$sha3" U1 Pat >/dev/null 2>&1; echo $?)|$([ -s "$tmp/agent-f1.jira-filed" ] && echo yes || echo no)"

check "undo closes the ticket with the first status the project has" "0|yes" \
  "$(session_jira_undo agent-a1 FXA-900 Pat >/dev/null 2>&1; echo $?)|$(grep -q "transition --key FXA-900 --status Won't Fix" "$tmp/acli" && echo yes)"
check "undo, edit and queue refuse a ticket this session did not file" "1|1|1" \
  "$(session_jira_undo agent-a1 FXA-1 Pat >/dev/null 2>&1; echo $?)|$(echo "$good" | session_jira_edit agent-a1 FXA-1 >/dev/null 2>&1; echo $?)|$(session_jira_queue agent-a1 FXA-1 >/dev/null 2>&1; echo $?)"
printf 'FXA-901\t%s\tU1\tPat\n' "$(( $(date +%s) - 700 ))" >> "$tmp/agent-a1.jira-filed"
check "undo works for 10 minutes only" "1" "$(session_jira_undo agent-a1 FXA-901 Pat >/dev/null 2>&1; echo $?)"
check "an edit keeps the trailer, and a queue adds the label" "yes|yes" \
  "$(echo "$good" | session_jira_edit agent-a1 FXA-900 >/dev/null && grep -q 'workitem edit --key FXA-900 --type Bug --summary Sign-in times out on slow networks' "$tmp/acli" && echo yes)|$(session_jira_queue agent-a1 FXA-900 >/dev/null && grep -q 'edit --key FXA-900 --labels ai-fixme' "$tmp/acli" && echo yes)"
exit "$fail"
