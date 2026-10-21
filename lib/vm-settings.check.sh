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
hk='command -v fxa-mem >/dev/null && fxa-mem hook; exit 0'
check "secrets and the host's hooks stay on the host" "null|fxa-bash-guard.sh" "$(jq -c '.env' <<< "$out")|$(jq -r --arg hk "$hk" '[.hooks[][].hooks[].command | select(. != $hk) | split("/")[-1]] | join(",")' <<< "$out")"
check "the host's own deny rules are kept" "true" "$(jq '.permissions.deny | index("Bash(rm -rf:*)") != null' <<< "$out")"
check "a repo skill the runner cannot use is denied" "true" "$(jq '.permissions.deny | index("Skill(fxa-pr-open)") != null' <<< "$out")"
check "the model and concise style come through" "opus|concise" "$(jq -r '"\(.model)|\(.outputStyle)"' <<< "$out")"
check "no host settings: still denied" "true" "$(_vm_settings_json "$tmp/none.json" | jq '.permissions.deny | index("Skill(fxa-triage)") != null')"
check "the bash guard group stays first" "Bash|bash /home/agent/.claude/hooks/fxa-bash-guard.sh" "$(jq -r '.hooks.PreToolUse[0] | "\(.matcher)|\(.hooks[0].command)"' <<< "$out")"
check "a failed Bash command runs the memory hook" "Bash|$hk|5" "$(jq -r '.hooks.PostToolUseFailure[0] | "\(.matcher)|\(.hooks[0].command)|\(.hooks[0].timeout)"' <<< "$out")"
check "a Bash result with exit 0 also runs the memory hook" "Bash|$hk|5" "$(jq -r '.hooks.PostToolUse[0] | "\(.matcher)|\(.hooks[0].command)|\(.hooks[0].timeout)"' <<< "$out")"
check "an edit runs the memory hook" "$hk|5" "$(jq -r '.hooks.PreToolUse[] | select(.matcher == "Edit|Write|MultiEdit") | "\(.hooks[0].command)|\(.hooks[0].timeout)"' <<< "$out")"
exit "$fail"
