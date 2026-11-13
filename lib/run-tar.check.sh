#!/usr/bin/env bash
# Offline check that the gce run tar, which holds the run's credentials, never stays in LOG_DIR.
#   bash lib/run-tar.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
here="$(cd "$(dirname "$0")" && pwd)"
eval "$(sed -n '/^_put_run_files() {/,/^}/p' "$here/agent.sh")"
worktree_secret_files() { :; }
LOG_DIR="$tmp/logs"; mkdir -p "$LOG_DIR" "$tmp/slot"; echo 'export ANTHROPIC_API_KEY=sk-ant-test-x' > "$tmp/slot/.fxa-auto-token"
# tar dies part way: it has written some of the archive.
tar() { while [ "$1" != -czf ]; do shift; done; echo partial > "$2"; return 1; }
vm_put() { echo put >> "$tmp/puts"; }; vm_exec() { :; }
_put_run_files agent-x1 "$tmp/slot" >/dev/null 2>&1; rc=$?
check "a tar that fails part way leaves no archive and ships nothing" "1|no|no" "$rc|$([ -e "$LOG_DIR/agent-x1-run.tar" ] && echo yes || echo no)|$([ -e "$tmp/puts" ] && echo yes || echo no)"
check "agent_stop removes a run tar a killed launch left" "yes" \
  "$(sed -n '/^agent_stop() {/,/^}/p' "$here/agent.sh" | grep -q 'rm -f .*"${LOG_DIR}/${name}-run.tar"' && echo yes)"
# The host's Figma export ships into the runner with the run files.
mkdir -p "$tmp/slot/.fxa-auto-design"; echo svg > "$tmp/slot/.fxa-auto-design/phone.svg"
tar() { while [ "$1" != -czf ]; do shift; done; shift; shift; printf '%s\n' "$@" > "$tmp/tarred"; : > "$LOG_DIR/agent-x2-run.tar"; }
_put_run_files agent-x2 "$tmp/slot" >/dev/null 2>&1
check "the design folder from Figma ships with the run files" "1" "$(grep -cx './.fxa-auto-design' "$tmp/tarred")"
# A DB dump: it ships, and the restore runs the mysql client as the agent, with LOCAL INFILE and \! off.
echo 'CREATE DATABASE fxa;' | gzip > "$tmp/slot/.fxa-resume-db.sql.gz"
vm_exec() { printf '%s\n' "$*" >> "$tmp/calls"; [ "$1 $2 $3 $4 $5" = "agent-x3 sudo -u agent bash" ] && [ "$6" = -c ] && printf '%s' "$7" > "$tmp/dbsh"; return 0; }
tar() { while [ "$1" != -czf ]; do shift; done; shift; shift; printf '%s\n' "$@" > "$tmp/tarred"; : > "$LOG_DIR/agent-x3-run.tar"; }
: > "$tmp/calls"; : > "$tmp/dbsh"; _put_run_files agent-x3 "$tmp/slot" >/dev/null 2>&1
check "the dump ships with the run files" "1" "$(grep -cx './.fxa-resume-db.sql.gz' "$tmp/tarred")"
check "no root call touches the dump" "0" "$(grep 'fxa-resume-db' "$tmp/calls" | grep -vc '^agent-x3 sudo -u agent bash -c ')"
mkdir -p "$tmp/ws" "$tmp/bin"; cp "$tmp/slot/.fxa-resume-db.sql.gz" "$tmp/ws/"
printf '#!/bin/sh\n[ "$1" = --help ] && { echo "  --system-command  Enable system command"; exit 0; }\necho "$*" > %s/args; cat > %s/sql\n' "$tmp" "$tmp" > "$tmp/bin/mysql"
printf '#!/bin/sh\nshift; exec "$@"\n' > "$tmp/bin/timeout"; chmod +x "$tmp/bin/mysql" "$tmp/bin/timeout"
c="$(cat "$tmp/dbsh")"; PATH="$tmp/bin:$PATH" bash -c "${c//\/workspace/$tmp/ws}" >/dev/null 2>&1
check "the client gets --local-infile=0 and --skip-system-command, the SQL on stdin, and the dump goes" \
  "-uroot --local-infile=0 --skip-system-command|CREATE DATABASE fxa;|no" "$(cat "$tmp/args")|$(cat "$tmp/sql")|$([ -e "$tmp/ws/.fxa-resume-db.sql.gz" ] && echo yes || echo no)"
check "agent_run ships the run files only after the egress firewall" "yes" "$(sed -n '/^agent_run() {/,/^}/p' "$here/agent.sh" \
  | awk '/_setup_egress_firewall "\$name"/{f=NR} /_put_run_files "\$name"/{p=NR} END{print (f && p > f) ? "yes" : "no"}')"
[ "$fail" = 0 ] && echo "all checks pass"
exit "$fail"
