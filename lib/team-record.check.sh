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
check "its prompts land beside the record, as text that never runs" "Run cargo test. \$(touch /tmp/team-record-ran)|# Rusty|no" \
  "$(cat "$T/rusty/CLAUDE.md")|$(cat "$T/rusty/guide.md")|$([ -e /tmp/team-record-ran ] && echo yes || echo no)"
check "profile_file finds a record's prompt, and a folder team's own file first" "$T/rusty/CLAUDE.md|$root/profiles/monitor/CLAUDE.md" \
  "$( export FXA_TEAMS_DIR="$T"; SANDBOX_ROOT="$root"; eval "$(sed -n '/^profile_file() {/,/^}/p' "$root/lib/config.sh")"; profile_file rusty CLAUDE.md)|$( SANDBOX_ROOT="$root"; FXA_TEAMS_DIR="$T"; eval "$(sed -n '/^profile_file() {/,/^}/p' "$root/lib/config.sh")"; profile_file monitor CLAUDE.md)"

# The validator: each rule refuses, and a refused record never loads.
bad() { printf '%s' "$2" > "$T/$1.json"; py validate "$T/$1.json" "$1" 2>&1; }
check "a host key in a record is refused" "1" "$(bad hk '{ "schema": 1, "repos": [ { "slug": "example/x", "role": "work" } ], "name": "hk", "state_uri": "gs://x" }' | grep -c 'state_uri is not a known key')"
check "a name that is not the file's is refused" "1" "$(bad n1 '{ "schema": 1, "repos": [ { "slug": "example/x", "role": "work" } ], "name": "other" }' | grep -c 'does not match')"
check "a built-in team's name is refused" "1" "$(bad fxa '{ "schema": 1, "repos": [ { "slug": "example/x", "role": "work" } ], "name": "fxa" }' | grep -c 'reserved')"
check "a label with a command is refused, and nothing runs" "1|no" \
  "$(bad lb '{ "schema": 1, "repos": [ { "slug": "example/x", "role": "work" } ], "name": "lb", "label": "$(touch /tmp/team-record-lb)" }' | grep -c 'label')|$([ -e /tmp/team-record-lb ] && echo yes || echo no)"
check "a repo slug with a shell character is refused" "1" "$(bad sl '{ "schema": 1, "name": "sl", "repos": [ { "slug": "a/b;rm", "role": "work" } ] }' | grep -c 'slug')"
check "a repo path outside /home/agent is refused" "1" "$(bad pa '{ "schema": 1, "name": "pa", "repos": [ { "slug": "a/b", "path": "/etc", "role": "work" } ] }' | grep -c 'path')"
check "a record with no work repo is refused" "1" "$(bad nw '{ "schema": 1, "name": "nw", "repos": [ { "slug": "a/b", "role": "dep" } ] }' | grep -c 'work repo')"
check "an FxA stack with no mozilla/fxa row is refused" "1" "$(bad sk '{ "schema": 1, "repos": [ { "slug": "example/x", "role": "work" } ], "name": "sk", "stack": { "kind": "fxa" } }' | grep -c 'mozilla/fxa')"
check "a launch cap over the operator ceiling is refused" "1" "$(bad cp '{ "schema": 1, "repos": [ { "slug": "example/x", "role": "work" } ], "name": "cp", "caps": { "launches_per_day": 500 } }' | grep -c 'launches_per_day')"
check "an egress host that is not a hostname is refused" "1" "$(bad eg '{ "schema": 1, "repos": [ { "slug": "example/x", "role": "work" } ], "name": "eg", "egress": { "approved": ["x.com;curl"] } }' | grep -c 'egress')"
check "a refused record does not load" "1" "$(loaded hk >/dev/null; echo $?)"
check "a folder profile wins over a record of the same name" "Monitor Team" \
  "$(printf '%s' '{ "schema": 1, "repos": [ { "slug": "example/x", "role": "work" } ], "name": "monitor", "label": "Not Monitor" }' > "$T/monitor.json"; loaded monitor | sed -n "s/^PIPE_LABEL=//p" | tr -d "'")"
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

[ "$fail" = 0 ] && echo "all checks pass"; exit "$fail"
