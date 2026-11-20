#!/usr/bin/env bash
# session host-write (lib/asks.sh): a quick look's Jira comment, PR comment or new PR body. Who may ask, the scope,
# the words gate, and one write with a read back. gh and acli are stubbed; the call counts go to files.
#   bash lib/host-write.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
command -v jq >/dev/null && command -v python3 >/dev/null || { echo "skip: needs jq and python3"; exit 0; }
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
source "$here/config.sh"
export FXA_SESSION_STORE_URI="" FXA_SESSION_BACKUP_URI=""
FXA_SESSION_DIR="$tmp" source "$here/session.sh"
source "$here/trees.sh"
source "$here/turn-words.sh"
source "$here/asks.sh"
eval "$(sed -n '/^gh_pr_comment() {/,/^}/p;/^gh_pr_body_set() {/,/^}/p' "$here/github.sh")"
eval "$(sed -n '/^_finish_pii_guard() {/,/^}/p' "$here/finish.sh")"
eval "$(sed -n '/^jira_comment() {/,/^}/p' "$here/jira.sh")"
SESSION_DIR="$tmp" FINISH_LIB_DIR="$here" JIRA_LIB_DIR="$here"
_session_db_sync() { :; }
pipeline_require() { :; }; _jira_sa() { return 1; }
PIPE_PROFILE=fxa PIPE_REPO_SLUG=mozilla/fxa PIPE_JIRA_PROJECT=FXA FXA_TEAMS_DIR="$tmp/teams"
mkdir -p "$FXA_TEAMS_DIR"
cat > "$FXA_TEAMS_DIR/fxa.json" <<'EOF'
{"name": "fxa", "admins": [{"slack": "UADMINX1", "email": "admin1@example.com"}],
 "people": [{"slack": "UADMINX2", "admin": true, "github": "bo-gh"}, {"slack": "UPLAIN01", "github": "cy-gh"}]}
EOF
github_app_enabled() { :; }; github_app_token() { echo "tok-${PIPE_REPO_SLUG}"; }; github_app_login() { echo 'fxa-agent[bot]'; }
acli() { echo acli >> "$tmp/calls"; [ -z "${ACLI_FAIL:-}" ]; }
gh() {
  case "$*" in
    *full_name*) echo "mozilla/fxa ${AUTHOR:-fxa-agent[bot]}" ;;
    "api -X POST "*) echo post >> "$tmp/calls"; cat > "$tmp/body"; [ -z "${POST_FAIL:-}" ] || return 1; echo https://github.com/mozilla/fxa/pull/5#issuecomment-1 ;;
    "api --paginate "*) echo readback >> "$tmp/calls"; cat "$tmp/list" 2>/dev/null || echo '[]' ;;
    "api -X PATCH "*) echo patch >> "$tmp/calls"; cat > "$tmp/prbody" ;;
    *) cat "$tmp/prbody" 2>/dev/null ;;
  esac
}
PR=https://github.com/mozilla/fxa/pull/5
w() { jq -nc --arg o "$1" --arg t "$2" --arg b "${3:-Looks good.}" '{op: $o, body: $b} + (if $o == "jira-comment" then {key: $t} else {url: $t} end)'; }
# hw <json> <by> <words or --confirmed>   Prints "rc|stdout|stderr|calls".
hw() {
  : > "$tmp/calls"
  local out rc=0
  if [ "$3" = --confirmed ]; then out="$(printf '%s' "$1" | session_host_write agent-abcd "$2" "" 1 2>"$tmp/err")" || rc=$?
  else out="$(printf '%s' "$1" | session_host_write agent-abcd "$2" "$3" 0 2>"$tmp/err")" || rc=$?; fi
  echo "${rc}|${out}|$(cat "$tmp/err")|$(paste -sd, "$tmp/calls")"
}

check "an admin whose words name it posts one PR comment, with the AI-agent footer" \
  "0|{\"ok\":true,\"url\":\"$PR#issuecomment-1\",\"op\":\"pr-comment\"}||post|Looks good.||_This comment is from an AI agent._" \
  "$(hw "$(w pr-comment $PR)" UADMINX1 "comment on PR 5: looks good")|$(paste -sd'|' "$tmp/body")"
check "an admin whose words do not name the target gets needs-confirm and nothing runs" "3||needs-confirm|" \
  "$(hw "$(w pr-comment $PR)" UADMINX1 "comment on PR 6 please")"
check "a team admin's tap (confirmed) runs it without words" "0|post" "$(hw "$(w pr-comment $PR)" UADMINX2 --confirmed | cut -d'|' -f1,4)"
check "a person who is not a team admin is refused, even with naming words" "1||refused: only a team admin of fxa can ask for this.|" \
  "$(hw "$(w pr-comment $PR)" UPLAIN01 "comment on PR 5")"
check "a PR outside the team's work repos is refused" "1||refused: other/repo is not a work repo of team fxa.|" \
  "$(hw "$(w pr-comment https://github.com/other/repo/pull/5)" UADMINX1 "comment on other/repo#5")"
check "a key outside the team's Jira project is refused" "1||refused: MOZ-12 is not a ticket of the FXA project.|" \
  "$(hw "$(w jira-comment MOZ-12)" UADMINX1 "comment on MOZ-12")"
check "a Jira comment named by the words goes through acli once" \
  '0|{"ok":true,"url":"https://mozilla-hub.atlassian.net/browse/FXA-12","op":"jira-comment"}||acli' \
  "$(hw "$(w jira-comment FXA-12)" UADMINX1 "Comment on FXA-12: the fix is in main")"
check "a bad op line is refused" "1||refused: that is not a host write.|" "$(hw '{"op":"merge","body":"x"}' UADMINX1 x)"

# One POST, never a second: a failed reply is read back.
check "a failed post that did not land: one post, one read back, and a failure" "1||failed: GitHub refused the comment on $PR.|post,readback" \
  "$(POST_FAIL=1 hw "$(w pr-comment $PR)" UADMINX1 "comment on PR 5")"
jq -n --arg b $'Looks good.\n\n_This comment is from an AI agent._' --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '[{body: $b, created_at: $t, html_url: "https://github.com/mozilla/fxa/pull/5#issuecomment-9"}]' > "$tmp/list"
check "a failed post that landed: the read back finds it, still one post" "0|post,readback|$PR#issuecomment-9" \
  "$(POST_FAIL=1 hw "$(w pr-comment $PR)" UADMINX1 "comment on PR 5" | cut -d'|' -f1,4)|$(POST_FAIL=1 hw "$(w pr-comment $PR)" UADMINX1 "comment on PR 5" | cut -d'|' -f2 | jq -r .url)"

# A new PR body: only on the App's PRs, or the asker's own when the record maps a GitHub login.
echo 'Old.' > "$tmp/prbody"
check "the App's PR gets the new body, read back" "0|patch|New body." \
  "$(hw "$(w pr-body $PR 'New body.')" UADMINX1 "update the description of PR 5" | cut -d'|' -f1,4)|$(cat "$tmp/prbody")"
check "a person's PR is refused for an admin with no GitHub login, and says why" "1||refused: $PR is by dana; the host changes the description only of its own PRs, since the team record maps no GitHub login to you.|" \
  "$(AUTHOR=dana hw "$(w pr-body $PR 'Other.')" UADMINX1 "update the description of PR 5")"
check "another person's PR is refused for a mapped admin" "1|" "$(AUTHOR=dana hw "$(w pr-body $PR 'Other.')" UADMINX2 "update the description of PR 5" | cut -d'|' -f1,4)"
check "the mapped admin's own PR gets the new body" "0|patch" "$(AUTHOR=Bo-GH hw "$(w pr-body $PR 'Mine.')" UADMINX2 "update the description of PR 5" | cut -d'|' -f1,4)"
check "a body with personal data is refused before any write" "1|" \
  "$(hw "$(w pr-body $PR 'Ping jane.doe@gmail.com')" UADMINX1 "update the description of PR 5" | cut -d'|' -f1,4)"

# The session verb: host: jira-comment <KEY>, through the same gate.
k=agent-abcd
printf '{"key":"%s","state":"active"}\n' "$k" > "$tmp/$k.json"
worktree_branch_for() { echo runner; }; vm_exec_as_agent() { printf 'Found the cause.\n'; }
check "host: jira-comment refuses a key outside the project" "refused: MOZ-1 is not a ticket of the FXA project." "$(asks_gate 1 Ana 'jira-comment MOZ-1')"
: > "$tmp/calls"
check "host: jira-comment posts the comment file once" "done: posted a comment on https://mozilla-hub.atlassian.net/browse/FXA-7|acli" \
  "$(_ask_one $k 1 Ana 'jira-comment FXA-7')|$(paste -sd, "$tmp/calls")"
jq -nc '{user: "Ana", ts: "1.2", text: "comment on FXA-7 with the cause"}' > "$tmp/wd"; words_add "$k" "$tmp/wd" 0
check "an admin's words that name the key allow host: jira-comment, once" "0|1" \
  "$(_asks_words $k 0 'jira-comment FXA-7'; echo $?)|$(_asks_words $k 0 'jira-comment FXA-7'; echo $?)"
check "host: jira-comment gets a card with the body" "Jira FXA-7|Found the cause." \
  "$(_asks_card $k Bo 'jira-comment FXA-7' >/dev/null; asks_card_events $k | jq -r '.[0] | "\(.target)|\(.body)"')"
exit $fail
