#!/usr/bin/env bash
# Offline check of github_repo_confirmed_private (lib/github.sh): only an authenticated private == true
# passes; a public repo, an unclear answer and a host with no login all fail, each with its reason.
#   bash lib/repo-private.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
command -v jq >/dev/null || { echo "skip: needs jq"; exit 0; }
eval "$(sed -n '/^_GH_CONFIRMED=/p;/^github_repo_confirmed_private() {/,/^}/p' "$(dirname "$0")/github.sh")"
github_read_token() { [ "$1" != example/noapp ] && echo tok; }
# GitHub by repo: the token must come on stdin (-K -), never in the args.
curl() { local u="${@: -1}" cfg; cfg="$(cat)"; [ "$cfg" = 'header = "Authorization: Bearer tok"' ] || { printf '{}\n401'; return; }
  echo x >> "$tmp/calls"
  case "$u" in */example/priv) printf '{"private":true,"visibility":"private"}\n200' ;; */example/pub) printf '{"private":false,"visibility":"public"}\n200' ;;
    */example/corp) printf '{"private":true,"visibility":"internal"}\n200' ;;
    */example/flaky) printf 'oops\n503' ;; *) printf '{}\n404' ;; esac; }
gh() { case "$1 $2" in "auth status") [ -n "${GH_OK:-}" ] ;; "api repos/example/priv") echo "A new release of gh is available" >&2; echo private ;; "api repos/example/pub") echo public ;; *) echo "HTTP 404: Not Found" >&2; return 1 ;; esac; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
# Each run in a subshell, so a yes kept for the process does not carry into the next case.
run() { ( github_repo_confirmed_private "$1" 2>&1; echo "rc=$?" ); }
github_app_enabled() { return 0; }
check "App: private true passes" "rc=0" "$(run example/priv)"
check "App: a public repo fails and says so" "example/pub is public|rc=1" "$(run example/pub | tr '\n' '|' | sed 's/|$//')"
check "App: a 503 fails with the HTTP code" "could not confirm that example/flaky is private (GitHub answered HTTP 503)|rc=1" "$(run example/flaky | tr '\n' '|' | sed 's/|$//')"
check "a bad slug fails before any call" "1" "$(run 'a/b;rm' | grep -c 'not a repo slug')"
check "App: an enterprise internal repo says private: true, and is refused" "example/corp is internal (every member of the enterprise can read it), not private|rc=1" "$(run example/corp | tr '\n' '|' | sed 's/|$//')"
check "App: no read token names the App, not a missing login" "1|rc=1" "$(run example/noapp | grep -c 'the GitHub App gave no read token: is it installed on example/noapp')|$(run example/noapp | tail -1)"
: > "$tmp/calls"
check "a yes is kept for the process: the second read makes no call" "rc=0|1" "$( (github_repo_confirmed_private example/priv; github_repo_confirmed_private example/priv; echo "rc=$?") 2>&1)|$(grep -c . "$tmp/calls")"
github_app_enabled() { return 1; }
check "no App, a gh login: private passes (gh's notice on stderr does not count), public fails, an error names gh's line" "rc=0|rc=1|1" "$(GH_OK=1 run example/priv)|$(GH_OK=1 run example/pub | tail -1)|$(GH_OK=1 run example/gone | grep -c '(gh: HTTP 404: Not Found)')"
check "no App and no gh login: fails with the next step" "1|rc=1" "$(run example/priv | grep -c 'Run gh auth login, or run on the manager.')|$(run example/priv | tail -1)"
[ "$fail" = 0 ] && echo "all checks pass"; exit "$fail"
