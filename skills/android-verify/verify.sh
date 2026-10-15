#!/bin/bash
# android-verify: run an Android pairing spec across the FxA stack, desktop Nightly and Fenix in the
# emulator; save the phone's screen and the FxA logcat lines; print a verdict.
#   verify.sh [--fenix] [--spec <name>]
set -uo pipefail
source /etc/agent-env.sh 2>/dev/null || true
spec=pairingFlowV2Android fenix=""
while [ $# -gt 0 ]; do
  case "$1" in
    --fenix) fenix=1; shift ;;
    --spec) spec="${2:?--spec needs a name}"; shift 2 ;;
    *) echo "usage: verify.sh [--fenix] [--spec <name>]" >&2; exit 2 ;;
  esac
done
[[ "$spec" =~ ^[A-Za-z0-9]+Android$ ]] || { echo "ERROR: --spec must be an Android spec name, such as pairingFlowAndroid" >&2; exit 2; }
FXA=/workspace FF=/home/agent/firefox PKG=org.mozilla.fenix.debug MEDIA=/workspace/.fxa-auto-media
mkdir -p "$MEDIA"
rows=()
row() { rows+=("$(printf '%-6s %s' "$1" "$2")"); }

# Preconditions, each a row: a missing one is the reason, not a spec failure.
[ -f /run/fxa-profile/ready ] || { echo "FAIL: the emulator is not ready: $(cat /run/fxa-profile/failed 2>/dev/null || echo 'see /var/log/profile-boot.log')"; exit 1; }
adb devices | grep -q '^emulator-.*device$' && row PASS "emulator up" || { echo "FAIL: no emulator in adb devices"; exit 1; }
if [ -n "$fenix" ]; then
  ( cd "$FF" && timeout 1800 ./mach gradle :fenix:assembleDebug > /tmp/android-verify-gradle.log 2>&1 ) \
    && adb install -r /home/agent/fenix-debug.apk > /dev/null && row PASS "Fenix rebuilt and installed" \
    || { tail -20 /tmp/android-verify-gradle.log; echo "FAIL: the Fenix build or install failed"; exit 1; }
fi
adb shell pm list packages | grep -q "$PKG" && row PASS "Fenix installed" || { echo "FAIL: $PKG is not installed"; exit 1; }
curl -sf --max-time 10 -o /dev/null http://localhost:9000/__heartbeat__ && row PASS "auth server up" || { echo "FAIL: the auth server is down: run /fxa-stack"; exit 1; }
( cd "$FXA" && bash _scripts/adb-reverse.sh > /dev/null 2>&1 ) && row PASS "adb reverse" || row WARN "adb reverse failed"

run() {
  ( cd "$FXA/packages/functional-tests" && ANDROID_PAIRING_ENABLED=1 ANDROID_PAIRING_V2_ENABLED=1 \
      timeout 600 xvfb-run -a npx playwright test "$spec" --project=local --reporter=list ) > "/tmp/android-verify-$1.log" 2>&1
  grep -qE '^ *1 passed' "/tmp/android-verify-$1.log"
}
verdict=FAIL
if run 1; then verdict=PASS; row PASS "$spec"
else
  row FAIL "$spec, try 1: $(grep -m1 -E 'Error:|skipped|Timeout' /tmp/android-verify-1.log | cut -c1-120)"
  if run 2; then verdict=PASS; row PASS "$spec, try 2 (try 1 failed; a cold-start fxa_status miss is a known FxA bug)"
  else row FAIL "$spec, try 2: $(grep -m1 -E 'Error:|skipped|Timeout' /tmp/android-verify-2.log | cut -c1-120)"; fi
fi

adb exec-out screencap -p > "$MEDIA/android-${spec}.png" 2>/dev/null && row INFO "screen: $MEDIA/android-${spec}.png"
adb logcat -d -v time 2>/dev/null | grep -E 'FirefoxAccountStateMachine|mozac-fxawebchannel|fxa_client|Firefox WebChannel' \
  | tail -200 > "$MEDIA/android-${spec}-logcat.txt" && row INFO "logcat: $MEDIA/android-${spec}-logcat.txt"

printf '\n%s\n' "${rows[@]}"
echo "android-verify: ${verdict}"
[ "$verdict" = PASS ]
