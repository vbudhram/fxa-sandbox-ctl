#!/bin/bash
# Runs as root on the manager VM (infra/gce/manager.sh sends it). Safe to run
# again: each step checks before it acts.
#
# The services run as the `fxa` user, which owns the repos, the state and the
# credentials. You work as that user too: `sudo -iu fxa`, then tmux and claude.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
U=fxa H=/home/fxa
W="$H/Desktop/working2" C="$H/.config/fxa"
say() { printf '\n== %s\n' "$*"; }

say "packages"
apt-get update -qq
apt-get install -y -qq git jq tmux rsync curl ca-certificates python3 python3-venv unzip build-essential openssl sqlite3 >/dev/null
if ! command -v gh >/dev/null; then
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    > /etc/apt/sources.list.d/github-cli.list
  apt-get update -qq && apt-get install -y -qq gh >/dev/null
fi

say "node"
# FxA's install refuses any Node but the exact one in its .nvmrc; before the
# first clone, take the newest 24.
want="$(sed 's/^v//' "$W/fxa/.nvmrc" 2>/dev/null || true)"
if [ -z "$want" ] && node --version 2>/dev/null | grep -q '^v24\.'; then want="$(node --version | sed 's/^v//')"; fi
if [ "$(node --version 2>/dev/null)" != "v${want:-none}" ]; then
  # The official build, checked against the release's own checksum list.
  base=https://nodejs.org/dist/latest-v24.x; [ -n "$want" ] && base="https://nodejs.org/dist/v${want}"
  tmp="$(mktemp -d)"
  curl -fsSL "$base/SHASUMS256.txt" -o "$tmp/SHASUMS256.txt"
  f="$(grep -oE 'node-v[0-9.]+-linux-x64\.tar\.xz' "$tmp/SHASUMS256.txt" | head -1)"
  curl -fsSL "$base/$f" -o "$tmp/$f"
  (cd "$tmp" && grep " $f\$" SHASUMS256.txt | sha256sum -c -)
  tar -xJf "$tmp/$f" -C /usr/local --strip-components=1
  rm -rf "$tmp"
fi
corepack enable
node --version

say "claude, codex, acli"
command -v claude >/dev/null || npm install -g --silent @anthropic-ai/claude-code
command -v codex >/dev/null || npm install -g --silent @openai/codex
if ! command -v acli >/dev/null; then
  curl -fsSL -o /usr/local/bin/acli https://acli.atlassian.com/linux/latest/acli_linux_amd64/acli \
    && chmod 755 /usr/local/bin/acli || echo "WARN: acli did not install; the pass needs it for Jira"
fi
command -v gcloud >/dev/null || echo "WARN: gcloud is missing; the image should carry it"

# The guest agent reloads "sshd.service" for OS Login, and Ubuntu 24.04 calls it ssh.
systemctl reload ssh 2>/dev/null || true

say "user $U"
id "$U" >/dev/null 2>&1 || useradd -m -s /bin/bash "$U"
install -d -o "$U" -g "$U" -m 755 "$H/Desktop" "$W" "$H/bin"
install -d -o "$U" -g "$U" -m 700 "$H/.config" "$C" "$H/.ssh"
sudo -u "$U" bash -c '
  [ -f ~/.ssh/fxa-sandbox-gce ] || ssh-keygen -q -t ed25519 -N "" -C "fxa-manager" -f ~/.ssh/fxa-sandbox-gce
  git config --global user.name fxa-agent
  git config --global user.email fxa-agent@users.noreply.github.com
  git config --global init.defaultBranch main
  grep -q "fxa manager" ~/.bashrc || cat >> ~/.bashrc <<"RC"
# fxa manager: the gh shim first, then the controller.
export PATH="$HOME/bin:$PATH"
# Your interactive claude bills to the same API key as the timers and runners.
k="$(grep -m1 "^ANTHROPIC_API_KEY=" ~/Desktop/working2/fxa-sandbox-ctl/.env 2>/dev/null | cut -d= -f2-)"
[ -n "$k" ] && export ANTHROPIC_API_KEY="$k"; unset k
cd ~/Desktop/working2/fxa-sandbox-ctl 2>/dev/null
[ -z "$TMUX" ] && echo "Work in tmux: tmux new -As main, then claude"
RC
'

# gh acts as the fxa-agent GitHub App: a fresh installation token each call
# (the controller caches it for 50 minutes).
cat > "$H/bin/gh" <<'GH'
#!/bin/bash
GH_TOKEN="$(cd ~/Desktop/working2/fxa-sandbox-ctl 2>/dev/null && ./fxa-sandbox-ctl app-token 2>/dev/null)"
[ -n "$GH_TOKEN" ] && export GH_TOKEN
exec /usr/bin/gh "$@"
GH
chown "$U:$U" "$H/bin/gh"; chmod 755 "$H/bin/gh"

say "your Claude setup"
if [ -s /tmp/fxa-claude-bundle.tgz ]; then
  # Uploaded by your login user, mode 600: root unpacks it and hands it to fxa.
  install -d -o "$U" -g "$U" -m 700 "$H/.claude"
  tar -xzf /tmp/fxa-claude-bundle.tgz -C "$H/.claude" --no-same-owner
  chown -R "$U:$U" "$H/.claude"
  rm -f /tmp/fxa-claude-bundle.tgz
fi
for f in ctl.env.base bot.env.base; do
  [ -s "/tmp/fxa-$f" ] && install -o "$U" -g "$U" -m 600 "/tmp/fxa-$f" "$C/$f" && rm -f "/tmp/fxa-$f"
done

say "sshd keepalive"
# Drop a client that stopped answering (an IAP tunnel that died) after 3 min;
# the default never checks, and 34 dead sessions piled up on 2026-09-29.
printf '%s\n' 'ClientAliveInterval 60' 'ClientAliveCountMax 3' > /etc/ssh/sshd_config.d/60-fxa-keepalive.conf
sshd -t && systemctl reload ssh

say "secrets unit"
# Writes the .env files and key files from Secret Manager at every boot, so no
# secret is baked into the disk image and a rotation needs only a reboot.
# The script itself is infra/gce/fxa-secrets.sh; manager.sh splices it in at the marker, and
# vm.sh sync installs a changed one.
cat > /usr/local/sbin/fxa-secrets <<'SEC'
__FXA_SECRETS__
SEC
chmod 700 /usr/local/sbin/fxa-secrets

say "systemd units (installed, not started)"
path='PATH=/home/fxa/bin:/usr/local/bin:/usr/bin:/bin:/snap/bin'
cat > /etc/systemd/system/fxa-secrets.service <<UNIT
[Unit]
Description=Write the FxA manager's .env and key files from Secret Manager
Wants=network-online.target
After=network-online.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/fxa-secrets
[Install]
WantedBy=multi-user.target
UNIT
cat > /etc/systemd/system/fxa-agent-bot.service <<UNIT
[Unit]
Description=fxa-agent Slack bot
Requires=fxa-secrets.service
After=fxa-secrets.service
[Service]
User=$U
WorkingDirectory=$W/fxa-agent-bot
Environment=$path
ExecStart=/usr/local/bin/node --env-file=.env src/app.js
Restart=on-failure
# A restart must not kill a session boot or an Open PR job the bot started;
# the bot stops its own watches on SIGTERM.
KillMode=process
RestartSec=10
[Install]
WantedBy=multi-user.target
UNIT
cat > /etc/systemd/system/fxa-dashboard.service <<UNIT
[Unit]
Description=fxa-sandbox-ctl dashboard (127.0.0.1:8787)
Requires=fxa-secrets.service
After=fxa-secrets.service
[Service]
User=$U
WorkingDirectory=$W/fxa-sandbox-ctl
Environment=$path
# All addresses: the Cloud Run gateway reaches it on the private network; the
# GCP firewall admits only the gateway's subnet, and only to this VM.
Environment=FXA_DASHBOARD_BIND=0.0.0.0
ExecStart=$W/fxa-sandbox-ctl/fxa-sandbox-ctl dashboard
Restart=on-failure
RestartSec=10
[Install]
WantedBy=multi-user.target
UNIT
# The only holder of the Anthropic API key for runners (infra/llm-proxy): they
# get a per-run token. All addresses: the GCP firewall admits only the runner
# subnets, and only to this VM's port 8788.
cat > /etc/systemd/system/fxa-llm-proxy.service <<UNIT
[Unit]
Description=fxa-llm-proxy (runners reach Claude through it, :8788)
Requires=fxa-secrets.service
After=fxa-secrets.service
[Service]
User=$U
EnvironmentFile=-$W/fxa-sandbox-ctl/.env
Environment=LLM_PROXY_LISTEN=0.0.0.0:8788
ExecStart=/usr/bin/python3 $W/fxa-sandbox-ctl/infra/llm-proxy/proxy.py
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
UNIT
# Read-only MCP tools for runners (infra/mcp-gateway): they get a per-run
# token. It starts only once $C/mcp-gateway.json names its connectors. The
# GCP firewall must admit the runner subnets to port 8789 as it does to 8788.
cat > /etc/systemd/system/fxa-mcp-gateway.service <<UNIT
[Unit]
Description=fxa-mcp-gateway (runners reach MCP tools through it, :8789)
Requires=fxa-secrets.service
After=fxa-secrets.service
ConditionPathExists=$C/mcp-gateway.json
[Service]
User=$U
EnvironmentFile=-$C/mcp-gateway.env
Environment=MCP_GATEWAY_LISTEN=0.0.0.0:8789
Environment=MCP_GATEWAY_CONFIG=$C/mcp-gateway.json
ExecStart=/usr/bin/python3 $W/fxa-sandbox-ctl/infra/mcp-gateway/gateway.py
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
UNIT

say "grafana (yardstick through IAP, read-only, for the gateway's grafana connector)"
# mzcld gets the IAP token as this VM's service account, which SRE must allow to
# impersonate grafana-iap-access (README, MCP gateway). manager.sh builds it: its repo is private.
MCPG_V=2.0.2
if [ -s /tmp/fxa-mzcld ]; then install -m 755 /tmp/fxa-mzcld /usr/local/bin/mzcld; rm -f /tmp/fxa-mzcld; fi
[ -x /usr/local/bin/mzcld ] || echo "WARN: no mzcld; the grafana connector cannot reach yardstick"
if [ "$(cat /usr/local/lib/fxa-mcp-grafana.version 2>/dev/null)" != "$MCPG_V" ]; then
  tmp="$(mktemp -d)" base="https://github.com/grafana/mcp-grafana/releases/download/v$MCPG_V"
  curl -fsSL "$base/mcp-grafana_${MCPG_V}_checksums.txt" -o "$tmp/sums"
  curl -fsSL "$base/mcp-grafana_Linux_x86_64.tar.gz" -o "$tmp/mcp-grafana_Linux_x86_64.tar.gz"
  (cd "$tmp" && grep ' mcp-grafana_Linux_x86_64.tar.gz$' sums | sha256sum -c - >/dev/null)
  tar -xzf "$tmp/mcp-grafana_Linux_x86_64.tar.gz" -C "$tmp" mcp-grafana
  install -m 755 "$tmp/mcp-grafana" /usr/local/bin/mcp-grafana
  echo "$MCPG_V" > /usr/local/lib/fxa-mcp-grafana.version
  rm -rf "$tmp"
fi
# mzcld has no bind flag and listens on every interface, and anything that reaches it passes
# IAP. So the unit drops port 3000 from all but loopback, on each start (a reboot clears iptables).
cat > /etc/systemd/system/fxa-grafana-iap.service <<UNIT
[Unit]
Description=fxa-grafana-iap (yardstick.mozilla.org through IAP, loopback :3000 only)
After=network-online.target
[Service]
User=$U
ExecStartPre=+/bin/sh -c 'iptables -C INPUT -p tcp --dport 3000 ! -i lo -j DROP 2>/dev/null || iptables -I INPUT -p tcp --dport 3000 ! -i lo -j DROP'
ExecStart=/usr/local/bin/mzcld iap --host yardstick.mozilla.org --proxy --port 3000 --auth-mode adc
Restart=always
RestartSec=60
[Install]
WantedBy=multi-user.target
UNIT
# Read-only twice over: no write or generic-API tools here, and the gateway's allowlist.
# No token here either: the gateway sends it on each call, so it stays the only holder.
cat > /etc/systemd/system/fxa-grafana-mcp.service <<UNIT
[Unit]
Description=fxa-grafana-mcp (read-only Grafana MCP for the gateway, 127.0.0.1:8000)
After=fxa-grafana-iap.service
[Service]
User=$U
Environment=GRAFANA_URL=http://127.0.0.1:3000
ExecStart=/usr/local/bin/mcp-grafana -t streamable-http --address 127.0.0.1:8000 --disable-write --disable-api --disable-admin --disable-incident --disable-oncall --disable-asserts --disable-pyroscope --disable-loki --disable-assistant --disable-provisioning --disable-rendering --disable-snapshot
Restart=always
RestartSec=10
[Install]
WantedBy=multi-user.target
UNIT
# The two jobs the fxa-automation skill defines, with the same prompts.
pass='Invoke /fxa-ai-fixme and run one full pass using the precheck output below as the worklist: take the lock, judge the reconcile and drain lines, sweep review feedback, fill free slots via `freeslots` at most `launchcap` launches. Never merge. Release the lock.'
triage='FxA ai-fixme escalation triage. Read-only. Do NOT take the pass lock, do NOT launch an agent, do NOT relabel anything. Report only items that need a human decision: tickets blocked awaiting a reporter answer (re-verify each live with `fxa-sandbox-ctl ticket <KEY>`), tickets that exhausted the 2-round feedback cap, done PRs stalled in review 3+ days (name the oldest and its reviewer; lead with this), inflight tickets whose agent run died silently (check `git diff --shortstat` on the slot worktree), and structural blockers (frozen paths, missing credentials, disk below the launch floor (PIPE_MIN_FREE_GB)). Output a table of ticket, blocker type, and the decision needed. Omit empty categories. If all are empty, say so in one line.'
for job in pass triage; do
  prompt="$pass"; [ "$job" = triage ] && prompt="$triage"
  printf '%s\n' "$prompt" > "$C/$job-prompt.txt"; chown "$U:$U" "$C/$job-prompt.txt"
  cat > "/etc/systemd/system/fxa-$job.service" <<UNIT
[Unit]
Description=fxa-ai-fixme $job (claude -p)
Requires=fxa-secrets.service
After=fxa-secrets.service
[Service]
Type=oneshot
User=$U
WorkingDirectory=$W/fxa-sandbox-ctl
Environment=$path
EnvironmentFile=-$W/fxa-sandbox-ctl/.env
# The wrapper also records each run's cost in job-costs.jsonl.
ExecStart=$W/fxa-sandbox-ctl/infra/gce/claude-job.sh $job $C/$job-prompt.txt
TimeoutStartSec=3h
# launch returns at once and runs the agent in the background: the pass ending
# must not kill it (the default killed every launch seconds after it started).
KillMode=process
UNIT
done
# Quiet hours 20:00-07:00 New York: no pass starts, so nothing new launches.
# Runs already going finish on their own; reconcile waits for the morning.
cat > /etc/systemd/system/fxa-pass.timer <<'UNIT'
[Unit]
Description=fxa-ai-fixme pass at :04, :19, :34 and :49, 07:04-19:49 New York
[Timer]
OnCalendar=*-*-* 07..19:04,19,34,49:00 America/New_York
Persistent=false
[Install]
WantedBy=timers.target
UNIT
cat > /etc/systemd/system/fxa-triage.timer <<'UNIT'
[Unit]
Description=fxa-ai-fixme escalation triage, weekdays 09:23, 13:23, 17:23 New York
[Timer]
OnCalendar=Mon..Fri 09,13,17:23:00 America/New_York
Persistent=false
[Install]
WantedBy=timers.target
UNIT
systemctl daemon-reload
systemctl enable -q fxa-secrets.service
systemctl enable -q fxa-llm-proxy.service
systemctl enable -q fxa-mcp-gateway.service fxa-grafana-iap.service fxa-grafana-mcp.service
systemctl restart fxa-grafana-iap.service fxa-grafana-mcp.service

say "repos (in the background: the FxA clone and yarn install take a while)"
cat > "$C/provision-repos.sh" <<'REPOS'
#!/bin/bash
set -euo pipefail
export COREPACK_ENABLE_DOWNLOAD_PROMPT=0  # no one is there to answer it
cd ~/Desktop/working2
[ -d fxa-sandbox-ctl ] || git clone -q https://github.com/vbudhram/fxa-sandbox-ctl.git
git -C fxa-sandbox-ctl pull -q --ff-only || true
[ -d fxa-agent-bot ] || git clone -q https://github.com/vbudhram/fxa-agent-bot.git
git -C fxa-agent-bot pull -q --ff-only || true
(cd fxa-agent-bot && npm ci --silent --omit=dev)
mkdir -p ~/.claude/skills
for s in fxa-sandbox-ctl/skills/*/; do n="$(basename "$s")"; ln -sfn "$HOME/Desktop/working2/$s" "$HOME/.claude/skills/$n"; done
[ -d fxa ] || git clone -q https://github.com/mozilla/fxa.git
cd fxa && git pull -q --ff-only || true
yarn install --immutable > ~/.config/fxa/yarn-install.log 2>&1
echo "repos: done"
REPOS
chown "$U:$U" "$C/provision-repos.sh"; chmod 700 "$C/provision-repos.sh"
if pgrep -u "$U" -f provision-repos.sh >/dev/null; then
  echo "already running; log: $C/provision-repos.log"
else
  # Root runs it: the repos as fxa, then the secrets step, which needs root and
  # runs even when yarn fails, so the .env files exist either way.
  nohup setsid bash -c "sudo -u $U -H $C/provision-repos.sh; /usr/local/sbin/fxa-secrets" > "$C/provision-repos.log" 2>&1 < /dev/null &
  disown
  echo "started; log: $C/provision-repos.log"
fi
