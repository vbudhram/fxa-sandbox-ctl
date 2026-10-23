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
[ "$n" = "${FAIL_SECRET:-}" ] && { echo "ERROR: (gcloud.secrets.versions.access) UNAVAILABLE: the service is unavailable on $n" >&2; exit 1; }
# FLAKY_SECRET fails its first read only, as at a boot before the network is up.
[ "$n" = "${FLAKY_SECRET:-}" ] && [ ! -e "$FLAKY_MARK" ] && { : > "$FLAKY_MARK"; echo "ERROR: (gcloud.secrets.versions.access) There was a problem refreshing your current auth tokens" >&2; exit 1; }
[ "$n" = "${DENY_SECRET:-}" ] && { echo "ERROR: (gcloud.secrets.versions.access) PERMISSION_DENIED: Permission denied on resource (or it may not exist)." >&2; exit 1; }
case " ${HAVE:-} " in *" $n "*) printf 'v-%s' "$n"; exit 0 ;; esac
case "$n" in fxa-claude-token|fxa-runlayer-agent-token|fxa-sentry-token|fxa-grafana-token|fxa-jira-*|fxa-agent-memory-key|fxa-dashboard-hmac)
  echo "ERROR: (gcloud.secrets.versions.access) NOT_FOUND: Secret [$n] not found or has no versions." >&2; exit 1 ;; esac
printf 'v-%s' "$n"
SH
chmod +x "$t/bin/"*
sed "s#/home/fxa#$t/home#g" "$here/fxa-secrets.sh" > "$t/fxa-secrets.sh"
export FXA_SECRETS_RETRY_S=0 FLAKY_MARK="$t/flaky"
C="$t/home/.config/fxa" B="$t/home/Desktop/working2/fxa-agent-bot/.env"
printf 'A=1\n' > "$C/ctl.env.base"; printf 'B=1\n' > "$C/bot.env.base"; printf 'old pem\n' > "$C/github-app.pem"
printf 'B=1\nSLACK_BOT_TOKEN=xoxb-old\n' > "$B"
FAIL_SECRET=fxa-slack-bot-token PATH="$t/bin:$PATH" bash "$t/fxa-secrets.sh" >/dev/null 2>"$t/err"; rc=$?
check "a failed Slack token read exits 1, says which, and leaves the bot .env and the pem as they were" "1|yes|xoxb-old|old pem" \
  "$rc|$(grep -q 'could not read fxa-slack-bot-token' "$t/err" && echo yes)|$(sed -n 's/^SLACK_BOT_TOKEN=//p' "$B")|$(cat "$C/github-app.pem")"
printf 'old pem\n' > "$C/github-app.pem"; FAIL_SECRET=fxa-github-app-key PATH="$t/bin:$PATH" bash "$t/fxa-secrets.sh" >/dev/null 2>&1; rc=$?
check "a failed first read (the GitHub key) also stops it" "1|old pem" "$rc|$(cat "$C/github-app.pem")"
rm -f "$FLAKY_MARK"; FLAKY_SECRET=fxa-github-app-key PATH="$t/bin:$PATH" bash "$t/fxa-secrets.sh" >/dev/null 2>&1; rc=$?
check "a read that fails once at boot is tried again, and the files are written" "0|v-fxa-github-app-key" "$rc|$(cat "$C/github-app.pem")"
printf 'old pem\n' > "$C/github-app.pem"
PATH="$t/bin:$PATH" bash "$t/fxa-secrets.sh" >/dev/null 2>&1; rc=$?
check "with every read, the files hold the new values" "0|v-fxa-slack-bot-token|v-fxa-github-app-key|ANTHROPIC_API_KEY=v-fxa-anthropic-api-key" \
  "$rc|$(sed -n 's/^SLACK_BOT_TOKEN=//p' "$B")|$(cat "$C/github-app.pem")|$(grep '^ANTHROPIC' "$t/home/Desktop/working2/fxa-sandbox-ctl/.env")"
mv "$C/bot.env.base" "$t/bb"; PATH="$t/bin:$PATH" bash "$t/fxa-secrets.sh" >/dev/null 2>&1; rc=$?
check "a .env base that cannot be read stops it before any write" "1|v-fxa-slack-bot-token|B=1" "$( [ "$rc" = 0 ] && echo 0 || echo 1)|$(sed -n 's/^SLACK_BOT_TOKEN=//p' "$B")|$(head -1 "$B")"
mv "$t/bb" "$C/bot.env.base"
mv "$C/ctl.env.base" "$t/cb"; cp "$B" "$t/bot.good"; PATH="$t/bin:$PATH" bash "$t/fxa-secrets.sh" >/dev/null 2>&1; rc=$?
check "a ctl .env base that cannot be read stops it before any write, the bot .env included" "1|same" "$([ "$rc" = 0 ] && echo 0 || echo 1)|$(cmp -s "$B" "$t/bot.good" && echo same)"
mv "$t/cb" "$C/ctl.env.base"
PATH="$t/bin:$PATH" bash "$t/fxa-secrets.sh" >/dev/null 2>&1
check "the LLM proxy gets a file with the API key only, and its unit reads that file, not the ctl .env" "ANTHROPIC_API_KEY=v-fxa-anthropic-api-key|1|0" \
  "$(cat "$C/llm-proxy.env")|$(grep -A8 'fxa-llm-proxy.service <<' "$here/manager-setup.sh" | grep -c 'EnvironmentFile=-$C/llm-proxy.env')|$(grep -A8 'fxa-llm-proxy.service <<' "$here/manager-setup.sh" | grep -c 'fxa-sandbox-ctl/.env')"
E="$t/home/Desktop/working2/fxa-sandbox-ctl/.env"; cp "$E" "$t/ctl.env.good"
FAIL_SECRET=fxa-anthropic-api-key HAVE=fxa-claude-token PATH="$t/bin:$PATH" bash "$t/fxa-secrets.sh" >/dev/null 2>&1; rc=$?
check "no API key, only a setup-token: it stops, and the ctl .env keeps its API key" "1|same" "$([ "$rc" = 0 ] && echo 0 || echo 1)|$(cmp -s "$E" "$t/ctl.env.good" && echo same)"
HAVE="fxa-dashboard-hmac fxa-sentry-token" PATH="$t/bin:$PATH" bash "$t/fxa-secrets.sh" >/dev/null 2>&1
cp "$C/dashboard-hmac" "$t/hmac.good"; cp "$C/mcp-gateway.env" "$t/gw.good"
FAIL_SECRET=fxa-dashboard-hmac HAVE="fxa-sentry-token" PATH="$t/bin:$PATH" bash "$t/fxa-secrets.sh" >/dev/null 2>"$t/err"; rc=$?
check "an optional secret that fails to read (UNAVAILABLE): it stops, and the HMAC and gateway files stay" "1|same|same|yes" \
  "$([ "$rc" = 0 ] && echo 0 || echo 1)|$(cmp -s "$C/dashboard-hmac" "$t/hmac.good" && echo same)|$(cmp -s "$C/mcp-gateway.env" "$t/gw.good" && echo same)|$(grep -q 'could not read fxa-dashboard-hmac' "$t/err" && echo yes)"
PATH="$t/bin:$PATH" bash "$t/fxa-secrets.sh" >/dev/null 2>"$t/err"; rc=$?
check "optional secrets that do not exist: it runs, says nothing about them, and removes their files" "0|0|no|no" "$rc|$(grep -c NOT_FOUND "$t/err")|$([ -e "$C/dashboard-hmac" ] && echo yes || echo no)|$([ -e "$C/mcp-gateway.env" ] && echo yes || echo no)"
# A link planted in the fxa-owned config folder does not aim root's error write.
echo keep > "$t/target"; ln -sf "$t/target" "$C/.opt-err"
PATH="$t/bin:$PATH" bash "$t/fxa-secrets.sh" >/dev/null 2>&1
check "a link planted at the old error path leaves its target unchanged" "keep" "$(cat "$t/target")"
DENY_SECRET=fxa-runlayer-agent-token PATH="$t/bin:$PATH" bash "$t/fxa-secrets.sh" >/dev/null 2>&1; rc=$?
check "an optional secret the manager has no grant on (PERMISSION_DENIED, as for one that does not exist) reads as empty" "0" "$rc"
# sudo logs the variables it keeps (ENV=...) to the journal, so the Jira token must not pass through sudo.
# The stubs log their arguments and, as sudo does, the values of --preserve-env; runuser runs the command.
cat > "$t/bin/sudo" <<'SH'
#!/bin/bash
for a; do case "$a" in --preserve-env=*) for v in $(tr , ' ' <<< "${a#*=}"); do printf 'ENV=%s ' "${!v}"; done ;; esac; done >> "$LOG"
echo "sudo $*" >> "$LOG"
SH
cat > "$t/bin/runuser" <<'SH'
#!/bin/bash
echo "runuser $*" >> "$LOG"; while [ "$1" != -- ]; do shift; done; shift; exec "$@"
SH
printf '#!/bin/sh\ncat >> "$LOG.acli"\n' > "$t/bin/acli"; chmod +x "$t/bin/"*
LOG="$t/log" HAVE="fxa-jira-token fxa-jira-email" PATH="$t/bin:$PATH" bash "$t/fxa-secrets.sh" >/dev/null 2>&1
check "the Jira token reaches acli, and no logged command line or sudo ENV holds it" "v-fxa-jira-token|0" \
  "$(cat "$t/log.acli" 2>/dev/null)|$(grep -c 'v-fxa-jira-token' "$t/log" 2>/dev/null)"
exit "$fail"
