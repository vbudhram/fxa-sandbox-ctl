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
check "a run with launched_at and wall_seconds ends at their sum" "1792189701|41|example/repo" "$(jq -r '"\(.end)|\(.prn)|\(.prr)"' <<< "$r")"
check "the old keys and src stay" "pipeline|EX-1|fix|30|true" "$(jq -r '"\(.src)|\(.key)|\(.kind)|\(.min)|\(.pr)"' <<< "$r")"
r="$(row '{"recorded_at":"2026-10-16T22:23:20Z","issue":"EX-2","kind":"fix","wall_seconds":0}')"
check "a run with no launched_at ends at recorded_at, with no PR" "1792189400|null|null|false" "$(jq -r '"\(.end)|\(.prn)|\(.prr)|\(.pr)"' <<< "$r")"
check "fc_state none with no host" "none" "$(FXA_FC_HOST= _fc_state)"
check "fc_state up" "up" "$(_fc_up() { return 0; }; FXA_FC_HOST=10.0.0.9 _fc_state)"
check "fc_state down" "down" "$(_fc_up() { return 1; }; FXA_FC_HOST=10.0.0.9 _fc_state)"
grep -q 'fc_state: \$fcs' "$here/snapshot.sh" && grep -q 'firecracker_host: \$fc,' "$here/snapshot.sh"; check "the agents feed sends fc_state and keeps firecracker_host" 0 $?
exit $fail
