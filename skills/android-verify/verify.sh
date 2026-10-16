#!/bin/bash
# android-verify: run an Android pairing spec across the FxA stack, desktop Nightly and Fenix in the
# emulator; save the phone's screen and the FxA logcat lines; print a verdict.
#   verify.sh [--fenix] [--spec <name>] [--record]
set -uo pipefail
source /etc/agent-env.sh 2>/dev/null || true
spec=pairingFlowV2Android fenix="" record=""
while [ $# -gt 0 ]; do
  case "$1" in
    --fenix) fenix=1; shift ;;
    --spec) spec="${2:?--spec needs a name}"; shift 2 ;;
    --record) record=1; shift ;;
    *) echo "usage: verify.sh [--fenix] [--spec <name>] [--record]" >&2; exit 2 ;;
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

# --record: the phone (adb screenrecord) and desktop Nightly (an ffmpeg grab of its X display), side by side.
rec_start() {
  R="/tmp/android-verify-rec-$1"; rm -rf "$R"; mkdir -p "$R"
  adb shell 'rm -f /sdcard/fxa-rec-*.mp4'
  Xvfb :99 -screen 0 1600x1000x24 > /dev/null 2>&1 & XV=$!; sleep 2
  # screenrecord stops at 180 s: record segments back to back until the stop mark.
  ( i=0; while [ ! -f "$R/stop" ]; do adb shell screenrecord --bit-rate 4000000 --time-limit 180 "/sdcard/fxa-rec-$i.mp4"; i=$((i+1)); done ) & PH=$!
  date +%s.%N > "$R/phone.t0"
  ffmpeg -loglevel error -f x11grab -video_size 1600x1000 -framerate 15 -i :99 -c:v libx264 -preset veryfast -pix_fmt yuv420p "$R/desktop.mp4" < /dev/null & FFM=$!
  date +%s.%N > "$R/desktop.t0"
}
rec_stop() {
  local out="$MEDIA/android-${spec}-try$1.mp4" font=/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf off i a="" b=""
  sleep 2; touch "$R/stop"; adb shell pkill -INT screenrecord; kill -INT "$FFM"; wait "$FFM" "$PH"; kill "$XV" 2>/dev/null
  for i in $(adb shell ls /sdcard/ | tr -d '\r' | grep -E '^fxa-rec-[0-9]+\.mp4$' | sort -t- -k3 -n); do
    adb pull -q "/sdcard/$i" "$R/$i" > /dev/null 2>&1 && echo "file '$R/$i'"
  done > "$R/list.txt"
  ffmpeg -loglevel error -y -f concat -safe 0 -i "$R/list.txt" -c copy "$R/phone.mp4" || { row WARN "recording: no phone video"; return; }
  off="$(python3 -c "print(round($(cat "$R/desktop.t0") - $(cat "$R/phone.t0"), 3))")"
  [ -f "$font" ] && a=",drawtext=fontfile=$font:text='Fenix (supplicant)':x=20:y=20:fontsize=28:fontcolor=white:box=1:boxcolor=black@0.5:boxborderw=8" \
    && b=",drawtext=fontfile=$font:text='Desktop Nightly (authority)':x=20:y=20:fontsize=28:fontcolor=white:box=1:boxcolor=black@0.5:boxborderw=8"
  # The phone writes a frame only when its screen changes: fps=15 makes it constant, as players expect.
  ffmpeg -loglevel error -y -i "$R/phone.mp4" -itsoffset "$off" -i "$R/desktop.mp4" -filter_complex \
    "[0:v]fps=15,scale=-2:1000${a}[p];[1:v]scale=-2:1000${b}[d];[p][d]hstack=inputs=2[v]" -map '[v]' \
    -c:v libx264 -preset fast -crf 23 -pix_fmt yuv420p -movflags +faststart "$out" \
    && row INFO "video: $out" || row WARN "recording: the combine failed (see $R)"
}

run() {
  local -a vars=(ANDROID_PAIRING_ENABLED=1 ANDROID_PAIRING_V2_ENABLED=1) x=(xvfb-run -a)
  [ -n "$record" ] && { rec_start "$1"; vars+=(DISPLAY=:99 MARIONETTE_HEADLESS=false); x=(); }
  ( cd "$FXA/packages/functional-tests" && env "${vars[@]}" \
      timeout 600 ${x[@]+"${x[@]}"} npx playwright test "$spec" --project=local --reporter=list ) > "/tmp/android-verify-$1.log" 2>&1
  [ -n "$record" ] && rec_stop "$1"
  # Per try: the next try's reset clears the device log. The page's pairing lines too, since
  # "Unexpected state change: complete" was how a dropped state showed.
  adb logcat -d -v time 2>/dev/null | grep -E 'FirefoxAccountStateMachine|mozac-fxawebchannel|fxa_client|Firefox WebChannel|pairing message|state change' \
    | tail -300 > "$MEDIA/android-${spec}-try$1-logcat.txt" && row INFO "logcat: $MEDIA/android-${spec}-try$1-logcat.txt"
  cp "/tmp/android-verify-$1.log" "$MEDIA/android-${spec}-try$1-spec.log"
  grep -qE '^ *1 passed' "/tmp/android-verify-$1.log"
}
verdict=FAIL
if run 1; then verdict=PASS; row PASS "$spec"
else
  row FAIL "$spec, try 1: $(grep -m1 -E 'Error:|skipped|Timeout' /tmp/android-verify-1.log | cut -c1-120)"
  if run 2; then verdict=PASS; row PASS "$spec, try 2 (try 1 failed; see the traps in the FxA Android guide)"
  else row FAIL "$spec, try 2: $(grep -m1 -E 'Error:|skipped|Timeout' /tmp/android-verify-2.log | cut -c1-120)"; fi
fi

adb exec-out screencap -p > "$MEDIA/android-${spec}.png" 2>/dev/null && row INFO "screen: $MEDIA/android-${spec}.png"

printf '\n%s\n' "${rows[@]}"
echo "android-verify: ${verdict}"
[ "$verdict" = PASS ]
