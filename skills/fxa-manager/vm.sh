#!/bin/bash
# Operate the fxa-manager VM, from the laptop or on the VM itself.
#   vm.sh status          services, timers, pipeline, repos, disk, secrets, runners
#   vm.sh run '<cmd>'     run a shell command as fxa in the controller repo
#   vm.sh run - <<'EOF'   the same, with a script on stdin (no quoting, no base64)
#   vm.sh runner <name> '<cmd>'   run a command as the agent user on a runner, through the controller
#   vm.sh sys '<cmd>'     run as your own login user, who can sudo (systemctl, journalctl)
#   vm.sh screen          read the tmux session "main" (read-only, secrets masked)
#   vm.sh sync            pull both repos on the VM (after a push from the laptop)
#   vm.sh test [file]     the controller's checks (or one check file) on the VM's Ubuntu, from this working tree
#                         (no commit, no Docker); a scratch folder, removed after
#   vm.sh dev [stop|log [n]|calls [n]|report <thread|key>|ctl <args>]   (FXA_SESSION_BASE_SHA=<sha> vm.sh dev: pin new sessions; FXA_FC_HOST=<ip>: Firecracker slots)
#                         (FXA_DEV_FAKE=1 vm.sh dev: a scripted controller, no runner and no PR; see fxa-ctl-dev/fake-ctl.sh)
#                         the dev bot (app fxa-agent-dev) on the VM, from this laptop's working trees of
#                         both repos: uncommitted changes included. Its own sessions folder and thread map;
#                         the same runners, proxy and store as the real bot. Deploy for real with sync.
#   vm.sh promote         sync the live bot, only when main in both repos is exactly what
#                         the last vm.sh dev deployed (uncommitted files included), then check it
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
BOT_ROOT="$(cd "$CTL_ROOT/../fxa-agent-bot" 2>/dev/null && pwd || true)"
DEV_RECORD="$(git -C "$CTL_ROOT" rev-parse --git-common-dir 2>/dev/null)/fxa-dev-deployed"
# promote_diff <repo> <recorded tree>   Nothing when origin/main is that tree; else what differs.
promote_diff() {
  [ "$(git -C "$1" rev-parse 'origin/main^{tree}')" = "$2" ] && return 0
  echo "$(basename "$1"): origin/main differs from what the dev bot ran:"
  git -C "$1" diff --stat "$2" 'origin/main^{tree}' | sed 's/^/  /'
  return 1
}

# secret_clean [prefix] < value   The value alone: no "NAME=" in front, no quotes or
# whitespace around it. Fails when a prefix is given and the value does not start with it.
secret_clean() {
  local v; v="$(cat)"
  v="$(printf '%s' "$v" | tr -d '\r\n')"; v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
  [[ "$v" =~ ^[A-Z][A-Z0-9_]*=(.+)$ ]] && v="${BASH_REMATCH[1]}"
  v="${v#[\"\']}"; v="${v%[\"\']}"
  [ -n "$v" ] || return 1
  [ -z "${1:-}" ] || [ "${v:0:${#1}}" = "$1" ] || return 1
  printf '%s' "$v"
}

# On the VM, run here; on the laptop, run over IAP ssh.
on_vm() {
  if [ "$(hostname -s)" = "$VM" ]; then bash -s
  else gcloud compute ssh "$VM" --tunnel-through-iap --zone "$Z" --project "$P" --quiet --command 'bash -s' 2>/dev/null
  fi
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
grep -q "^ANTHROPIC_API_KEY=" .env && echo "  ANTHROPIC_API_KEY: present" || { grep -q "^CLAUDE_CODE_OAUTH_TOKEN=" .env && echo "  setup-token: present" || echo "  MISSING: runners cannot start"; }
echo "== tmux"; tmux ls 2>/dev/null | sed "s/^/  /" || echo "  no session"
echo "== open errors"; ./fxa-sandbox-ctl errors 2>/dev/null | grep -cE "^[0-9a-f]{10}" | sed "s/^/  /"
'
echo "== disk"; df -h / | tail -1 | awk '{print "  " $4 " free of " $2}'
echo "== runners (name, status, the controller that started it)"; gcloud compute instances list --filter='name~^agent-' --format='value(name,status,labels.fxa-controller)' 2>/dev/null | sed 's/^/  /'
echo "== secrets the VM can read (present or missing, never the value)"
for s in fxa-slack-bot-token fxa-slack-app-token fxa-github-app-key fxa-circleci-token fxa-anthropic-api-key fxa-jira-token; do
  gcloud secrets versions access latest --secret "$s" >/dev/null 2>&1 && printf '  %-22s present\n' "$s" || printf '  %-22s missing\n' "$s"
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
      stop) printf 'exec sudo -u fxa -H bash -s\n%s\n%s\n' "$vars" '[ -f $D/bot.pid ] && kill "$(cat $D/bot.pid)" 2>/dev/null && echo "dev bot stopped" || echo "dev bot not running"' | on_vm ;;
      log) printf 'exec sudo -u fxa -H bash -s\n%s\ntail -n %d $D/bot.log\n' "$vars" "${3:-40}" | on_vm | mask ;;
      # The dev bot's last n Slack calls: time, method, message, and each row or text it sent.
      calls) printf 'exec sudo -u fxa -H bash -s\n%s\ntail -n %d $D/slack-calls.jsonl | jq -r %q\n' "$vars" "${3:-60}" \
          '"\(.at / 1000 | strftime("%H:%M:%S")) \(.method) \(.args.ts // .args.thread_ts // "")" + ([(.args.chunks // [])[] | if .type == "task_update" then "\n    [\(.id) \(.status)] \(.title)\(if .details then " | " + (.details | gsub("\n"; " ⏎ ")) else "" end)" else "\n    text: \(.text // "" | gsub("\n"; " ⏎ ") | .[0:120])" end] | join("")) + (if .args.text and (.args.chunks | not) then "\n    \(.args.text | gsub("\n"; " ⏎ ") | .[0:160])" else "" end) + (if .args.name then " :\(.args.name):" else "" end)' | on_vm | mask ;;
      # The dev controller, with its own sessions folder: vm.sh dev ctl diff <key>, ctl stop <key>.
      ctl) shift 2; [ $# -gt 0 ] || { echo "usage: vm.sh dev ctl <args>" >&2; exit 1; }
        printf 'exec sudo -u fxa -H bash -s\n%s\ncd $D/fxa-sandbox-ctl && ./fxa-sandbox-ctl --backend gce%s\n' "$vars" "$(printf ' %q' "$@")" | on_vm | mask ;;
      report) [ -n "${3:-}" ] || { echo "usage: vm.sh dev report <thread ts | key>" >&2; exit 1; }
        printf 'exec sudo -u fxa -H bash -s\n%s\ncd $D/fxa-sandbox-ctl && ./fxa-sandbox-ctl session report %q\n' "$vars" "$3" | on_vm | mask ;;
      up)
        BOT_ROOT="$(cd "$CTL_ROOT/../fxa-agent-bot" && pwd)"
        [ -f "$BOT_ROOT/.env.dev" ] || { echo "vm.sh dev: no $BOT_ROOT/.env.dev" >&2; exit 1; }
        { echo 'exec sudo -u fxa -H bash -s'
          echo "$vars"
          echo 'mkdir -p $D $S && chmod 700 $S && cd $D && base64 -d <<"B64" | tar -xzf -'
          # Tracked and new files of both repos (not ignored ones: .env, ai/, logs/, node_modules), and the dev env.
          ( cd "$CTL_ROOT/.." && for r in fxa-sandbox-ctl fxa-agent-bot; do
              git -C "$r" ls-files -co --exclude-standard | while IFS= read -r f; do [ -e "$r/$f" ] && printf '%s/%s\n' "$r" "$f"; done
            done; echo fxa-agent-bot/.env.dev ) | ( cd "$CTL_ROOT/.." && COPYFILE_DISABLE=1 tar -czf - -T - ) | base64
          echo 'B64'
          cat <<'EOF2'
chmod 600 fxa-agent-bot/.env.dev
R=$HOME/Desktop/working2
ln -sfn $R/fxa-sandbox-ctl/.env fxa-sandbox-ctl/.env
# The real bot's packages, unless this tree changed them.
if cmp -s fxa-agent-bot/package-lock.json $R/fxa-agent-bot/package-lock.json; then
  [ -d fxa-agent-bot/node_modules ] && [ ! -L fxa-agent-bot/node_modules ] && rm -rf fxa-agent-bot/node_modules
  ln -sfn $R/fxa-agent-bot/node_modules fxa-agent-bot/node_modules
else rm -f fxa-agent-bot/node_modules; (cd fxa-agent-bot && npm ci --silent); fi
printf 'FXA_CTL=%s\nERROR_DMS=0\nSLACK_CALL_LOG=%s\n' "$D/fxa-sandbox-ctl/fxa-sandbox-ctl" "$D/slack-calls.jsonl" > fxa-agent-bot/.env.devhost
EOF2
          # An eval pins every new session to one commit (vm.sh dev with FXA_SESSION_BASE_SHA set); unset, main.
          [[ "${FXA_SESSION_BASE_SHA:-}" =~ ^[0-9a-f]{40}$ ]] && echo "echo FXA_SESSION_BASE_SHA=${FXA_SESSION_BASE_SHA} >> fxa-agent-bot/.env.devhost"
          # FXA_FC_HOST=<ip> vm.sh dev: the dev bot's sessions run as Firecracker slots on that host.
          [[ "${FXA_FC_HOST:-}" =~ ^[0-9]+(\.[0-9]+){3}$ ]] && echo "echo FXA_FC_HOST=${FXA_FC_HOST} >> fxa-agent-bot/.env.devhost"
          # FXA_DEV_FAKE=1: skills/fxa-ctl-dev/fake-ctl.sh plays each session (no runner, no PR), with its own sessions file.
          [ "${FXA_DEV_FAKE:-}" = 1 ] && echo 'echo FXA_CTL=$D/fxa-sandbox-ctl/skills/fxa-ctl-dev/fake-ctl.sh >> fxa-agent-bot/.env.devhost; export FXA_AGENT_STATE=$HOME/.fxa-agent-dev-fake-sessions.json FAKE_CTL_DIR=$D/fake-ctl'
          cat <<'EOF2'
[ -f bot.pid ] && kill "$(cat bot.pid)" 2>/dev/null && sleep 2
cd fxa-agent-bot
# The real bot's settings, then the dev app's, then the dev paths: the last file wins.
setsid nohup node --env-file=$R/fxa-agent-bot/.env --env-file=.env.dev --env-file=.env.devhost src/app.js >> $D/bot.log 2>&1 < /dev/null &
echo $! > $D/bot.pid
for i in 1 2 3 4 5 6 7 8 9 10; do sleep 1; grep -q "is running" <(tail -n 5 $D/bot.log) && break; done
kill -0 "$(cat $D/bot.pid)" 2>/dev/null && echo "dev bot up (pid $(cat $D/bot.pid))" || { echo "dev bot failed:"; tail -n 20 $D/bot.log; }
EOF2
        } | on_vm | mask > "${TMPDIR:-/tmp}/vm-dev-up.$$"
        cat "${TMPDIR:-/tmp}/vm-dev-up.$$"; up=0; grep -q '^dev bot up' "${TMPDIR:-/tmp}/vm-dev-up.$$" && up=1; rm -f "${TMPDIR:-/tmp}/vm-dev-up.$$"
        [ "$up" = 1 ] || exit 1
        # What promote compares main with: the trees this deploy sent.
        printf 'ctl %s\nbot %s\nat %s\n' "$(worktree_tree "$CTL_ROOT")" "$(worktree_tree "$BOT_ROOT")" "$(date -u +%FT%TZ)" > "$DEV_RECORD"
        echo "recorded for vm.sh promote" ;;
      *) echo "usage: vm.sh dev [stop|log [n]|calls [n]|report <thread|key>|ctl <args>]" >&2; exit 1 ;;
    esac ;;
  promote)
    [ -s "$DEV_RECORD" ] || { echo "vm.sh promote: no dev deploy recorded; run vm.sh dev and test first" >&2; exit 1; }
    git -C "$CTL_ROOT" fetch -q origin main && git -C "$BOT_ROOT" fetch -q origin main || { echo "vm.sh promote: fetch failed" >&2; exit 1; }
    ok=1
    promote_diff "$CTL_ROOT" "$(sed -n 's/^ctl //p' "$DEV_RECORD")" || ok=0
    promote_diff "$BOT_ROOT" "$(sed -n 's/^bot //p' "$DEV_RECORD")" || ok=0
    [ "$ok" = 1 ] || { echo "Not promoted. Commit and push exactly what you tested (or vm.sh dev again from main), then promote." >&2; exit 1; }
    echo "main matches the dev deploy of $(sed -n 's/^at //p' "$DEV_RECORD"); syncing..."
    "$0" sync || exit 1
    want_ctl="$(git -C "$CTL_ROOT" rev-parse --short origin/main)" want_bot="$(git -C "$BOT_ROOT" rev-parse --short origin/main)"
    on_vm <<EOF | mask
echo "== after promote"
for u in fxa-agent-bot fxa-dashboard fxa-mcp-gateway fxa-llm-proxy; do printf '  %-16s %s\n' "\$u" "\$(systemctl is-active \$u)"; done
c=\$(sudo -u fxa git -C /home/fxa/Desktop/working2/fxa-sandbox-ctl rev-parse --short HEAD); b=\$(sudo -u fxa git -C /home/fxa/Desktop/working2/fxa-agent-bot rev-parse --short HEAD)
printf '  controller %s (want $want_ctl)  bot %s (want $want_bot)\n' "\$c" "\$b"
sleep 5; sudo journalctl -u fxa-agent-bot --since "-2min" --no-pager -o cat | grep -q "is running" && echo "  bot connected" || echo "  WARN: the bot has not logged 'is running' in 2 min"
printf '  dashboard HTTP %s\n' "\$(curl -s -o /dev/null -w %{http_code} -H 'Host: localhost' localhost:8787/api/snapshot)"
EOF
    ;;
  api)
    [[ "${2:-}" =~ ^[A-Za-z0-9/_.=\&?-]+$ ]] || { echo "usage: vm.sh api <path>, such as errors or snapshot" >&2; exit 1; }
    printf 'curl -sf -m 60 -H "Host: localhost" %q\n' "localhost:8787/api/$2" | on_vm | mask ;;
  secret)
    name="${2:-}"; [[ "$name" =~ ^fxa-[a-z0-9-]+$ ]] || { echo "usage: vm.sh secret fxa-<name> [--prefix <p>]" >&2; exit 1; }
    prefix=""; [ "${3:-}" = --prefix ] && prefix="${4:-}"
    # Typed or pasted at a hidden prompt: never in the clipboard history of a command, or a file.
    read -rs -p "Paste the value for $name, then Enter (hidden): " raw < /dev/tty; echo >&2
    val="$(printf '%s' "$raw" | secret_clean "$prefix")" || { echo "vm.sh secret: empty${prefix:+, or it does not start with $prefix}; nothing stored" >&2; exit 1; }
    unset raw
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
    echo "The manager uses it after fxa-secrets runs: vm.sh sys 'sudo /usr/local/sbin/fxa-secrets', then restart what reads it." ;;
  ssh)
    echo "gcloud compute ssh $VM --tunnel-through-iap --zone $Z --project $P -- -L 8787:localhost:8787"
    echo "then: sudo -iu fxa; tmux new -As main" ;;
  *) sed -n '2,9p' "$0"; exit 1 ;;
esac
