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
apt-get install -y -qq git jq tmux rsync curl ca-certificates python3 python3-venv unzip build-essential openssl >/dev/null
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

say "secrets unit"
# Writes the .env files and key files from Secret Manager at every boot, so no
# secret is baked into the disk image and a rotation needs only a reboot.
cat > /usr/local/sbin/fxa-secrets <<'SEC'
#!/bin/bash
set -euo pipefail
H=/home/fxa W=/home/fxa/Desktop/working2 C=/home/fxa/.config/fxa
P="$(curl -fsS -H Metadata-Flavor:Google http://metadata.google.internal/computeMetadata/v1/project/project-id)"
get() { gcloud secrets versions access latest --secret "$1" --project "$P" 2>/dev/null; }
umask 077
get fxa-github-app-key > "$C/github-app.pem"
mkdir -p "$H/.circleci"; printf 'token: %s\n' "$(get fxa-circleci-token)" > "$H/.circleci/cli.yml"
if [ -d "$W/fxa-sandbox-ctl" ]; then
  { cat "$C/ctl.env.base"
    # The API key when there is one (billed per token), else a setup-token.
    k="$(get fxa-anthropic-api-key || true)"; t="$(get fxa-claude-token || true)"
    if [ -n "$k" ]; then printf 'ANTHROPIC_API_KEY=%s\n' "$k"; elif [ -n "$t" ]; then printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n' "$t"; fi
    true; } > "$W/fxa-sandbox-ctl/.env"
fi
if [ -d "$W/fxa-agent-bot" ]; then
  { cat "$C/bot.env.base"
    printf 'SLACK_BOT_TOKEN=%s\n' "$(get fxa-slack-bot-token)"
    printf 'SLACK_APP_TOKEN=%s\n' "$(get fxa-slack-app-token)"; } > "$W/fxa-agent-bot/.env"
fi
chown -R fxa:fxa "$C" "$H/.circleci"
[ -f "$W/fxa-sandbox-ctl/.env" ] && chown fxa:fxa "$W/fxa-sandbox-ctl/.env"
[ -f "$W/fxa-agent-bot/.env" ] && chown fxa:fxa "$W/fxa-agent-bot/.env"
echo "fxa-secrets: wrote the key files and the .env files"
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
# The two jobs the fxa-automation skill defines, with the same prompts.
pass='Run `~/Desktop/working2/fxa-sandbox-ctl/fxa-sandbox-ctl precheck`. If it prints a line starting `quiet`, `locked`, or `paused`, reply with that one line and stop. Do not load any skill. Otherwise invoke /fxa-ai-fixme and run one full pass using the precheck output as the worklist: take the lock, judge the reconcile and drain lines, sweep review feedback, fill free slots via `freeslots` at most `launchcap` launches. Never merge. Release the lock.'
triage='FxA ai-fixme escalation triage. Read-only. Do NOT take the pass lock, do NOT launch an agent, do NOT relabel anything. Report only items that need a human decision: tickets blocked awaiting a reporter answer (re-verify each live with `fxa-sandbox-ctl ticket <KEY>`), tickets that exhausted the 2-round feedback cap, done PRs stalled in review 3+ days (name the oldest and its reviewer; lead with this), inflight tickets whose agent run died silently (check `git diff --shortstat` on the slot worktree), and structural blockers (frozen paths, missing credentials, disk below the 25GB launch floor). Output a table of ticket, blocker type, and the decision needed. Omit empty categories. If all are empty, say so in one line.'
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
ExecStart=/bin/bash -c 'claude -p --permission-mode auto < $C/$job-prompt.txt'
TimeoutStartSec=3h
# launch returns at once and runs the agent in the background: the pass ending
# must not kill it (the default killed every launch seconds after it started).
KillMode=process
UNIT
done
cat > /etc/systemd/system/fxa-pass.timer <<'UNIT'
[Unit]
Description=fxa-ai-fixme pass at :09, :29 and :49
[Timer]
OnCalendar=*-*-* *:09,29,49:00
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
