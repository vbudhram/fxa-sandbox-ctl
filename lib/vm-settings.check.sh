#!/usr/bin/env bash
# Offline check for the Claude settings a runner gets: allowed keys only, and repo skills it cannot use denied.
#   bash lib/vm-settings.check.sh
set -u
fail=0
check() { # check <name> <want> <got>
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi
}
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
eval "$(sed -n '/^_vm_skill_blocklist() {/,/^}/p; /^_vm_settings_json() {/,/^}/p' "$(dirname "$0")/agent.sh")"

printf '{"env":{"ANTHROPIC_API_KEY":"sk-x"},"hooks":{},"model":"opus","permissions":{"deny":["Bash(rm -rf:*)"]}}' > "$tmp/s.json"
out="$(_vm_settings_json "$tmp/s.json")"
check "secrets and hooks stay on the host" "null|null" "$(jq -c '.env' <<< "$out")|$(jq -c '.hooks' <<< "$out")"
check "the host's own deny rules are kept" "true" "$(jq '.permissions.deny | index("Bash(rm -rf:*)") != null' <<< "$out")"
check "a repo skill the runner cannot use is denied" "true" "$(jq '.permissions.deny | index("Skill(fxa-pr-open)") != null' <<< "$out")"
check "the model and concise style come through" "opus|concise" "$(jq -r '"\(.model)|\(.outputStyle)"' <<< "$out")"
check "no host settings: still denied" "true" "$(_vm_settings_json "$tmp/none.json" | jq '.permissions.deny | index("Skill(fxa-triage)") != null')"
exit "$fail"
