#!/usr/bin/env bash
# _run_model: feedback and rebase runs and a share of fix runs take the light model; empty turns it off.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
eval "$(sed -n '/^_run_model() {/,/^}/p' "$here/agent.sh")"
f=0; t() { [ "$(_run_model "$1" "$2")" = "$3" ] || { echo "FAIL: _run_model $1 $2 gave '$(_run_model "$1" "$2")', want '$3'"; f=1; }; }
unset FXA_AGENT_LIGHT_MODEL FXA_AGENT_LIGHT_FIX_PCT
t feedback FXA-14808 claude-sonnet-5-5
t rebase FXA-1 claude-sonnet-5-5
t fix FXA-14808 claude-sonnet-5-5   # 08 < 25
t fix FXA-14850 ""
t fix FXA-0099 ""                   # 10# keeps a leading zero decimal
t fix junk ""
FXA_AGENT_LIGHT_FIX_PCT=0 t fix FXA-14808 ""
FXA_AGENT_LIGHT_MODEL=claude-haiku-5-5 t feedback FXA-1 claude-haiku-5-5
FXA_AGENT_LIGHT_MODEL= t feedback FXA-1 ""
FXA_AGENT_LIGHT_MODEL= t fix FXA-14808 ""
[ "$f" = 0 ] && echo "run-model.check: ok"; exit "$f"
