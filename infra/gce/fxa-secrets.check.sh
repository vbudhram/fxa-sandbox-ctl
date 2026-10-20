#!/usr/bin/env bash
# Offline check that manager.sh's splice puts infra/gce/fxa-secrets.sh into the setup
# script intact, and that both parse.
#   bash infra/gce/fxa-secrets.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
here="$(cd "$(dirname "$0")" && pwd)"
check "fxa-secrets.sh parses and is not empty" "yes" "$(bash -n "$here/fxa-secrets.sh" && [ -s "$here/fxa-secrets.sh" ] && echo yes)"
# The same sed line manager.sh runs.
splice="$(grep -o 'sed -e "/^__FXA_SECRETS__.*manager-setup.sh"' "$here/manager.sh")"
check "manager.sh still splices at the marker" "1" "$(grep -c '^__FXA_SECRETS__$' "$here/manager-setup.sh")"
out="$(ROOT="$here/../.." eval "$splice")"
check "the spliced setup parses" "yes" "$(bash -n <(printf '%s\n' "$out") && echo yes)"
check "it holds fxa-secrets.sh unchanged, and no marker" "same|0" \
  "$(awk '/^cat > \/usr\/local\/sbin\/fxa-secrets <<.SEC.$/{f=1;next} /^SEC$/{f=0} f' <<< "$out" | cmp -s - "$here/fxa-secrets.sh" && echo same)|$(grep -c '^__FXA_SECRETS__$' <<< "$out")"
# A failed read of a needed secret changes no file and exits non-zero; with every read, the files are written.
t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
mkdir -p "$t/bin" "$t/home/.config/fxa" "$t/home/Desktop/working2/fxa-sandbox-ctl" "$t/home/Desktop/working2/fxa-agent-bot"
for c in curl chown sudo; do printf '#!/bin/sh\n[ "$(basename "$0")" = curl ] && echo proj\nexit 0\n' > "$t/bin/$c"; done
cat > "$t/bin/gcloud" <<'SH'
#!/bin/sh
n=""; while [ $# -gt 0 ]; do [ "$1" = --secret ] && n="$2"; shift; done
[ "$n" = "${FAIL_SECRET:-}" ] && { echo "ERROR: permission denied on $n" >&2; exit 1; }
case "$n" in fxa-claude-token|fxa-runlayer-agent-token|fxa-sentry-token|fxa-grafana-token|fxa-jira-*|fxa-agent-memory-key|fxa-dashboard-hmac) exit 1 ;; esac
printf 'v-%s' "$n"
SH
chmod +x "$t/bin/"*
sed "s#/home/fxa#$t/home#g" "$here/fxa-secrets.sh" > "$t/fxa-secrets.sh"
C="$t/home/.config/fxa" B="$t/home/Desktop/working2/fxa-agent-bot/.env"
printf 'A=1\n' > "$C/ctl.env.base"; printf 'B=1\n' > "$C/bot.env.base"; printf 'old pem\n' > "$C/github-app.pem"
printf 'B=1\nSLACK_BOT_TOKEN=xoxb-old\n' > "$B"
FAIL_SECRET=fxa-slack-bot-token PATH="$t/bin:$PATH" bash "$t/fxa-secrets.sh" >/dev/null 2>"$t/err"; rc=$?
check "a failed Slack token read exits 1, says which, and leaves the bot .env and the pem as they were" "1|yes|xoxb-old|old pem" \
  "$rc|$(grep -q 'could not read fxa-slack-bot-token' "$t/err" && echo yes)|$(sed -n 's/^SLACK_BOT_TOKEN=//p' "$B")|$(cat "$C/github-app.pem")"
printf 'old pem\n' > "$C/github-app.pem"; FAIL_SECRET=fxa-github-app-key PATH="$t/bin:$PATH" bash "$t/fxa-secrets.sh" >/dev/null 2>&1; rc=$?
check "a failed first read (the GitHub key) also stops it" "1|old pem" "$rc|$(cat "$C/github-app.pem")"
PATH="$t/bin:$PATH" bash "$t/fxa-secrets.sh" >/dev/null 2>&1; rc=$?
check "with every read, the files hold the new values" "0|v-fxa-slack-bot-token|v-fxa-github-app-key|ANTHROPIC_API_KEY=v-fxa-anthropic-api-key" \
  "$rc|$(sed -n 's/^SLACK_BOT_TOKEN=//p' "$B")|$(cat "$C/github-app.pem")|$(grep '^ANTHROPIC' "$t/home/Desktop/working2/fxa-sandbox-ctl/.env")"
mv "$C/bot.env.base" "$t/bb"; PATH="$t/bin:$PATH" bash "$t/fxa-secrets.sh" >/dev/null 2>&1; rc=$?
check "a .env base that cannot be read stops it before any write" "1|v-fxa-slack-bot-token|B=1" "$( [ "$rc" = 0 ] && echo 0 || echo 1)|$(sed -n 's/^SLACK_BOT_TOKEN=//p' "$B")|$(head -1 "$B")"
exit "$fail"
