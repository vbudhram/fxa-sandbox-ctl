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
  "$(grep -E '^PIPE_(REPO_SLUG|STATE_DIR)=' <<< "$fxa" | tr -d "'" | LC_ALL=C sort | paste -sd'|' -)"
check "a name cannot be a path" "1" "$(loaded "$root" ../profiles/fxa >/dev/null; echo $?)"

# A profile with one key gets the defaults.
mkdir -p "$tmp/r/profiles/demo" "$tmp/r/pipelines"; echo 'PIPE_REPO_SLUG="mozilla/demo"' > "$tmp/r/profiles/demo/profile.conf"
demo="$(loaded "$tmp/r" demo)"
check "a small profile gets its own state dir and the defaults" \
  "PIPE_BASE_BRANCH=main|PIPE_MIN_FREE_GB=5|PIPE_PROFILE=demo|PIPE_REPO=$tmp/home/Desktop/working2/demo|PIPE_STALL_MINUTES=20|PIPE_STATE_DIR=$tmp/home/.claude/state/demo" \
  "$(grep -E '^PIPE_(BASE_BRANCH|MIN_FREE_GB|PROFILE|REPO|STALL_MINUTES|STATE_DIR)=' <<< "$demo" | tr -d "'" | LC_ALL=C sort | paste -sd'|' -)"
check "a small profile's state dir is made" "yes" "$([ -d "$tmp/home/.claude/state/demo" ] && echo yes)"

# A team stack: every work row can be picked; the first is the profile's own repo.
py="$(loaded "$root" pyfxa-team)"
check "pyfxa-team loads, PyFxA first, both repos as work rows" "PIPE_REPO_SLUG=mozilla/PyFxA|PIPE_STACK_DEFAULT=mozilla/PyFxA mozilla/fxa" \
  "$(grep -E '^PIPE_(REPO_SLUG|STACK_DEFAULT)=' <<< "$py" | tr -d "'" | LC_ALL=C sort | paste -sd'|' -)"
check "pyfxa-team's work rows" "mozilla/PyFxA /home/agent/pyfxa|mozilla/fxa /home/agent/fxa" \
  "$( ( export HOME="$tmp/home"; SANDBOX_ROOT="$root"; source "$root/lib/pipeline.sh"; pipeline_load pyfxa-team >/dev/null 2>&1; printf '%s\n' "${PIPE_WORK_ROWS[@]}" ) | paste -sd'|' -)"
mkdir -p "$tmp/r/profiles/dup"; printf 'PIPE_REPOS=(\n "mozilla/a /home/agent/a work"\n "mozilla/b /home/agent/a work"\n)\n' > "$tmp/r/profiles/dup/profile.conf"
check "two work rows on one path are refused" "1" "$(loaded "$tmp/r" dup >/dev/null; echo $?)"
# A team skill is a directory with a SKILL.md that names it, and its scripts parse.
bad=""
for d in "$root"/profiles/*/skills/*/; do
  n="$(basename "$d")"
  grep -q "^name: ${n}\$" "${d}SKILL.md" 2>/dev/null || bad="${bad} ${n}:name"
  for f in "$d"*.sh; do [ -f "$f" ] && { bash -n "$f" 2>/dev/null || bad="${bad} ${n}:$(basename "$f")"; }; done
done
check "every team skill names itself and its scripts parse" "" "${bad# }"

# A session's command loads the profile its record names, whatever --pipeline said.
eval "$(sed -n '/^_profile_from_args() {/,/^}/p' "$root/fxa-sandbox-ctl")"
SESSION_DIR="$tmp/sess"; mkdir -p "$SESSION_DIR"; _session_file() { printf '%s/%s.json' "$SESSION_DIR" "$1"; }
echo '{"key":"agent-mon1","profile":"monitor"}' > "$SESSION_DIR/agent-mon1.json"
echo '{"key":"agent-old1"}' > "$SESSION_DIR/agent-old1.json"
check "a session key's record sets the profile" "monitor" "$(_profile_from_args session-finish agent-mon1 --pr)"
check "a resume takes the resumed session's profile" "monitor" "$(_profile_from_args task --source slack --id agent-new9 --resume-from agent-mon1)"
check "an old record, or no key, keeps the default" "|" "$(_profile_from_args turn agent-old1)|$(_profile_from_args queue)"

# A child must not take the repo its parent's load exported; a repo set by hand still wins.
child_repo() { ( export HOME="$tmp/home" FXA_REPO="$1" _FXA_REPO_LOADED="$2"; SANDBOX_ROOT="$tmp/r"; _FXA_PIPELINE_LOADED=
  source "$root/lib/pipeline.sh"; pipeline_load demo >/dev/null 2>&1; echo "$PIPE_REPO" ); }
check "a repo exported by the parent's load is ignored" "$tmp/home/Desktop/working2/demo" "$(child_repo /x/fxa /x/fxa)"
check "a repo set by hand wins" "/y/mine" "$(child_repo /y/mine /x/fxa)"

# A read-only profile pushes nothing and opens no PR.
eval "$(sed -n '/^_finish_push_and_pr() {/,/^}/p' "$root/lib/finish.sh")"
gh() { echo gh >> "$tmp/gh"; }; git() { echo git >> "$tmp/gh"; }
: > "$tmp/gh"; out="$(PIPE_PR_OPEN=0 PIPE_PROFILE=monitor _finish_push_and_pr "$tmp" true 2>&1)"; rc=$?
check "a read-only profile refuses to push or open a PR" "1|0|1" "$rc|$(wc -l < "$tmp/gh" | tr -d ' ')|$(grep -c 'read-only' <<< "$out")"
unset -f gh git
check "the monitor profile is read-only for now" "PIPE_PROFILE=monitor|PIPE_PR_OPEN=0|PIPE_REPO_SLUG=mozilla/blurts-server" \
  "$(loaded "$root" monitor | grep -E '^PIPE_(PR_OPEN|PROFILE|REPO_SLUG)=' | tr -d "'" | LC_ALL=C sort | paste -sd'|' -)"

# A profile with its own repo: cloned beside FxA, and /workspace points at it.
eval "$(sed -n '/^_gce_profile_workspace() {/,/^}/p' "$root/lib/agent.sh")"
vm_exec() { shift; printf '%s\n' "$*" >> "$tmp/vmx"; }
: > "$tmp/vmx"; PIPE_WORKSPACE=/home/agent/monitor PIPE_REPO_SLUG=mozilla/blurts-server _gce_profile_workspace r1 >/dev/null
check "a profile repo is cloned and /workspace points at it" "1|1" \
  "$(grep -c 'git clone --quiet --filter=blob:none https://github.com/mozilla/blurts-server.git /home/agent/monitor' "$tmp/vmx")|$(grep -c 'ln -sfn /home/agent/monitor /workspace' "$tmp/vmx")"
: > "$tmp/vmx"; _gce_profile_workspace r1 >/dev/null; PIPE_WORKSPACE=/home/agent/fxa _gce_profile_workspace r1 >/dev/null
check "FxA keeps the baked clone, with no call" "0" "$(wc -l < "$tmp/vmx" | tr -d ' ')"
check "a workspace or slug that is not plain is refused" "1|1" \
  "$(PIPE_WORKSPACE='/home/agent/x;rm' PIPE_REPO_SLUG=a/b _gce_profile_workspace r1 >/dev/null 2>&1; echo $?)|$(PIPE_WORKSPACE=/home/agent/x PIPE_REPO_SLUG='a/b c' _gce_profile_workspace r1 >/dev/null 2>&1; echo $?)"
check "the monitor profile works in its own clone, with FxA's stack beside it" "PIPE_STACK_DIR=/home/agent/fxa|PIPE_WORKSPACE=/home/agent/monitor" \
  "$(loaded "$root" monitor | grep -E '^PIPE_(STACK_DIR|WORKSPACE)=' | tr -d "'" | LC_ALL=C sort | paste -sd'|' -)"

# profile show: each repo's effective access, from the profile and the GitHub App.
eval "$(sed -n '/^pipeline_profile_json() {/,/^}/p;/^_profile_app_repos() {/,/^}/p;/^pipeline_mcp() {/p' "$root/lib/pipeline.sh")"
_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"; }
PIPE_STATE_DIR="$tmp/ps"; mkdir -p "$PIPE_STATE_DIR"
gh() { echo "call" >> "$tmp/ghcalls"; printf '%s\n' mozilla/fxa; }
pj() { PIPE_PROFILE="$1" PIPE_REPO_SLUG="$2" PIPE_DEP_REPOS="$3" PIPE_PR_OPEN="$4" pipeline_profile_json | jq -c '[.read_only, (.repos[] | "\(.slug):\(.role):\(.write)")]'; }
check "fxa can write to its repo" '[false,"mozilla/fxa:work:true"]' "$(pj fxa mozilla/fxa '' 1)"
check "a read-only profile writes nowhere, deps included" '[true,"mozilla/blurts-server:work:false","mozilla/fxa:dep:false"]' "$(pj monitor mozilla/blurts-server mozilla/fxa 0)"
check "no App on the work repo: no write" '"the agent'"'"'s GitHub App is not installed on this repo"' \
  "$(PIPE_PROFILE=x PIPE_REPO_SLUG=mozilla/other PIPE_PR_OPEN=1 pipeline_profile_json | jq -c '.repos[0].why')"
check "the App's repo list is read once, then cached" "1" "$(: > "$tmp/ghcalls"; rm -f "$PIPE_STATE_DIR/app-repos.txt"; pj fxa mozilla/fxa '' 1 >/dev/null; pj fxa mozilla/fxa '' 1 >/dev/null; wc -l < "$tmp/ghcalls" | tr -d ' ')"
gh() { return 1; }; rm -f "$PIPE_STATE_DIR/app-repos.txt"
check "a profile's PIPE_MCP replaces the bot's list" "github,jira" "$(PIPE_MCP=github,jira pipeline_mcp jira,slack)"
check "an empty PIPE_MCP means none" "" "$(PIPE_MCP= pipeline_mcp jira,slack)"
check "no PIPE_MCP: the bot's list" "jira,slack" "$(unset PIPE_MCP; pipeline_mcp jira,slack)"
check "the profile JSON names the team's connectors" '["github","jira"]|null' \
  "$(PIPE_PROFILE=x PIPE_REPO_SLUG=mozilla/fxa PIPE_MCP=github,jira pipeline_profile_json | jq -c .mcp)|$(unset PIPE_MCP; PIPE_PROFILE=x PIPE_REPO_SLUG=mozilla/fxa pipeline_profile_json | jq -c .mcp)"
check "pyfxa-team sets its connectors" "github,jira" "$( ( source "$root/profiles/pyfxa-team/profile.conf"; echo "$PIPE_MCP" ) )"
check "a failed App check means no write" '"mozilla/fxa:work:false"' "$(PIPE_PROFILE=fxa PIPE_REPO_SLUG=mozilla/fxa PIPE_PR_OPEN=1 pipeline_profile_json | jq -c '.repos[0] | "\(.slug):\(.role):\(.write)"')"
unset -f gh

# PIPE_REPOS: one row per repo (slug path role); the old single values come from it.
mkdir -p "$tmp/r/profiles/multi" "$tmp/r/profiles/badrole"
cat > "$tmp/r/profiles/multi/profile.conf" <<'CONF'
PIPE_REPOS=(
  "mdn/rari    /home/agent/rari    work"
  "mdn/content /home/agent/content data"
  "mdn/fred    /home/agent/fred    ref"
  "mozilla/fxa /home/agent/fxa     dep"
)
CONF
printf 'PIPE_REPOS=("a/b /home/agent/b work" "c/d /home/agent/d boss")\n' > "$tmp/r/profiles/badrole/profile.conf"
check "the work row sets the repo and workspace, dep rows the dep list" \
  "PIPE_DEP_REPOS=mozilla/fxa|PIPE_REPO_SLUG=mdn/rari|PIPE_WORKSPACE=/home/agent/rari" \
  "$(loaded "$tmp/r" multi | grep -E '^PIPE_(DEP_REPOS|REPO_SLUG|WORKSPACE)=' | tr -d "'" | LC_ALL=C sort | paste -sd'|' -)"
check "a row with an unknown role is refused" "1" "$(loaded "$tmp/r" badrole >/dev/null; echo $?)"
check "fxa sets no repo rows" "" "$(loaded "$root" fxa | grep '^PIPE_REPOS=')"

# Every tree but the work tree is cloned beside it by role, and named in the guide as read-only.
: > "$tmp/vmx"; ( PIPE_REPOS=("mdn/rari /home/agent/rari work" "mdn/content /home/agent/content data" "mdn/fred /home/agent/fred ref" "mozilla/fxa /home/agent/fxa dep")
  PIPE_WORKSPACE=/home/agent/rari PIPE_REPO_SLUG=mdn/rari _gce_profile_workspace r1 >/dev/null )
check "data is a blobless clone, ref a shallow one, and a baked dep is kept" "1|1|1" \
  "$(grep -c '\[ -d /home/agent/content/.git \] || sudo -u agent git clone --quiet --filter=blob:none https://github.com/mdn/content.git /home/agent/content' "$tmp/vmx")|$(grep -c 'git clone --quiet --depth 1 https://github.com/mdn/fred.git /home/agent/fred' "$tmp/vmx")|$(grep -c '\[ -d /home/agent/fxa/.git \] ||' "$tmp/vmx")"
eval "$(sed -n '/^_profile_guide_trees() {/,/^}/p' "$root/lib/agent.sh")"
g="$( PIPE_REPOS=("mdn/rari /home/agent/rari work" "mdn/content /home/agent/content data"); _profile_guide_trees )"
check "the guide names the work tree and marks the others read-only" "2|1" "$(grep -c '^- `/home/agent/' <<< "$g")|$(grep -c 'content.*read-only' <<< "$g")"
check "fxa adds nothing to the guide" "" "$(_profile_guide_trees)"

# The manager clones a profile's work repo the first time it needs it.
eval "$(sed -n '/^pipeline_ensure_clone() {/,/^}/p' "$root/lib/pipeline.sh")"
git() { echo "git $*" >> "$tmp/gitc"; }
: > "$tmp/gitc"; PIPE_REPO="$tmp/nope/blurts-server" PIPE_REPO_SLUG=mozilla/blurts-server pipeline_ensure_clone >/dev/null 2>&1
mkdir -p "$tmp/have/.git"; PIPE_REPO="$tmp/have" PIPE_REPO_SLUG=mozilla/x pipeline_ensure_clone >/dev/null 2>&1
check "a missing manager clone is made once, an existing one is kept" "git clone --quiet https://github.com/mozilla/blurts-server.git $tmp/nope/blurts-server" "$(cat "$tmp/gitc")"
unset -f git

# A ticket for another team's session goes to its own Jira project, or nowhere.
eval "$(sed -n '/^session_create_jira() {/,/^}/p' "$root/lib/session.sh")"
session_get() { echo "https://github.com/x/y/pull/1"; }; gh() { echo '{"title":"fix(x): y","body":"b","headRefName":"agent-1"}'; }
acli() { echo acli >> "$tmp/acli"; }
: > "$tmp/acli"; out="$(PIPE_PROFILE=monitor session_create_jira agent-q1 2>&1)"; rc=$?
check "a profile with no Jira project files no ticket" "1|0|1" "$rc|$(wc -l < "$tmp/acli" | tr -d ' ')|$(grep -c 'no Jira project' <<< "$out")"
unset -f session_get gh acli

# A ship refuses while a read-only tree has changes: only the work tree is shipped.
eval "$(sed -n '/^_session_dirty_trees() {/,/^}/p' "$root/lib/session.sh")"
_session_sh() { printf '%s\n' "$2" > "$tmp/dirtycmd"; echo /home/agent/content; }
d="$( PIPE_REPOS=("mdn/rari /home/agent/rari work" "mdn/content /home/agent/content data" "mozilla/fxa /home/agent/fxa dep"); _session_dirty_trees r1 )"
check "the other trees are checked for tracked changes, the work tree is not" "/home/agent/content|1|1|0" \
  "$d|$(grep -c '/home/agent/content' "$tmp/dirtycmd")|$(grep -c 'untracked-files=no' "$tmp/dirtycmd")|$(grep -c '/home/agent/rari' "$tmp/dirtycmd")"
: > "$tmp/dirtycmd"; check "a profile with no repo rows checks nothing" "|0" "$(_session_dirty_trees r1)|$(wc -c < "$tmp/dirtycmd" | tr -d ' ')"
unset -f _session_sh

# A profile's boot.sh is shipped and started as root, detached; FxA has none.
eval "$(sed -n '/^_gce_profile_boot() {/,/^}/p' "$root/lib/agent.sh")"
vm_exec() { printf '%s\n' "${*: -1}" >> "$tmp/bootx"; }
: > "$tmp/bootx"; SANDBOX_ROOT="$root" PIPE_PROFILE=monitor _gce_profile_boot r1 >/dev/null
check "monitor's boot.sh goes to the runner" "1" "$(grep -c "base64 -d > /usr/local/sbin/profile-boot" "$tmp/bootx")"
# Detached for real: the command returns while the script still runs, even with its output on a
# pipe that ssh holds open. (setsid is Linux only: the docker leg of test.sh runs this.)
if command -v setsid >/dev/null; then
  slow="$(printf '#!/bin/bash\nsleep 3\n' | base64 | tr -d '\n')"
  c="$(sed -e "s#^echo '[^']*'#echo '$slow'#" -e "s#/usr/local/sbin/profile-boot#$tmp/pb#g" -e "s#/var/log/profile-boot.log#$tmp/pb.log#" "$tmp/bootx")"
  t0=$(date +%s); bash -c "$c" | cat; check "the boot command returns before boot.sh ends" "fast" "$([ $(( $(date +%s) - t0 )) -lt 2 ] && echo fast || echo "waited $(( $(date +%s) - t0 ))s")"
fi
check "the shipped script is the profile's own" "same" "$([ "$(sed -n "s/^echo '\([^']*\)'.*/\1/p" "$tmp/bootx" | base64 -d)" = "$(cat "$root/profiles/monitor/boot.sh")" ] && echo same)"
: > "$tmp/bootx"; SANDBOX_ROOT="$root" PIPE_PROFILE=fxa _gce_profile_boot r1 >/dev/null
check "fxa has no boot.sh, so nothing runs" "0" "$(wc -l < "$tmp/bootx" | tr -d ' ')"
check "monitor's boot.sh is valid bash" "0" "$(bash -n "$root/profiles/monitor/boot.sh"; echo $?)"

# Extra egress hosts come from the profile, and only plain host names.
eval "$(sed -n '/^_profile_egress_extra() {/,/^}/p' "$root/lib/agent.sh")"
check "a profile adds plain host names to the allowlist" " fonts.gstatic.com a.example" "$(PIPE_EGRESS_EXTRA="fonts.gstatic.com a.example" _profile_egress_extra)"
check "a host that is not plain is refused" "1" "$(PIPE_EGRESS_EXTRA='a.example;rm' _profile_egress_extra >/dev/null 2>&1; echo $?)"

# The profile's guide.md follows the FxA guide, after the repo list.
g="$(cd "$root" && SANDBOX_ROOT="$root" PIPE_PROFILE=monitor bash -c 'source lib/config.sh >/dev/null 2>&1; source lib/agent.sh >/dev/null 2>&1; vm_guide_build session')"
check "the monitor guide is added to the session guide" "1" "$(grep -c '^# Monitor' <<< "$g")"

# "Try it in Firefox" opens the profile's page; FxA keeps :3030 (the script's default).
check "a desktop command loads the session's profile" "monitor" "$(_profile_from_args session desktop agent-mon1 user@example.com)"
eval "$(sed -n '/^session_desktop() {/,/^}/p' "$root/lib/session.sh")"
desk() { ( worktree_branch_for() { echo b; }; session_live() { :; }; vm_is_running() { :; }; session_set() { :; }; ssh() { :; }; vm_name() { :; }
  vm_exec() { echo "page=${!#}" > "$tmp/desk"; printf 'ip=10.0.0.9\npassword=abcd1234\n'; }
  SANDBOX_ROOT="$root"; eval "$(loaded "$root" "$1" | grep '^PIPE_DESKTOP_URL=')"; session_desktop agent-x >/dev/null; cat "$tmp/desk" ); }
check "monitor's desktop opens Monitor" "page=http://localhost:6060/" "$(desk monitor)"
check "fxa's desktop gets no page, so the script opens :3030" "page=" "$(desk fxa)"

# A boot.sh runs as root beside the agent: its markers must be where the agent cannot plant a link.
check "every boot.sh writes its markers outside the agent's home" "" \
  "$(grep -HE '^[A-Z ]*(READY|FAIL)=' "$root"/profiles/*/boot.sh | grep -oE '(READY|FAIL)=[^ ]+' | grep -v '=/run/' || true)"
[ "$fail" = 0 ] && echo "all ok"
exit "$fail"
