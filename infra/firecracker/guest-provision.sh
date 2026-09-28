#!/bin/bash
# guest-provision.sh: run the Packer build's steps, in the Packer order, inside
# a Firecracker build guest. Run as root from a copy of the repo's packer/ dir
# with VM_AGENT_GUIDE.md beside it:   sudo bash guest-provision.sh
set -euo pipefail
cd "$(dirname "$0")"
S=packer/scripts
for s in 01-base 02-node 03-infra 04-claude 04b-codex 05-proxy 06-agent-init 08-playwright 09-fxa-services; do
  echo "=== $s"; bash "$S/$s.sh"
done
cp VM_AGENT_GUIDE.md /tmp/vm-agent-guide.md
echo "=== 10-agent-guide"; bash "$S/10-agent-guide.sh"
echo "=== 07-cleanup"; bash "$S/07-cleanup.sh"
# The template's inline agent-user step, read from the template so it cannot drift.
echo "=== agent user"
python3 - packer/fxa-dev.pkr.hcl > /tmp/agent-user.sh <<'PY'
import json, re, sys
src = open(sys.argv[1]).read()
block = re.search(r'inline = \[\n(.*?)\n    \]', src, re.S).group(1)
for line in block.splitlines():
    line = line.strip()
    if line.startswith('"'):
        print(json.loads(line.rstrip(',')).replace('%%{', '%{'))
PY
bash -e /tmp/agent-user.sh
echo "=== 11-gce-clone"; bash "$S/11-gce-clone.sh"
echo "=== 12-gce-startup"; bash "$S/12-gce-startup.sh"
echo "=== provisioned"
