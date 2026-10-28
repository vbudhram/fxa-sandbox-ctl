#!/usr/bin/env bash
# The Sandboxes page's feed fields: a pipeline stats row's end, prn and prr, and the agents feed's fc_state.
#   bash lib/snapshot-sb.check.sh
set -u
here="$(cd "$(dirname "$0")" && pwd)"; fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want [$2] got [$3]"; fail=1; fi; }
eval "$(sed -n "/^_STATS_RUN_ROW='/,/};'\$/p" "$here/snapshot.sh")"
eval "$(sed -n '/^_fc_state() {/,/^}/p' "$here/snapshot.sh")"
row() { jq -c "$_STATS_RUN_ROW runrow" <<< "$1"; }
r="$(row '{"recorded_at":"2026-10-16T22:23:20Z","issue":"EX-1","kind":"fix","cost_usd":3.86,"wall_seconds":1800,"launched_at":1792187901,"pr":"https://github.com/example/repo/pull/41"}')"
check "a run with launched_at and wall_seconds ends at their sum, and the row sends its PR number (a PR's cost still counts each row once)" "1792189701|41" "$(jq -r '"\(.end)|\(.prn)"' <<< "$r")"
check "the old keys and src stay" "pipeline|EX-1|fix|30|true" "$(jq -r '"\(.src)|\(.key)|\(.kind)|\(.min)|\(.pr)"' <<< "$r")"
r="$(row '{"recorded_at":"2026-10-16T22:23:20Z","issue":"EX-2","kind":"fix","wall_seconds":0}')"
check "a run with no launched_at ends at recorded_at" "1792189400|false" "$(jq -r '"\(.end)|\(.pr)"' <<< "$r")"
check "fc_state none with no host" "none" "$(FXA_FC_HOST= _fc_state)"
check "fc_state up" "up" "$(_fc_up() { return 0; }; FXA_FC_HOST=10.0.0.9 _fc_state)"
check "fc_state down" "down" "$(_fc_up() { return 1; }; FXA_FC_HOST=10.0.0.9 _fc_state)"
check "a pipeline run's stats row keeps its PR number and repo; no PR gives nulls" "2707|mozilla-services/syncstorage-rs|null|null" \
  "$(row '{"issue":"STOR-460","pr":"https://github.com/mozilla-services/syncstorage-rs/pull/2707"}' | jq -r '"\(.prn)|\(.prr)"')|$(row '{"issue":"FXA-1","pr":""}' | jq -r '"\(.prn)|\(.prr)"')"
eval "$(sed -n '/^_pipeline_prs() {/,/^}/p' "$here/snapshot.sh")"
# The fake GitHub: the label list has #10 and #8; the plain list has the App's #12 and #10, a person's #11.
gh() { case "$*" in *--label*) echo '[{"number":10},{"number":8}]' ;; *) echo '[{"number":12,"author":{"login":"app/fxa-agent"}},{"number":11,"author":{"login":"someone"}},{"number":10,"author":{"login":"app/fxa-agent"}}]' ;; esac; }
check "pipeline PRs: the label's in their order, then the App's not already listed, a person's PR left out" "[10,8,12]" "$(_pipeline_prs merged 30 number | jq -c 'map(.number)')"
check "pipeline PRs: the limit holds" "[10,8]" "$(_pipeline_prs merged 2 number | jq -c 'map(.number)')"
gh() { return 1; }
check "pipeline PRs: both reads failed is a failure, not an empty list" "1" "$(_pipeline_prs merged 30 number >/dev/null; echo $?)"
unset -f gh
grep -q 'fc_state: \$fcs' "$here/snapshot.sh" && grep -q 'firecracker_host: \$fc,' "$here/snapshot.sh"; check "the agents feed sends fc_state and keeps firecracker_host" 0 $?
exit $fail
