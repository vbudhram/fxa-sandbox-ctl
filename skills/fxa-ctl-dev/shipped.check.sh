#!/usr/bin/env bash
# Offline check for shipped.sh's packer_after: the packer/ commits that a GCE image older than them lacks.
#   bash skills/fxa-ctl-dev/shipped.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
here="$(cd "$(dirname "$0")" && pwd)"; tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
eval "$(sed -n '/^packer_after() {/,/^}/p' "$here/shipped.sh")"
g() { git -C "$tmp/r" -c user.name=t -c user.email=t@example.com "$@"; }
git init -q "$tmp/r"; mkdir -p "$tmp/r/packer" "$tmp/r/lib"
echo a > "$tmp/r/lib/x"; g add -A; GIT_COMMITTER_DATE=2026-11-01T00:00:00Z g commit -qm base
echo b > "$tmp/r/packer/s.sh"; g add -A; GIT_COMMITTER_DATE=2026-11-05T00:00:00Z g commit -qm packer
echo c > "$tmp/r/lib/x"; g add -A; GIT_COMMITTER_DATE=2026-11-06T00:00:00Z g commit -qm lib
g update-ref refs/remotes/origin/main HEAD
check "an image from before the packer commit lacks it; a lib commit does not count" "1" "$(packer_after "$tmp/r" 2026-11-03T00:00:00Z)"
check "an image after the packer commit has every one" "0" "$(packer_after "$tmp/r" 2026-11-05T12:00:00Z)"
[ "$fail" = 0 ] && echo "all checks pass"; exit "$fail"
