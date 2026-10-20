#!/usr/bin/env bash
# Record an X display to /workspace/.fxa-auto-media/<name>.mp4, for a desktop
# Firefox flow that /fxa-functional-local does not record. See SKILL.md.
#   record.sh start <name>      starts Xvfb on $FXA_RECORD_DISPLAY (:99) when nothing serves it
#   record.sh stop [--speed N]  ends the file cleanly; --speed 8 plays it 8x faster
set -u
D="${FXA_RECORD_DISPLAY:-:99}" PIDF="${TMPDIR:-/tmp}/fxa-record.pid" OUTF="${TMPDIR:-/tmp}/fxa-record.out"
MEDIA="${FXA_WORKSPACE:-/workspace}/.fxa-auto-media"
recording() { [ -s "$PIDF" ] && kill -0 "$(cat "$PIDF")" 2>/dev/null; }
# The blank-video check from fxa-functional-local/run.sh: near-uniform frames show nothing.
shows_something() {
  command -v ffmpeg >/dev/null || return 0
  ffmpeg -nostdin -v error -i "$1" -vf "entropy,metadata=print:key=lavfi.entropy.normalized_entropy.normal.Y:file=-" -f null - 2>/dev/null \
    | awk -F= '/entropy/ { if ($2 + 0 > m) m = $2 + 0 } END { exit !(m >= 0.12) }'
}
case "${1:-}" in
  start)
    name="${2:-}"
    [[ "$name" =~ ^[A-Za-z0-9_-]{1,80}$ ]] || { echo "usage: $0 start <name: letters, digits, _ or ->" >&2; exit 2; }
    recording && { echo "record: already recording $(cat "$OUTF"); run: $0 stop" >&2; exit 1; }
    if [ ! -e "/tmp/.X11-unix/X${D#:}" ]; then
      nohup Xvfb "$D" -screen 0 1600x1000x24 >/tmp/fxa-xvfb.log 2>&1 </dev/null &
      for _ in $(seq 20); do [ -e "/tmp/.X11-unix/X${D#:}" ] && break; sleep 0.5; done
    fi
    out="$MEDIA/$name.mp4"; mkdir -p "$MEDIA"; rm -f "$out"
    # No -video_size: x11grab takes the whole screen.
    nohup ffmpeg -y -loglevel error -f x11grab -framerate 12 -i "$D" -c:v libx264 -preset veryfast -pix_fmt yuv420p "$out" \
      >/tmp/fxa-record.log 2>&1 </dev/null &
    echo $! > "$PIDF"; echo "$out" > "$OUTF"
    sleep 1; recording || { echo "record: ffmpeg did not start: $(tail -3 /tmp/fxa-record.log)" >&2; exit 1; }
    echo "recording $D to $out; start the browser with DISPLAY=$D" ;;
  stop)
    speed=1; [ "${2:-}" = --speed ] && speed="${3:-}"
    [[ "$speed" =~ ^[1-9][0-9]?$ ]] || { echo "usage: $0 stop [--speed 2..99]" >&2; exit 2; }
    recording || { echo "record: nothing is recording" >&2; exit 1; }
    out="$(cat "$OUTF")"
    # SIGINT: ffmpeg writes the mp4 index; a kill -9 leaves a file that does not play.
    kill -INT "$(cat "$PIDF")"; for _ in $(seq 20); do recording || break; sleep 0.5; done
    rm -f "$PIDF"
    if [ "$speed" != 1 ]; then
      ffmpeg -y -loglevel error -i "$out" -vf "setpts=PTS/$speed" -r 24 -an -c:v libx264 -preset veryfast -pix_fmt yuv420p "$out.fast.mp4" \
        && mv "$out.fast.mp4" "$out"
    fi
    echo "saved $out ($(du -h "$out" | cut -f1))"
    # A blank video leaves the media folder, so the wrap-up's media_paths never posts it.
    shows_something "$out" || { mv -f "$out" "$out.blank"; echo "record: the video is blank (kept as $out.blank, not posted). Set gfx.webrender.software=true in the Firefox profile and start Firefox with env -u MOZ_HEADLESS" >&2; exit 1; } ;;
  *) echo "usage: $0 start <name> | stop [--speed N]" >&2; exit 2 ;;
esac
