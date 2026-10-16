#!/bin/bash
# fxa-teams-reconcile: a pass timer (fxa-pass@<team>) for each active team record with a Jira queue,
# and none for a record team that is off or gone. Runs as root: the fxa user cannot use systemctl.
# vm.sh sync installs it as /usr/local/sbin/fxa-teams-reconcile; fxa-teams.path runs it when the
# teams index changes. A folder team keeps the timer manager-setup.sh gave it.
#   fxa-teams-reconcile [--install]   --install also writes and starts its own units first
set -uo pipefail
U="${FXA_USER:-fxa}"; H="${FXA_HOME:-$(getent passwd "$U" 2>/dev/null | cut -d: -f6)}"; H="${H:-/home/$U}"
W="$H/Desktop/working2"; I="$H/.claude/state/teams/index.json"; S="${FXA_SYSTEMD_DIR:-/etc/systemd/system}"
NAME='^[a-z][a-z0-9-]{1,30}$'

if [ "${1:-}" = --install ]; then
  cat > "$S/fxa-teams.path" <<UNIT
[Unit]
Description=Reconcile the team pass timers when the teams index changes
[Path]
PathChanged=$I
[Install]
WantedBy=multi-user.target
UNIT
  cat > "$S/fxa-teams.service" <<'UNIT'
[Unit]
Description=Reconcile the team pass timers with the team records
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/fxa-teams-reconcile
UNIT
  # Each team's pass at its own fixed offset, so they do not all start at the same minute.
  mkdir -p "$S/fxa-pass@.timer.d"
  printf '[Timer]\nRandomizedDelaySec=120\nFixedRandomDelay=true\n' > "$S/fxa-pass@.timer.d/offset.conf"
  systemctl daemon-reload
  systemctl enable -q --now fxa-teams.path
fi

# The record teams that should run a pass, then the folder teams that keep theirs.
want="$(jq -r '.teams // {} | to_entries[] | select(.value.status == "active" and .value.queue == true and (.value.jira // "") != "") | .key' "$I" 2>/dev/null | grep -E "$NAME" || true)"
keep="$want"
for f in "$W"/fxa-sandbox-ctl/profiles/*/profile.conf; do
  t="$(basename "$(dirname "$f")")"
  [ "$t" != fxa ] && grep -q '^PIPE_JIRA_PROJECT=' "$f" && keep="$keep"$'\n'"$t"
done
for t in $want; do
  systemctl is-enabled -q "fxa-pass@${t}.timer" 2>/dev/null || { systemctl enable -q --now "fxa-pass@${t}.timer" && echo "started the pass of ${t}"; }
done
for u in "$S"/timers.target.wants/fxa-pass@*.timer; do
  [ -e "$u" ] || continue
  t="${u##*/fxa-pass@}"; t="${t%.timer}"
  grep -qx "$t" <<< "$keep" || { systemctl disable -q --now "fxa-pass@${t}.timer" && echo "stopped the pass of ${t}"; }
done
exit 0
