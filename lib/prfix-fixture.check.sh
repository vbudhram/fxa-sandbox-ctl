#!/usr/bin/env bash
# Offline check of the shared dependency PR fixture (lib/testdata/prfix): each file parses and has the fields the
# sweep, finish and prfix_report read, and the fake gh serves them by path and logs each call.
#   bash lib/prfix-fixture.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fx="$(cd "$(dirname "$0")" && pwd)/testdata/prfix" api="repos/mozilla/fxa"
export PATH="$fx/bin:$PATH" PRFIX_GH_LOG="$tmp/log"
bad=""; for f in $(find "$fx" -name '*.json' | sort); do jq empty "$f" 2>/dev/null || bad="$bad ${f#$fx/}"; done
check "every JSON file parses" "" "$bad"
# The PR fields the sweep and the checkout read, and red in both check shapes: a check run's conclusion, a status's state.
check "each PR has the fields the sweep reads" "6" "$(cat "$fx"/pr/*.json | jq -s '[.[] | select((.number | type) == "number" and (.headRefOid | test("^[0-9a-f]{40}$"))
  and (.headRefName | type) == "string" and .baseRefName == "main" and (.isCrossRepository | type) == "boolean" and (.author.login | type) == "string"
  and (.labels | all(.name | type == "string")) and (.statusCheckRollup | length > 0))] | length')"
red='[.statusCheckRollup[] | if .__typename == "CheckRun" then (if .status != "COMPLETED" then "pending" elif (.conclusion | IN("FAILURE", "TIMED_OUT", "CANCELLED")) then "red" else "ok" end)
  else (if .state == "PENDING" or .state == "EXPECTED" then "pending" elif (.state | IN("FAILURE", "ERROR")) then "red" else "ok" end) end]
  | if index("red") then "red" elif index("pending") then "pending" else "green" end'
check "red by a check run, red by a status, pending, green, a timed-out bot branch with '@', a cancelled fork" \
  "90001 red CheckRun|90002 red StatusContext|90003 pending|90004 green|90005 red blender/security-bump-@opentelemetry/x|90006 red fork" \
  "$(for n in 90001 90002 90003 90004 90005 90006; do jq -r --arg n "$n" "\"\(\$n) \" + ($red) + (if \$n == \"90001\" then \" CheckRun\" elif \$n == \"90002\" then \" StatusContext\" elif \$n == \"90005\" then \" \" + .headRefName elif .isCrossRepository then \" fork\" else \"\" end)" "$fx/pr/$n.json"; done | paste -sd'|' -)"
check "the timeline: each labeled event has a User actor, a label name and a time; the writer's agent-help is on page 2" "6|example-writer agent-help 2026-10-24T10:00:00Z" \
  "$(cat "$fx/api/$api"/issues/*/timeline*.json | jq -s '[.[][] | select(.event == "labeled" and .actor.type == "User" and (.label.name | type) == "string" and (.created_at | type) == "string")] | length')|$(jq -r '.[] | "\(.actor.login) \(.label.name) \(.created_at)"' "$fx/api/$api/issues/90001/timeline.page2.json")"
check "the comments: a BLEnder Bot comment, the same text from a User, a User marker, an App marker" \
  "mozilla-blender[bot] Bot - no|example-triage User - no|example-triage User - marker|example-fxa-app[bot] Bot 123456 marker" \
  "$(cat "$fx/api/$api/issues/90002/comments.json" "$fx/api/$api/issues/90001/comments.json" | jq -rs '[.[][] | select((.id | type) == "number" and (.created_at | type) == "string")
    | "\(.user.login) \(.user.type) \(.performed_via_github_app.id // "-") \(if (.body | contains("<!-- fxa-agent:pr-fix -->")) then "marker" else "no" end)"] | join("|")')"
check "permission: write, triage" "write write|read triage" \
  "$(jq -r '"\(.permission) \(.role_name)"' "$fx/api/$api/collaborators/example-writer/permission.json")|$(jq -r '"\(.permission) \(.role_name)"' "$fx/api/$api/collaborators/example-triage/permission.json")"
check "each head commit has its committer date" "6" "$(cat "$fx/api/$api"/commits/*.json | jq -s '[.[] | select(.commit.committer.date == "2026-10-24T09:00:00Z")] | length')"

# The fake gh.
check "gh pr list: open PRs of one author, newest first, in either login form, with --json and --jq" "90006,90004,90003,90002,90001|90005|90003,90001" \
  "$(gh pr list -R mozilla/fxa --author 'dependabot[bot]' --json number,statusCheckRollup --jq '[.[].number] | join(",")')|$(gh pr list --author app/mozilla-blender --json number --jq '.[].number')|$(gh pr list --author dependabot --label agent-help --json number --jq '[.[] | select(.number < 90004) | .number] | join(",")')"
check "gh pr view: by number or URL, only the --json fields" "blender/security-bump-@opentelemetry/x|headRefName,number" \
  "$(gh pr view https://github.com/mozilla/fxa/pull/90005 --json headRefName --jq .headRefName)|$(gh pr view 90005 --json number,headRefName | jq -r 'keys | join(",")')"
check "gh api: one page, or both with --paginate" "4|5" \
  "$(gh api "$api/issues/90001/timeline?per_page=100" | jq length)|$(gh api --paginate "$api/issues/90001/timeline?per_page=100" | jq -s 'add | length')"
out="$(gh api "$api/collaborators/example-outsider/permission" 2>"$tmp/err")"; rc=$?
check "gh api: a 404 answers as gh does" "1|Not Found|gh: Not Found (HTTP 404)" "$rc|$(jq -r .message <<< "$out")|$(cat "$tmp/err")"
check "gh api: --jq, and a path with no file is a 404" "write|1" \
  "$(gh api "/$api/collaborators/example-writer/permission" --jq .permission)|$(gh api "$api/pulls/1" >/dev/null 2>&1; echo $?)"
echo '{"body":"x"}' | gh api -X PATCH "$api/issues/comments/7001" --input - >/dev/null
check "gh logs each call, with the --input body" "11|api -X PATCH $api/issues/comments/7001 --input - <<< {\"body\":\"x\"}" \
  "$(wc -l < "$tmp/log" | tr -d ' ')|$(tail -1 "$tmp/log")"
