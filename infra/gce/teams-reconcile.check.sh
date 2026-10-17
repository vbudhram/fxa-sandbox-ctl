#!/usr/bin/env bash
# Offline check for fxa-teams-reconcile: an active record with a Jira queue gets a pass timer, an
# off or gone record loses its one, and a folder team keeps the timer manager-setup.sh gave it.
#   bash infra/gce/teams-reconcile.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
here="$(cd "$(dirname "$0")" && pwd -P)"; root="$(cd "$here/../.." && pwd -P)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
H="$tmp/home"; S="$tmp/systemd"; mkdir -p "$H/Desktop/working2" "$H/.claude/state/teams" "$S/timers.target.wants" "$tmp/bin"
# A folder team with a Jira queue (foldq), as manager-setup.sh finds it.
mkdir -p "$H/Desktop/working2/fxa-sandbox-ctl/profiles/foldq"; echo 'PIPE_JIRA_PROJECT="FQ"' > "$H/Desktop/working2/fxa-sandbox-ctl/profiles/foldq/profile.conf"
# A fake systemctl: enable and disable add and remove the wants link; every call is logged.
cat > "$tmp/bin/systemctl" <<EOF
#!/bin/bash
echo "\$*" >> "$tmp/calls"
u="\${@: -1}"
case "\$*" in
  *show*MainPID*) cat "$tmp/mainpid" 2>/dev/null || echo 0 ;;
  *is-enabled*) [ -e "$S/timers.target.wants/\$u" ] ;;
  *enable*) : > "$S/timers.target.wants/\$u" ;;
  *disable*) rm -f "$S/timers.target.wants/\$u" ;;
esac
EOF
chmod +x "$tmp/bin/systemctl"
run() { PATH="$tmp/bin:$PATH" FXA_HOME="$H" FXA_SYSTEMD_DIR="$S" bash "$here/teams-reconcile.sh" "$@"; }
index() { printf '{ "schema": 1, "teams": %s }' "$1" > "$H/.claude/state/teams/index.json"; }
wants() { ls "$S/timers.target.wants" | grep '^fxa-pass@' | sed 's/^fxa-pass@//; s/\.timer$//' | sort | paste -sd, -; }

index '{ "rusty": { "status": "active", "jira": "RUST", "queue": true }, "quiet": { "status": "active", "jira": "QT", "queue": false },
         "off": { "status": "disabled", "jira": "OFF", "queue": true }, "bad name": { "status": "active", "jira": "X", "queue": true } }'
: > "$S/timers.target.wants/fxa-pass@foldq.timer"   # a folder team's, from manager-setup.sh
: > "$S/timers.target.wants/fxa-pass@gone.timer"           # a record team that was deleted
run --install > "$tmp/out"
check "install writes the path unit, its service and the timer offset, and starts the path unit" "yes|yes|yes|1" \
  "$(grep -q "PathChanged=$H/.claude/state/teams/index.json" "$S/fxa-teams.path" && echo yes)|$(grep -q 'ExecStart=/usr/local/sbin/fxa-teams-reconcile' "$S/fxa-teams.service" && echo yes)|$(grep -q 'FixedRandomDelay=true' "$S/fxa-pass@.timer.d/offset.conf" && echo yes)|$(grep -c 'enable -q --now fxa-teams.path' "$tmp/calls")"
check "only an active record with a Jira queue gets a pass; a folder team keeps its own; a gone record loses its" \
  "foldq,rusty" "$(wants)"
check "a record turned off loses its pass on the next run" "foldq" \
  "$(index '{ "rusty": { "status": "disabled", "jira": "RUST", "queue": true } }'; run >/dev/null; wants)"
check "no index stops every record pass, and keeps the folder team's" "foldq" \
  "$(index '{ "rusty": { "status": "active", "jira": "RUST", "queue": true } }'; run >/dev/null; rm -f "$H/.claude/state/teams/index.json"; run >/dev/null; wants)"
check "a run with nothing to change makes no enable or disable" "0" \
  "$(: > "$tmp/calls"; run >/dev/null; grep -cE '^(enable|disable)' "$tmp/calls")"

# A team turned off mid-pass: its running pass ends, and a run it launched (adopted by PID 1) does not.
index '{ "busy": { "status": "active", "jira": "BZ", "queue": true } }'; run >/dev/null
bash -c 'sleep 300 & sleep 300 & wait' >/dev/null 2>&1 & echo $! > "$tmp/mainpid"
( nohup sleep 301 >/dev/null 2>&1 & echo $! > "$tmp/launched" )
sleep 1; kids="$(ps -eo pid=,ppid= | awk -v p="$(cat "$tmp/mainpid")" '$2 == p { print $1 }' | tr '\n' ' ')"
index '{ "busy": { "status": "disabled", "jira": "BZ", "queue": true } }'; run > "$tmp/out2"; sleep 1
alive() { kill -0 "$1" 2>/dev/null && echo up || echo gone; }
check "turning a team off ends its running pass and the pass's children, not a run it launched" "gone|gone gone |up|1" \
  "$(alive "$(cat "$tmp/mainpid")")|$(for k in $kids; do printf '%s ' "$(alive "$k")"; done)|$(alive "$(cat "$tmp/launched")")|$(grep -c 'ended the running pass of busy' "$tmp/out2")"
kill "$(cat "$tmp/launched")" "$(cat "$tmp/mainpid")" $kids 2>/dev/null; rm -f "$tmp/mainpid"

[ "$fail" = 0 ] && echo "all checks pass"; exit "$fail"
