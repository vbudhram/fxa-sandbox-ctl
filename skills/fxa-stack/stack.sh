#!/usr/bin/env bash
# Check, start, and diagnose the FxA stack on the sandbox VM. See SKILL.md.
set -u
ok() { printf '  %-16s %-5s %s\n' "$1" "$2" "$3"; }
http() { curl -sf -o /dev/null --max-time 3 "$1"; }
tcp() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }

status() {
  local down=0 name check
  while IFS='|' read -r name check; do
    if eval "$check" >/dev/null 2>&1; then ok "$name" up ""; else ok "$name" DOWN "$check"; down=$((down + 1)); fi
  done <<'LIST'
mysql|mysqladmin ping -u root --silent
redis|redis-cli ping
firestore|tcp 9090
goaws|tcp 4100
auth|http http://localhost:9000/__heartbeat__
inbox|tcp 9001
content (nginx)|http http://localhost:3030/
settings|http http://localhost:3000/settings/static/js/bundle.js
profile|http http://localhost:1111/__heartbeat__
admin-server|tcp 8095
LIST
  return "$down"
}

# The services a UI check cannot run without. Others are reported, not required.
core_up() { http http://localhost:9000/__heartbeat__ && http http://localhost:3030/ && http http://localhost:3000/settings/static/js/bundle.js; }

ensure() {
  if core_up; then echo "stack already up"; status; return 0; fi
  echo "starting the stack with fxa-start (about 2 minutes)..."
  source /etc/agent-env.sh 2>/dev/null
  fxa-start > /tmp/fxa-start.log 2>&1 || echo "fxa-start exited non-zero; see /tmp/fxa-start.log"
  local i
  for i in $(seq 40); do core_up && break; sleep 3; done
  status || echo "(some optional services are down; bash $0 diagnose shows why)"
  core_up || { echo "auth, content, or settings is down; run: bash $0 diagnose"; return 1; }
}

diagnose() {
  # Only what is broken: a failed health check, or a pm2 app in "errored".
  # One-shot build steps (settings-css, settings-ftl) are "stopped" when done.
  local down; down="$(status | awk '$2 == "DOWN" || $3 == "DOWN" {print $1}')"
  [ -z "$down" ] && ! pm2 jlist 2>/dev/null | jq -e 'any(.[]; .pm2_env.status == "errored")' >/dev/null && { echo "all services up"; return 0; }
  local name pm
  for name in $down; do
    case "$name" in auth|inbox|profile|content) pm="$name" ;; settings) pm=settings-react ;;
      admin-server) echo "== admin-server is down (not a pm2 app): tail /tmp/admin-start.log /tmp/admin-build.log"; tail -5 /tmp/admin-start.log 2>/dev/null; continue ;;
      mysql|redis|firestore|goaws) echo "== ${name} is down: journalctl -u ${name/redis/redis-server} -n 30 (firestore: firestore-emulator)"; continue ;; *) continue ;; esac
    echo "== ${name} is down (pm2 ${pm}: $(pm2 jlist 2>/dev/null | jq -r --arg n "$pm" '.[] | select(.name == $n) | .pm2_env.status' || echo unknown))"
    pm2 logs "$pm" --lines 15 --nostream --err 2>/dev/null | grep -v TAILING | tail -15
  done
  pm2 jlist 2>/dev/null | jq -r '.[] | select(.pm2_env.status == "errored") | .name' | while read -r pm; do
    echo "== pm2 ${pm} is errored"; pm2 logs "$pm" --lines 15 --nostream --err 2>/dev/null | grep -v TAILING | tail -15
  done
}

case "${1:-status}" in
  status) echo "FxA stack:"; status; exit $? ;;
  ensure) ensure ;;
  diagnose) diagnose ;;
  *) echo "usage: $0 status|ensure|diagnose" >&2; exit 2 ;;
esac
