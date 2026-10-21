#!/usr/bin/env bash
# Offline check that every runner image and the Firecracker snapshot get Firefox Nightly and its env:
# packer/scripts/03b-toolchain.sh installs it once a day, 06-agent-init.sh and refresh.sh export it,
# and 13-android.sh no longer installs a second copy.
#   bash lib/nightly.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
root="$(cd "$(dirname "$0")/.." && pwd)"
tc="$root/packer/scripts/03b-toolchain.sh"
env_lines() { grep -cE '^export (FIREFOX_BINARY=/opt/firefox-nightly/firefox|MOZ_REMOTE_ALLOW_SYSTEM_ACCESS=1)$' "$1"; }

check "06-agent-init.sh exports Nightly's env in every image" 2 "$(env_lines "$root/packer/scripts/06-agent-init.sh")"
check "refresh.sh adds Nightly's env to an older snapshot" 2 "$(env_lines "$root/infra/firecracker/refresh.sh")"
check "13-android.sh does not install Nightly again" 0 "$(grep -c 'firefox-nightly' "$root/packer/scripts/13-android.sh")"
check "03b-toolchain.sh runs the Nightly install" 1 "$(grep -cx 'nightly' "$tc")"

# The install, with curl and tar stubbed: a counter in a file, since the pipe runs them in subshells.
t="$(mktemp -d "${TMPDIR:-/tmp}/nightly.XXXXXX")"
pat='/^nightly() {/,/^}/p'; eval "$(sed -n "$pat" "$tc")"
NIGHTLY="$t/opt"
curl() { echo x >> "$t/fetches"; [ ! -e "$t/fail" ]; }
tar() { cat > /dev/null; [ -e "$t/fail" ] || { : > "$NIGHTLY.new/firefox"; chmod +x "$NIGHTLY.new/firefox"; }; }
n() { wc -l < "$t/fetches" 2>/dev/null | tr -d ' ' || echo 0; }
nightly 2>/dev/null; check "a new image fetches Nightly" "1|1" "$(n)|$([ -x "$NIGHTLY/firefox" ] && echo 1)"
nightly 2>/dev/null; check "a second refresh the same day does not fetch it again" 1 "$(n)"
echo 2000-01-01 > "$NIGHTLY/.fetched"; touch "$t/fail"
rc=0; nightly 2>/dev/null || rc=$?
check "a failed fetch on a later day keeps the earlier copy" "2|0|1" "$(n)|$rc|$([ -x "$NIGHTLY/firefox" ] && echo 1)"
rm -rf "$NIGHTLY"
rc=0; nightly 2>/dev/null || rc=$?; check "a failed fetch with no copy fails the toolchain" 1 "$rc"
rm -rf "$t"
exit "$fail"
