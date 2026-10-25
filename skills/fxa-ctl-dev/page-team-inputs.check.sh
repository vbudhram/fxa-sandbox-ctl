#!/usr/bin/env bash
# dashboard/index.html: the team Settings page shows how work reaches a team, in headless Chrome with stubbed writes.
#   bash skills/fxa-ctl-dev/page-team-inputs.check.sh
set -u
p="$(dirname "$0")/page.sh" F="$(dirname "$0")/page-fixture-teams.json"; fail=0
ck() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want [$2] got [$3]"; fail=1; fi; }
G="$(mktemp)"; trap 'rm -f "$G"' EXIT
# fx <jq filter>: the teams fixture with Example active, then the filter applied, in $G.
fx() { jq '(."/api/teams/example".status) = "active" | (."/api/teams".teams[] | select(.profile == "example") | .access.status) = "active" | '"$1" "$F" > "$G"; }
stub='const w = ms => new Promise(r => setTimeout(r, ms)), sent = [], f0 = window.fetch;
  window.fetch = (u, o) => o?.method === "POST" ? (sent.push([u, JSON.parse(o.body)]), Promise.resolve(new Response(JSON.stringify({ ok: true, out: "ok" })))) : f0(u, o);
  const q = s => document.querySelector(s), main = () => document.getElementById("s-teams").innerText;'

fx '(."/api/teams/example".access) = {"open": false, "users": [], "channels": ["C0AAAA111"], "jira_prefixes": []} | (."/api/teams".teams[] | select(.profile == "example") | .access.channels) = 1'
who="$stub"' await w(700); const rec = o => ({ access: { open: false, users: [], channels: [], ...o } }), T = { profile: "x", access: { record: true } };
  return [teamWho(T, rec({ channels: ["C1"] })), teamWho({ profile: "x", access: { open: false, users: 0, listed: 0, channels: 2 } }), teamWho(T, rec({ users: ["U0AAA1111"], channels: ["C1"] })),
    /Nobody can start Example\./.test(document.querySelector(".thead").innerText)].join("|")'
out="$(bash "$p" '#teams/example/settings' --fixture "$G" --probe "$who")"; rc=$?
[ "$rc" = 3 ] && { echo "SKIP (no Chrome): the page probes did not run; set CHROME to run them"; exit 0; }
ck "a team with channels and no people reads Nobody: a channel lets nobody start it" "Nobody|Nobody|1 person|true" "$out"

# Each Jira setting has one home: the keys go with Slack, the launch cap with the queue. Each save keeps the other form's caps.
fx '(."/api/teams/example") += {"jira": {"project": "EXA", "queue": true}, "caps": {"usd_per_day": 5, "usd_per_month": 50, "launches_per_day": 7}} | (."/api/teams/example".access.jira_prefixes) = ["EXB"]'
keys="$stub"' try { await w(700); const open = async k => { q(`[data-tf="${k}"]`).click(); await w(400); }, save = async () => { q("[data-tf-save]").click(); await w(500); };
  const set = (sel, v) => { const e = q(sel); e.value = v; e.dispatchEvent(new Event("input", { bubbles: true })); }, form = () => q("[data-tf-save]").closest(".ckbody");
  await open("jira"); const jf = `${!!form().querySelector("#tf-launches_per_day")}:${!!form().querySelector("#tf-prefixes")}:${q("[data-tf-save]").textContent}`; set("#tf-launches_per_day", "9"); await save();
  await open("caps"); const cf = `${!!form().querySelector("#tf-launches_per_day")}`; set("#tf-usd_per_day", "6"); await save();
  await open("access"); const af = form().querySelector("#tf-prefixes")?.value; set("#tf-prefixes", "EXB, EXC"); await save();
  const b = i => sent.filter(x => /\/api\/teams\/example$/.test(x[0]))[i]?.[1] ?? {}, c = i => JSON.stringify(b(i).record?.caps);
  return [jf, c(0), b(0).record?.access?.jira_prefixes?.join(","), cf, c(1), af, b(2).record?.access?.jira_prefixes?.join(","), [0, 1, 2].map(i => b(i).generation).join(",")].join("|") } catch (e) { return "ERR " + e.message + " after " + sent.length + " posts"; }'
ck "Jira keys move to the Slack form and the launch cap to the Jira form; each save keeps the other caps and sends the loaded generation" \
  'true:false:Save|{"usd_per_day":5,"usd_per_month":50,"launches_per_day":9}|EXB|false|{"usd_per_day":6,"usd_per_month":50,"launches_per_day":7}|EXB|EXB,EXC|1792640520000000,1792640520000000,1792640520000000' \
  "$(PAGE_BUDGET=12000 bash "$p" '#teams/example/settings' --fixture "$G" --probe "$keys")"

# The inputs card: each way a session starts, with its rule. says <k>: the lines of one row, then its tag.
says='const says = k => [...document.querySelectorAll(`[data-tin=${k}] .says`)].map(e => e.textContent).join(" / ") + " [" + q(`[data-tin=${k}] .tag`)?.textContent + "]";'
order='const at = s => main().indexOf(s), keys = it => Object.keys(teamPatch({ item: it, d: teamItemDraft(it, TED.rec) }));
  const runs = [...q("[data-tmore=runs]").querySelectorAll("[data-tf]")].map(b => b.dataset.tf), rest = [...document.querySelectorAll("[data-tform] [data-tf]")].filter(b => !b.closest("[data-tmore=runs]")).map(b => b.dataset.tf);
  const ok = ["What it works on", "How work reaches this team", "Budget", "About the team", "How it runs"].map(at).every((x, i, a) => x > 0 && (!i || x > a[i - 1]));
  const m = document.getElementById("main"); m.style.width = "375px"; await w(100); const r = m.getBoundingClientRect().right;
  const wide = [...m.querySelectorAll("*")].filter(e => !e.closest(".tscroll") && e.getBoundingClientRect().right > r + 1).length;'
fx '(."/api/teams/example") += {"jira": {"project": "EXA", "queue": true}, "caps": {"launches_per_day": 7}, "secrets": {"jira": "fxa-team-example--jira"}}
  | (."/api/teams/example".access) = {"open": false, "users": ["U0AAA1111", "U0BBB2222"], "channels": ["C0AAAA111"], "jira_prefixes": ["EXB"]}
  | (."/api/teams/example/routine-channels") = {"at": 1, "channels": [{"id": "C0AAAA111", "name": "example-team"}]} | (."/api/teams/example/secrets") = {"fxa-team-example--jira": "present"}'
act="$stub$says"' await w(900); '"$order"'
  return [says("access"), says("jira"), ok, [...new Set(runs.flatMap(keys))].sort().join(","), rest.filter(x => x !== "repos").flatMap(keys).filter(k => TEAM_RUNNER_KEYS.includes(k)).join(","), wide, document.documentElement.scrollWidth <= innerWidth].join("|")'
ck "an active team: the Slack and Jira rows give each rule, the parts come in order, How it runs holds the runner keys, no sideways scroll at 375 px" \
  "2 people can start it · watches #example-team / A message with EXB-123 or EXA-123 picks this team [on]|Takes EXA tickets with the ai-fixme label, every 5 minutes on weekdays, hourly on weekends, 07:04 to 19:59 New York time · at most 7 launches a day / Jira login: present [on]|true|$(echo boot egress mcp runner secrets skills stack | tr ' ' ',')||0|true" \
  "$(PAGE_BUDGET=9000 bash "$p" '#teams/example/settings' --fixture "$G" --width 375 --probe "$act")"
drf="$stub$says"' await w(800); return [says("access"), says("jira")].join("|")'
ck "a draft open to anyone says so after the test; a team with no project does not use Jira" \
  "Anyone the bot allows can tag @fxa-agent (after the test) [on]|Not used [off]" "$(bash "$p" '#teams/example/settings' --fixture "$F" --probe "$drf")"
fx '(."/api/teams/example") += {"jira": {"project": "EXA"}} | (."/api/teams/example".access) = {"open": false, "users": [], "channels": ["C0AAAA111", "C0BBBB222"], "jira_prefixes": []}'
ck "channels with no people: nobody can start it from Slack, and the row asks for people; a queue that is off names the project" \
  "Nobody can start it from Slack · watches 2 channels / A message with EXA-123 picks this team [add people]|Off · project EXA / Jira login: the bot's [off]" "$(bash "$p" '#teams/example/settings' --fixture "$G" --probe "$drf")"

# Secret tickets: the copy says which tickets, and the interlock shows before Save and goes into the record.
fx '(."/api/teams/example") += {"jira": {"project": "EXA", "queue": true}} | (."/api/teams/example".access) = {"open": true, "users": [], "channels": [], "jira_prefixes": ["EXB"]}'
sec="$stub"' try { await w(700); q("[data-tf=jira]").click(); await w(400); const box = q("[data-tfk=secret]"), before = !!q("[data-tf-secret]");
  box.checked = true; box.dispatchEvent(new Event("input", { bubbles: true })); await w(200);
  const hint = q("[data-tf-secret]"), ahead = !!(hint && hint.compareDocumentPosition(q("[data-tf-save]")) & Node.DOCUMENT_POSITION_FOLLOWING);
  q("[data-tf-save]").click(); await w(500); const r = sent[0]?.[1]?.record ?? {};
  return [box.parentElement.textContent.trim(), before, hint?.textContent, ahead, r.jira?.secret, r.access?.open, JSON.stringify(r.access?.jira_prefixes)].join("|") } catch (e) { return "ERR " + e.message; }'
ck "secret tickets: the box says only secret tickets, the hint shows before Save, and the save turns off open and clears the Jira keys" \
  'Take only secret tickets (a security level, or a security or hackerone label)|false|Needs private work repos. Turns off "Anyone the bot allows" and clears the Jira keys. One team per project.|true|true|false|[]' \
  "$(bash "$p" '#teams/example/settings' --fixture "$G" --probe "$sec")"

# Routines and dependency PR fixes, from the routine summary: a dependency fix is the routine with on pr-label.
fx '(."/api/routines/summary") = {"teams": {"example": {"routines": 2, "paused": 0, "failed": 0}}, "routines": {
  "1": {"name": "Dependency fixes", "team": "example", "template": "blank", "on": "pr-label", "paused": false, "next": null},
  "2": {"name": "Code review", "team": "example", "template": "code-review", "on": "schedule", "paused": false, "next": "@epoch+3600"}}}'
rts="$stub$says"' await w(800); const sum = `${says("routines")} / ${says("depfix")}`, link = q("[data-tin=routines] a")?.getAttribute("href");
  RT = { team: "example", list: [{ id: 1, paused: 0, data: { on: "pr-label", pr: { repo: "example/app", label: "agent-help" } } }] }; teamPaint(); const list = says("depfix");
  TEAM_ADMIN = { admin: false }; const t = TEAMS.teams.find(x => x.profile === "example"), user = String(teamInputsHtml(t, TED.rec, null));
  return [sum.replace(/next run .*? \[/, "next run X ["), link, list, /Routines|Dependency PRs|None|on a schedule/.test(user)].join("|")'
ck "Routines and Dependency PRs rows: counts from the summary, the repo and label once the routine list is loaded, nothing for a viewer who is not an admin" \
  "1 on a schedule · next run X [on] / 1 on [on]|#teams/example/routines|On for example/app, label agent-help [on]|false" \
  "$(bash "$p" '#teams/example/settings' --fixture "$G" --probe "$rts")"

[ "$fail" = 0 ] && echo "all checks pass"
exit "$fail"
