#!/usr/bin/env bash
# eval-local.sh: one eval on the laptop with Claude or Codex, judged as eval.sh judges.
#
#   eval-local.sh <evals/name.json> --runtime claude|codex
#   FXA_EVAL_CLAUDE_MODEL=claude-sonnet-5-5 eval-local.sh <spec> --runtime claude
#
# The agent works in a scratch copy of FxA at the spec's base (agent-try.sh --base: no
# newer ref, no remote), with the runner's prompt, skills and (Claude) subagents. It
# answers a question with the spec's answer, up to max_replies. Then it saves the same
# files as eval.sh, and eval.sh --judge scores them. The copy is installed
# (eval-install.sh), so tests run; there is no stack and no Linux.
# Results: ai/evals/<time>-<name>-<runtime>-local/ (local only).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
spec="${1:?usage: eval-local.sh <evals/name.json> --runtime claude|codex}"
[ "${2:-}" = --runtime ] && runtime="${3:-}" || runtime=""
case "$runtime" in claude|codex) ;; *) echo "usage: eval-local.sh <spec> --runtime claude|codex" >&2; exit 2 ;; esac
s() { jq -r "$1" "$spec"; }
base="$(s .base)"
# FXA_EVAL_CLAUDE_MODEL (e.g. claude-sonnet-5-5) runs Claude on that model; the folder names it.
CLAUDE_MODEL="${FXA_EVAL_CLAUDE_MODEL:-}"
label="$runtime${CLAUDE_MODEL:+-$CLAUDE_MODEL}"; [ "$runtime" = codex ] && label="codex${FXA_EVAL_CODEX_MODEL:+-$FXA_EVAL_CODEX_MODEL}"
out="$ROOT/ai/evals/$(date +%Y%m%d-%H%M)-$(s .name)-$label-local"; mkdir -p "$out"; cp "$spec" "$out/spec.json"

# An installed checkout at the base (made once per base), so the agent can run tests,
# and that commit's Node version first on PATH for the agent and its tests.
inst="$(bash "$ROOT/skills/fxa-ctl-dev/eval-install.sh" "$base")"
# shellcheck source=/dev/null
export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"; . "$NVM_DIR/nvm.sh"
PATH="$(dirname "$(nvm which "$(cat "$inst/.nvmrc")")"):$PATH"; export PATH
info="$(bash "$ROOT/skills/fxa-ctl-dev/agent-try.sh" --dry-run --base "$base" --runtime "$runtime" --from "$inst" "$(s .prompt)")"
repo="$(sed -n 's/^scratch copy: //p' <<< "$info")"; ws="$(dirname "$repo")"
trap 'rm -rf "$ws"' EXIT
t0=$(date +%s) sid="" reply=""
# Codex: the model is named, not left to ~/.codex/config.toml, so the report and the price agree.
CODEX_MODEL="${FXA_EVAL_CODEX_MODEL:-$(sed -n 's/^model *= *"\(.*\)"/\1/p' ~/.codex/config.toml 2>/dev/null | head -1)}"
# Codex gets its own home with only the login and the effort earlier runs used: no MCP
# servers or plugins from ~/.codex, which act as you.
if [ "$runtime" = codex ]; then
  mkdir -p "$ws/codex-home" && ln -sf ~/.codex/auth.json "$ws/codex-home/auth.json"
  echo "model_reasoning_effort = \"${FXA_EVAL_CODEX_EFFORT:-medium}\"" > "$ws/codex-home/config.toml"
fi

# turn <message file>: one turn; its events go to events.jsonl, its reply to $reply.
turn() {
  if [ "$runtime" = claude ]; then
    ( cd "$repo" && ENABLE_CLAUDEAI_MCP_SERVERS=false claude -p ${CLAUDE_MODEL:+--model "$CLAUDE_MODEL"} ${sid:+--resume "$sid"} --output-format stream-json --verbose \
        --setting-sources project,local --permission-mode bypassPermissions --strict-mcp-config \
        --disallowedTools 'Bash(git push:*)' 'Bash(gh:*)' WebFetch WebSearch < "$1" ) > "$ws/turn.jsonl" 2>>"$out/agent.err" || true
    sid="$(jq -r 'select(.type == "result") | .session_id' "$ws/turn.jsonl" | tail -1)"
    # The result holds only the last text block; the reply is every block the main agent wrote.
    reply="$(jq -r 'select(.type == "assistant" and .parent_tool_use_id == null) | .message.content[]? | select(.type == "text") | .text' "$ws/turn.jsonl")"
  else
    # workspace-write: it edits and commits in the copy, with no network.
    if [ -z "$sid" ]; then
      ( cd "$repo" && CODEX_HOME="$ws/codex-home" codex exec --json ${CODEX_MODEL:+-m "$CODEX_MODEL"} -s workspace-write --skip-git-repo-check -o "$ws/last.txt" - < "$1" ) > "$ws/turn.jsonl" 2>>"$out/agent.err" || true
      sid="$(jq -r 'select(.type == "thread.started") | .thread_id' "$ws/turn.jsonl" | head -1)"
    else
      ( cd "$repo" && CODEX_HOME="$ws/codex-home" codex exec resume "$sid" --json -o "$ws/last.txt" - < "$1" ) > "$ws/turn.jsonl" 2>>"$out/agent.err" || true
    fi
    reply="$(cat "$ws/last.txt" 2>/dev/null || true)"
  fi
  cat "$ws/turn.jsonl" >> "$out/events.jsonl"
}

echo "== $runtime at ${base:0:10} in $repo"
printf 'me: %s\n' "$(s .prompt)" > "$out/thread.txt"
turn "$(sed -n 's/^prompt: \([^ ]*\) .*/\1/p' <<< "$info")"
n=0
while :; do
  printf 'agent: %s\n' "$reply" >> "$out/thread.txt"
  echo "== reply $((n + 1)): $(head -c 300 <<< "$reply" | tr '\n' ' ')"
  # A question: the QUESTION/OPTION form the guide asks for, or a reply that ends asking.
  if { grep -qE '^QUESTION:|status: needs-input' <<< "$reply" || tail -3 <<< "$reply" | grep -q '?[*_ ]*$'; } && [ "$n" -lt "$(s '.max_replies // 3')" ]; then
    n=$((n + 1)); s .answer > "$ws/next.md"; printf 'me: %s\n' "$(s .answer)" >> "$out/thread.txt"
    echo "== answering question $n"; turn "$ws/next.md"
  else break; fi
done

# The diff from the base, commits and untracked files included, without the trial's own files.
x=(':(exclude).fxa-*' ':(exclude).claude')
{ git -C "$repo" diff "$base" -- . "${x[@]}"
  git -C "$repo" ls-files -o --exclude-standard -- . "${x[@]}" | while read -r f; do git -C "$repo" diff --no-index /dev/null "$f" || true; done
} > "$out/diff.patch"
# Every tool call, subagents included: one line each.
if [ "$runtime" = claude ]; then
  jq -r 'select(.type == "assistant") | .message.content[]? | select(.type == "tool_use")
    | "\(.name): \(.input.command // .input.file_path // .input.pattern // .input.description // "" | tostring | gsub("\n"; " ") | .[0:300])"' "$out/events.jsonl" > "$out/commands.txt"
else
  jq -r 'select(.type == "item.started" or .type == "item.completed") | .item
    | if .type == "command_execution" then "Bash: \(.command | tostring | gsub("\n"; " ") | .[0:300])"
      elif .type == "file_change" then "Edit: \([.changes[]?.path] | join(", "))" else empty end' "$out/events.jsonl" | uniq > "$out/commands.txt"
fi
{ echo "runtime: $runtime (local, no stack)"; echo "base: $base"; echo "seconds: $(( $(date +%s) - t0 ))"; echo "questions answered: $n"
  if [ "$runtime" = claude ]; then
    jq -rs '[.[] | select(.type == "result") | .modelUsage // {} | to_entries[]] | group_by(.key)[]
      | "model \(.[0].key): \(map(.value.inputTokens + .value.cacheReadInputTokens + .value.cacheCreationInputTokens) | add) in, \(map(.value.outputTokens) | add) out, $\(map(.value.costUSD) | add * 100 | round / 100)"' "$out/events.jsonl"
  else
    jq -rs --arg m "$CODEX_MODEL" --slurpfile p "$ROOT/evals/prices.json" -f "$ROOT/skills/fxa-ctl-dev/codex-cost.jq" "$out/events.jsonl"
  fi
} > "$out/report.txt"
echo "== saved to $out ($(wc -l < "$out/commands.txt" | tr -d ' ') tool calls, $(grep -c '^diff --git' "$out/diff.patch" || true) files changed)"
cat "$out/report.txt"
bash "$ROOT/skills/fxa-ctl-dev/eval.sh" "$spec" --judge "$out"
