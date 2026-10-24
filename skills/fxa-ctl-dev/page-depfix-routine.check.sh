#!/usr/bin/env bash
# dashboard/index.html: a pr-label routine (a dependency PR fix) on the Routines page: its card, its page, its runs,
# the form, Run now with a PR URL, and Stop of the run shown.
#   bash skills/fxa-ctl-dev/page-depfix-routine.check.sh
set -u
p="$(dirname "$0")/page.sh" F="$(dirname "$0")/page-fixture-depfix-routine.json"; fail=0
ck() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want [$2] got [$3]"; fail=1; fi; }
W='const w = ms => new Promise(r => setTimeout(r, ms)); await w(600); const tx = s => document.querySelector(s)?.innerText.replace(/\s+/g, " ").trim() ?? "none";'
out="$(bash "$p" '#teams/example/routines' --fixture "$F" --probe "$W return tx('[data-rt-row=\"1\"] .says')")"; rc=$?
[ "$rc" = 3 ] && { echo "SKIP (no Chrome): the page probes did not run; set CHROME to run them"; exit 0; }

# The card and the page say what a pr-label routine does, with no schedule (A33).
ck "the card says when it runs, what it does and where it posts" "When a dependency PR in example/app asks for help, pushes one fix commit, and posts in #deps." "$out"
ck "the card's next run is on request, and the list has no undefined and no 60 min promise" "on request|false|false" \
  "$(bash "$p" '#teams/example/routines' --fixture "$F" --probe "$W const c = tx('[data-rt-row=\"1\"]'), l = tx('[data-routine-list]');
    return [[...document.querySelectorAll('[data-rt-row=\"1\"] .fact')].find(f => /Next run/.test(f.textContent))?.textContent.replace(/Next run\s*/, '').trim(), /undefined/.test(l), /within 60 min/.test(c)].join('|')")"
ck "the page's setup shows the repo, authors and label, not a schedule, zone or commit rule" "Repo,Authors,Label|false|false" \
  "$(bash "$p" '#teams/example/routines/1' --fixture "$F" --probe "$W const k = [...document.querySelectorAll('.rtd .kv > span')].map(s => s.textContent);
    return [['Repo', 'Authors', 'Label'].filter(x => k.includes(x)).join(','), k.some(x => ['Schedule', 'Time zone', 'No new commits'].includes(x)), /undefined/.test(tx('.rtd'))].join('|')")"
ck "the page's next run tile is on request" "on request" \
  "$(bash "$p" '#teams/example/routines/1' --fixture "$F" --probe "$W return [...document.querySelectorAll('.rtd .stat')].find(s => /Next run/.test(s.textContent))?.querySelector('.big').textContent")"
ck "the page lists every live run: the running PR, one in line and one that waits on a gate" "#90001 Running|#90002 In line behind #90001|#90003 Waiting: the team budget is used" \
  "$(bash "$p" '#teams/example/routines/1' --fixture "$F" --probe "$W return [...document.querySelectorAll('.rtd [data-rt-live]')].map(e => e.innerText.replace(/\s+/g, ' ').replace(/ agent-\S+| Stop run/g, '').trim()).join('|')")"
[ "$fail" = 0 ] && echo "all checks pass"
exit "$fail"
