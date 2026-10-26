#!/usr/bin/env bash
# Offline check for team records (lib/team_record.py and the record path of pipeline_load): a record
# is data that a validator checks and an allowlist maps, never sourced, and it names no host key.
#   bash lib/team-record.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
root="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
T="$tmp/teams"; mkdir -p "$T"
py() { FXA_RESERVED_TEAMS="fxa monitor" python3 -I "$root/lib/team_record.py" "$@"; }
# Every PIPE_ value after a load of <name> from the records in $T.
loaded() { ( export HOME="$tmp/home" FXA_TEAMS_DIR="$T"; unset FXA_REPO
  SANDBOX_ROOT="$root"; _FXA_PIPELINE_LOADED=; source "$root/lib/pipeline.sh"; pipeline_load "$1" >/dev/null 2>&1 || exit 1
  set | grep '^PIPE_' ); }

cat > "$T/rusty.json" <<'EOF'
{ "schema": 1, "name": "rusty", "label": "Rusty Team", "status": "active",
  "repos": [ { "slug": "example/rusty", "path": "/home/agent/rusty", "role": "work", "base": "master", "default": true },
             { "slug": "mozilla/fxa", "role": "dep" } ],
  "stack": { "kind": "fxa" }, "runner": { "backend": "gce" },
  "egress": { "requested": ["static.crates.io"], "approved": ["static.crates.io", "index.crates.io"] },
  "jira": { "project": "RUST", "queue": true }, "pr": { "open": false },
  "prompts": { "claude_md": "Run cargo test. $(touch /tmp/team-record-ran)", "guide_md": "# Rusty\n" } }
EOF
v="$(loaded rusty)"
get() { printf '%s\n' "$v" | sed -n "s/^$1=//p" | tr -d "'"; }
check "a valid record loads under its file name" "rusty|Rusty Team|master" "$(get PIPE_PROFILE)|$(get PIPE_LABEL)|$(get PIPE_BASE_BRANCH)"
check "its repo rows, default and stack dir come from the record" \
  "example/rusty /home/agent/rusty work|mozilla/fxa /home/agent/fxa dep|example/rusty|/home/agent/fxa" \
  "$(printf '%s\n' "$v" | grep -o 'example/rusty /home/agent/rusty work')|$(printf '%s\n' "$v" | grep -o 'mozilla/fxa /home/agent/fxa dep')|$(get PIPE_STACK_DEFAULT)|$(get PIPE_STACK_DIR)"
check "only approved egress reaches the firewall, PR off, Jira project set" "static.crates.io index.crates.io|0|RUST" \
  "$(get PIPE_EGRESS_EXTRA)|$(get PIPE_PR_OPEN)|$(get PIPE_JIRA_PROJECT)"
check "a record with no connectors gets none, not the bot's FxA set" "1|" "$(printf '%s\n' "$v" | grep -c '^PIPE_MCP=')|$(get PIPE_MCP)"
check "the host keys are derived from the name, not read" "$tmp/home/.claude/state/rusty|rusty-auto" "$(get PIPE_STATE_DIR)|$(get PIPE_POOL_NAME)"
check "a team's state mirror and pause marker come from its name, in the state bucket" \
  "gs://p1-fxa-ai-fixme/teams-state/rusty/state|gs://p1-fxa-ai-fixme/teams-state/rusty/PAUSED|" \
  "$(FXA_GCE_PROJECT=p1 loaded rusty | sed -n "s/^PIPE_STATE_URI=//p" | tr -d "'")|$(FXA_GCE_PROJECT=p1 loaded rusty | sed -n "s/^PIPE_PAUSE_URI=//p" | tr -d "'")|$(get PIPE_STATE_URI)"
ino() { ls -i "$1" | awk '{print $1}'; }
# Unchanged: the file is not written (its old mtime stays). Changed: a new file is renamed in (a new inode).
touch -t 200001010000 "$T/rusty/CLAUDE.md"; i1="$(ino "$T/rusty/CLAUDE.md")"; py prompts "$T/rusty.json" "$T/rusty" >/dev/null 2>&1
old="$(find "$T/rusty/CLAUDE.md" -newer "$tmp" | grep -c .)"
jq '.prompts.claude_md = "# Rusty 2"' "$T/rusty.json" > "$tmp/rusty2.json"; py prompts "$tmp/rusty2.json" "$T/rusty" >/dev/null 2>&1
check "prompts leave an unchanged file alone, and rename a changed one in whole, with no temp left" "0|# Rusty 2|new|0" \
  "$old|$(head -1 "$T/rusty/CLAUDE.md")|$([ "$(ino "$T/rusty/CLAUDE.md")" != "$i1" ] && echo new || echo same)|$(ls "$T/rusty" | grep -c tmp)"
py prompts "$T/rusty.json" "$T/rusty" >/dev/null 2>&1
check "its prompts land beside the record, as text that never runs" "Run cargo test. \$(touch /tmp/team-record-ran)|# Rusty|no" \
  "$(cat "$T/rusty/CLAUDE.md")|$(cat "$T/rusty/guide.md")|$([ -e /tmp/team-record-ran ] && echo yes || echo no)"
mkdir -p "$tmp/pf/profiles/foldy"; echo f > "$tmp/pf/profiles/foldy/CLAUDE.md"
check "profile_file finds a record's prompt, and a folder team's own file first" "$T/rusty/CLAUDE.md|$tmp/pf/profiles/foldy/CLAUDE.md" \
  "$( export FXA_TEAMS_DIR="$T"; SANDBOX_ROOT="$root"; eval "$(sed -n '/^profile_file() {/,/^}/p' "$root/lib/config.sh")"; profile_file rusty CLAUDE.md)|$( SANDBOX_ROOT="$tmp/pf"; FXA_TEAMS_DIR="$T"; eval "$(sed -n '/^profile_file() {/,/^}/p' "$root/lib/config.sh")"; profile_file foldy CLAUDE.md)"

# The validator: each rule refuses, and a refused record never loads.
bad() { printf '%s' "$2" > "$T/$1.json"; py validate "$T/$1.json" "$1" 2>&1; }
check "a host key in a record is refused" "1" "$(bad hk '{ "schema": 1, "repos": [ { "slug": "example/x", "role": "work" } ], "name": "hk", "state_uri": "gs://x" }' | grep -c 'state_uri is not a known key')"
check "a name that is not the file's is refused" "1" "$(bad n1 '{ "schema": 1, "repos": [ { "slug": "example/x", "role": "work" } ], "name": "other" }' | grep -c 'does not match')"
check "a built-in team's name is refused" "1" "$(bad fxa '{ "schema": 1, "repos": [ { "slug": "example/x", "role": "work" } ], "name": "fxa" }' | grep -c 'reserved')"
hostname_rec() { printf '{ "schema": 1, "repos": [ { "slug": "example/x", "role": "work" } ], "name": "%s" }' "$1"; }
r=""; for hn in agent-sessions agent-sessions-dev fxa-ai-fixme llm-proxy mcp-gateway teams; do r="$r $(bad "$hn" "$(hostname_rec "$hn")" | grep -c reserved)"; done
check "a name the host uses under ~/.claude/state is refused (the team would get that store)" "1 1 1 1 1 1" "${r# }"
r=""; for hn in new all routines options people; do r="$r $(bad "$hn" "$(hostname_rec "$hn")" | grep -c reserved)"; done
check "the dashboard route words new, all, routines, options and people are refused as team names" "1 1 1 1 1" "${r# }"
check "a label with a command is refused, and nothing runs" "1|no" \
  "$(bad lb '{ "schema": 1, "repos": [ { "slug": "example/x", "role": "work" } ], "name": "lb", "label": "$(touch /tmp/team-record-lb)" }' | grep -c 'label')|$([ -e /tmp/team-record-lb ] && echo yes || echo no)"
check "a repo slug with a shell character is refused" "1" "$(bad sl '{ "schema": 1, "name": "sl", "repos": [ { "slug": "a/b;rm", "role": "work" } ] }' | grep -c 'slug')"
check "a repo path outside /home/agent is refused" "1" "$(bad pa '{ "schema": 1, "name": "pa", "repos": [ { "slug": "a/b", "path": "/etc", "role": "work" } ] }' | grep -c 'path')"
check "a record with no work repo is refused" "1" "$(bad nw '{ "schema": 1, "name": "nw", "repos": [ { "slug": "a/b", "role": "dep" } ] }' | grep -c 'work repo')"
check "an FxA stack with no mozilla/fxa row is refused" "1" "$(bad sk '{ "schema": 1, "repos": [ { "slug": "example/x", "role": "work" } ], "name": "sk", "stack": { "kind": "fxa" } }' | grep -c 'mozilla/fxa')"
check "a launch cap over the operator ceiling is refused" "1" "$(bad cp '{ "schema": 1, "repos": [ { "slug": "example/x", "role": "work" } ], "name": "cp", "caps": { "launches_per_day": 500 } }' | grep -c 'launches_per_day')"
check "an egress host that is not a hostname is refused" "1" "$(bad eg '{ "schema": 1, "repos": [ { "slug": "example/x", "role": "work" } ], "name": "eg", "egress": { "approved": ["x.com;curl"] } }' | grep -c 'egress')"
check "a refused record does not load" "1" "$(loaded hk >/dev/null; echo $?)"
# A folder is a folder team only with a profile.conf: one that holds only boot.sh or skills reserves no name.
FR="$tmp/fr"; mkdir -p "$FR/profiles/foldt" "$FR/profiles/assets"; ln -s "$root/lib" "$FR/lib"
printf 'PIPE_PROFILE="foldt"\nPIPE_LABEL="Fold T"\nPIPE_REPOS=(\n  "example/x /home/agent/x work"\n)\n' > "$FR/profiles/foldt/profile.conf"; echo 'echo boot' > "$FR/profiles/assets/boot.sh"
for n in assets foldt; do printf '{ "schema": 1, "name": "%s", "label": "Rec %s", "repos": [ { "slug": "mozilla/fxa", "role": "work" } ], "stack": { "kind": "fxa" } }' $n $n > "$T/$n.json"; done
fl() { ( export HOME="$tmp/home" FXA_TEAMS_DIR="$T"; SANDBOX_ROOT="$FR"; _FXA_PIPELINE_LOADED=; source "$root/lib/pipeline.sh"; pipeline_load "$1" >/dev/null 2>&1 && echo "$PIPE_LABEL" ); }
check "a folder with only boot.sh lets its record load; a folder with profile.conf still wins; only that one is a folder team" "Rec assets|Fold T|foldt" \
  "$(fl assets)|$(fl foldt)|$( SANDBOX_ROOT="$FR"; _FXA_PIPELINE_LOADED=; source "$root/lib/pipeline.sh"; pipeline_folder_teams | paste -sd, -)"
check "the index has no reserved names, so a host with the folder writes the index a host without writes; fxa-android is free" "Rec foldt|0" \
  "$(FXA_RESERVED_TEAMS= python3 -I "$root/lib/team_record.py" index "$T" | jq -r '.teams.foldt.label')|$(bad fxa-android '{ "schema": 1, "name": "fxa-android", "repos": [ { "slug": "mozilla/fxa", "role": "work" } ], "stack": { "kind": "fxa" } }' | grep -c reserved)"
rm -f "$T/assets.json" "$T/foldt.json" "$T/fxa-android.json"
check "an approved egress host that takes data out is refused, with its subdomains; a normal one is fine" "1|1|0" \
  "$(bad e1 '{ "schema": 1, "name": "e1", "repos": [ { "slug": "mozilla/fxa", "role": "work" } ], "stack": { "kind": "fxa" }, "egress": { "approved": ["pastebin.com"] } }' | grep -c 'take data out')|$(bad e2 '{ "schema": 1, "name": "e2", "repos": [ { "slug": "mozilla/fxa", "role": "work" } ], "stack": { "kind": "fxa" }, "egress": { "approved": ["abc.ngrok-free.app"] } }' | grep -c 'take data out')|$(bad e3 '{ "schema": 1, "name": "e3", "repos": [ { "slug": "mozilla/fxa", "role": "work" } ], "stack": { "kind": "fxa" }, "egress": { "approved": ["static.crates.io"] } }' | grep -c .)"
rm -f "$T"/e1.json "$T"/e2.json "$T"/e3.json
check "a team without the FxA stack must bring its own goal" "1" "$(bad ng '{ "schema": 1, "name": "ng", "repos": [ { "slug": "a/b", "role": "work" } ] }' | grep -c 'goal_md')"
check "a repo row keeps its own base branch, for that tree" "example/rusty /home/agent/rusty work master" "$(printf '%s\n' "$v" | grep -o 'example/rusty /home/agent/rusty work master')"
rm -f "$T"/ng.json "$T"/hk.json "$T"/n1.json "$T"/fxa.json "$T"/lb.json "$T"/sl.json "$T"/pa.json "$T"/nw.json "$T"/sk.json "$T"/cp.json "$T"/eg.json "$T"/monitor.json

# Code a record names: skills from the catalog, a boot script of the repo pinned by its hash.
R="$tmp/repo"; mkdir -p "$R/boot" "$R/skills"; printf 'android-verify\n# a comment\n' > "$R/skills/team-catalog.txt"
printf '#!/bin/bash\necho boot\n' > "$R/boot/rusty.sh"; pin="$( { sha256sum "$R/boot/rusty.sh" 2>/dev/null || shasum -a 256 "$R/boot/rusty.sh"; } | cut -d' ' -f1)"
code() { printf '{ "schema": 1, "name": "cd", "repos": [ { "slug": "mozilla/fxa", "role": "work" } ], "stack": { "kind": "fxa" }%s }' "$1" > "$T/cd.json"; FXA_TEAM_REPO="$R" py env "$T/cd.json" cd 2>&1; }
check "a goal that would push the rendered /goal over Claude's 4000 chars is refused; 2500 fits" "1|0" \
  "$(code ", \"prompts\": { \"goal_md\": \"$(printf 'x%.0s' $(seq 1 2600))\" }" | grep -c 'goal_md must be text')|$(code ", \"prompts\": { \"goal_md\": \"$(printf 'y%.0s' $(seq 1 2500))\" }" | grep -c 'goal_md must be text')"
check "a record with no row marked default sets no stack default, so its sessions are not trees sessions" "0|1" \
  "$(code '' | grep -c '^PIPE_STACK_DEFAULT')|$(code '' | grep -c '^PIPE_BASE_BRANCH')"
check "a catalog skill and a pinned boot script reach the loader" "android-verify|rusty|$pin" \
  "$(code ", \"skills\": [\"android-verify\"], \"boot\": { \"script\": \"rusty\", \"sha256\": \"$pin\" }" | awk -F'\t' '/^PIPE_TEAM_SKILLS|^PIPE_BOOT_SCRIPT|^PIPE_BOOT_SHA256/{print $2}' | paste -sd'|' -)"
check "a skill off the catalog is refused" "1" "$(code ', "skills": ["fxa-manager"]' | grep -c "not on skills/team-catalog.txt")"
check "a boot script outside boot/ is refused" "1" "$(code ', "boot": { "script": "../x", "sha256": "'"$pin"'" }' | grep -c 'boot.script')"
printf 'echo edited\n' >> "$R/boot/rusty.sh"
check "a boot script edited since its pin is refused, with the new hash to review" "1" \
  "$(code ", \"boot\": { \"script\": \"rusty\", \"sha256\": \"$pin\" }" | grep -c 'changed since it was pinned: review it, then pin [0-9a-f]\{64\}')"
# The runner: the pinned version runs; an edited one does not reach the runner.
eval "$(sed -n '/^_gce_profile_boot() {/,/^}/p;/^_vm_skill_allowlist() {/,/^}/p' "$root/lib/agent.sh")"
android_overlay() { :; }; _vm_repo_dirs() { :; }; vm_exec() { printf '%s' "$*" > "$tmp/vm"; }
boot() { : > "$tmp/vm"; ( SANDBOX_ROOT="$R"; PIPE_PROFILE=cd PIPE_BOOT_SCRIPT=rusty PIPE_BOOT_SHA256="$1"; _gce_profile_boot r >/dev/null 2>&1; echo $? ); }
now="$( { sha256sum "$R/boot/rusty.sh" 2>/dev/null || shasum -a 256 "$R/boot/rusty.sh"; } | cut -d' ' -f1)"
check "the runner gets the pinned script; a stale pin runs nothing" "0|1|1|0" \
  "$(boot "$now")|$(grep -c "$(base64 < "$R/boot/rusty.sh" | tr -d '\n' | cut -c1-30)" "$tmp/vm")|$(boot "$pin")|$(wc -c < "$tmp/vm" | tr -d ' ')"
check "a record's skills are in the runner's allowlist" "1" "$(PIPE_TEAM_SKILLS="android-verify" _vm_skill_allowlist | grep -cx android-verify)"
rm -f "$T/cd.json" "$T/cd.gen"; rm -rf "$T/cd"
# A row's fourth field (its base) must not leak into its role: every row reader takes four fields.
eval "$(sed -n '/^_session_dirty_trees() {/,/^}/p' "$root/lib/session.sh")"
_session_sh() { printf '%s' "$2"; }
check "a dep row with a base is still a dep (the read-only trees list it)" "1" \
  "$(PIPE_REPOS=("example/w /home/agent/w work main" "example/d /home/agent/d dep master"); _session_dirty_trees r | grep -c 'for p in /home/agent/d;')"
check "every reader of a repo row takes the fourth field apart" "" \
  "$(grep -nE 'read -r [a-z_]+ [a-z_]+ [a-z_]+ <<< "\$row"' "$root"/lib/*.sh "$root/fxa-sandbox-ctl" | grep -v check.sh || true)"

# A team's own Jira credential: a Secret Manager name of its own; the loader reads it, logs acli in once.
check "secrets.jira must be the team's own fxa-team-<name>-* name" "0|1" \
  "$(code ', "secrets": { "jira": "fxa-team-cd--jira" }' | grep -c 'secrets.jira')|$(code ', "secrets": { "jira": "fxa-team-other--jira" }' | grep -c 'secrets.jira')"
mkdir -p "$tmp/fake"; cat > "$tmp/fake/gcloud" <<G
#!/bin/bash
echo "\$*" >> "$tmp/gcloud.calls"; cat "$tmp/secret"
G
cat > "$tmp/fake/acli" <<G
#!/bin/bash
echo "HOME=\$HOME \$* token=\$(cat)" >> "$tmp/acli.calls"
G
chmod +x "$tmp/fake/gcloud" "$tmp/fake/acli"
printf '{ "schema": 1, "name": "jt", "repos": [ { "slug": "mozilla/fxa", "role": "work" } ], "stack": { "kind": "fxa" }, "secrets": { "jira": "fxa-team-jt--jira" } }' > "$T/jt.json"
printf 'bot@example.com:tok123' > "$tmp/secret"
jl() { ( PATH="$tmp/fake:$PATH" FXA_TEAMS_SECRET_DIR="$tmp/tsec" loaded jt | grep -E '^PIPE_JIRA_BASIC=' ); }
first="$(jl)"; second="$(jl)"; acli_logins="$(grep -c 'jira auth login' "$tmp/acli.calls")"
check "the team's credential becomes its PIPE_JIRA_BASIC; acli logs in once, in the team's home" \
  "PIPE_JIRA_BASIC=bot@example.com:tok123|1|1|1" \
  "$(tr -d "'" <<< "$first")|$acli_logins|$(grep -c "HOME=$tmp/tsec/jt/acli-home jira auth login --site mozilla-hub.atlassian.net --email bot@example.com --token token=tok123" "$tmp/acli.calls")|$([ "$first" = "$second" ] && echo 1)"
check "the cached credential is private and outside the mirrored state dir" "600" \
  "$(stat -c %a "$tmp/tsec/jt/jira.basic" 2>/dev/null || stat -f %Lp "$tmp/tsec/jt/jira.basic")"
printf 'not-a-credential' > "$tmp/secret"; rm -f "$tmp/tsec/jt/jira.basic"
check "a secret that is not email:token stops the load" "1" "$(PATH="$tmp/fake:$PATH" FXA_TEAMS_SECRET_DIR="$tmp/tsec" loaded jt >/dev/null; echo $?)"
check "acli runs in the team's home when one is set, else in the real one" "HOME=/x/home a b|HOME=$HOME c" \
  "$( : > "$tmp/acli.calls"; ( eval "$(sed -n '/^_acli_once() {/,/^}/p' "$root/lib/jira.sh")"; PATH="$tmp/fake:$PATH"; FXA_ACLI_HOME=/x/home _acli_once a b < /dev/null; unset FXA_ACLI_HOME; _acli_once c < /dev/null ); sed 's/ token=$//' "$tmp/acli.calls" | paste -sd'|' -)"
rm -f "$T/jt.json"

# Spend caps for each team: the record's caps, inside the operator ceilings, reach the proxy's team file.
check "a team's dollar caps must be above 0 and within the ceilings" "0|1|1" \
  "$(code ', "caps": { "usd_per_day": 25, "usd_per_month": 400 }' | grep -c 'caps\.')|$(code ', "caps": { "usd_per_day": 0 }' | grep -c 'caps.usd_per_day')|$(code ', "caps": { "usd_per_month": 99999 }' | grep -c 'caps.usd_per_month')"
check "the caps reach the loader" "25|400" \
  "$(code ', "caps": { "usd_per_day": 25, "usd_per_month": 400 }' | awk -F'\t' '/^PIPE_TEAM_USD_DAY/{d=$2} /^PIPE_TEAM_USD_MONTH/{m=$2} END{print d "|" m}')"
tok() { ( source "$root/lib/llm-token.sh"; FXA_LLM_PROXY_DIR="$tmp/proxy" PIPE_PROFILE="$1" PIPE_TEAM_USD_DAY="$2" PIPE_TEAM_USD_MONTH="$3" llm_token_for "run-$1" ) >/dev/null; }
tok capped 25 400; tok plain "" ""
check "a run token names its team, and the team file holds the record's caps (none for a team without)" \
  "capped|{\"day_usd\":25,\"month_usd\":400}|{}" \
  "$(jq -r .team "$tmp"/proxy/tokens/$(cat "$tmp/proxy/runs/run-capped").json)|$(jq -c . "$tmp/proxy/teams/capped.json")|$(jq -c . "$tmp/proxy/teams/plain.json")"

# Runtime secrets: names of the team's own, written inside its own repo folders, never on a command line.
check "a runtime secret must be the team's own, and land inside one of its repo folders" "0|1|1|1" \
  "$(code ', "repos": [ { "slug": "mozilla/fxa", "role": "work" }, { "slug": "mozilla/cfg", "role": "dep" } ], "secrets": { "runtime": [ { "secret": "fxa-team-cd--db", "path": "/home/agent/cfg/.env.db" } ] }' | grep -c 'secrets.runtime')|$(code ', "secrets": { "runtime": [ { "secret": "fxa-team-other--db", "path": "/home/agent/fxa/.env" } ] }' | grep -c 'secrets.runtime\[0\].secret')|$(code ', "secrets": { "runtime": [ { "secret": "fxa-team-cd--db", "path": "/home/agent/.bashrc" } ] }' | grep -c 'secrets.runtime\[0\].path')|$(code ', "secrets": { "runtime": [ { "secret": "fxa-team-cd--db", "path": "/home/agent/other/x" } ] }' | grep -c 'secrets.runtime\[0\].path')"
check "a value that ends in a newline is refused (slug, base)" "1|1" \
  "$(code ', "repos": [ { "slug": "mozilla/fxa\n", "role": "work" } ]' | grep -c 'slug must be owner/name')|$(code ', "repos": [ { "slug": "mozilla/fxa", "role": "work", "base": "main\n" } ]' | grep -c 'base is not a branch name')"
check "Mozilla/fxa with the FxA stack validates and loads as mozilla/fxa, as GitHub reads slugs without case" "0|1|1" \
  "$(code ', "repos": [ { "slug": "Mozilla/fxa", "role": "work" } ]' | grep -cE 'Error|Traceback|must|needs')|$(code ', "repos": [ { "slug": "Mozilla/fxa", "role": "work" } ]' | grep -c '^PIPE_STACK_DIR')|$(code ', "repos": [ { "slug": "Mozilla/fxa", "role": "work" } ]' | grep -c '^REPO	mozilla/fxa ')"
check "a label or a repo path that ends in a newline is refused too" "1|1" \
  "$(code ', "label": "Team\n"' | grep -c 'label')|$(code ', "repos": [ { "slug": "mozilla/fxa", "role": "work", "path": "/home/agent/fxa\n" } ]' | grep -c 'path must')"
check "a pipelines/<name>.conf alias is a reserved name" "1" \
  "$(bad fxa-ai-fixme '{ "schema": 1, "repos": [ { "slug": "example/x", "role": "work" } ], "name": "fxa-ai-fixme", "prompts": { "goal_md": "g" } }' | grep -c reserved)"
check "a slug part of . or .. is refused" "1" \
  "$(code ', "repos": [ { "slug": "mozilla/..", "role": "work" } ]' | grep -c 'slug must be owner/name')"
check "a runtime secret in a work repo is refused, since its files can ship in a PR" "1" \
  "$(code ', "secrets": { "runtime": [ { "secret": "fxa-team-cd--db", "path": "/home/agent/fxa/.env.db" } ] }' | grep -c 'is in a work repo')"
eval "$(sed -n '/^_team_runtime_secrets() {/,/^}/p' "$root/lib/agent.sh")"
R2="$tmp/rt"; mkdir -p "$R2/home/agent/fxa/.git/info"
gcloud() { case "$*" in *fxa-team-cd--db*) printf 'DB=postgres://s3cret' ;; *) return 1 ;; esac; }
# The runner: the script after "sudo -u agent bash -c" runs here, with /home/agent moved under $R2.
vm_exec() { shift 6; printf '%s\n' "$*" >> "$tmp/rt.cmds"; bash -c "${1//\/home\/agent/$R2/home/agent}"; }
PIPE_RUNTIME_SECRETS="fxa-team-cd--db=/home/agent/fxa/config/.env.db"; _team_runtime_secrets r 2>/dev/null; rc=$?
check "a runtime secret lands at its path, mode 600, out of git, and never on a command line" "0|DB=postgres://s3cret|600|1|0" \
  "$rc|$(cat "$R2/home/agent/fxa/config/.env.db")|$(stat -c %a "$R2/home/agent/fxa/config/.env.db" 2>/dev/null || stat -f %Lp "$R2/home/agent/fxa/config/.env.db")|$(grep -cx '/config/.env.db' "$R2/home/agent/fxa/.git/info/exclude")|$(grep -c 's3cret' "$tmp/rt.cmds")"
vm_exec() { shift 6; bash -c "${1//\/home\/agent/$R2/home/agent}" < /dev/null; }   # stdin used up (an ssh retry)
rm -f "$R2/home/agent/fxa/config/.env.db"; PIPE_RUNTIME_SECRETS="fxa-team-cd--db=/home/agent/fxa/config/.env.db"; _team_runtime_secrets r 2>/dev/null; rc=$?
check "a short read fails and leaves no file" "1|no|0" \
  "$rc|$([ -e "$R2/home/agent/fxa/config/.env.db" ] && echo yes || echo no)|$(ls -A "$R2/home/agent/fxa/config" | grep -c fxa-secret)"
unset -f gcloud vm_exec
# A trailing newline survives (an ssh key, a PEM); a path git tracks is refused, since exclude would not cover it.
gcloud() { printf 'KEY\nline2\n'; }
vm_exec() { shift 6; bash -c "${1//\/home\/agent/$R2/home/agent}"; }
PIPE_RUNTIME_SECRETS="fxa-team-cd--db=/home/agent/fxa/id_key"; _team_runtime_secrets r 2>/dev/null
check "a runtime secret keeps its trailing newline" "$(printf 'KEY\nline2\n' | od -c | head -2 | tr -s ' ')" "$(od -c < "$R2/home/agent/fxa/id_key" | head -2 | tr -s ' ')"
( cd "$R2/home/agent/fxa" && git init -q . 2>/dev/null; echo tracked > app.cfg && git add app.cfg && git -c user.email=t@example.com -c user.name=t commit -qm x )
PIPE_RUNTIME_SECRETS="fxa-team-cd--db=/home/agent/fxa/app.cfg"; out="$(_team_runtime_secrets r 2>&1)"; rc=$?
check "a path git tracks is refused, and the tracked file is left as it was" "1|1|tracked" \
  "$rc|$(grep -c 'is a file git tracks' <<< "$out")|$(cat "$R2/home/agent/fxa/app.cfg")"
unset -f gcloud vm_exec
check "a team name may not hold -- (it separates a team's secrets)" "1" "$(bad n--x '{ "schema": 1, "name": "n--x", "repos": [ { "slug": "a/b", "role": "work" } ] }' | grep -c 'no --')"
check "team pay cannot name a secret of team pay-x" "1" \
  "$(printf '{ "schema": 1, "name": "pay", "repos": [ { "slug": "mozilla/fxa", "role": "work" } ], "stack": { "kind": "fxa" }, "secrets": { "jira": "fxa-team-pay-x--jira" } }' > "$T/pay.json"; py validate "$T/pay.json" pay 2>&1 | grep -c 'secrets.jira')"
rm -f "$T/pay.json" "$T/n--x.json"

# MCP: another team's token carries its own Jira project and repos; FxA's carries none (the rules as written).
mt() { ( source "$root/lib/mcp-token.sh"; FXA_MCP_GATEWAY_DIR="$tmp/mcp" PIPE_PROFILE="$1" PIPE_JIRA_PROJECT="$2"; PIPE_REPOS=(); [ -z "$3" ] || eval "PIPE_REPOS=($3)"
  t="$(mcp_token_for "mt-$1" jira,github)" && jq -c '.scope // "none"' "$tmp/mcp/tokens/$t.json" ); }
check "an MCP token names the team's Jira project and repos; FxA's names none" \
  '{"jira_projects":["PAY"],"repos":["mozilla/fxa","mozilla/PyFxA"]}|"none"' \
  "$(mt ent PAY '"mozilla/fxa /home/agent/fxa work" "mozilla/PyFxA /home/agent/pyfxa dep"')|$(mt fxa '' '')"

# A folder profile may not set a host key, or name another team.
f="$tmp/r/profiles/evil"; mkdir -p "$f"
lint() { printf '%s\n' "$@" > "$f/profile.conf"; ( source "$root/lib/pipeline.sh"; pipeline_conf_lint "$f/profile.conf" >/dev/null; echo $? ); }
check "a folder profile that sets a host key is refused" "1|1" "$(lint 'PIPE_REPO_SLUG="a/b"' 'PIPE_STATE_URI="gs://elsewhere/x"')|$(lint 'PIPE_RELOCK_CMD=rm')"
check "a folder profile that names another team is refused; its own name is fine" "1|0" \
  "$(lint 'PIPE_REPO_SLUG="a/b"' 'PIPE_PROFILE="fxa"')|$(lint 'PIPE_REPO_SLUG="a/b"' 'PIPE_PROFILE="evil"')"

# profile list: every team, records too; one that does not load is named, not dropped.
printf '{ "schema": 1, "name": "broken", "repos": [] }' > "$T/broken.json"
mkdir -p "$tmp/home/.ssh"; out="$(cd "$root" && HOME="$tmp/home" FXA_TEAMS_DIR="$T" ./fxa-sandbox-ctl profile list 2>"$tmp/err")"
check "profile list holds the record's team" "1" "$(jq '[.[] | select(.profile == "rusty")] | length' <<< "$out")"
check "a record that does not load is named on stderr" "1" "$(grep -c 'profile list: broken does not load' "$tmp/err")"
rm -f "$T/broken.json"

# A team that takes the secret tickets of a project, on its private fork of FxA.
S="$tmp/secret-teams"; mkdir -p "$S"
srec() { printf '{ "schema": 1, "name": "%s", "label": "FxA Private", "repos": [ { "slug": "mozilla/fxa-private", "path": "/home/agent/fxa", "role": "work" } ], "stack": { "kind": "fxa", "repo": "mozilla/fxa-private" }, "jira": { "project": "FXA", "queue": true, "secret": true }, "access": { "users": ["U012345"] }%s }' "$1" "${2:-}" > "$S/$1.json"; echo "$S/$1.json"; }
uq() { FXA_BUILTIN_JIRA='FXA:fxa' py unique "$1" "$S" 2>&1; }
senv="$(py env "$(srec fxa-private)" fxa-private)"
sget() { printf '%s\n' "$senv" | awk -F'\t' -v k="$1" '$1 == k {print $2}'; }
check "a secret team on an FxA fork is valid beside fxa; its env names its labels and its stack dir" "0||1|ai-fixme|ai-fixme-private|/home/agent/fxa" \
  "$(py validate "$S/fxa-private.json" fxa-private >/dev/null 2>&1; echo $?)|$(uq "$S/fxa-private.json")|$(sget PIPE_SECRET_TICKETS)|$(sget PIPE_QUEUE_LABEL)|$(sget PIPE_LABEL_PREFIX)|$(sget PIPE_STACK_DIR)"
two="$(uq "$(srec fxa-private2)")"; rm -f "$S/fxa-private2.json"
printf '{ "schema": 1, "name": "pub", "repos": [ { "slug": "example/pub", "role": "work" } ], "prompts": { "goal_md": "g" }, "jira": { "project": "FXA", "queue": true } }' > "$S/pub.json"
pub="$(uq "$S/pub.json")"; rm -f "$S/pub.json"
check "a second secret team for FXA is refused; a public record for FXA keeps today's line" "1|1" \
  "$(grep -c "Jira project FXA's secret tickets belong to team fxa-private: remove jira.secret, or use a different jira.project" <<< "$two")|$(grep -c 'Jira project FXA belongs to team fxa' <<< "$pub")"
check "a secret team cannot be open, list Jira prefixes, or go without a queue" "1|1|1" \
  "$(py validate "$(srec so ', "access": { "open": true }')" so 2>&1 | grep -c 'cannot be open')|$(py validate "$(srec sp ', "access": { "users": ["U012345"], "jira_prefixes": ["FXA"] }')" sp 2>&1 | grep -c 'cannot list access.jira_prefixes')|$(sed 's/"queue": true, //' "$(srec sq)" > "$S/sq2.json"; py validate "$S/sq2.json" sq2 2>&1 | grep -c 'jira.secret needs jira.project and jira.queue')"
rm -f "$S"/so.json "$S"/sp.json "$S"/sq.json "$S"/sq2.json
check "stack.repo must be one of the record's repos; the index marks the secret team" "1|true|false" \
  "$(sed 's#"repo": "mozilla/fxa-private"#"repo": "mozilla/other"#' "$S/fxa-private.json" > "$S/sr.json"; py validate "$S/sr.json" sr 2>&1 | grep -c 'stack.repo must be the slug'; rm -f "$S/sr.json")|$(FXA_RESERVED_TEAMS= python3 -I "$root/lib/team_record.py" index "$S" | jq -r '.teams["fxa-private"].secret')|$(FXA_RESERVED_TEAMS= python3 -I "$root/lib/team_record.py" index "$T" | jq -r '.teams.rusty.secret')"

fsrc() { ( export HOME="$tmp/home" FXA_TEAMS_DIR="$T"; unset FXA_REPO
  SANDBOX_ROOT="$root"; _FXA_PIPELINE_LOADED=; source "$root/lib/pipeline.sh"; pipeline_load "$1" >/dev/null 2>&1 || exit 1
  echo "${FXA_SECRETS_SOURCE:-none}" ); }
cp "$S/fxa-private.json" "$T/fxa-private.json"
check "an FxA fork that runs the stack from its own repo takes the FxA dev secrets from the FxA host clone; FxA as a dep row does not" \
  "$tmp/home/Desktop/working2/fxa|none" "$( (unset FXA_SECRETS_SOURCE; fsrc fxa-private))|$( (unset FXA_SECRETS_SOURCE; fsrc rusty))"
check "a child does not keep the source its parent's load set; a source set by hand wins" "none|/mine" \
  "$(FXA_SECRETS_SOURCE=/x _FXA_SECRETS_LOADED=/x fsrc rusty)|$(FXA_SECRETS_SOURCE=/mine fsrc fxa-private)"
check "a load after a secret team's load keeps none of its flag, labels or queue" "|ai-fixme|ai-fixme|ai-fixme" \
  "$( ( export HOME="$tmp/home" FXA_TEAMS_DIR="$T"; unset FXA_REPO; SANDBOX_ROOT="$root"; _FXA_PIPELINE_LOADED=; source "$root/lib/pipeline.sh"
    pipeline_load fxa-private >/dev/null 2>&1 && pipeline_load rusty >/dev/null 2>&1 || exit 1
    printf '%s|%s|%s|%s' "${PIPE_SECRET_TICKETS:-}" "$PIPE_QUEUE_LABEL" "$PIPE_LABEL_PREFIX" "$(grep -o '"ai-fixme[a-z-]*"' <<< "$PIPE_QUEUE_JQL" | tr -d '"')" ) )"
sv="$(loaded fxa-private)"; rm -f "$T/fxa-private.json"
sl() { printf '%s\n' "$sv" | sed -n "s/^$1=//p" | tr -d "'"; }
check "a secret record loads its flag, its labels and a queue that reads ai-fixme" '1|ai-fixme|ai-fixme-private|labels = "ai-fixme" AND statusCategory != Done ORDER BY created ASC' \
  "$(sl PIPE_SECRET_TICKETS)|$(sl PIPE_QUEUE_LABEL)|$(sl PIPE_LABEL_PREFIX)|$(sl PIPE_QUEUE_JQL)"
printf 'PIPE_REPO_SLUG=example/x\nPIPE_SECRET_TICKETS=1\n' > "$tmp/folder.conf"
check "a folder conf cannot make itself a secret team (a host key)" "1" "$( (source "$root/lib/pipeline.sh"; pipeline_conf_lint "$tmp/folder.conf") 2>&1 | grep -c 'host key: .*PIPE_SECRET_TICKETS')"

# options: the dashboard's choices, with the connector names only (never a URL or a header) and the boot pins.
mkdir -p "$tmp/opt/boot" "$tmp/opt/skills"; printf 'echo hi\n' > "$tmp/opt/boot/web-setup.sh"; printf '# c\nfxa-stack\nzz\n' > "$tmp/opt/skills/team-catalog.txt"
printf '{"connectors":{"jira":{"url":"https://jira.example.com/mcp","headers":{"Authorization":"Bearer x"}},"Bad Name":{}}}' > "$tmp/opt/gw.json"
o="$(FXA_TEAM_REPO="$tmp/opt" MCP_GATEWAY_CONFIG="$tmp/opt/gw.json" TEAM_CAP_USD_PER_DAY=50 python3 -I "$root/lib/team_record.py" options)"
check "options: caps from the env, the catalog, a valid connector name only, and each boot script with its pin" "50|fxa-stack,zz|jira|web-setup:$(shasum -a 256 "$tmp/opt/boot/web-setup.sh" | cut -c1-64)|0" \
  "$(jq -r '.caps.usd_per_day' <<< "$o")|$(jq -r '.skills | join(",")' <<< "$o")|$(jq -r '.connectors | join(",")' <<< "$o")|$(jq -r '.boot[0] | .script + ":" + .sha256' <<< "$o")|$(grep -c 'example.com\|Bearer' <<< "$o")"
check "options: no gateway config gives null connectors, not an empty list" "null" "$(FXA_TEAM_REPO="$tmp/opt" MCP_GATEWAY_CONFIG="$tmp/none.json" python3 -I "$root/lib/team_record.py" options | jq -c .connectors)"

[ "$fail" = 0 ] && echo "all checks pass"; exit "$fail"
