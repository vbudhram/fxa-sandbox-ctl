#!/usr/bin/env bash
# Offline check of a runner gap (a tool the runner should have and cannot run): sync-e2e's firefox.py
# exits 4 when its Firefox does not start, and finish records each ENV line of the verify verdict once.
#   bash lib/env-gaps.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
here="$(cd "$(dirname "$0")" && pwd)"
t="$(mktemp -d "${TMPDIR:-/tmp}/envgaps.XXXXXX")"; trap 'rm -rf "$t"' EXIT

# firefox.py with its Python deps stubbed: only the start-up check runs.
ff() { FIREFOX_BINARY="$1" python3 - "$here/../profiles/sync-storage/skills/sync-e2e/firefox.py" <<'PY'
import runpy, sys, types
for m in ("fxa", "fxa.core", "fxa.crypto", "marionette_driver", "marionette_driver.marionette", "e2e"):
    sys.modules[m] = types.ModuleType(m)
sys.modules["fxa"].core, sys.modules["fxa"].crypto = sys.modules["fxa.core"], sys.modules["fxa.crypto"]
sys.modules["marionette_driver.marionette"].Marionette = object
sys.modules["e2e"].AUTH, sys.modules["e2e"].confirm = "", None
sys.argv = [sys.argv[1]]
runpy.run_path(sys.argv[0], run_name="__main__")
PY
}
out="$(ff /nonexistent/firefox 2>&1)"; rc=$?
check "firefox.py: no Firefox at FIREFOX_BINARY exits 4 and names it" "4|1" "$rc|$(grep -c "(/nonexistent/firefox) does not start" <<< "$out")"
printf '#!/bin/sh\necho "libgtk-3.so.0: cannot open shared object file" >&2; exit 255\n' > "$t/ff"; chmod +x "$t/ff"
out="$(ff "$t/ff" 2>&1)"; rc=$?
check "firefox.py: a Firefox that does not start exits 4 with its last error line" "4|1" "$rc|$(grep -c 'does not start: libgtk-3.so.0' <<< "$out")"

# finish: one error for each distinct ENV line, for the ticket, none with no ENV line.
eval "$(sed -n '/^_finish_env_gaps() {/,/^}/p' "$here/finish.sh")"
errors_record() { printf '%s|%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" "$5" >> "$t/errors"; }
mkdir -p "$t/wt"; printf 'header\nPASS   build   1s\nSKIP   firefox sync   0s\nENV    firefox sync: no Firefox\nENV    firefox sync: no Firefox\n' > "$t/wt/.fxa-verify-verdict.txt"
_finish_env_gaps "$t/wt" STOR-1
check "finish: an ENV line is one error for the ticket" "1|pipeline|env_gap|STOR-1|verify|the runner lacks a tool: firefox sync: no Firefox" "$(wc -l < "$t/errors" | tr -d ' ')|$(head -1 "$t/errors")"
rm -f "$t/errors"; printf 'header\nPASS   build   1s\n' > "$t/wt/.fxa-verify-verdict.txt"; _finish_env_gaps "$t/wt" STOR-1
check "finish: no ENV line, no error" no "$([ -e "$t/errors" ] && echo yes || echo no)"
exit "$fail"
