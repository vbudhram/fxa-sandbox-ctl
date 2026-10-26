#!/usr/bin/env bash
# Offline check that every PR read by branch name skips a fork PR from a branch with the key's name.
# Covers lib/github.sh (gh_pr_approver, gh_red_infra, gh_gate_stuck, gh_pr_states_json, the feedback
# PR lookup) and lib/finish.sh (the existing-PR lookups). No network.
#   bash lib/fork-pr.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
command -v jq >/dev/null || { echo "skip: needs jq"; exit 0; }
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$tmp"' EXIT

eval "$(sed -n "/^read -r -d '' _GH_ROLLUP_JQ/,/^JQ$/p" "$here/github.sh")"
eval "$(sed -n '/^gh_pr_approver() {/,/^}/p;/^gh_red_infra() {/,/^}/p;/^gh_gate_stuck() {/,/^}/p;/^gh_pr_states_json() {/,/^}/p' "$here/github.sh")"
pipeline_require() { :; }; worktree_branch_for() { printf '%s\n' "$1" | tr 'A-Z' 'a-z'; }
export PIPE_REPO_SLUG=mozilla/fxa PIPE_STATE_DIR="$tmp" PIPE_INFRA_CHECKS='ci=Bad credentials'
old='"2020-01-01T00:00:00Z"'
# The newest PR first, as gh lists them: a stranger's fork PR, then ours.
cat > "$tmp/prs.json" <<JSON
[{"number":9,"isCrossRepository":true,"headRefName":"fxa-7","url":"https://github.com/mozilla/fxa/pull/9","headRefOid":"f0","state":"OPEN",
  "reviews":[{"state":"APPROVED","author":{"login":"stranger"}}],
  "statusCheckRollup":[{"name":"Approve Functional Tests","status":"PENDING"}],"commits":[{"committedDate":$old}]},
 {"number":8,"isCrossRepository":false,"headRefName":"fxa-7","url":"https://github.com/mozilla/fxa/pull/8","headRefOid":"a8","state":"OPEN",
  "reviews":[{"state":"APPROVED","author":{"login":"owner"}}],
  "statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"FAILURE","detailsUrl":"https://x/runs/1/job/2"}],"commits":[{"committedDate":"2999-01-01T00:00:00Z"}]}]
JSON
# A fake gh: pr list prints the list (first N with --limit), -q runs jq as gh does; run view prints the log.
mkdir -p "$tmp/bin"; cat > "$tmp/bin/gh" <<'SH'
#!/usr/bin/env bash
[ "$1 $2" = "run view" ] && { echo "Error: Bad credentials"; exit 0; }
q=""; n=100; while [ $# -gt 0 ]; do case "$1" in -q) q="$2"; shift ;; --limit) n="$2"; shift ;; esac; shift; done
j="$(jq -c --argjson n "$n" '.[:$n]' "$FAKE_PRS")"
if [ -n "$q" ]; then jq -r "$q" <<< "$j"; else printf '%s\n' "$j"; fi
SH
chmod +x "$tmp/bin/gh"; export PATH="$tmp/bin:$PATH" FAKE_PRS="$tmp/prs.json"

check "gh_pr_approver: the approver of our PR, not of the fork's" "owner" "$(gh_pr_approver FXA-7)"
check "gh_red_infra: reads our PR's red check, at our head" "ci(Bad credentials)|a8" "$(gh_red_infra FXA-7)|$(head -1 "$tmp/FXA-7.redinfra")"
check "gh_gate_stuck: the fork's stuck gate is not ours (no url, a nonzero exit)" "|1" "$(gh_gate_stuck FXA-7)|$(gh_gate_stuck FXA-7 >/dev/null && echo 0 || echo 1)"
check "gh_pr_states_json: our PR for the branch, even when a fork PR is newer" "8" "$(gh_pr_states_json FXA-7 | jq -r '.[0].pr')"

# The feedback PR lookup and the finish lookups use the same filter as gh's -q.
for f in github.sh finish.sh; do
  grep -oE "\-q '[^']*isCrossRepository[^']*'" "$here/$f" | sed -E "s/^-q '(.*)'$/\1/" | while IFS= read -r q; do
    got="$(jq -r "$q" "$tmp/prs.json")"
    case "$q" in *url*) want="https://github.com/mozilla/fxa/pull/8" ;; *) want=8 ;; esac
    check "$f lookup [$q] takes our PR" "$want" "$got"
  done
done
check "every PR read by --head asks for isCrossRepository" "" \
  "$(cat "$here/github.sh" "$here/finish.sh" | grep -A2 -- 'gh pr list.*--head' | grep -- '--json' | grep -v isCrossRepository)"
exit $fail
