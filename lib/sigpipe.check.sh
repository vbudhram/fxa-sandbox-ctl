#!/usr/bin/env bash
# Check that the controller puts SIGPIPE back at its default when it starts with it ignored (a systemd unit).
# Linux only: it reads /proc/self/status.
#   bash lib/sigpipe.check.sh
set -u
[ -r /proc/self/status ] || { echo "skip: no /proc (Linux only)"; exit 0; }
command -v perl >/dev/null || { echo "skip: needs perl"; exit 0; }
here="$(cd "$(dirname "$0")" && pwd)"; tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
# The block from the controller, then what a pipeline sees: yes | head under pipefail (141 by SIGPIPE, 1 with it ignored).
{ echo '#!/bin/bash'; echo 'set -euo pipefail'; sed -n '/^# sigpipe-reset: begin/,/^# sigpipe-reset: end/p' "$here/../fxa-sandbox-ctl"
  echo 'set +e; yes | head -1 >/dev/null; echo "rc=$?"'; } > "$tmp/prog"; chmod +x "$tmp/prog"
got="$(perl -e '$SIG{PIPE} = "IGNORE"; exec @ARGV' "$tmp/prog" 2>/dev/null)" || got="failed"
if [ "$got" = "rc=141" ]; then echo "ok   started with SIGPIPE ignored, a writer into a closed reader ends by SIGPIPE (141), which the ERR trap skips"; else echo "FAIL started with SIGPIPE ignored, a writer into a closed reader ends by SIGPIPE (141): want [rc=141] got [$got]"; exit 1; fi
