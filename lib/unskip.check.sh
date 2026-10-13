#!/usr/bin/env bash
# Offline check that `unskip` drops a skip record, so the next pass judges the ticket again.
#   bash lib/unskip.check.sh
set -u
fail=0
check() { # check <name> <want> <got>
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi
}

d="$(dirname "$0")"
PIPE_STATE_DIR="$(mktemp -d)"; trap 'rm -rf "$PIPE_STATE_DIR"' EXIT
eval "$(sed -n '/^pipeline_skip_clear() {/,/^}/p' "$d/pipeline.sh")"
eval "$(sed -n '/^cmd_unskip() /p' "$d/../fxa-sandbox-ctl")"
pipeline_require() { :; }
_key() { echo "$1"; }

printf 'h\t1\t1\tr\n' > "$PIPE_STATE_DIR/FXA-1.skipped"
printf 'h\t1\t1\tr\n' > "$PIPE_STATE_DIR/FXA-2.skipped"
cmd_unskip FXA-1
check "unskip drops the record" "no" "$([ -f "$PIPE_STATE_DIR/FXA-1.skipped" ] && echo yes || echo no)"
check "unskip leaves other records" "yes" "$([ -f "$PIPE_STATE_DIR/FXA-2.skipped" ] && echo yes || echo no)"
check "the dispatcher routes unskip" "1" "$(grep -c '^    unskip) *cmd_unskip' "$d/../fxa-sandbox-ctl")"

exit "$fail"
