#!/bin/bash
# Operate the fxa-manager VM, from the laptop or on the VM itself.
#   vm.sh status          services, timers, pipeline, repos, disk, secrets, runners
#   vm.sh run '<cmd>'     run a shell command as fxa in the controller repo
#   vm.sh run - <<'EOF'   the same, with a script on stdin (no quoting, no base64)
#   vm.sh runner <name> '<cmd>'   run a command as the agent user on a runner, through the controller
#   vm.sh sys '<cmd>'     run as your own login user, who can sudo (systemctl, journalctl)
#   vm.sh fc [status|log [n]|install|refresh]   the Firecracker snapshot: its commit, versions and last
#                         refresh, the refresh log, or a refresh with the repo's scripts (starts the host)
#   vm.sh screen          read the tmux session "main" (read-only, secrets masked)
#   vm.sh sync            pull both repos on the VM (after a push from the laptop)
#   vm.sh test [file]     the controller's checks (or one check file) on the VM's Ubuntu, from this working tree
#                         (no commit, no Docker); a scratch folder, removed after
#   vm.sh dev [stop|log [n]|calls [n]|report <thread|key>|ctl <args>|fn <commands>|smoke]   (FXA_SESSION_BASE_SHA=<sha> vm.sh dev: pin new sessions; FXA_FC_HOST=<ip>: Firecracker slots)
#                         (FXA_DEV_FAKE=1 vm.sh dev: a scripted controller, no runner and no PR; see fxa-ctl-dev/fake-ctl.sh)
#                         the dev bot (app fxa-agent-dev) on the VM, from this laptop's working trees of
#                         both repos: uncommitted changes included. Its own sessions folder and thread map;
#                         the same runners, proxy and store as the real bot. Deploy for real with sync.
#   vm.sh promote         sync the live bot, only when main in both repos is exactly what
#                         the last vm.sh dev deployed (uncommitted files included) and CI passed on
#                         both commits (no CI result: the bot's npm test and e2e run here;
#                         FXA_PROMOTE_SKIP_TESTS=1 skips both), then check it and watch live for
#                         new errors for FXA_PROMOTE_WATCH_S (120) s
#   vm.sh rollback        put the live bot back on the commits the last promote replaced, then check it
#                         (main does not change: revert there after)
#   vm.sh api <path>      GET the dashboard's /api/<path> as JSON (snapshot, errors, sessions, stats)
#   vm.sh secret <name> [--prefix <p>]   prompt for a secret's value (hidden), clean it,
#                         check the prefix, and store it in Secret Manager for the manager
#   vm.sh ssh             print the ssh command for a person
# Never prints a secret value: secrets show as present or missing.
set -euo pipefail
P="${FXA_GCE_PROJECT:-moz-fx-dev-vbudhram-sandbox}" Z="${FXA_MANAGER_ZONE:-us-central1-b}" VM=fxa-manager
HERE="$(cd "$(dirname "$0")" && pwd)"
CTL_ROOT="$(cd "$HERE/../.." && pwd)"
mask() { sed -E 's/(sk-ant-[a-z0-9]+-)[A-Za-z0-9_-]+/\1<masked>/g; s/(xox[abpr]-|xapp-|ghs_|ghp_|github_pat_)[A-Za-z0-9_-]+/\1<masked>/g'; }

# The exact content of a working tree, as a git tree id: what vm.sh dev sends (tracked and
# untracked, not ignored), written from a scratch index so the real index is untouched.
worktree_tree() {
  local idx; idx="$(mktemp)"; cp "$(git -C "$1" rev-parse --absolute-git-dir)/index" "$idx" 2>/dev/null || rm -f "$idx"
  GIT_INDEX_FILE="$idx" git -C "$1" add -A >/dev/null 2>&1 && GIT_INDEX_FILE="$idx" git -C "$1" write-tree; local rc=$?
  rm -f "$idx"; return $rc
}
# FXA_DEV_BOT_ROOT: a bot tree other than the sibling one, such as a second worktree on another branch.
BOT_ROOT="$(cd "${FXA_DEV_BOT_ROOT:-$CTL_ROOT/../fxa-agent-bot}" 2>/dev/null && pwd || true)"
# dev_tar <ctl tree> <bot tree>   Both trees' tracked and new files (not ignored ones: .env, ai/, logs/, node_modules) and the
# dev env, gzipped to stdout under the names the VM expects, whatever the local folders are called.
dev_tar() {
  { for x in "fxa-sandbox-ctl $1" "fxa-agent-bot $2"; do n="${x%% *}" r="${x#* }"
      # Not diagrams/*.png: half of the upload, and only the laptop's doc scripts read them.
      git -C "$r" ls-files -co --exclude-standard | while IFS= read -r f; do case "$f" in diagrams/*.png) continue ;; esac; [ -e "$r/$f" ] && printf '%s\t%s\n' "$r/$f" "$n/$f"; done
    done; printf '%s\t%s\n' "$2/.env.dev" fxa-agent-bot/.env.dev; } \
  | python3 -c 'import sys, tarfile
t = tarfile.open(fileobj=sys.stdout.buffer, mode="w|gz")
for l in sys.stdin:
    a, b = l.rstrip("\n").split("\t"); t.add(a, arcname=b, recursive=False)
t.close()'
}
# Absolute: a relative .git would resolve against the caller's directory, such as the bot repo.
DEV_RECORD="$(git -C "$CTL_ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)/fxa-dev-deployed"
# promote_diff <repo> <recorded tree>   Nothing when origin/main is that tree; else what differs.
promote_diff() {
  [ "$(git -C "$1" rev-parse 'origin/main^{tree}')" = "$2" ] && return 0
  echo "$(basename "$1"): origin/main differs from what the dev bot ran:"
  git -C "$1" diff --stat "$2" 'origin/main^{tree}' | sed 's/^/  /'
  return 1
}
# promote_tests <bot repo> <its recorded tree> <ctl repo> <its recorded tree>   The bot's tests and
# fake-Slack e2e (which runs the controller tree's fake-ctl), only on the trees that dev ran.
promote_tests() {
  local log
  [ "$(worktree_tree "$1")" = "$2" ] && [ "$(worktree_tree "$3")" = "$4" ] \
    || { echo "Not promoted: a working tree changed since the dev deploy, so the tests would not run what dev ran. vm.sh dev again." >&2; return 1; }
  log="$(mktemp)"
  echo "Running the bot's tests and e2e..."
  # FXA_CTL_REPO: the e2e takes fake-ctl from the ctl tree checked above, not from ../fxa-sandbox-ctl.
  if ( cd "$1" && export FXA_CTL_REPO="$3" && npm test --silent > "$log" 2>&1 && npm run e2e --silent >> "$log" 2>&1 ); then
    echo "  $(grep -m1 -oE '[0-9]+/[0-9]+ pass' "$log" | tail -1) e2e"; rm -f "$log"
  else
    tail -20 "$log" >&2; echo "Not promoted: the bot's tests or e2e failed (log: $log)." >&2; return 1
  fi
}

# secret_clean [prefix] < value   The value alone: no "NAME=" in front, no quotes or
# whitespace around it. Fails when a prefix is given and the value does not start with it.
# secret_unit <name>   The service that reads the secret once at start, so a new value needs its restart;
# nothing for a secret read per run or per request (the Jira login, the dashboard key, the GitHub App key).
secret_unit() {
  case "$1" in
    fxa-slack-bot-token|fxa-slack-app-token) echo fxa-agent-bot ;;
    fxa-runlayer-agent-token|fxa-sentry-token|fxa-grafana-token) echo fxa-mcp-gateway ;;
    fxa-anthropic-api-key) echo fxa-llm-proxy ;;
  esac
}

secret_clean() {
  local v; v="$(cat)"
  v="$(printf '%s' "$v" | tr -d '\r\n')"; v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
  [[ "$v" =~ ^[A-Z][A-Z0-9_]*=(.+)$ ]] && v="${BASH_REMATCH[1]}"
  v="${v#[\"\']}"; v="${v%[\"\']}"
  [ -n "$v" ] || return 1
  [ -z "${1:-}" ] || [ "${v:0:${#1}}" = "$1" ] || return 1
  printf '%s' "$v"
}

# promote_ci <ctl state> <bot state>   What promote does with CI on main: red, running, skip-tests or test.
promote_ci() {
  case "$1 $2" in *red*) echo red ;; *running*) echo running ;; "green green") echo skip-tests ;; *) echo test ;; esac
}
# promote_ci_wait <ctl dir> <ctl sha> <bot dir> <bot sha>   "<ctl state> <bot state>", after waiting up to
# FXA_PROMOTE_CI_WAIT_S (600) for runs still going: a promote right after a push need not be run again.
promote_ci_wait() {
  local cs bs said="" end=$(( $(date +%s) + ${FXA_PROMOTE_CI_WAIT_S:-600} ))
  while :; do
    cs="$(ci_state "$1" "$2")" bs="$(ci_state "$3" "$4")"
    [ "$(promote_ci "$cs" "$bs")" = running ] && [ "$(date +%s)" -lt "$end" ] || break
    [ -n "$said" ] || { echo "Waiting for CI on main (controller $cs, bot $bs)..." >&2; said=1; }
    sleep "${FXA_PROMOTE_CI_POLL_S:-10}"
  done
  echo "$cs $bs"
}
# ci_state <repo dir> <sha>   green, red, running, or none: the CI runs of that commit on main.
# Only main's runs: after a fast-forward the same commit also has its improve branch's run,
# and a flaky red there must not block a green main.
ci_state() {
  local slug; slug="$(git -C "$1" remote get-url origin | sed -E 's#^(git@github\.com:|https://github\.com/)##; s#\.git$##')"
  gh api "repos/$slug/actions/runs?head_sha=$2&branch=main" --jq '[.workflow_runs[] | if .status == "completed" then .conclusion else "running" end]
    | if length == 0 then "none" elif any(. == "running") then "running"
      elif all(. == "success" or . == "skipped" or . == "neutral") then "green" else "red" end' 2>/dev/null || echo none
}

# promote_new_errors <before> <after>   The open error signatures in after and not in before.
promote_new_errors() { comm -13 <(printf '%s\n' "$1" | sort -u) <(printf '%s\n' "$2" | sort -u) | grep . || true; }
# promote_watch <signatures before>   After the watch: fails on a new open error, or when the read fails,
# since a promote that broke the dashboard also breaks the read.
promote_watch() {
  local all after fresh sig
  all="$(errs_api)" && after="$(open_sigs <<< "$all")" || {
    echo "WARN: vm.sh api errors failed after the promote, so the watch saw nothing. If this promote broke the dashboard: bash skills/fxa-manager/vm.sh rollback" >&2; return 1; }
  fresh="$(promote_new_errors "$1" "$after")"
  if [ -n "$fresh" ]; then
    echo "WARN: new errors on live since the promote:" >&2
    for sig in $fresh; do jq -r --arg s "$sig" '.[] | select(.sig == $s) | "  \(.sig) \(.source)/\(.kind): \(.message | .[0:160])"' <<< "$all" >&2; done
    echo "If this promote caused them: bash skills/fxa-manager/vm.sh rollback" >&2
    return 1
  fi
  echo "  no new errors on live"
}
# open_sigs   The open error signatures in the JSON list on stdin; fails when stdin is not a list.
# promote_access_teams <bot env>   The teams that env lets someone start (PROFILE_OPEN, PROFILE_USERS), one a line.
promote_access_teams() {
  sed -n 's/^PROFILE_OPEN=//p; s/^PROFILE_USERS=//p' "$1" 2>/dev/null | tr ',' '\n' | cut -d: -f1 | tr -d ' "' | grep . | sort -u
}
# promote_access_drift <dev env> <live env>   Teams open in dev but not live: a promote ships code, not access.
promote_access_drift() {
  comm -23 <(promote_access_teams "$1") <(promote_access_teams "$2")
}

open_sigs() { jq -er 'if type == "array" then [.[] | select(.status != "resolved") | .sig] | join("\n") else error("not a list") end' 2>/dev/null; }

# deploy_heads_script   A script for fxa on the VM: "<ctl sha> <bot sha>" of the live checkouts.
deploy_heads_script() {
  echo 'echo "$(git -C ~/Desktop/working2/fxa-sandbox-ctl rev-parse HEAD) $(git -C ~/Desktop/working2/fxa-agent-bot rev-parse HEAD)"'
}

# rollback_script   A script for fxa on the VM: move both live checkouts back to the commits the last
# promote in ~/.fxa-deploys.log replaced. Only when they are still at what that promote deployed, so a
# second rollback, or one after a sync by hand, stops. reset --keep keeps main a branch, so the next
# sync fast-forwards; the bot and the dashboard need a restart after.
rollback_script() {
  cat <<'EOS'
set -u
# The lock manager.sh sync holds: a rollback waits for a sync, so two npm ci runs never share node_modules.
if { exec 9</run/fxa-sync.lock; } 2>/dev/null; then flock -w 600 9 || { echo "rollback: a sync still runs after 10 min; nothing changed"; exit 1; }; fi
L=~/.fxa-deploys.log
line="$(grep ' promote ' "$L" 2>/dev/null | tail -1)"
[ -n "$line" ] || { echo "rollback: no promote recorded in $L"; exit 1; }
set -- $line; oc=$3 ob=$4 nc=$5 nb=$6
for x in "fxa-sandbox-ctl $nc" "fxa-agent-bot $nb"; do
  set -- $x; cur="$(git -C ~/Desktop/working2/$1 rev-parse HEAD)"
  [ "$cur" = "$2" ] || { echo "rollback: $1 is at ${cur:0:7}, not at ${2:0:7} from the last promote; nothing changed"; exit 1; }
  [ -z "$(git -C ~/Desktop/working2/$1 status --porcelain --untracked-files=no)" ] || { echo "rollback: $1 has local edits on the VM; nothing changed"; exit 1; }
done
git -C ~/Desktop/working2/fxa-sandbox-ctl reset -q --keep "$oc" && git -C ~/Desktop/working2/fxa-agent-bot reset -q --keep "$ob" || { echo "rollback: git reset failed"; exit 1; }
echo "fxa-sandbox-ctl: ${nc:0:7} -> ${oc:0:7}"; echo "fxa-agent-bot: ${nb:0:7} -> ${ob:0:7}"
(cd ~/Desktop/working2/fxa-agent-bot && npm ci --silent --omit=dev) || echo "rollback: npm ci failed"
for s in ~/Desktop/working2/fxa-sandbox-ctl/skills/*/; do ln -sfn "${s%/}" ~/.claude/skills/"$(basename "$s")"; done  # as sync does
(cd ~/Desktop/working2/fxa-sandbox-ctl && ./fxa-sandbox-ctl fc install >/dev/null 2>&1) || echo "fc install failed; run vm.sh fc install"
echo "$(date -u +%FT%TZ) rollback $nc $nb $oc $ob" >> "$L"
EOS
}

# deploy_record_script <old heads> <new heads>   The VM line that records a promote, or nothing: a
# promote that moved no commit (or whose heads could not be read) must not become rollback's target.
deploy_record_script() {
  [ -n "$1" ] && [ -n "$2" ] && [ "$1" != "$2" ] || return 0
  printf 'echo %q >> ~/.fxa-deploys.log\n' "$(date -u +%FT%TZ) promote $1 $2"
}

# rollback_targets <rollback output>   Two lines, the ctl sha then the bot sha the rollback moved to;
# a line is empty when its repo did not move.
rollback_targets() {
  printf '%s\n%s\n' "$(printf '%s\n' "$1" | sed -n 's/^fxa-sandbox-ctl: .* -> //p')" "$(printf '%s\n' "$1" | sed -n 's/^fxa-agent-bot: .* -> //p')"
}

# deploy_check <want ctl> <want bot>   The services, the live commits, the bot's connection and the dashboard.
deploy_check() {
  on_vm <<EOF | mask
echo "== after deploy"
for u in fxa-agent-bot fxa-dashboard fxa-mcp-gateway fxa-llm-proxy; do printf '  %-16s %s\n' "\$u" "\$(systemctl is-active \$u)"; done
c=\$(sudo -u fxa git -C /home/fxa/Desktop/working2/fxa-sandbox-ctl rev-parse --short HEAD); b=\$(sudo -u fxa git -C /home/fxa/Desktop/working2/fxa-agent-bot rev-parse --short HEAD)
printf '  controller %s (want $1)  bot %s (want $2)\n' "\$c" "\$b"
sleep 5; sudo journalctl -u fxa-agent-bot --since "-2min" --no-pager -o cat | grep -q "is running" && echo "  bot connected" || echo "  WARN: the bot has not logged 'is running' in 2 min"
printf '  dashboard HTTP %s\n' "\$(curl -s -o /dev/null -w %{http_code} -H 'Host: localhost' localhost:8787/api/snapshot)"
EOF
}

# On the VM, run here; on the laptop, run over IAP ssh.
# gcloud's stderr is noise when the call works; when it fails, say why: an expired login, or ssh's error.
on_vm() {
  if [ "$(hostname -s)" = "$VM" ]; then bash -s; return; fi
  local err rc=0; err="$(mktemp "${TMPDIR:-/tmp}/vm-ssh.XXXXXX")"
  # One IAP connection, shared for 30 min: gcloud opens it (about 3 s), and each later call is plain
  # ssh over it (0.15 s, against 5 s for a new gcloud ssh). A promote makes about ten calls.
  local m="$HOME/.ssh/fxa-mux-$VM"
  ssh -S "$m" -O check x 2>/dev/null || gcloud compute ssh "$VM" --tunnel-through-iap --zone "$Z" --project "$P" --quiet \
    --ssh-flag=-oControlMaster=auto --ssh-flag="-oControlPath=$m" --ssh-flag=-oControlPersist=1800 --command true 2>"$err" >/dev/null </dev/null || rc=$?
  [ "$rc" != 0 ] || ssh -S "$m" -o ControlMaster=no x 'bash -s' 2>>"$err" || rc=$?
  if [ "$rc" != 0 ]; then
    if grep -qiE 'reauthentication|refreshing your current auth tokens|gcloud auth login' "$err"; then
      echo "vm.sh: the gcloud login expired: run ! gcloud auth login" >&2
    elif [ "$rc" = 255 ]; then echo "vm.sh: ssh to $VM failed:" >&2; tail -3 "$err" >&2; fi
  fi
  rm -f "$err"; return "$rc"
}

# dev_fn_script <commands>   A script for fxa on the VM (after $vars): the dev controller's functions
# (its entry point without the line that runs main, copied beside it, since it sources lib/ from its
# own folder), the GCE backend and the dev bot's FXA_FC_HOST,
# then the commands, with stderr merged. No ERR trap, set -e or pipefail: a probe that fails says so.
dev_fn_script() {
  printf '%s\n' 'cd "$D/fxa-sandbox-ctl" || exit 1' \
    'h="$(sed -n "s/^FXA_FC_HOST=\([0-9.]*\)$/\1/p" "$D/fxa-agent-bot/.env.devhost" 2>/dev/null | tail -1)"; [ -z "$h" ] || export FXA_FC_HOST="$h"' \
    'f=".fn-ctl.$$"; sed "\$d" fxa-sandbox-ctl > "$f" && source "./$f"; rm -f "$f"' \
    'source lib/vm-gce.sh; trap - ERR; set +eu +o pipefail; exec 2>&1' "$1"
}

# dev_stop_bots   Stop every dev bot, not only the one in bot.pid: one left by two deploys at once ran 2 days, and Slack gave it half the events.
dev_stop_bots() {
  local p='--env-file=.env.devhost src/app.js' i
  pkill -f -- "$p" || return 0
  for i in 1 2 3 4 5; do pgrep -f -- "$p" >/dev/null || return 0; sleep 1; done
  pkill -9 -f -- "$p"; return 0
}
# dev_prune <tarball>   In $D: remove the files the last vm.sh dev copied that this tarball no longer has
# (tar never deletes), then keep its list for the next deploy. Files no deploy copied stay.
dev_prune() {
  tar -tzf "$1" 2>/dev/null | LC_ALL=C sort > .dev-files.new
  [ -s .dev-files.new ] || { rm -f .dev-files.new; return 0; }
  [ -f .dev-files ] && LC_ALL=C comm -23 .dev-files .dev-files.new | while IFS= read -r f; do rm -f -- "$f"; done
  mv .dev-files.new .dev-files
}

case "${1:-status}" in
  status)
    on_vm <<'EOF' | mask
echo "== services"
for u in fxa-secrets fxa-agent-bot fxa-dashboard; do printf '  %-16s %s\n' "$u" "$(systemctl is-active $u 2>/dev/null)"; done
for t in fxa-pass fxa-triage; do printf '  %-16s timer %s\n' "$t" "$(systemctl is-active $t.timer 2>/dev/null)"; done
sudo -u fxa -H bash -c '
cd ~/Desktop/working2/fxa-sandbox-ctl || exit 0
echo "== pipeline"; echo "  paused: $(./fxa-sandbox-ctl paused 2>/dev/null || echo no)"
echo "== agent sessions"; echo "  $(./fxa-sandbox-ctl sessions status 2>/dev/null)"
echo "== repos"
for r in fxa-sandbox-ctl fxa-agent-bot; do d=~/Desktop/working2/$r; git -C "$d" fetch -q origin 2>/dev/null
  printf "  %-16s %s  (%s behind origin)\n" "$r" "$(git -C "$d" log --oneline -1 | cut -c1-60)" "$(git -C "$d" rev-list --count HEAD..origin/main 2>/dev/null)"; done
echo "== claude credential for runners"
grep -q "^ANTHROPIC_API_KEY=" .env && echo "  ANTHROPIC_API_KEY: present" || { grep -q "^CLAUDE_CODE_OAUTH_TOKEN=" .env && echo "  MISSING: only a setup-token, and the LLM proxy needs ANTHROPIC_API_KEY: runners cannot start" || echo "  MISSING: runners cannot start"; }
d="$(bash skills/fxa-manager/env-drift.sh ../fxa-agent-bot/.env ~/.config/fxa/bot.env.base | tr "\n" " ")"
[ -z "$d" ] || echo "WARN: the bot .env has settings that ~/.config/fxa/bot.env.base does not: ${d}. The next fxa-secrets run drops them: edit bot.env.base too."
d="$(bash skills/fxa-manager/env-drift.sh .env ~/.config/fxa/ctl.env.base "ANTHROPIC_API_KEY|CLAUDE_CODE_OAUTH_TOKEN|PIPE_JIRA_BASIC" | tr "\n" " ")"
[ -z "$d" ] || echo "WARN: the controller .env has settings that ~/.config/fxa/ctl.env.base does not: ${d}. The next fxa-secrets run drops them: edit ctl.env.base too."
echo "== tmux"; tmux ls 2>/dev/null | sed "s/^/  /" || echo "  no session"
echo "== open errors"; ./fxa-sandbox-ctl errors 2>/dev/null | grep -cE "^[0-9a-f]{10}" | sed "s/^/  /"
'
echo "== disk"; df -h / | tail -1 | awk '{print "  " $4 " free of " $2}'
echo "== runners (name, status, the controller that started it)"; gcloud compute instances list --filter='name~^agent-' --format='value(name,status,labels.fxa-controller)' 2>/dev/null | sed 's/^/  /'
echo "== secrets the VM can read (present or missing, never the value)"
# Every secret fxa-secrets reads, from the script itself, so a new one shows here too. The ones it reads with opt_get are optional.
for s in $(sudo grep -oE '(need|get) fxa-[a-z0-9-]+' /home/fxa/Desktop/working2/fxa-sandbox-ctl/infra/gce/fxa-secrets.sh | awk '{print $2}' | sort -u); do
  sudo grep -q "opt_get $s" /home/fxa/Desktop/working2/fxa-sandbox-ctl/infra/gce/fxa-secrets.sh && o=" (optional)" || o=""
  gcloud secrets versions access latest --secret "$s" >/dev/null 2>&1 && printf '  %-26s present\n' "$s" || printf '  %-26s missing%s\n' "$s" "$o"
done
EOF
    ;;
  run)
    [ -n "${2:-}" ] || { echo "usage: vm.sh run '<command>' | vm.sh run - <<'EOF' ... EOF" >&2; exit 1; }
    if [ "$2" = - ]; then
      # The script goes in a quoted heredoc: nothing in it is expanded before fxa's shell runs it.
      { echo "sudo -u fxa -H bash -l <<'__FXA_RUN_SCRIPT__'"; echo 'cd ~/Desktop/working2/fxa-sandbox-ctl'; cat; echo '__FXA_RUN_SCRIPT__'; } | on_vm | mask
    else
      printf 'sudo -u fxa -H bash -lc %q\n' "cd ~/Desktop/working2/fxa-sandbox-ctl && $2" | on_vm | mask
    fi ;;
  runner)
    [ -n "${2:-}" ] && [ -n "${3:-}" ] || { echo "usage: vm.sh runner <name> '<command>'" >&2; exit 1; }
    printf 'sudo -u fxa -H bash -lc %q\n' "cd ~/Desktop/working2/fxa-sandbox-ctl && ./fxa-sandbox-ctl --backend gce exec $(printf %q "$2") $(printf %q "$3")" | on_vm | mask ;;
  fc)
    # The Firecracker snapshot: status, the refresh log, or a refresh with the repo's scripts.
    case "${2:-status}" in status|log|install|refresh) ;; *) echo "usage: vm.sh fc status | log [lines] | install | refresh" >&2; exit 1 ;; esac
    [[ "${3:-80}" =~ ^[0-9]+$ ]] || { echo "usage: vm.sh fc log [lines]" >&2; exit 1; }
    printf 'sudo -u fxa -H bash -lc %q\n' "cd ~/Desktop/working2/fxa-sandbox-ctl && ./fxa-sandbox-ctl fc ${2:-status} ${3:-} 2>&1" | on_vm | mask ;;  # on_vm drops stderr: keep the reason a start failed
  sys)
    [ -n "${2:-}" ] || { echo "usage: vm.sh sys '<command>'" >&2; exit 1; }
    printf '%s\n' "$2" | on_vm | mask ;;
  screen)
    echo 'sudo -u fxa -H tmux capture-pane -p -t main -S -40 | sed "/^\s*$/d" | tail -40' | on_vm | mask ;;
  sync)
    bash "$CTL_ROOT/infra/gce/manager.sh" sync "$P" "$Z" ;;
  test)
    # Tracked and new files, not ignored ones (.env, ai/, logs/), as base64 in the script on stdin.
    { echo 'd=$(mktemp -d) && cd "$d" && base64 -d <<"B64" | tar -xzf -'
      ( cd "$CTL_ROOT" && git ls-files -co --exclude-standard | while IFS= read -r f; do [ -e "$f" ] && printf '%s\n' "$f"; done \
        | COPYFILE_DISABLE=1 tar -czf - -T - ) | base64
      echo 'B64'
      # The git identity and default branch the checks commit with, as the Docker run sets them; scratch only.
      echo 'export GIT_CONFIG_GLOBAL="$d/.gitconfig"; git config --global user.email test@example.com; git config --global user.name test; git config --global init.defaultBranch main'
      # One check file, with its full output, when named; else the whole suite.
      if [ -n "${2:-}" ]; then printf 'bash %q; rc=$?; cd /; rm -rf "$d"; exit $rc\n' "$2"
      else echo 'bash skills/fxa-ctl-dev/test.sh here; rc=$?; cd /; rm -rf "$d"; exit $rc'; fi
    } | on_vm | mask ;;
  dev)
    # Each dev path, and what the dev bot runs with, as fxa on the VM.
    vars='D=$HOME/dev; S=$HOME/.claude/state/agent-sessions-dev; export FXA_SESSION_DIR=$S FXA_AGENT_STATE=$HOME/.fxa-agent-dev-sessions.json FXA_ENV=dev'
    case "${2:-up}" in
      stop) printf 'exec sudo -u fxa -H bash -s\n%s\n%s\ndev_stop_bots; echo "dev bot stopped"\n' "$vars" "$(declare -f dev_stop_bots)" | on_vm ;;
      log) printf 'exec sudo -u fxa -H bash -s\n%s\ntail -n %d $D/bot.log\n' "$vars" "${3:-40}" | on_vm | mask ;;
      # The dev bot's last n Slack calls: time, method, message, and each row or text it sent.
      calls) printf 'exec sudo -u fxa -H bash -s\n%s\ntail -n %d $D/slack-calls.jsonl | jq -r %q\n' "$vars" "${3:-60}" \
          '"\(.at / 1000 | strftime("%H:%M:%S")) \(.method) \(.args.ts // .args.thread_ts // "")" + ([(.args.chunks // [])[] | if .type == "task_update" then "\n    [\(.id) \(.status)] \(.title)\(if .details then " | " + (.details | gsub("\n"; " ⏎ ")) else "" end)" else "\n    text: \(.text // "" | gsub("\n"; " ⏎ ") | .[0:120])" end] | join("")) + (if .args.text and (.args.chunks | not) then "\n    \(.args.text | gsub("\n"; " ⏎ ") | .[0:160])" else "" end) + (if .args.name then " :\(.args.name):" else "" end)' | on_vm | mask ;;
      # The dev controller, with its own sessions folder: vm.sh dev ctl diff <key>, ctl stop <key>.
      ctl) shift 2; [ $# -gt 0 ] || { echo "usage: vm.sh dev ctl <args>" >&2; exit 1; }
        printf 'exec sudo -u fxa -H bash -s\n%s\ncd $D/fxa-sandbox-ctl && ./fxa-sandbox-ctl --backend gce%s 2>&1\n' "$vars" "$(printf ' %q' "$@")" | on_vm | mask ;;
      # The smoke check before a promote: fake-mode threads, then a quick answer; it ends on the real controller.
      smoke) exec bash "$CTL_ROOT/skills/fxa-ctl-dev/dev-smoke.sh" ;;
      # The dev controller's functions on the VM: vm.sh dev fn '_answer_dns_gate', or a script with -.
      fn) [ -n "${3:-}" ] || { echo "usage: vm.sh dev fn '<commands>' | vm.sh dev fn - <<'EOF' ... EOF" >&2; exit 1; }
        cmds="$3"; [ "$cmds" = - ] && cmds="$(cat)"
        printf 'exec sudo -u fxa -H bash -s\n%s\n%s\n' "$vars" "$(dev_fn_script "$cmds")" | on_vm | mask ;;
      report) [ -n "${3:-}" ] || { echo "usage: vm.sh dev report <thread ts | key>" >&2; exit 1; }
        printf 'exec sudo -u fxa -H bash -s\n%s\ncd $D/fxa-sandbox-ctl && ./fxa-sandbox-ctl session report %q 2>&1\n' "$vars" "$3" | on_vm | mask ;;
      up)
        [ -n "$BOT_ROOT" ] && [ -f "$BOT_ROOT/.env.dev" ] || { echo "vm.sh dev: no $BOT_ROOT/.env.dev" >&2; exit 1; }
        # Reach the VM before the tar starts: on an expired login on_vm says so, and no tar writes into a closed pipe.
        on_vm <<< true >/dev/null || exit $?
        { echo 'exec sudo -u fxa -H bash -s'
          echo "$vars"
          # Stop the old dev bot first: its timers ran ctl against a half-extracted tree ("Permission denied").
          declare -f dev_stop_bots
          echo 'mkdir -p $D $S && chmod 700 $S && cd $D && dev_stop_bots && t=$(mktemp) && base64 -d <<"B64" > "$t" && tar -xzf "$t"'
          dev_tar "$CTL_ROOT" "$BOT_ROOT" | base64
          echo 'B64'
          declare -f dev_prune; echo 'dev_prune "$t"; rm -f "$t"'
          cat <<'EOF2'
chmod 600 fxa-agent-bot/.env.dev
R=$HOME/Desktop/working2
ln -sfn $R/fxa-sandbox-ctl/.env fxa-sandbox-ctl/.env
# The routine tick reads the bot's access rules from the sibling tree, as the dashboard did at the save.
ln -sfn $R/fxa-agent-bot/.env fxa-agent-bot/.env
# The real bot's packages, unless this tree changed them.
if cmp -s fxa-agent-bot/package-lock.json $R/fxa-agent-bot/package-lock.json; then
  [ -d fxa-agent-bot/node_modules ] && [ ! -L fxa-agent-bot/node_modules ] && rm -rf fxa-agent-bot/node_modules
  ln -sfn $R/fxa-agent-bot/node_modules fxa-agent-bot/node_modules
else rm -f fxa-agent-bot/node_modules; (cd fxa-agent-bot && npm ci --silent); fi
# ROUTINES_ENV=dev: the dev bot loads the live bot's .env first (ROUTINES_ENV=live), and a dev bot that ticks live
# routines claims the live runs and posts with the dev app, so they fail (channel_not_found) and never run live.
printf 'FXA_CTL=%s\nERROR_DMS=0\nSLACK_CALL_LOG=%s\nROUTINES_ENV=dev\n' "$D/fxa-sandbox-ctl/fxa-sandbox-ctl" "$D/slack-calls.jsonl" > fxa-agent-bot/.env.devhost
EOF2
          # An eval pins every new session to one commit (vm.sh dev with FXA_SESSION_BASE_SHA set); unset, main.
          [[ "${FXA_SESSION_BASE_SHA:-}" =~ ^[0-9a-f]{40}$ ]] && echo "echo FXA_SESSION_BASE_SHA=${FXA_SESSION_BASE_SHA} >> fxa-agent-bot/.env.devhost"
          # FXA_FC_HOST=<ip> vm.sh dev: the dev bot's sessions run as Firecracker slots on that host.
          [[ "${FXA_FC_HOST:-}" =~ ^[0-9]+(\.[0-9]+){3}$ ]] && echo "echo FXA_FC_HOST=${FXA_FC_HOST} >> fxa-agent-bot/.env.devhost"
          # FXA_DEV_FAKE=1: skills/fxa-ctl-dev/fake-ctl.sh plays each session (no runner, no PR), with its own sessions file.
          [ "${FXA_DEV_FAKE:-}" = 1 ] && echo 'echo FXA_CTL=$D/fxa-sandbox-ctl/skills/fxa-ctl-dev/fake-ctl.sh >> fxa-agent-bot/.env.devhost; export FXA_AGENT_STATE=$HOME/.fxa-agent-dev-fake-sessions.json FAKE_CTL_DIR=$D/fake-ctl'
          # FAKE_TICK=<s>: a faster fake clock, for the smoke.
          [ "${FXA_DEV_FAKE:-}" = 1 ] && [[ "${FAKE_TICK:-}" =~ ^[0-9]+(\.[0-9]+)?$ ]] && echo "export FAKE_TICK=${FAKE_TICK}"
          cat <<'EOF2'
cd fxa-agent-bot
# The real bot's settings, then the dev app's, then the dev paths: the last file wins.
setsid nohup node --env-file=$R/fxa-agent-bot/.env --env-file=.env.dev --env-file=.env.devhost src/app.js >> $D/bot.log 2>&1 < /dev/null &
echo $! > $D/bot.pid
for i in 1 2 3 4 5 6 7 8 9 10; do sleep 1; grep -q "is running" <(tail -n 5 $D/bot.log) && break; done
kill -0 "$(cat $D/bot.pid)" 2>/dev/null && echo "dev bot up (pid $(cat $D/bot.pid))" || { echo "dev bot failed:"; tail -n 20 $D/bot.log; }
# ponytail: two deploys at the same moment can still start two; this says so, and the next deploy stops both.
n=$(pgrep -fc -- '--env-file=.env.devhost src/app.js'); [ "${n:-0}" -le 1 ] || echo "WARN: $n dev bots run (another vm.sh dev ran at the same time): run vm.sh dev again"
EOF2
        } | on_vm | mask > "${TMPDIR:-/tmp}/vm-dev-up.$$"
        cat "${TMPDIR:-/tmp}/vm-dev-up.$$"; up=0; grep -q '^dev bot up' "${TMPDIR:-/tmp}/vm-dev-up.$$" && up=1; rm -f "${TMPDIR:-/tmp}/vm-dev-up.$$"
        [ "$up" = 1 ] || exit 1
        # What promote compares main with: the trees this deploy sent.
        printf 'ctl %s\nbot %s\nat %s\n' "$(worktree_tree "$CTL_ROOT")" "$(worktree_tree "$BOT_ROOT")" "$(date -u +%FT%TZ)" > "$DEV_RECORD"
        echo "recorded for vm.sh promote" ;;
      *) echo "usage: vm.sh dev [stop|log [n]|calls [n]|report <thread|key>|ctl <args>|fn <commands>|smoke]" >&2; exit 1 ;;
    esac ;;
  promote)
    [ -s "$DEV_RECORD" ] || { echo "vm.sh promote: no dev deploy recorded; run vm.sh dev and test first" >&2; exit 1; }
    git -C "$CTL_ROOT" fetch -q origin main && git -C "$BOT_ROOT" fetch -q origin main || { echo "vm.sh promote: fetch failed" >&2; exit 1; }
    ok=1
    promote_diff "$CTL_ROOT" "$(sed -n 's/^ctl //p' "$DEV_RECORD")" || ok=0
    promote_diff "$BOT_ROOT" "$(sed -n 's/^bot //p' "$DEV_RECORD")" || ok=0
    [ "$ok" = 1 ] || { echo "Not promoted. Commit and push exactly what you tested (or vm.sh dev again from main), then promote." >&2; exit 1; }
    echo "main matches the dev deploy of $(sed -n 's/^at //p' "$DEV_RECORD")."
    # CI on both main commits: red or still running refuses; green in both skips the bot's tests here;
    # no result runs them, on the tree that dev ran (about 2 min). FXA_PROMOTE_SKIP_TESTS=1 for an emergency.
    if [ "${FXA_PROMOTE_SKIP_TESTS:-}" != 1 ]; then
      read -r cs bs <<< "$(promote_ci_wait "$CTL_ROOT" "$(git -C "$CTL_ROOT" rev-parse origin/main)" "$BOT_ROOT" "$(git -C "$BOT_ROOT" rev-parse origin/main)")"
      echo "CI on main: controller $cs, bot $bs."
      case "$(promote_ci "$cs" "$bs")" in
        red) echo "Not promoted: CI failed on main. Fix it first (gh run list -b main)." >&2; exit 1 ;;
        running) echo "Not promoted: CI on main still runs after ${FXA_PROMOTE_CI_WAIT_S:-600} s. Promote again when it is done." >&2; exit 1 ;;
        skip-tests) echo "CI passed on both commits, so the bot's tests do not run again here." ;;
        *) promote_tests "$BOT_ROOT" "$(sed -n 's/^bot //p' "$DEV_RECORD")" "$CTL_ROOT" "$(sed -n 's/^ctl //p' "$DEV_RECORD")" || exit 1 ;;
      esac
    fi
    errs_api() { "$0" api errors 2>/dev/null; }
    errs_before="$(errs_api | open_sigs)" && errs_read=1 || errs_read=0
    # What sync replaces and deploys, for vm.sh rollback.
    old="$(printf 'exec sudo -u fxa -H bash -s\n%s\n' "$(deploy_heads_script)" | on_vm)" || old=""
    echo "Syncing..."
    "$0" sync || exit 1
    new="$(printf 'exec sudo -u fxa -H bash -s\n%s\n' "$(deploy_heads_script)" | on_vm)" || new=""
    rec="$(deploy_record_script "$old" "$new")"
    if [ -n "$rec" ]; then printf 'exec sudo -u fxa -H bash -s\n%s\n' "$rec" | on_vm
    elif [ -z "$old" ] || [ -z "$new" ]; then echo "WARN: the deploy was not recorded, so vm.sh rollback cannot undo it" >&2
    else echo "No commit moved, so nothing is recorded: vm.sh rollback still undoes the promote before."; fi
    deploy_check "$(git -C "$CTL_ROOT" rev-parse --short origin/main)" "$(git -C "$BOT_ROOT" rev-parse --short origin/main)"
    # A team that worked on the dev bot is refused live when only .env.dev opens it.
    drift="$(printf 'exec sudo -u fxa -H bash -s\n%s\npromote_access_drift ~/dev/fxa-agent-bot/.env.dev ~/Desktop/working2/fxa-agent-bot/.env\n' \
      "$(declare -f promote_access_teams promote_access_drift)" | on_vm)" || drift=""
    [ -z "$drift" ] || echo "WARN: open on the dev bot but not live: $(echo $drift). Add it to PROFILE_OPEN or PROFILE_USERS in the live .env and ~fxa/.config/fxa/bot.env.base, then restart the bot." >&2
    # The first minutes on live: a new or reopened error fails the promote, with the way back.
    w="${FXA_PROMOTE_WATCH_S:-30}"
    if [ "$errs_read" = 0 ]; then
      echo "WARN: the live watch is skipped: vm.sh api errors failed before the sync, so no error can be called new" >&2
    elif [ "$w" -gt 0 ] 2>/dev/null; then
      # A wait cut short still checks live errors: under set -e a killed sleep once ended the promote with no verdict.
      trap 'echo "WARN: the live watch was cut short; checking live errors now" >&2; promote_watch "$errs_before"; exit $?' TERM INT
      echo "Watching live for ${w} s..."; sleep "$w" || echo "WARN: the live watch wait was cut short; checking live errors now" >&2
      trap - TERM INT
      promote_watch "$errs_before" || exit 1
    fi
    ;;
  rollback)
    out="$(printf 'exec sudo -u fxa -H bash -s\n%s\n' "$(rollback_script)" | on_vm)" && rc=0 || rc=$?
    printf '%s\n' "$out"
    [ "$rc" = 0 ] || exit 1
    on_vm <<'EOF'
for u in fxa-agent-bot fxa-dashboard; do systemctl is-active -q $u && sudo systemctl restart $u && echo "restarted $u"; done; true
EOF
    { read -r c; read -r b; } <<< "$(rollback_targets "$out")"; deploy_check "$c" "$b"
    echo "Rolled back. main still has the change: revert it there, then dev and promote as usual. fxa-secrets is not rolled back."
    ;;
  api)
    [[ "${2:-}" =~ ^[A-Za-z0-9/_.=\&?-]+$ ]] || { echo "usage: vm.sh api <path>, such as errors or snapshot" >&2; exit 1; }
    printf 'curl -sf -m 60 -H "Host: localhost" %q\n' "localhost:8787/api/$2" | on_vm | mask ;;
  secret)
    name="${2:-}"; [[ "$name" =~ ^fxa-[a-z0-9-]+$ ]] || { echo "usage: vm.sh secret fxa-<name> [--prefix <p> | --from-vm /home/fxa/<file>]" >&2; exit 1; }
    if [ "${3:-}" = --from-vm ]; then
      # A file made on the manager (a deploy key: several lines), streamed over ssh and never printed.
      [[ "${4:-}" =~ ^/home/fxa/[A-Za-z0-9._/-]+$ ]] && [[ "$4" != *..* ]] || { echo "vm.sh secret: --from-vm takes a file under /home/fxa" >&2; exit 1; }
      val="$(printf 'sudo -u fxa -H cat -- %q\n' "$4" | on_vm)"
      [ -n "$val" ] || { echo "vm.sh secret: $4 is empty or missing on the manager; nothing stored" >&2; exit 1; }
    else
      prefix=""; [ "${3:-}" = --prefix ] && prefix="${4:-}"
      # Typed or pasted at a hidden prompt: never in the clipboard history of a command, or a file.
      read -rs -p "Paste the value for $name, then Enter (hidden): " raw < /dev/tty; echo >&2
      val="$(printf '%s' "$raw" | secret_clean "$prefix")" || { echo "vm.sh secret: empty${prefix:+, or it does not start with $prefix}; nothing stored" >&2; exit 1; }
      unset raw
    fi
    if gcloud secrets describe "$name" --project "$P" >/dev/null 2>&1; then
      printf '%s' "$val" | gcloud secrets versions add "$name" --data-file=- --project "$P" >/dev/null || exit 1
    else
      printf '%s' "$val" | gcloud secrets create "$name" --replication-policy=automatic --data-file=- --project "$P" >/dev/null || exit 1
      # fxa-secrets reads it as the manager's service account, which needs access to each secret.
      sa="$(gcloud compute instances describe "$VM" --zone "$Z" --project "$P" --format='value(serviceAccounts[0].email)')"
      gcloud secrets add-iam-policy-binding "$name" --project "$P" --member "serviceAccount:$sa" \
        --role roles/secretmanager.secretAccessor >/dev/null && echo "granted $sa access to $name"
    fi
    unset val
    echo "stored the latest version of $name ($(gcloud secrets versions list "$name" --project "$P" --limit 1 --format='value(name)'))."
    # The manager writes its key and .env files from Secret Manager, then the reader starts again.
    printf 'sudo /usr/local/sbin/fxa-secrets\n' | on_vm | mask || { echo "vm.sh secret: fxa-secrets failed on the manager; run: vm.sh sys 'sudo /usr/local/sbin/fxa-secrets'" >&2; exit 1; }
    u="$(secret_unit "$name")"
    if [ "$u" = fxa-llm-proxy ]; then
      # A restart drops every model call in flight: the operator picks the moment.
      echo "fxa-llm-proxy reads it at start. When no session is at work (vm.sh api sessions), run: vm.sh sys 'sudo systemctl restart fxa-llm-proxy'"
    elif [ -n "$u" ]; then
      printf 'sudo systemctl restart %s\n' "$u" | on_vm && echo "restarted $u, which reads $name at start"
    else echo "nothing to restart: $name is read per run or per request"; fi ;;
  ssh)
    echo "gcloud compute ssh $VM --tunnel-through-iap --zone $Z --project $P -- -L 8787:localhost:8787"
    echo "then: sudo -iu fxa; tmux new -As main" ;;
  *) sed -n '2,9p' "$0"; exit 1 ;;
esac
