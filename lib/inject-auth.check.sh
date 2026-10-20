#!/usr/bin/env bash
# Offline check that a runner's Claude credential fails closed and never stays on the host.
#   bash lib/inject-auth.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
here="$(cd "$(dirname "$0")" && pwd)"
eval "$(sed -n '/^_claude_auth_line() {/,/^}/p;/^_inject_claude_auth() {/,/^}/p' "$here/agent.sh")"
source "$here/runtime-claude.sh"
slot_write() { cat > "$1"; }
mcp_auth_lines() { :; }
llm_token_for() { [ "${MINT_FAIL:-}" = 1 ] && return 1; echo fxl_x; }
unset ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN
export FXA_LLM_PROXY_URL=http://proxy.test

mkdir -p "$tmp/a"; runtime_inject_auth "$tmp/a" agent-1 >/dev/null; rc=$?
check "a proxy run needs no raw key in the ctl env" "0|export ANTHROPIC_API_KEY=fxl_x" "$rc|$(grep -o 'export ANTHROPIC_API_KEY=.*' "$tmp/a/.fxa-auto-token" 2>/dev/null)"

mkdir -p "$tmp/b"; MINT_FAIL=1 runtime_inject_auth "$tmp/b" agent-1 >/dev/null; rc=$?
check "a failed token mint stops the launch and leaves no file" "1|no" "$rc|$([ -e "$tmp/b/.fxa-auto-token" ] && echo yes || echo no)"

unset FXA_LLM_PROXY_URL
mkdir -p "$tmp/c"; runtime_inject_auth "$tmp/c" agent-1 >/dev/null; rc=$?
check "no credential at all stops the launch" "1" "$rc"

export ANTHROPIC_API_KEY=sk-ant-test-x
mkdir -p "$tmp/d" "$tmp/e"
FXA_VM_BACKEND=gce runtime_attach_hook "$tmp/d" agent-1 >/dev/null
FXA_VM_BACKEND=tart runtime_attach_hook "$tmp/e" agent-1 >/dev/null
check "attach writes the credential only for a tart mount" "no|yes" "$([ -e "$tmp/d/.fxa-auto-token" ] && echo yes || echo no)|$([ -e "$tmp/e/.fxa-auto-token" ] && echo yes || echo no)"

# Each gce ship of the run files removes the slot's copy of the credentials right after.
n_put="$(grep -c '_put_run_files "\$name"' "$here/agent.sh")"
n_rm="$(awk '/_put_run_files "\$name"/{w=4} w&&/^ *_slot_creds_rm "\$(workspace_dir|new_workspace)"$/{n++; w=0} w{w--} END{print n+0}' "$here/agent.sh")"
check "agent_run and agent_switch leave no credential in the slot after the ship" "$n_put" "$n_rm"
# From the credential write to the launch, every failed return removes the slot's copy too.
left="$(awk '/runtime_inject_auth "\$(workspace_dir|new_workspace)"/{on=1} /^ *_launch_in_screen/{on=0} on&&/return 1/&&!/_slot_creds_rm/' "$here/agent.sh")"
check "a launch that fails after the credential write leaves no credential in the slot" "" "$left"

[ "$fail" = 0 ] && echo "all checks pass"
exit "$fail"
