#!/usr/bin/env bash
# What is not yet shipped, for both repos: work not on origin/main, main against the dev deploy and
# the live bot, and the backlog items that wait. Reads only. Usage: shipped.sh [--no-live]
set -uo pipefail
W="${FXA_WORKING2:-$HOME/Desktop/working2}"; CTL="$W/fxa-sandbox-ctl"; BOT="$W/fxa-agent-bot"
for r in "$CTL" "$BOT"; do git -C "$r" fetch -q origin 2>/dev/null || echo "WARN: fetch failed in $r"; done

echo "== work not on origin/main (branch or worktree: commits, uncommitted files, CI)"
for r in "$CTL" "$BOT"; do
  slug="$(git -C "$r" remote get-url origin | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##')"
  git -C "$r" worktree list --porcelain | awk '/^worktree /{w=$2} /^branch /{sub("refs/heads/","",$2); print w"\t"$2} /^detached/{print w"\t-"}' |
  while IFS=$'\t' read -r wt br; do
    [ -d "$wt" ] || continue
    # git cherry drops commits whose patch is already on main (rebased or cherry-picked).
    n="$(git -C "$wt" cherry origin/main HEAD 2>/dev/null | grep -c '^+')"
    d="$(git -C "$wt" status --porcelain --untracked-files=no 2>/dev/null | wc -l | tr -d ' ')"
    [ "$n" = 0 ] && [ "$d" = 0 ] && continue
    ci=""
    if [ "$br" != - ] && [ "$n" != 0 ]; then
      ci="$(gh run list -R "$slug" -b "$br" -L 1 --json status,conclusion --jq '.[0] // empty | "CI \(.status) \(.conclusion)"' 2>/dev/null)"
    fi
    printf '  %-16s %-40s %3s commits %3s dirty  %s  %s\n' "$(basename "$r")" "$br" "$n" "$d" "${ci:-no CI run}" "${wt/#$HOME/~}"
  done
done

echo "== main"
rec="$(git -C "$CTL" rev-parse --git-common-dir)/fxa-dev-deployed"
for r in "$CTL" "$BOT"; do
  k=ctl; [ "$r" = "$BOT" ] && k=bot
  local_ahead="$(git -C "$r" rev-list --count origin/main..main 2>/dev/null)"
  dev="same as the last dev deploy"
  [ "$(sed -n "s/^$k //p" "$rec" 2>/dev/null)" = "$(git -C "$r" rev-parse 'origin/main^{tree}')" ] || dev="NOT what the last dev deploy ran"
  printf '  %-16s origin/main %s, local main %s ahead, %s\n' "$(basename "$r")" "$(git -C "$r" rev-parse --short origin/main)" "$local_ahead" "$dev"
done
[ -s "$rec" ] && echo "  last dev deploy: $(sed -n 's/^at //p' "$rec")"

if [ "${1:-}" != --no-live ]; then
  live="$(bash "$CTL/skills/fxa-manager/vm.sh" run 'git rev-parse --short HEAD; git -C ../fxa-agent-bot rev-parse --short HEAD' 2>&1 | tail -2 | tr '\n' ' ')"
  case "$live" in
    *expired*|*failed*|"") echo "  live: unknown (${live:-no answer}); run ! gcloud auth login" ;;
    *) set -- $live
       for p in "fxa-sandbox-ctl $1 $CTL" "fxa-agent-bot $2 $BOT"; do
         set -- $p
         if git -C "$3" merge-base --is-ancestor origin/main "$2" 2>/dev/null; then s="has origin/main"
         else s="$(git -C "$3" rev-list --count "$2"..origin/main 2>/dev/null) commits behind origin/main: promote"; fi
         printf '  %-16s live %s, %s\n' "$1" "$2" "$s"
       done ;;
  esac
fi

echo "== backlog items that wait (ready, doing, verifying, blocked)"
awk '/^### /{t=$0} /^- status: (ready|doing|verifying|blocked)/{split($0,a," · "); print "  " a[1] "  " substr(t,5,100)}' "$CTL/ai/docs/improve-backlog.md" 2>/dev/null | sed 's/- status: //'
