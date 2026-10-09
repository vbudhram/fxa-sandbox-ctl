#!/bin/bash
# fc-idle-stop: power the host off after FC_IDLE_MIN minutes with no slot in use.
# The host lives on demand: a controller starts it for a session (vm-firecracker.sh),
# and any controller can, so the stop is decided here, not by one of them.
# Run as root every minute by fc-idle-stop.timer.
set -u
FC="${FC_ROOT:-/fc}"; idle="${FC_IDLE_MIN:-30}"; mark="$FC/run/last-busy"
mkdir -p "$FC/run"
now="$(date +%s)"; booted="${FC_BOOTED:-$(( now - $(cut -d. -f1 /proc/uptime) ))}"  # FC_BOOTED: for the check
# A mark from before this boot counts from the boot: a fresh host is not idle yet.
[ -f "$mark" ] && [ "$(stat -c %Y "$mark")" -ge "$booted" ] || touch -d "@$booted" "$mark"
# A dev slot (lib/devslot.sh) with no sync or run for FC_DEV_IDLE_MIN is stopped.
for m in "$FC"/slots/*/meta; do
  [ -f "$m" ] || continue
  case "$(cut -f1 "$m")" in *-dev-*) ;; *) continue ;; esac
  if [ $(( now - $(stat -c %Y "$m") )) -ge $(( ${FC_DEV_IDLE_MIN:-30} * 60 )) ]; then
    logger -t fc-idle-stop "dev slot $(cut -f1 "$m") idle; stopping it"
    ${FC_CMD:-/usr/local/sbin/fc} stop "$(basename "$(dirname "$m")")" || true
  fi
done
busy=0
compgen -G "$FC/slots/*/meta" >/dev/null && busy=1
# Never during a snapshot refresh: a cut one leaves no snapshot to restore.
systemctl is-active --quiet fc-refresh.service && busy=1
pgrep -f fc-make-snapshot >/dev/null && busy=1
if [ "$busy" = 1 ]; then touch "$mark"; exit 0; fi
if [ $(( now - $(stat -c %Y "$mark") )) -ge $(( idle * 60 )) ]; then
  # Decide under the claim lock, and leave a marker claim refuses: a claim in the
  # same seconds once restored a slot on a host that was shutting down.
  exec 9> "$FC/run/claim.lock"; flock 9
  compgen -G "$FC/slots/*/meta" >/dev/null && { touch "$mark"; exit 0; }
  touch "${FC_OFF_MARK:-/run/fc-powering-off}"
  logger -t fc-idle-stop "no slot in use for ${idle} min; powering off"
  ${FC_POWEROFF:-systemctl poweroff}
fi
