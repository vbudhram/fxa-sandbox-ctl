#!/usr/bin/env bash
# Offline check for the team store (lib/teams.sh): create, set with a generation, status, delete
# and sync, against the local cache and against a fake bucket; clashes with other teams.
#   bash lib/teams.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
root="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home" SANDBOX_ROOT="$root" FXA_TEAMS_DIR="$tmp/cache" FXA_TEAM_ACTOR=owner@example.com FXA_TEAMS_LIVE=0
mkdir -p "$HOME/.ssh"
SESSION_DIR="$tmp/sessions"; mkdir -p "$SESSION_DIR"
source "$root/lib/pipeline.sh"
FXA_TEAMS_URI=""; source "$root/lib/teams.sh"
FXA_DB="$tmp/fxa.db"; source "$root/lib/db.sh"
rec() { printf '{ "schema": 1, "name": "%s", "label": "%s", "repos": [ { "slug": "example/%s", "role": "work" } ], "prompts": { "goal_md": "Run make test." }%s }' "$1" "$2" "$1" "${3:-}" > "$tmp/$1.json"; echo "$tmp/$1.json"; }
gen() { cat "$FXA_TEAMS_DIR/$1.gen"; }

# The local store (no bucket).
check "create writes the record at generation 1, stamped, with an index entry" "1|owner@example.com|Rusty" \
  "$(teams_create "$(rec rusty Rusty)" >/dev/null; gen rusty)|$(jq -r .created.by "$FXA_TEAMS_DIR/rusty.json")|$(jq -r '.teams.rusty.label' "$FXA_TEAMS_DIR/index.json")"
check "a second create of the same name is refused" "2" "$(teams_create "$(rec rusty Again)" >/dev/null 2>&1; echo $?)"
check "set with the cached generation writes, keeps created, moves the generation" "0|2|Rusty Two|owner@example.com" \
  "$(FXA_TEAM_ACTOR=other@example.com teams_set rusty "$(rec rusty 'Rusty Two')" >/dev/null; echo $?)|$(gen rusty)|$(jq -r .label "$FXA_TEAMS_DIR/rusty.json")|$(jq -r .created.by "$FXA_TEAMS_DIR/rusty.json")"
check "set with a stale generation is refused and changes nothing" "2|Rusty Two" \
  "$(teams_set rusty "$(rec rusty Stale)" 1 >/dev/null 2>&1; echo $?)|$(jq -r .label "$FXA_TEAMS_DIR/rusty.json")"
check "a record cannot rename a team" "1" "$(teams_set rusty "$(rec other Other)" >/dev/null 2>&1; echo $?)"
check "disable sets the status, in the record and the index" "disabled|disabled" \
  "$(teams_status rusty disabled >/dev/null; jq -r .status "$FXA_TEAMS_DIR/rusty.json")|$(jq -r .teams.rusty.status "$FXA_TEAMS_DIR/index.json")"
check "a record that fails its own rules is refused" "1" "$(teams_create "$(rec bad 'Bad$(x)')" >/dev/null 2>&1; echo $?)"
check "a record cannot take a built-in team's Jira project" "1" \
  "$(teams_create "$(rec jira1 Jira ', "jira": { "project": "FXA" }')" 2>&1 | grep -c 'FXA belongs to team fxa')"
teams_create "$(rec chan1 Chan ', "access": { "channels": ["C0123ABCD"] }, "jira": { "project": "CHAN" }')" >/dev/null
check "a channel or Jira project of another record is refused" "1|1" \
  "$(teams_create "$(rec chan2 Chan ', "access": { "channels": ["C0123ABCD"] }')" 2>&1 | grep -c 'channel C0123ABCD belongs to team chan1')|$(teams_create "$(rec chan3 Chan ', "jira": { "project": "CHAN" }')" 2>&1 | grep -c 'CHAN belongs to team chan1')"
# The CLI's status verbs (bash 3.2 once failed to parse their case inside $(...)). No bucket: FXA_TEAMS_URI is empty.
cli() { ( cd "$root" && FXA_TEAMS_URI= FXA_TEAMS_DIR="$FXA_TEAMS_DIR" FXA_DB="$FXA_DB" ./fxa-sandbox-ctl profile "$@" >/dev/null 2>&1; echo $? ); }
check "a record turns active only after a passed test of its generation" "1|draft|0|active" \
  "$(cli enable chan1)|$(jq -r '.status // "draft"' "$FXA_TEAMS_DIR/chan1.json")|$(cp "$FXA_TEAMS_DIR/chan1.gen" "$FXA_TEAMS_DIR/chan1.tested"; cli enable chan1)|$(jq -r .status "$FXA_TEAMS_DIR/chan1.json")"
check "a test of an older generation does not count" "1" \
  "$(cli draft chan1 >/dev/null; echo 1 > "$FXA_TEAMS_DIR/chan1.tested"; cli enable chan1)"
check "profile enable, disable and draft set the status" "0|active|0|disabled|0|draft" \
  "$(cp "$FXA_TEAMS_DIR/chan1.gen" "$FXA_TEAMS_DIR/chan1.tested"; cli enable chan1)|$(jq -r .status "$FXA_TEAMS_DIR/chan1.json")|$(cli disable chan1)|$(jq -r .status "$FXA_TEAMS_DIR/chan1.json")|$(cli draft chan1)|$(jq -r .status "$FXA_TEAMS_DIR/chan1.json")"
# The test gate: create and set cannot make a team active; an active team keeps its test only for text and people.
check "create with status active is refused; set cannot turn a draft active" "1|1" \
  "$(teams_create "$(rec ga1 Ga1 ', "status": "active"')" 2>&1 | grep -c 'starts as draft')|$(teams_create "$(rec ga2 Ga2)" >/dev/null; jq '.status = "active"' "$FXA_TEAMS_DIR/ga2.json" > "$tmp/ga2.json"; teams_set ga2 "$tmp/ga2.json" 2>&1 | grep -c 'with profile enable')"
cp "$FXA_TEAMS_DIR/ga2.gen" "$FXA_TEAMS_DIR/ga2.tested"; teams_status ga2 active >/dev/null
check "an active team: a guide edit stays active, a repo change is refused" "0|1" \
  "$(jq '.prompts.guide_md = "new"' "$FXA_TEAMS_DIR/ga2.json" > "$tmp/ga2.json"; teams_set ga2 "$tmp/ga2.json" >/dev/null 2>&1; echo $?)|$(jq '.repos += [{slug: "example/more", role: "dep"}]' "$FXA_TEAMS_DIR/ga2.json" > "$tmp/ga2.json"; teams_set ga2 "$tmp/ga2.json" 2>&1 | grep -c 'a change to repos needs a new test')"
check "disable works while the live checks fail" "0|disabled" \
  "$( (_teams_live() { [ "${FXA_TEAMS_LIVE:-1}" = 1 ] || return 0; echo "ERROR: down" >&2; return 1; }; FXA_TEAMS_LIVE=1 teams_status ga2 disabled >/dev/null 2>&1; echo $?) )|$(jq -r .status "$FXA_TEAMS_DIR/ga2.json")"
printf '{"profile":"rusty","state":"paused"}' > "$SESSION_DIR/agent-r1.json"
check "delete is refused while a session of the team can resume" "1" "$(teams_delete rusty >/dev/null 2>&1; echo $?)"
printf '{"profile":"rusty","state":"stopped"}' > "$SESSION_DIR/agent-r1.json"
check "delete removes the record, its prompts and its index entry" "0|no|null" \
  "$(teams_delete rusty >/dev/null; echo $?)|$([ -e "$FXA_TEAMS_DIR/rusty.json" ] && echo yes || echo no)|$(jq -r .teams.rusty "$FXA_TEAMS_DIR/index.json")"
check "a folder team cannot be deleted" "1" "$(teams_delete fxa >/dev/null 2>&1; echo $?)"
# monitor is a record whose profiles/monitor/ keeps only its boot.sh.
check "a record team that keeps a folder for its boot.sh can be deleted" "0|no" \
  "$(jq '.name = "monitor"' "$(rec monitor Monitor)" > "$tmp/mon.json"; FXA_TEAMS_LIVE=0 teams_create "$tmp/mon.json" >/dev/null 2>&1; teams_delete monitor >/dev/null 2>&1; echo $?)|$([ -e "$FXA_TEAMS_DIR/monitor.json" ] && echo yes || echo no)"
check "each write leaves an audit row: who, what, the generations and the keys that changed" \
  "delete|owner@example.com|3||created,label,name,prompts,repos,schema,status|set|other@example.com|1|2|label|create|owner@example.com|0|1|created,label,name,prompts,repos,schema" \
  "$(teams_audit rusty | jq -r '.[] | [.action, .actor, .old_gen, .new_gen, .changed] | join("|")' | grep -vE '^set\|owner@example.com\|[23]\|' | paste -sd'|' -)"
check "profile lint passes with records and the index in the cache" "profiles: ok" \
  "$(teams_create "$(rec linted Linted)" >/dev/null; cd "$root" && ./fxa-sandbox-ctl profile lint 2>&1 | tail -1)"
check "the index is not a team, and no record can be named index" "0|1" \
  "$(pipeline_profile_names | grep -cx index)|$(teams_create "$(rec index Index)" 2>&1 | grep -c reserved)"

# The live checks, with GitHub and Jira faked: a curl that answers by URL.
curl() { local u="${@: -1}"
  case "$u" in
    *repos/example/noapp/installation|*repos/example/pv2/installation) echo 404 ;; *installation) echo 200 ;;
    */repos/example/pv1|*/repos/example/pv2|*/repos/example/pv3) echo 404 ;;
    */repos/example/*) echo 200 ;;
    *project/NOPE) echo 404 ;; *project/*) echo 200 ;;
    *mypermissions*projectKey=RO*) echo '{"permissions":{"BROWSE_PROJECTS":{"havePermission":true},"EDIT_ISSUES":{"havePermission":false},"TRANSITION_ISSUES":{"havePermission":false}}}' ;;
    *mypermissions*) echo '{"permissions":{"BROWSE_PROJECTS":{"havePermission":true},"EDIT_ISSUES":{"havePermission":true},"TRANSITION_ISSUES":{"havePermission":true}}}' ;;
  esac; }
github_app_jwt() { echo jwt; }
eval "$(sed -n '/^github_repo_private() {/,/^}/p' "$root/lib/github.sh")"; export TMPDIR="$tmp"
type _mtime >/dev/null 2>&1 || _mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"; }
live() { FXA_TEAMS_LIVE=1 PIPE_JIRA_BASIC="u@example.com:t" teams_validate "$(rec "$1" Live "$2")" "$1" 2>&1; }
check "a work repo without the GitHub App is a warning, and the record is still valid" "1|0" \
  "$(sed -i.bak 's#example/lv2#example/noapp#' "$(rec lv2 Live)"; FXA_TEAMS_LIVE=1 teams_validate "$tmp/lv2.json" lv2 2>&1 | grep -c 'App is not installed on example/noapp')|$(FXA_TEAMS_LIVE=1 teams_validate "$tmp/lv2.json" lv2 >/dev/null 2>&1; echo $?)"
check "an unknown Jira project is refused" "1|1" \
  "$(live lv3 ', "jira": { "project": "NOPE" }' | grep -c 'no Jira project NOPE')|$(FXA_TEAMS_LIVE=1 PIPE_JIRA_BASIC=u:t teams_validate "$(rec lv3 Live ', "jira": { "project": "NOPE" }')" lv3 >/dev/null 2>&1; echo $?)"
check "an active queue where the login cannot edit is refused; a draft or no queue only warns" "1|0|0|1" \
  "$(FXA_TEAMS_LIVE=1 PIPE_JIRA_BASIC=u:t teams_validate "$(rec lv4 Live ', "status": "active", "jira": { "project": "RO", "queue": true }')" lv4 >/dev/null 2>&1; echo $?)|$(FXA_TEAMS_LIVE=1 PIPE_JIRA_BASIC=u:t teams_validate "$(rec lv5 Live ', "status": "draft", "jira": { "project": "RO", "queue": true }')" lv5 >/dev/null 2>&1; echo $?)|$(FXA_TEAMS_LIVE=1 PIPE_JIRA_BASIC=u:t teams_validate "$(rec lv6 Live ', "status": "active", "jira": { "project": "RO" }')" lv6 >/dev/null 2>&1; echo $?)|$(live lv5 ', "status": "draft", "jira": { "project": "RO", "queue": true }' | grep -c 'lacks EDIT_ISSUES TRANSITION_ISSUES on RO')"
check "full rights and an active queue: valid, no warning" "0|0" \
  "$(FXA_TEAMS_LIVE=1 PIPE_JIRA_BASIC=u:t teams_validate "$(rec lv7 Live ', "status": "active", "jira": { "project": "OK", "queue": true }')" lv7 >/dev/null 2>&1; echo $?)|$(live lv7 ', "status": "active", "jira": { "project": "OK", "queue": true }' | grep -c WARN)"
pv() { local o; o="$(live "$1" "$2"; echo "rc=$?")"; printf '%s/%s' "$(grep -c "$3" <<< "$o")" "${o##*rc=}"; }
check "a private repo: refused without the App or with access.open; valid for listed users" "1/1|1/1|0/0" \
  "$(pv pv2 '' 'pv2 is private (or GitHub did not answer), and the agent.s GitHub App is not installed')|$(pv pv1 ', "access": { "open": true }' 'cannot be open to everyone')|$(pv pv3 ', "access": { "users": ["U012345"] }' ERROR)"
gcloud() { return 1; }   # the team's credential is not stored yet
check "a team credential that is not stored yet: refused for an active queue, a warning for a draft" "1|1" \
  "$(FXA_TEAMS_LIVE=1 teams_validate "$(rec lv8 Live ', "status": "active", "jira": { "project": "OK", "queue": true }, "secrets": { "jira": "fxa-team-lv8--jira" }')" lv8 >/dev/null 2>&1; echo $?)|$(FXA_TEAMS_LIVE=1 teams_validate "$(rec lv9 Live ', "jira": { "project": "OK", "queue": true }, "secrets": { "jira": "fxa-team-lv9--jira" }')" lv9 2>&1 | grep -c 'store it with vm.sh secret fxa-team-lv9--jira')"
gcloud() { echo "bot@example.com:tok"; }
check "with the team credential stored, an active queue with full rights is valid" "0" \
  "$(FXA_TEAMS_LIVE=1 PIPE_JIRA_BASIC= teams_validate "$(rec lv10 Live ', "status": "active", "jira": { "project": "OK", "queue": true }, "secrets": { "jira": "fxa-team-lv10--jira" }')" lv10 >/dev/null 2>&1; echo $?)"
unset -f curl github_app_jwt gcloud

# The checks a test runs on the runner, from the loaded team.
probe() { ( PIPE_PROFILE=pt PIPE_REPOS=("example/w /home/agent/w work main" "mozilla/fxa /home/agent/fxa dep"); PIPE_STACK_DIR=/home/agent/fxa
  PIPE_EGRESS_EXTRA="static.crates.io"; PIPE_TEAM_SKILLS="fxa-stack"; PIPE_BOOT_SCRIPT=pt; _teams_probe_script ); }
check "the test checks each repo, the boot, the stack, each approved host, a blocked host and each skill" "2|1|1|1|1|1" \
  "$(probe | grep -c "^r 'repo ")|$(probe | grep -c 'the boot script finished ready')|$(probe | grep -c ':9000/__heartbeat__.;')|$(probe | grep -c 'egress to static.crates.io')|$(probe | grep -c 'example.com')|$(probe | grep -c 'skill fxa-stack')"
check "the probe script is valid shell, and a host it did not approve counts as blocked only when the request fails" "0" \
  "$(probe | bash -n; echo $?)"

# Secrets the dashboard sets: only names the record uses, written as the writer account, value on stdin.
teams_create "$(rec sx Sx ', "secrets": { "jira": "fxa-team-sx--jira", "runtime": [ { "secret": "fxa-team-sx--db", "path": "/home/agent/sx/.env" } ] }')" >/dev/null 2>&1 \
  || { mkdir -p "$FXA_TEAMS_DIR"; jq -n '{schema:1,name:"sx",repos:[{slug:"example/sx",role:"work"}],prompts:{goal_md:"g"},secrets:{jira:"fxa-team-sx--jira",runtime:[{secret:"fxa-team-sx--db",path:"/home/agent/sx/.env"}]}}' > "$FXA_TEAMS_DIR/sx.json"; }
gcloud() { local a d=""; for a in "$@"; do case "$a" in (--data-file=*) d="$(cat "${a#*=}")" ;; esac; done; printf '%s | stdin=%s\n' "$*" "$d" >> "$tmp/gsec"; case "$*" in *describe*fxa-team-sx--db*) return 0 ;; *describe*) return 1 ;; *access*fxa-team-sx--db*) echo v ;; *access*) return 1 ;; esac; }
ss() { printf '%s' "$3" | FXA_TEAM_SECRETS_SA="${4-writer@p.iam.gserviceaccount.com}" FXA_TEAMS_SECRET_DIR="$tmp/tsec2" teams_secret_set "$1" "$2" 2>&1; }
mkdir -p "$tmp/tsec2/sx"; echo cached > "$tmp/tsec2/sx/jira.basic"; : > "$tmp/gsec"
check "a secret the record does not name is refused; no writer account is refused; a bad Jira value is refused" "1|1|1" \
  "$(ss sx fxa-team-sx--other v | grep -c 'does not name')|$(ss sx fxa-team-sx--db v '' | grep -c 'no writer account')|$(ss sx fxa-team-sx--jira 'not-a-cred' | grep -c 'email:token')"
out="$(ss sx fxa-team-sx--jira 'bot@example.com:tok9')"; out2="$(ss sx fxa-team-sx--db 'DB=x9')"
check "a new secret is created, an existing one gets a version, every call as the writer, the value only in a file" "1|1|4|0" \
  "$(grep -c 'secrets create fxa-team-sx--jira .*--impersonate-service-account writer@p.iam.gserviceaccount.com.* | stdin=bot@example.com:tok9' "$tmp/gsec")|$(grep -c 'secrets versions add fxa-team-sx--db .*| stdin=DB=x9' "$tmp/gsec")|$(grep -c 'impersonate-service-account writer@' "$tmp/gsec")|$(cut -d'|' -f1 "$tmp/gsec" | grep -c 'tok9\|x9')"
check "storing drops the team's cached Jira credential, and the audit names the secret, not its value" "no|1|0" \
  "$([ -e "$tmp/tsec2/sx/jira.basic" ] && echo yes || echo no)|$(teams_audit sx | jq '[.[] | select(.action == "secret" and .changed == "fxa-team-sx--db")] | length')|$(teams_audit sx | grep -c 'x9\|tok9')"
check "the team's secrets read as present or missing" '{"fxa-team-sx--jira":"missing","fxa-team-sx--db":"present"}' "$(teams_secret_status sx)"
gcloud() { local a; for a in "$@"; do case "$a" in (--data-file=*) od -c < "${a#*=}" | head -1 | tr -s ' ' > "$tmp/gsec.bytes" ;; esac; done; case "$*" in *describe*) return 0 ;; esac; }
printf 'K1\n' | FXA_TEAM_SECRETS_SA=w@p FXA_TEAMS_SECRET_DIR="$tmp/tsec2" teams_secret_set sx fxa-team-sx--db >/dev/null 2>&1
check "a value keeps its trailing newline (a key, a PEM)" "$(printf 'K1\n' | od -c | head -1 | tr -s ' ')" "$(cat "$tmp/gsec.bytes")"
unset -f gcloud

# profile test asks the boot for the stack only when the team has one.
mkdir -p "$tmp/sd"; printf '#!/bin/bash\n[ "$3" = --pipeline ] && echo "$4 stack=${FXA_SESSION_STACK:-}" >> "%s/tcalls"; exit 0\n' "$tmp" > "$tmp/sd/fxa-sandbox-ctl"; chmod +x "$tmp/sd/fxa-sandbox-ctl"
cp "$(rec ts1 Ts1)" "$FXA_TEAMS_DIR/ts1.json"; jq '.stack = {kind: "fxa"} | .repos += [{slug: "mozilla/fxa", role: "dep"}]' "$(rec ts2 Ts2)" > "$FXA_TEAMS_DIR/ts2.json"
( SCRIPT_DIR="$tmp/sd"; _session_try_wait() { return 1; }; teams_test ts1; teams_test ts2 ) >/dev/null 2>&1
check "profile test starts a team's stack only when it has one" "ts1 stack=|ts2 stack=1" "$(paste -sd'|' - < "$tmp/tcalls")"
out="$( (SCRIPT_DIR="$tmp/sd"; _session_try_wait() { _TRY_LAST=error; return 0; }; teams_test ts1; echo "rc=$?") 2>&1)"
check "a first turn that ends in an error fails the test, and records no pass" "1|rc=1|0" \
  "$(grep -c 'it ended in error' <<< "$out")|$(tail -1 <<< "$out")|$(ls "$FXA_TEAMS_DIR"/ts1.tested 2>/dev/null | grep -c .)"
# A plain call, as the profile command makes it: on the left of || bash would turn set -e off.
echo 7 > "$FXA_TEAMS_DIR/ts1.gen"   # a real team always has its generation
out="$( (set -eo pipefail; SCRIPT_DIR="$tmp/sd"; _session_try_wait() { _TRY_LAST=turn_end; return 0; }; _session_sh() { return 255; }; worktree_branch_for() { echo "$1"; }; teams_test ts1) 2>&1)"
check "a failed probe ssh under set -e still stops the runner and fails" "1|1" \
  "$(grep -c '== stopped' <<< "$out")|$(grep -c 'failed: team ts1' <<< "$out")"
rm -f "$FXA_TEAMS_DIR/ts1.json" "$FXA_TEAMS_DIR/ts2.json"
( eval "$(sed -n '/^_session_try_wait() {/,/^}/p' "$root/lib/session.sh")"
  printf '#!/bin/sh\necho "{\\"cursor\\":2,\\"events\\":[{\\"type\\":\\"text\\"},{\\"type\\":\\"error\\"}]}"\n' > "$tmp/evctl"; chmod +x "$tmp/evctl"
  check "the try wait says which event ended it" "error" "$(FXA_TRY_POLL_SECONDS=0 _session_try_wait "$tmp/evctl" k >/dev/null 2>&1; echo "${_TRY_LAST:-}")"
  exit "$fail" ) || fail=1

# The bucket: a fake gcloud keeps each object and its generation under $B.
B="$tmp/bucket"; mkdir -p "$B"; FXA_TEAMS_URI="gs://test/teams"; rm -rf "$FXA_TEAMS_DIR"; next=100
gcloud() {
  shift; local verb="$1"; shift; local a want="" uri="" src=""
  for a in "$@"; do case "$a" in --if-generation-match=*) want="${a#*=}" ;; --format=*|-q) ;; gs://*) uri="$a" ;; *) src="$a" ;; esac; done
  local o="${uri##*/}"; o="${o%%#*}"
  case "$verb" in
    ls) ls "$B"/*.json >/dev/null 2>&1 || { echo "ERROR: One or more URLs matched no objects." >&2; return 1; }
        for a in "$B"/*.json; do echo "gs://test/teams/${a##*/}"; done ;;
    # The real bucket keeps old versions: list names them (and deleted teams), describe gives the live one.
    objects) [ "$1" = describe ] && cat "$B/$o.gen" 2>/dev/null
             [ "$1" = list ] && { echo "teams/gone.json"; echo 1; cat "$B/$o.gen" 2>/dev/null; } ;;
    cat) [ "${uri##*#}" = "$(cat "$B/$o.gen" 2>/dev/null)" ] && cat "$B/$o" ;;
    cp) [ "$want" = "$(cat "$B/$o.gen" 2>/dev/null || echo 0)" ] || { echo "ERROR: HTTPError 412: Precondition Failed" >&2; return 1; }
        next=$((next + 1)); cp "$src" "$B/$o"; echo "$next" > "$B/$o.gen" ;;
    rm) [ "$want" = "$(cat "$B/$o.gen" 2>/dev/null)" ] && rm -f "$B/$o" "$B/$o.gen" ;;
  esac
}
check "sync of an empty store succeeds" "0" "$(teams_sync >/dev/null 2>&1; echo $?)"
check "create in the bucket: the cache gets the object's generation" "101|101" "$(teams_create "$(rec web Web)" >/dev/null; gen web)|$(cat "$B/web.json.gen")"
check "a write after another host's change is refused (412), and the cache keeps the old copy" "2|Web" \
  "$(cp "$B/web.json" "$B/web.tmp"; jq '.label = "Theirs"' "$B/web.tmp" > "$B/web.json"; echo 150 > "$B/web.json.gen"; teams_set web "$(rec web Mine)" >/dev/null 2>&1; echo $?)|$(jq -r .label "$FXA_TEAMS_DIR/web.json")"
check "sync brings the other host's change and its generation" "Theirs|150" "$(teams_sync >/dev/null; jq -r .label "$FXA_TEAMS_DIR/web.json")|$(gen web)"
check "set after the sync writes" "0|Mine" "$(teams_set web "$(rec web Mine)" >/dev/null 2>&1; echo $?)|$(jq -r .label "$B/web.json")"
rm -f "$B/web.json" "$B/web.json.gen"
check "sync removes a team that left the store" "no|null" "$(teams_sync >/dev/null; [ -e "$FXA_TEAMS_DIR/web.json" ] && echo yes || echo no)|$(jq -r .teams.web "$FXA_TEAMS_DIR/index.json")"

[ "$fail" = 0 ] && echo "all checks pass"; exit "$fail"
