#!/usr/bin/env bash
# profile.check.sh: profiles under profiles/<name>/, the old pipelines/ name, and the
# loader's defaults for keys a profile leaves out.
set -u
fail=0
check() { # check <name> <want> <got>
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi
}
root="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
# Every PIPE_ value after a load, but the name the caller used.
loaded() { ( export HOME="$tmp/home"; unset FXA_REPO FXA_FIXME_STATE FXA_FIXME_RUNS FXA_FIXME_COSTS FXA_MIN_FREE_GB
  SANDBOX_ROOT="$1"; _FXA_PIPELINE_LOADED=; source "$root/lib/pipeline.sh"; pipeline_load "$2" >/dev/null 2>&1 || exit 1
  set | grep '^PIPE_' | grep -v '^PIPE_NAME=' ); }

fxa="$(loaded "$root" fxa)"
check "the fxa profile loads" "PIPE_PROFILE=fxa" "$(grep '^PIPE_PROFILE=' <<< "$fxa")"
check "the old pipeline name loads the same values" "same" "$([ "$fxa" = "$(loaded "$root" fxa-ai-fixme)" ] && echo same || diff <(echo "$fxa") <(loaded "$root" fxa-ai-fixme) | head -3)"
check "fxa keeps its repo and state dir" "PIPE_REPO_SLUG=mozilla/fxa|PIPE_STATE_DIR=$tmp/home/.claude/state/fxa-ai-fixme" \
  "$(grep -E '^PIPE_(REPO_SLUG|STATE_DIR)=' <<< "$fxa" | tr -d "'" | sort | paste -sd'|' -)"
check "a name cannot be a path" "1" "$(loaded "$root" ../profiles/fxa >/dev/null; echo $?)"

# A profile with one key gets the defaults.
mkdir -p "$tmp/r/profiles/demo" "$tmp/r/pipelines"; echo 'PIPE_REPO_SLUG="mozilla/demo"' > "$tmp/r/profiles/demo/profile.conf"
demo="$(loaded "$tmp/r" demo)"
check "a small profile gets its own state dir and the defaults" \
  "PIPE_BASE_BRANCH=main|PIPE_MIN_FREE_GB=5|PIPE_PROFILE=demo|PIPE_REPO=$tmp/home/Desktop/working2/demo|PIPE_STALL_MINUTES=20|PIPE_STATE_DIR=$tmp/home/.claude/state/demo" \
  "$(grep -E '^PIPE_(BASE_BRANCH|MIN_FREE_GB|PROFILE|REPO|STALL_MINUTES|STATE_DIR)=' <<< "$demo" | tr -d "'" | sort | paste -sd'|' -)"
check "a small profile's state dir is made" "yes" "$([ -d "$tmp/home/.claude/state/demo" ] && echo yes)"

# A session's command loads the profile its record names, whatever --pipeline said.
eval "$(sed -n '/^_profile_from_args() {/,/^}/p' "$root/fxa-sandbox-ctl")"
SESSION_DIR="$tmp/sess"; mkdir -p "$SESSION_DIR"; _session_file() { printf '%s/%s.json' "$SESSION_DIR" "$1"; }
echo '{"key":"agent-mon1","profile":"monitor"}' > "$SESSION_DIR/agent-mon1.json"
echo '{"key":"agent-old1"}' > "$SESSION_DIR/agent-old1.json"
check "a session key's record sets the profile" "monitor" "$(_profile_from_args session-finish agent-mon1 --pr)"
check "a resume takes the resumed session's profile" "monitor" "$(_profile_from_args task --source slack --resume-from agent-mon1)"
check "an old record, or no key, keeps the default" "|" "$(_profile_from_args turn agent-old1)|$(_profile_from_args queue)"

# A child must not take the repo its parent's load exported; a repo set by hand still wins.
child_repo() { ( export HOME="$tmp/home" FXA_REPO="$1" _FXA_REPO_LOADED="$2"; SANDBOX_ROOT="$tmp/r"; _FXA_PIPELINE_LOADED=
  source "$root/lib/pipeline.sh"; pipeline_load demo >/dev/null 2>&1; echo "$PIPE_REPO" ); }
check "a repo exported by the parent's load is ignored" "$tmp/home/Desktop/working2/demo" "$(child_repo /x/fxa /x/fxa)"
check "a repo set by hand wins" "/y/mine" "$(child_repo /y/mine /x/fxa)"

[ "$fail" = 0 ] && echo "all ok"
exit "$fail"
