#!/bin/bash
# profiles/fxa-android/boot.sh: start the Android emulator with Fenix beside the FxA stack. The
# fxa-dev-android image holds the SDK, the AVD `fxa`, the Fenix build and Nightly (13-android.sh).
# The controller runs it once as root on the runner, detached, after the egress firewall. The
# emulator and Fenix run only as agent. Log: /var/log/profile-boot.log.
# Done: /run/fxa-profile/ready, or failed.
set -uo pipefail
A=/home/agent APK=/home/agent/fenix-debug.apk PKG=org.mozilla.fenix.debug
R=/run/fxa-profile READY=/run/fxa-profile/ready FAIL=/run/fxa-profile/failed
install -d -m 755 -o root -g root "$R"; rm -f "$READY" "$FAIL"
step() { echo "$(date -u +%T) $*"; }
die() { step "FAILED: $*"; echo "$*" > "$FAIL"; chmod 644 "$FAIL"; exit 1; }
as_agent() { sudo -u agent -H bash -c "source /etc/agent-env.sh && $1" < /dev/null; }
adb_() { as_agent "adb $*"; }
t0=$(date +%s)

[ -e /dev/kvm ] || die "no /dev/kvm: this runner has no nested virtualization (an Android runner needs the --android machine type)"
[ -s "$APK" ] || die "no Fenix build at $APK: this is not the fxa-dev-android image"

step "emulator"
# sudo sets the agent's groups from /etc/group, kvm among them.
if ! as_agent "adb devices" | grep -q '^emulator-.*device$'; then
  as_agent "setsid nohup emulator -avd fxa -no-window -gpu swiftshader_indirect -noaudio -no-boot-anim -no-snapshot-save \
    -memory 4096 -cores 2 > $A/.emulator.log 2>&1 < /dev/null &"
fi
until [ "$(adb_ shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ]; do
  [ $(( $(date +%s) - t0 )) -lt 300 ] || die "the emulator did not boot in 300 s (see $A/.emulator.log)"
  grep -qE 'FATAL|give up' "$A/.emulator.log" 2>/dev/null && die "the emulator stopped: $(grep -m1 -E 'FATAL|give up' "$A/.emulator.log")"
  sleep 3
done
step "booted after $(( $(date +%s) - t0 ))s"

step "Fenix"
adb_ shell pm list packages | grep -q "$PKG" || adb_ install -r "$APK" > /dev/null || die "could not install Fenix"

step "adb reverse"
# The device's localhost reaches the runner's stack, which the pairing specs and Fenix's server override use.
as_agent "cd $A/fxa && bash _scripts/adb-reverse.sh" > /dev/null 2>&1 || die "adb reverse failed"
step "$(adb_ reverse --list | wc -l) ports reversed"

echo "ready after $(( $(date +%s) - t0 ))s" > "$READY"; chmod 644 "$READY"
step "ready after $(( $(date +%s) - t0 ))s"
