#!/usr/bin/env bash
# Offline check of packer/scripts/14-tools-check.sh: the image build's last step, and it fails the
# build when a runner tool does not run or is built for another CPU. Tools are stubbed on PATH.
#   bash lib/tools-check.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
root="$(cd "$(dirname "$0")/.." && pwd)" sc="$root/packer/scripts/14-tools-check.sh"
t="$(mktemp -d "${TMPDIR:-/tmp}/toolscheck.XXXXXX")"; trap 'rm -rf "$t"' EXIT

check "the tool check is the build's last provisioner" "14-tools-check.sh" \
  "$(grep -o 'scripts/[0-9a-z-]*\.sh' "$root/packer/fxa-dev.pkr.hcl" | tail -1 | cut -d/ -f2)"

mkdir -p "$t/bin" "$t/opt/firefox-nightly" "$t/opt/spanner-emulator" "$t/pw/firefox-1/firefox"
for b in node claude codex; do printf '#!/bin/sh\necho "%s 1.0"\n' "$b" > "$t/bin/$b"; done
printf '#!/bin/sh\n[ "$1" = -u ] && shift 2; exec "$@"\n' > "$t/bin/sudo"
printf '#!/bin/sh\ncat "%s/arch"\n' "$t" > "$t/bin/uname"; echo x86_64 > "$t/arch"
printf '#!/bin/sh\necho "Mozilla Firefox 161.0a1"\n' > "$t/opt/firefox-nightly/firefox"
cp "$t/opt/firefox-nightly/firefox" "$t/pw/firefox-1/firefox/firefox"
chmod +x "$t"/bin/* "$t/opt/firefox-nightly/firefox" "$t/pw/firefox-1/firefox/firefox"
printf '%18s\x3e' '' > "$t/opt/spanner-emulator/gateway_main"
go() { PATH="$t/bin:$PATH" OPT="$t/opt" PW="$t/pw" bash "$sc" > "$t/out" 2>&1; echo $?; }

check "every tool runs: the build goes on" 0 "$(go)"
check "it names each tool it ran" 6 "$(grep -c '^ok ' "$t/out")"
printf '#!/bin/sh\necho "libgtk-3.so.0: cannot open shared object file" >&2; exit 255\n' > "$t/opt/firefox-nightly/firefox"
check "a Firefox that does not start fails the build, with its error" "1|1" "$(go)|$(grep -c '^FAIL firefox nightly: libgtk-3' "$t/out")"
printf '#!/bin/sh\necho "Mozilla Firefox 161.0a1"\n' > "$t/opt/firefox-nightly/firefox"
echo aarch64 > "$t/arch"
check "an x86_64 server on an arm64 image fails the build" "1|1" "$(go)|$(grep -c '^FAIL spanner-emulator: .* is not built for aarch64' "$t/out")"
exit "$fail"
