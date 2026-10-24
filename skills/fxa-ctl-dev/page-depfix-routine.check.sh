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

# Each fix run in History: its result and next step from fix.why, the trigger, the PR, and base to new SHA (A28, A33).
hist="$(bash "$p" '#teams/example/routines/1' --fixture "$F" --probe "$W return [...document.querySelectorAll('.rtd .item')].map(e => [e.querySelector('.title')?.textContent, e.querySelector('.tag')?.textContent, e.querySelector('.line2')?.textContent.replace(/\s+/g, ' ').trim().replace(/ · \d\d:\d\d/, ''), e.querySelector('.next')?.textContent ?? ''].join(' / ')).join('\n')")"
row() { sed -n "${1}p" <<< "$hist"; }
ck "pushed: the new SHA, the trigger, the PR, base to new SHA, and the next step" "Pushed bbbbbbb to #90001 / Pushed / label by example-writer · \$1.20 · agent-fix021 · #90001 · aaaaaaa → bbbbbbb / Next: review the fix commit, then approve the functional tests gate." "$(row 1)"
ck "no fix found, by BLEnder" "No fix found for #90004 / No fix found / BLEnder · \$0.80 · #90004 · ccccccc / A new commit allows a new run." "$(row 2)"
ck "branch moved, by Run now" "The branch of #90005 moved, so nothing was pushed / Branch moved / Run now by admin · \$0.90 · #90005 · ddddddd / Add agent-help again to retry." "$(row 3)"
ck "a guard: not pushed, with its class and the guard text" "Not pushed (yarn.lock) / Not pushed / label by example-writer · \$0.70 · #90006 · eeeeeee / The fix changes yarn.lock entries, which I do not push. Fix it by hand." "$(row 4)"
ck "stopped: the cause" "Stopped (the agent-help label was removed) / Stopped / label by example-writer · \$0.20 · #90007 · fffffff / Nothing was pushed. Add agent-help again to retry." "$(row 5)"
ck "not started: the reason" "Not started (the PR has a new commit) / Not started / label by example-writer · no cost · #90008 · 0000000 / Add agent-help again to fix the new head." "$(row 6)"
ck "failed: the reason, and nothing was pushed" "The sandbox did not start / Failed / label by example-writer · no cost · #90009 · 9999999 / Nothing was pushed. Add agent-help again to retry." "$(row 7)"
ck "the legend names the fix results too" "true" \
  "$(bash "$p" '#teams/example/routines' --fixture "$F" --probe "$W const k = tx('.rtkey'); return ['Pushed', 'Not pushed', 'No fix found', 'Not started'].every(x => k.includes(x))")"

# The form: the dependency PR start asks when a PR asks for help, sends on and pr, and has no Create and run now (A33).
form="$W const sent = [], f0 = window.fetch, set = (s, v) => { const e = document.querySelector(s); e.value = v; e.dispatchEvent(new Event('input', { bubbles: true })); };
  window.fetch = (u, o) => o?.method === 'POST' ? (sent.push(JSON.parse(o.body)), Promise.resolve(new Response(JSON.stringify({ out: 'created routine 7' }), { status: 200 }))) : f0(u, o);
  document.querySelector('[data-rt-new]').click(); await w(200); document.querySelector('[data-rt-tpl=\"depfix\"]').click(); await w(200);
  set('#rt-pr_authors', 'dependabot[bot], example-blender[bot]'); set('#rt-channel', 'C0123ABCD'); await w(200);
  const f = tx('[data-routine-form]'), rb = tx('[data-rt-readback]'), run = !!document.querySelector('[data-rt-then=\"run\"]'), sched = !!document.querySelector('#rt-schedule, #rt-time, #rt-prompt');
  document.querySelector('[data-rt-save]').click(); await w(400); const r = sent[0]?.routine ?? {};
  return [/When: a dependency PR asks for help/.test(f), run, sched, rb, JSON.stringify([r.on, r.mode, r.repos, r.pr, 'schedule' in r, 'prompt' in r, 'zone' in r])].join('\n')"
ck "the form says when a dependency PR asks for help, has no Create and run now and no schedule or prompt, reads back, and sends on and pr" \
  "true
false
false
Dependency fixes runs when a dependency PR in example/app by dependabot[bot] or example-blender[bot] asks for help with the agent-help label. It pushes one fix commit to the PR branch, posts in #deps, and stops at \$10.00 a run.
[\"pr-label\",\"pr\",[\"example/app\"],{\"repo\":\"example/app\",\"authors\":[\"dependabot[bot]\",\"example-blender[bot]\"],\"label\":\"agent-help\"},false,false,false]" \
  "$(bash "$p" '#teams/example/routines' --fixture "$F" --probe "$form")"
edit="$W document.querySelector('[data-rt-act=\"edit\"][data-rt-id=\"1\"]').click(); await w(300);
  return [document.querySelector('#rt-pr_repo')?.value, document.querySelector('#rt-pr_authors')?.value, document.querySelector('#rt-pr_label')?.value, !!document.querySelector('[data-rt-then=\"run\"]')].join('|')"
ck "Edit of a pr-label routine fills the pr fields" "example/app|dependabot[bot], example-blender[bot]|agent-help|false" "$(bash "$p" '#teams/example/routines/1' --fixture "$F" --probe "$edit")"
[ "$fail" = 0 ] && echo "all checks pass"
exit "$fail"
