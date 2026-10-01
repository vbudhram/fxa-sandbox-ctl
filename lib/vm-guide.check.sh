#!/usr/bin/env bash
# Offline check that each mode's runner guide builds whole and holds only its own rules.
#   bash lib/vm-guide.check.sh
set -u
fail=0
check() { # check <name> <want> <got>
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi
}
SANDBOX_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
eval "$(sed -n '/^vm_guide_build() {/,/^}/p' "$SANDBOX_ROOT/lib/agent.sh")"
for mode in session pipeline; do
  g="$(vm_guide_build "$mode")"
  check "$mode: the marker is replaced" "0" "$(grep -c '^<!-- The host puts' <<<"$g")"
  check "$mode: sections 1 to 10 in order" "1 2 3 4 5 6 7 8 9 10" "$(grep -oE '^## [0-9]+' <<<"$g" | cut -c4- | tr '\n' ' ' | sed 's/ $//')"
done
check "session: git is the agent's" "1" "$(vm_guide_build session | grep -c '^Git is yours')"
check "session: no pipeline rule" "0" "$(vm_guide_build session | grep -c 'You cannot commit\|/goal with numbered steps')"
check "pipeline: cannot commit" "1" "$(vm_guide_build pipeline | grep -c '^You cannot commit')"
check "pipeline: no session rule" "0" "$(vm_guide_build pipeline | grep -c 'Git is yours\|OPTION: ')"
exit $fail
