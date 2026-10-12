#!/usr/bin/env bash
# Offline check that the section maps at the top of lib/session.sh and lib/agent.sh name only
# functions that exist in that file, so a rename or a removal cannot leave a map stale.
#   bash lib/session-map.check.sh
set -u
fail=0
here="$(dirname "$0")"
for f in session.sh agent.sh; do
  names="$(sed -n '/^# Map (file order/,/^[^#]/p' "$here/$f" | sed -n 's/^#  *[a-zA-Z, ]\{1,16\}  \{1,\}//p; s/^#  \{14,\}//p' | tr ' ' '\n' | grep -E '^[a-z_]+$' | sort -u)"
  [ -n "$names" ] || { echo "FAIL $f: no map at the top"; fail=1; continue; }
  for n in $names; do grep -qE "^${n}\(\) \{" "$here/$f" || { echo "FAIL $f: the map names ${n}, which is not a function here"; fail=1; }; done
  [ "$fail" = 0 ] && echo "ok   $f: $(printf '%s\n' "$names" | wc -l | tr -d ' ') names in the map, all functions"
done
exit "$fail"
