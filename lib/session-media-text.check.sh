#!/usr/bin/env bash
# Offline check for text files in session_media: masked, capped at 2 MB, and refused when they are
# .har, not UTF-8, hold a NUL byte or have a pii_guard hit.
#   bash lib/session-media-text.check.sh
source "$(dirname "$0")/session-check-head.sh"
ws="$tmp/ws/.fxa-auto-media"; mkdir -p "$ws"
SECRET="hunter2-team-secret"
_session_secret_values() { printf '"%s"\n' "$SECRET"; }
# The runner, here: the script runs on this host, with /workspace pointed at a scratch folder.
_session_sh() { bash -c "${2//\/workspace/$tmp/ws}"; }
echo '{"key":"agent-mt1","state":"active"}' > "$SESSION_DIR/agent-mt1.json"

printf 'step 1 ok\npassword=%s\n' "$SECRET" > "$ws/run.log"
printf 'name,mail\njane,jane.doe@gmail.com\n' > "$ws/users.csv"
printf '{"log":{"entries":[]}}' > "$ws/trace.har"
printf 'text\0more' > "$ws/nul.txt"
printf '\xff\xfe bad' > "$ws/bin.txt"
printf '{"ok": true}\n' > "$ws/result.json"
head -c 2097153 /dev/zero | tr '\0' a > "$ws/big.txt"
printf 'png' > "$ws/shot.png"

out="$tmp/out"; session_media agent-mt1 "$out" >/dev/null
check "text files that pass are kept beside the media" "result.json run.log shot.png" "$(cd "$out" && ls -A | tr '\n' ' ' | sed 's/ $//')"
check "the log is masked with the exact-value mask" "step 1 ok|password=<masked>" "$(paste -sd'|' "$out/run.log")"
check "the host copy is the masked one" "0" "$(grep -c "$SECRET" "$SESSION_DIR/agent-mt1.media/run.log")"
check "a clean json is unchanged" '{"ok": true}' "$(cat "$out/result.json")"
[ "$fail" = 0 ] && echo "all checks pass"; exit "$fail"
