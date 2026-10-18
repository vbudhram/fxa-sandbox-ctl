#!/usr/bin/env bash
# Offline check of the Board's facts in the snapshot: why a ticket is blocked, when it was first queued and
# its skip kind, read in one pass for the listed keys only, and joined only to the right rows.
#   bash lib/snapshot-facts.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
command -v jq >/dev/null || { echo "skip: needs jq"; exit 0; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/config.sh"
eval "$(sed -n '/^_snapshot_facts() {/,/^}/p;/^_snapshot_skipped() {/,/^}/p;/^_snapshot_last_pass() {/,/^}/p;/^snapshot_json() {/,/^}/p' "$here/snapshot.sh")"
eval "$(sed -n '/^_pipeline_skipped_row() {/,/^}/p;/^pipeline_skipped() {/,/^}/p' "$here/pipeline.sh")"
PIPE_STATE_DIR="$tmp/s"; mkdir -p "$PIPE_STATE_DIR"; PIPE_NAME=t; PIPE_REPO_SLUG=mozilla/fxa
# Jira and GitHub, stubbed: FXA-5 is blocked; FXA-10 to FXA-12 are queued; FXA-12 has a skip record.
items() { printf '['; local s=""; for k in "$@"; do printf '%s{"key":"%s","summary":"t %s"}' "$s" "$k" "$k"; s=,; done; printf ']'; }
pipeline_require() { :; }; jira_queue_items() { items FXA-10 FXA-11 FXA-12; }; pipeline_queue_jql() { echo q; }; jira_items_json() { jira_queue_items; }
jira_items_in_state() { case "$1" in blocked) items FXA-5 ;; *) echo '[]' ;; esac; }
_snapshot_pool() { echo '[]'; }; _snapshot_instances() { echo '[]'; }; _snapshot_inflight() { echo '[]'; }; _snapshot_telemetry() { echo '{}'; }
gh_pr_states_json() { echo '[]'; }; gh() { echo '[]'; }; gh_red_infra() { echo '[]'; }; worktree_free_slots() { :; }
pipeline_health_json() { echo '{}'; }; pipeline_focus_key() { :; }; pipeline_hold_marker() { echo /nonexistent; }; pipeline_holding_new() { return 1; }
printf '1700000000\toperator\twait for the SRE change\n' > "$PIPE_STATE_DIR/FXA-5.blocked-why"
printf '1700000100\tstalled\t\n' > "$PIPE_STATE_DIR/FXA-6.blocked-why"           # FXA-6 is not blocked in Jira
echo 1700000200 > "$PIPE_STATE_DIR/FXA-10.queued-at"
printf 'fp\t1700000300\t1\tunderspecified: no criteria\n' > "$PIPE_STATE_DIR/FXA-12.skipped"   # an old 4-field record
for n in $(seq 1 300); do echo 1 > "$PIPE_STATE_DIR/OLD-$n.queued-at"; done        # stale files of keys not listed

# jq calls, counted through a wrapper on PATH.
mkdir "$tmp/bin"; printf '#!/bin/sh\necho x >> "%s/jqn"\nexec %s "$@"\n' "$tmp" "$(command -v jq)" > "$tmp/bin/jq"; chmod +x "$tmp/bin/jq"
out="$(PATH="$tmp/bin:$PATH" snapshot_json 2>/dev/null)"; n1="$(wc -l < "$tmp/jqn")"
check "a Jira-blocked ticket has its kind, reason and time" "operator|wait for the SRE change|1700000000" "$(jq -r '.blocked[0].blocked_reason | "\(.kind)|\(.text)|\(.at)"' <<< "$out")"
check "a reason file of a ticket Jira does not list as blocked never shows" "0" "$(grep -c 'FXA-6' <<< "$out")"
check "only the ready ticket with a file has queued_at" "1700000200|null" "$(jq -r '[.queue.ready[] | .queued_at] | map(tostring) | join("|")' <<< "$out")"
check "an old skip record gets its kind from the reason" "underspecified" "$(jq -r '.queue.skipped[0].kind' <<< "$out")"
rm "$PIPE_STATE_DIR/FXA-5.blocked-why"
check "no reason file: blocked in Jira" "jira|blocked in Jira|null" "$(snapshot_json 2>/dev/null | jq -r '.blocked[0].blocked_reason | "\(.kind)|\(.text)|\(.at)"')"
rm -f "$PIPE_STATE_DIR"/OLD-*.queued-at "$tmp/jqn"; printf '1700000000\toperator\tx\n' > "$PIPE_STATE_DIR/FXA-5.blocked-why"
PATH="$tmp/bin:$PATH" snapshot_json >/dev/null 2>&1; n0="$(wc -l < "$tmp/jqn")"
check "300 stale state files cost no jq call" "$n0" "$n1"
printf 'fp\t1\t1\tpick a route\tneeds_decision\n' > "$PIPE_STATE_DIR/FXA-12.skipped"; echo FXA-9 > "$PIPE_STATE_DIR/FXA-11.held"
printf 'fp\t1\t1\theld until FXA-9 merges: x\t\n' > "$PIPE_STATE_DIR/FXA-11.skipped"
check "a recorded kind wins, and a hold is depends_on" "depends_on needs_decision" "$(snapshot_json 2>/dev/null | jq -r '[.queue.skipped[] | .kind] | sort | join(" ")')"
# The team block: exactly six keys from PIPE_*, no other host value; unset values fall back or are null.
tm="$(PIPE_PROFILE=t1 PIPE_LABEL='Team One' PIPE_JIRA_SITE=https://jira.example.com PIPE_LABEL_PREFIX=ai-x FXA_PR_LABEL=lbl PIPE_JIRA_BASIC=secretmark1 PIPE_RELOCK_SIGN=secretmark2 PIPE_STATE_URI=gs://secretmark3 snapshot_json 2>/dev/null)"
check "team: six keys with the PIPE values" "jira_site,name,pr_label,profile,queue_label,repo|t1|Team One|https://jira.example.com|ai-x|lbl|mozilla/fxa" \
  "$(jq -r '(.team | keys | join(",")) + "|" + ([.team.profile, .team.name, .team.jira_site, .team.queue_label, .team.pr_label, .team.repo] | join("|"))' <<< "$tm")"
check "team: no other host value reaches the snapshot" "0" "$(grep -c secretmark <<< "$tm")"
check "team: no label gives the profile as the name, and pr_label auto" "t1|auto|null" "$( (unset PIPE_LABEL FXA_PR_LABEL PIPE_JIRA_SITE; PIPE_PROFILE=t1 snapshot_json 2>/dev/null) | jq -r '"\(.team.name)|\(.team.pr_label)|\(.team.jira_site)"')"
check "the Done cap is in limits" "30" "$(jq -r .limits.merged_prs <<< "$tm")"
# A failed Jira read of done or inflight is unknown: review is null, and no PR state is read for it.
snap_states_fail() { jira_items_in_state() { if [ "$1" = blocked ]; then items FXA-5; else return 1; fi; }
  gh_pr_states_json() { echo x >> "$tmp/prs-calls"; echo '[]'; }; snapshot_json 2>/dev/null; }
check "a failed done and inflight read: review null, inflight unknown, no PR state read" "null|true|0" \
  "$(rm -f "$tmp/prs-calls"; snap_states_fail | jq -r '"\(.review)|\(.inflight_fetch_failed)"')|$(cat "$tmp/prs-calls" 2>/dev/null | wc -l | tr -d ' ')"
check "a good read: review is a list" "[]" "$(snapshot_json 2>/dev/null | jq -c .review)"
check "a failed in-flight PR read is flagged; a good one is not" "true|false" "$( (gh_pr_states_json() { echo null; }; snapshot_json 2>/dev/null) | jq -r .inflight_prs_failed)|$(snapshot_json 2>/dev/null | jq -r .inflight_prs_failed)"
eval "$(sed -n '/^_snapshot_slots() {/,/^}/p' "$here/snapshot.sh")"
slots() { local free cap; _snapshot_slots; printf '%s|%s' "$cap" "$(jq -c . <<< "$free")"; }
cmd_launchcap() { echo "cmd_launchcap must not run: it reads Jira again" >&2; echo 0; }
cmd_freeslots() { echo s-1; echo s-2; }
check "slots read: the cap from the one free list, and no second Jira read" '2|["s-1","s-2"]' "$(FXA_VM_BACKEND=gce slots 2>&1)"
check "the backend cap is the ceiling" '1|["s-1","s-2"]' "$(FXA_VM_BACKEND=tart slots 2>&1)"
cmd_freeslots() { echo "ERROR: cannot list inflight tickets" >&2; return 1; }
check "a slot read that fails: launchcap null, not 0" 'null|[]' "$(slots)"

# A file that goes away between the listing and the read gives no row, and the rest still parses.
rf() { _snapshot_facts FXA-5 FXA-77; }
printf '1\toperator\tx\n' > "$PIPE_STATE_DIR/FXA-77.blocked-why"
awk() { rm -f "$PIPE_STATE_DIR/FXA-77.blocked-why"; command awk "$@"; }
check "a state file removed during the read: no failure, the other key still reads" "0|operator" "$(set -o pipefail; out="$(rf)"; echo "$?|$(jq -r '.["FXA-5"].why.kind' <<< "$out")")"
unset -f awk

exit "$fail"
