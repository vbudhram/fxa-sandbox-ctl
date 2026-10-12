#!/usr/bin/env bash
# Offline check that precheck releases its lock when a read fails and ends the process.
#   bash lib/precheck-lock.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
eval "$(sed -n '/^cmd_precheck() {/,/^}/p' "$(dirname "$0")/../fxa-sandbox-ctl")"
PIPE_LOCK_DIR="$tmp/pass.lock" PIPE_STATE_DIR="$tmp"
pipeline_lock() { mkdir "$PIPE_LOCK_DIR" && echo $$ > "$PIPE_LOCK_DIR/pid"; }
cmd_reconcile() { :; }; cmd_drain() { :; }; cmd_reap() { :; }
jira_login_ok() { :; }   # the login works; the read after it fails
jira_done_keys() { echo x >> "$tmp/reads"; return 1; }

( set -e; cmd_precheck ) >/dev/null 2>&1
check "a failed Jira read releases the lock" "1|no" "$(wc -l < "$tmp/reads" 2>/dev/null | tr -d ' ')|$([ -d "$PIPE_LOCK_DIR" ] && echo yes || echo no)"

mkdir "$PIPE_LOCK_DIR"; echo 99999 > "$PIPE_LOCK_DIR/pid"
( pipeline_lock() { :; }; set -e; cmd_precheck ) >/dev/null 2>&1
check "another pass's lock is left alone" "yes" "$([ -d "$PIPE_LOCK_DIR" ] && echo yes || echo no)"
exit "$fail"
