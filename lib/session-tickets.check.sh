#!/usr/bin/env bash
# Offline check that a session's request pulls only readable, non-secret FXA tickets into the runner's context.
#   bash lib/session-tickets.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
here="$(cd "$(dirname "$0")" && pwd)"
eval "$(sed -n '/^_session_ticket_context() {/,/^}/p' "$here/../fxa-sandbox-ctl")"
eval "$(sed -n '/^jira_card() {/,/^}/p;/^jira_normalize_key() {/,/^}/p' "$here/jira.sh")"
SESSION_DIR="$tmp"; mkdir -p "$tmp/run"
session_set() { :; }; memory_ticket_md() { :; }
# acli: FXA-1 carries the hackerone label, FXA-2 is plain, FXA-3 has a security level; the view text names the key.
acli() {
  local k; for k in "$@"; do case "$k" in FXA-*) break ;; esac; done
  case "$*" in *--json*) case "$k" in
      FXA-1) echo '{"key":"FXA-1","fields":{"summary":"s","labels":["HackerOne"],"security":null,"status":{"name":"Open","statusCategory":{"key":"new"}}}}' ;;
      FXA-2) echo '{"key":"FXA-2","fields":{"summary":"s","labels":[],"security":null,"status":{"name":"Open","statusCategory":{"key":"new"}}}}' ;;
      FXA-3) echo '{"key":"FXA-3","fields":{"summary":"s","labels":[],"security":{"name":"Security"},"status":{"name":"Open","statusCategory":{"key":"new"}}}}' ;;
    esac ;; esac
}
jira_ticket() { echo "TEXT OF $1"; }
ctx() { : > "$tmp/run/.fxa-jira-context.md"; printf '%s\n' "$1" > "$tmp/agent-ab12.prompt.md"; _session_ticket_context agent-ab12 "$tmp/run" n0nce > "$tmp/out"; grep -o 'TEXT OF FXA-[0-9]*' "$tmp/run/.fxa-jira-context.md" | tr '\n' ' ' | sed 's/ $//'; }
check "a plain ticket goes in; a hackerone-labelled one stays out" "TEXT OF FXA-2" "$(ctx 'look at FXA-1 and FXA-2')"
check "a ticket with a security level stays out" "" "$(ctx 'look at FXA-3')"
check "the session log says which key was left out" "yes" "$(grep -q 'Left FXA-3 out of the session context' "$tmp/out" && echo yes)"
acli() { return 1; }
check "a Jira read that fails leaves the ticket out" "" "$(ctx 'look at FXA-2')"
exit "$fail"
