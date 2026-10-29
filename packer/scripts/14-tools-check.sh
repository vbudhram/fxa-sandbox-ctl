#!/bin/bash
# 14-tools-check.sh — the build's last step: each tool a runner uses must run on this image's CPU,
# not only unpack. Nightly 10-21 to 10-29 was an x86_64 build on the arm64 image, and nothing ran it.
# A tool that does not run fails the build. Run as root.
set -uo pipefail
OPT="${OPT:-/opt}" PW="${PW:-/home/agent/.cache/ms-playwright}"
as_agent() { sudo -u agent "$@"; }
fail=0
runs() { local n="$1" out; shift
  if out="$("$@" 2>&1 < /dev/null)"; then echo "ok   $n: $(tail -1 <<< "$out")"; else echo "FAIL $n: $(tail -2 <<< "$out" | tr '\n' ' ')"; fail=1; fi; }
# A server with no safe --version: its ELF machine byte must be this CPU's.
elf=3e; [ "$(uname -m)" = aarch64 ] && elf=b7
cpu() { [ -e "$2" ] || return 0
  if [ "$(od -An -tx1 -j18 -N1 "$2" 2>/dev/null | tr -d ' ')" = "$elf" ]; then echo "ok   $1: built for $(uname -m)"
  else echo "FAIL $1: $2 is not built for $(uname -m)"; fail=1; fi; }

runs node node --version
runs claude claude --version
runs codex codex --version
# Firefox loads GTK for --version too, so this also proves its libraries are there.
runs "firefox nightly" as_agent "$OPT/firefox-nightly/firefox" --headless --version
for b in "$PW"/firefox-*/firefox/firefox "$PW"/chromium-*/chrome-linux/chrome; do
  [ -x "$b" ] && runs "playwright ${b#"$PW"/}" as_agent "$b" --version
done
# x86_64 only (03b-toolchain.sh sync_tools); absent on arm64.
cpu spanner-emulator "$OPT/spanner-emulator/gateway_main"
cpu fake-gcs "$OPT/fake-gcs/fake-gcs-server"
[ "$fail" = 0 ] || echo "==> ERROR: a runner tool does not run on this image"
exit "$fail"
