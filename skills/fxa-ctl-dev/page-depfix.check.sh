#!/usr/bin/env bash
# dashboard/index.html: a dependency fix run on Sessions and Sandboxes. A team admin sees its PR and trigger;
# another viewer sees 'Dependency fix' with no team, PR or cost.
#   bash skills/fxa-ctl-dev/page-depfix.check.sh
set -u
p="$(dirname "$0")/page.sh" F="$(dirname "$0")/page-fixture-depfix.json"; fail=0
run() { local out rc; out="$(bash "$p" "$1" --fixture "$F" --width 1280 --probe "$2")"; rc=$?
  [ "$rc" = 3 ] && { echo "SKIP (no Chrome): the dependency fix probes did not run"; exit 0; }
  printf '%s\n' "$out"; grep -qv '^ok ' <<< "$out" && fail=1; }
# ck(name, cond): one line each. The non-admin view drops the admin fields the server would mask.
PRE='const w = ms => new Promise(r => setTimeout(r, ms)), out = [], ck = (n, c) => out.push(`${c ? "ok  " : "FAIL"} ${n}`);
  const nonAdmin = async () => { TEAM_ADMIN = { admin: false }; if (SB_DONE?.runs) SB_DONE.runs = SB_DONE.runs.map(r => r.src === "depfix"
    ? { ...r, title: "Dependency fix", key: "", team: "", usd: null, min: null, stop: null, pr_url: null, pr_number: null, fix_pr: undefined, fix_trigger: undefined, fix_actor: undefined } : r);
    Object.keys(LAST).forEach(k => delete LAST[k]); render(); renderRight(); await w(150); };
  await w(400);'

run '#runners' "$PRE"'
  const list = () => document.getElementById("sb-list").innerText, done = () => document.getElementById("sb-done").innerText;
  ck("Sandboxes, admin: the live fix run names its PR and trigger", list().includes("Dependency fix: #90001 (label by octo-example)"));
  ck("Sandboxes, admin: the stopped fix run with its runner up names its PR and trigger", list().includes("Dependency fix: #90002 (BLEnder)"));
  ck("Recently completed, admin: the fix run with its PR and trigger", done().includes("Dependency fix: #90002 (BLEnder)"));
  await nonAdmin();
  const l = list(), d = done(), rows = [...document.querySelectorAll("#sb-list tr")].filter(tr => /Dependency fix/.test(tr.textContent)).map(tr => tr.innerText);
  ck("Sandboxes, non-admin: two rows say Dependency fix", rows.length === 2);
  ck("Sandboxes, non-admin: no PR, trigger, team or cost on them", rows.every(t => !/9000[12]|octo-example|BLEnder|Example|\$\d/.test(t)));
  ck("Sandboxes, non-admin: no scheduled run text for a fix run", !/Dependency fix[\s\S]{0,40}scheduled run/.test(l) && !rows.some(t => /scheduled run/.test(t)));
  const dr = [...document.querySelectorAll("#sb-done tr")].find(tr => /Dependency fix/.test(tr.textContent))?.innerText ?? "";
  ck("Recently completed, non-admin: Dependency fix with no PR, team or cost", !!dr && !/9000|BLEnder|Example|\$\d|scheduled run/.test(dr));
  return out.join("\n")'

run '#sessions/live/agent-fix001' "$PRE"'
  const side = () => document.getElementById("side").innerText, main = () => document.getElementById("s-sess").innerText, right = () => document.getElementById("right")?.innerText ?? "";
  ck("Sessions, admin: the list names the fix run with its PR and trigger", side().includes("Dependency fix: #90001 (label by octo-example)"));
  ck("Sessions, admin: the details say the fix run", right().includes("Dependency fix: #90001 (label by octo-example)"));
  await nonAdmin();
  const s = side(), m = main(), r = right();
  ck("Sessions, non-admin: the list says Dependency fix", /Dependency fix/.test(s));
  ck("Sessions, non-admin: the list has no PR, trigger or cost for it", !/90001|octo-example|\$0\.85/.test(s));
  ck("Sessions, non-admin: the conversation and the bar show no PR or prompt", !/90001|Host frame|octo-example/.test(m) && /Dependency fix/.test(m));
  ck("Sessions, non-admin: the details show no PR, team, trigger or cost", !/90001|octo-example|Example|\$0\.85/.test(r));
  return out.join("\n")'
[ "$fail" = 0 ] && echo "all checks pass"
exit "$fail"
