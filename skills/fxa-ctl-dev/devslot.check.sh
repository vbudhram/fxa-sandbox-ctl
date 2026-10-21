#!/usr/bin/env bash
# devslot.sh: with FXA_FC_HOST unset the manager's .env gives the host; set, it goes with the command.
set -euo pipefail
D="$(cd "$(dirname "$0")" && pwd)"; T=$(mktemp -d "${TMPDIR:-/tmp}/devslot.XXXXXX"); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/fxa-ctl-dev" "$T/fxa-manager"; cp "$D/devslot.sh" "$T/fxa-ctl-dev/"
printf '#!/usr/bin/env bash\ncat\n' > "$T/fxa-manager/vm.sh"   # stub: print the command the manager would run
out="$(env -u FXA_FC_HOST bash "$T/fxa-ctl-dev/devslot.sh" list 2>&1)" || { echo "FAIL: unset host: $out"; exit 1; }
[ "$out" = "./fxa-sandbox-ctl --backend gce devslot list 2>&1" ] || { echo "FAIL: unset host sent: $out"; exit 1; }
out="$(FXA_FC_HOST=10.0.0.9 bash "$T/fxa-ctl-dev/devslot.sh" list)"
[ "$out" = "FXA_FC_HOST=10.0.0.9 ./fxa-sandbox-ctl --backend gce devslot list 2>&1" ] || { echo "FAIL: set host sent: $out"; exit 1; }
echo "devslot.check: ok"
