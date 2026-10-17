#!/usr/bin/env bash
# Offline check for a private repo's read token on the runner: the setup, the helper, and the drop.
#   bash lib/runner-git.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
here="$(cd "$(dirname "$0")" && pwd)"
eval "$(sed -n -e '/^_RUNNER_GIT_ENV=/p' -e "/^_RUNNER_GIT_SETUP='/,/exit 1; done'\$/p" -e '/^_runner_git_tokens() {/,/^}/p' -e '/^_runner_git_tokens_drop() {/,/^}/p' "$here/agent.sh")"
# The runner's paths and users, moved into tmp.
S="${_RUNNER_GIT_SETUP//\/run\/fxa-git/$tmp/run}"; S="${S//\/usr\/local\/sbin/$tmp}"; S="${S//-o agent -g agent/}"; S="${S//chown agent:agent/true}"
vm_exec() { shift; local c="$*"; [ "$1" = bash ] && { bash -c "$S"; return; }; echo "$c" >> "$tmp/execs"; }
github_repo_private() { [ "$1" = mozilla/fxa-private ]; }
github_read_token() { [ "$1" = mozilla/fxa-private ] && printf 't-read'; }
export TMPDIR="$tmp"
_runner_git_tokens agent-1 mozilla/fxa mozilla/fxa-private
ask() { printf 'protocol=https\nhost=github.com\npath=%s\n\n' "$1" | "$tmp/fxa-git-cred" get; }
check "the helper gives the private repo's token, and nothing for another repo" "username=x-access-token password=t-read||1" \
  "$(ask mozilla/fxa-private.git | tr '\n' ' ' | sed 's/ $//')|$(ask mozilla/fxa.git)|$(ls "$tmp/run" | wc -l | tr -d ' ')"
check "the token is not in the git env or a command line" "0" "$(printf '%s %s' "$_RUNNER_GIT_ENV" "$S" | grep -c t-read)"
_runner_git_tokens_drop agent-1
check "the drop removes the tokens once, and a start with none skips it" "rm -rf /run/fxa-git|" \
  "$(cat "$tmp/execs")|$(: > "$tmp/execs"; _runner_git_tokens_drop agent-1; cat "$tmp/execs")"
exit "$fail"
