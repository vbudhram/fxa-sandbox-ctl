#!/usr/bin/env bash
# Offline check for the verify.sh lock: a second run exits 75, and a row's child does not keep the lock.
#   bash skills/fxa-verify/lock.check.sh   (bash 4 and flock, as on the runner)
set -u
[ "${BASH_VERSINFO[0]}" -ge 4 ] || { echo "skip: needs bash 4"; exit 0; }
command -v flock >/dev/null || { echo "skip: needs flock"; exit 0; }
fail=0
check() { # check <name> <want> <got>
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi
}
V="$(cd "$(dirname "$0")" && pwd)/verify.sh"
tmp="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$tmp"' EXIT
export FXA_WORKSPACE="$tmp" TMPDIR="$tmp"
sed "s#/workspace/#${tmp}/#g" "$V" > "$tmp/verify.sh"
cd "$tmp" && git init -q && git -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m init && git update-ref refs/remotes/origin/main HEAD
echo x > a.txt
lockf="$tmp/fxa-verify-$(id -u).lock"
exec 8>"$lockf"; flock 8   # another run holds the lock
out="$(bash "$tmp/verify.sh" --run a.txt 2>&1)"; rc=$?
check "a run while another holds the lock exits 75" 75 "$rc"
check "and says why" 1 "$(grep -c 'another fxa-verify run holds' <<<"$out")"
check "the plan-only mode does not wait for the lock" 0 "$(bash "$tmp/verify.sh" a.txt >/dev/null 2>&1; echo $?)"
exec 8>&-
# A row that leaves a child behind, as a stack start leaves pm2.
printf '%s\t%s\t%s\n' "FAIL" "pkg unit|.|sleep 5 & echo 'Tests: 1 passed'" "FAIL pkg unit  1s  log" > "$tmp/.fxa-verify-rows.tsv"
bash "$tmp/verify.sh" --failed >/dev/null 2>&1
check "a child of a row does not keep the lock" free "$(flock -n "$lockf" true && echo free || echo held)"
[ "$fail" = 0 ] && echo "all checks pass"; exit "$fail"
