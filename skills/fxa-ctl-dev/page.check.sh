#!/usr/bin/env bash
# page.sh renders the dashboard from the fixture: a probe sees the team heading, and a probe error is printed, not lost.
# It renders dashboard/index.html, so test.sh changed runs it for a change to the page.
#   bash skills/fxa-ctl-dev/page.check.sh
set -u
p="$(dirname "$0")/page.sh"; fail=0
h="$(bash "$p" '#teams/example' --probe 'return document.getElementById("team-h")?.textContent ?? "none"')"; rc=$?
[ "$rc" = 3 ] && { echo "SKIP (no Chrome): the page probes did not run; set CHROME to run them"; exit 0; }
ck() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want [$2] got [$3]"; fail=1; fi; }
ck "the fixture team page has its heading" "Example" "${h%% *}"
ck "a probe that throws prints its error" "ERR boom" "$(bash "$p" '#teams' --probe 'throw new Error("boom")')"
F="$(dirname "$0")/page-fixture-pipeline.json"
ck "belts at 390 px: no sideways scroll, no stop header, the track below the ticket" "true|none|true" "$(bash "$p" '#pipeline/belts' --fixture "$F" --width 390 --probe '
  const rows = [...document.querySelectorAll(".belt > a")], h = document.querySelector(".bstops");
  const below = rows.every(a => a.querySelector(".trk").getBoundingClientRect().top >= a.querySelector(".tk").getBoundingClientRect().bottom - 1);
  return `${document.documentElement.scrollWidth <= innerWidth && rows.every(a => a.scrollWidth <= a.clientWidth)}|${getComputedStyle(h).display}|${rows.length > 0 && below}`')"
ck "belts at 1280 px: the status has its full text and overlaps nothing" "true|true" "$(bash "$p" '#pipeline/belts' --fixture "$F" --width 1280 --probe '
  const a = document.querySelector(".belt[data-belt=\"FXA-1\"] > a"), r = x => a.querySelector(x).getBoundingClientRect(), st = r(".st");
  return `${/approve the tooling change/.test(a.querySelector(".st .l2").title)}|${st.left >= r(".trk").right && st.right <= r(".age").left && a.scrollWidth <= a.clientWidth}`')"
ck "a row opens below itself with four blocks and one main action; the right panel is gone" "true|#pipeline/belts|CI: 1 of 22 checks failed;Agent;Review;Agent runs|Open the failing check|/pull/3/checks|none|false" "$(bash "$p" '#pipeline/belts/FXA-3' --fixture "$F" --probe '
  const a = document.querySelector(".belt[data-belt=\"FXA-3\"] > a"), d = a.nextElementSibling, m = d.querySelector(".main");
  return [a.getAttribute("aria-expanded"), a.getAttribute("href"), [...d.querySelectorAll("h3")].map(h => h.textContent.split(":")[0] === "CI" ? h.textContent : h.textContent.split(":")[0]).join(";"), m.textContent, m.getAttribute("href").replace(/^.*\/pull/, "/pull"), getComputedStyle(document.getElementById("right")).display, !!document.getElementById("tright")].join("|")')"
ck "a close keeps the place, focuses the row, and Back leaves the page" "true|0|true|true|true" "$(bash "$p" '#pipeline/belts' --fixture "$F" --width 1280 --probe '
  const w = () => new Promise(r => setTimeout(r, 300)), row = () => document.querySelectorAll(".belt > a")[6], m = document.getElementById("main"), n0 = history.length;
  row().click(); await w(); const open = !!document.querySelector(".bdet"); const top = m.scrollTop; row().click(); await w();
  const closed = !document.querySelector(".bdet") && document.activeElement === row(); row().click(); await w();
  document.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true })); await w();
  return [open, history.length - n0, closed, !document.querySelector(".bdet") && document.activeElement === row(), Math.abs(m.scrollTop - top) < 80].join("|")')"
ck "a poll keeps the open row, the Outside group and the focus on the main action" "true|true|true" "$(bash "$p" '#pipeline/belts/FXA-3' --fixture "$F" --probe '
  const w = () => new Promise(r => setTimeout(r, 200));
  document.querySelector("details.bout > summary").click(); await w(); document.querySelector("#bd-FXA-3 .main").focus();
  AGENTS.runners[0].elapsed_seconds += 120; renderLanes(); await w();
  return [document.querySelector("details.bout").open, !!document.getElementById("bd-FXA-3"), document.activeElement?.dataset.focus === "main" && !!document.activeElement.closest("#bd-FXA-3")].join("|")')"
ck "a link to a key with no belt says where it is" "FXA-7 waits on FXA-2 (Queue and review)|FXA-30 is ready in the queue (Queue and review)|FXA-50 merged N ago (Done)|FXA-999 is not on a belt now. Look in Queue and review or Done.|That link names no ticket." "$(for k in FXA-7 FXA-30 FXA-50 FXA-999 '%3Cimg%3E'; do bash "$p" "#pipeline/belts/$k" --fixture "$F" --probe 'return (document.querySelector(".bwhere")?.textContent ?? "none").replace(/merged (today|\d+ days? ago)/, "merged N ago") + (document.querySelector(".bdet") ? " OPEN" : "")'; done | paste -sd'|' -)"
ck "an old Board link lands on Belts, with a Jira key only" "#pipeline/belts/FXA-3|true|#pipeline/belts" "$(bash "$p" '#pipeline/board/FXA-3' --fixture "$F" --probe 'return location.hash + "|" + !!document.getElementById("bd-FXA-3")')|$(bash "$p" '#pipeline/board/%3Cimg%3E' --fixture "$F" --probe 'return location.hash')"
# The whole flow on one fixture, at desktop and phone width: no section fails, nothing scrolls sideways.
flow='const w = () => new Promise(r => setTimeout(r, 250)), bad = () => [...document.querySelectorAll(".emptybox")].some(e => /did not render/.test(e.textContent)), wide = () => document.documentElement.scrollWidth > innerWidth;
  let fails = [];
  const step = (n, ok) => { if (!ok || bad() || wide()) fails.push(n); };
  location.hash = "#pipeline"; await w(); step("open", /agents? works? now/.test(document.querySelector(".bhead")?.textContent ?? "") && document.querySelectorAll("#s-lanes h2").length === 4);
  document.querySelector(".belt[data-belt=\"FXA-3\"] > a").click(); await w(); step("row open", !!document.getElementById("bd-FXA-3"));
  document.querySelector(".belt[data-belt=\"FXA-3\"] > a").click(); await w(); step("row close", !document.querySelector(".bdet"));
  document.querySelector("details.bout > summary").click(); await w(); step("outside", document.querySelector("details.bout").open);
  location.hash = "#pipeline/done"; await w(); step("done", !!document.querySelector("#s-done table"));
  location.hash = "#pipeline/board/FXA-3"; await w(); await w(); step("board alias", location.hash === "#pipeline/belts/FXA-3");
  return fails.join(",") || "ok"'
ck "the whole Pipeline flow at 1280 px and 390 px" "ok|ok" "$(bash "$p" '#overview' --fixture "$F" --width 1280 --probe "$flow")|$(bash "$p" '#overview' --fixture "$F" --width 390 --probe "$flow")"
ck "a link to an Outside row opens the Outside group and shows the row" "true|true" "$(bash "$p" '#pipeline/belts/agent-abc123' --fixture "$F" --probe 'return document.querySelector("details.bout").open + "|" + document.getElementById("bd-agent-abc123").checkVisibility()')"
ck "Watch the agent opens the terminal, moves the focus there, and a poll keeps it open" "true|true|true" "$(bash "$p" '#pipeline/belts/FXA-20' --fixture "$F" --probe '
  const w = () => new Promise(r => setTimeout(r, 200)); document.querySelector("#bd-FXA-20 .main").click(); await w();
  const d = () => document.getElementById("lane-term-FXA-20"), o = d().open, f = !!document.activeElement?.closest("#lane-term-FXA-20");
  renderLanes(); await w(); return [o, f, d().open].join("|")')"
# Sandboxes: a stopped GCE instance is not up. It has its own group and a fix, with no lifetime meter.
R="$(mktemp "${TMPDIR:-/tmp}/fxa-runners.XXXXXX")"
jq '."/api/snapshot".agents.instances = [{"name":"agent-agent-41c0e6","state":"terminated","age_seconds":213277,"max_seconds":5400,"where":"gce"},
  {"name":"agent-fxa-9","state":"running","age_seconds":600,"max_seconds":5400,"where":"gce"}]' "$F" > "$R"
ck "a stopped instance: its own group, a fix, not counted up, no meter" "Stopped, needs a fix;Sandboxes up|1 sandbox up · 1 stopped|true|true|1" "$(bash "$p" '#runners' --fixture "$R" --width 1280 --probe '
  const h = [...document.querySelectorAll("#side h3, #side .grp, #side [data-group]")].map(e => e.textContent.trim()).filter(Boolean);
  const pool = document.querySelector("#s-pool h2")?.textContent ?? "", stop = [...document.querySelectorAll("#s-pool .slot")].find(e => e.textContent.includes("41c0e6"));
  return [h.join(";"), pool.replace(/burn.*/, "").split("free · ")[1]?.trim(), /fxa-sandbox-ctl stop agent-41c0e6/.test(stop?.textContent ?? ""), !!stop?.querySelector(".meter.none"), document.getElementById("n-runners").textContent].join("|")')"
rm -f "$R"
# #attn sandbox alerts (i376): runner faults with one stop rule, and feed text that never becomes markup.
ck "#attn: wrong base with its stop, goal rejected with its next step, idle warn, strays by the stop rule, escaped" "true|true|true|true|true|true|true|true" "$(bash "$p" '#overview' --fixture "$F" --width 1280 --probe '
  const x = "<img src=x onerror=alert(1)>";
  SNAP.inflight = [{ key: "FXA-41", summary: x }, { key: "FXA-42", summary: "g" }, { key: "FXA-45", summary: "i" }, { key: "FXA-46", summary: "n" }];
  AGENTS.runners = [{ key: "FXA-41", name: "fxa-auto-1", base_ok: false, agent_alive: true, stage: "watching", agent: {} },
    { key: "FXA-42", name: "fxa-auto-2", agent_alive: true, stage: "watching", agent: { num_turns: 0 } },
    { key: "FXA-45", name: "fxa-auto-5", agent_alive: true, stage: "watching", agent: { idle_seconds: 900, last_tool: x } },
    { key: "FXA-46", name: "x;rm -rf", base_ok: false, agent_alive: true, stage: "watching", agent: {} }];
  AGENTS.sessions = []; AGENTS.instances = [{ name: "agent-fxa-auto-9", state: "running", age_seconds: 600 }, { name: "agent-x;id", state: "running", age_seconds: 600 },
    { name: "gke-pool-1", state: "running", age_seconds: 600 }];
  renderAlerts(); const a = document.getElementById("attn"), h = a.innerHTML, row = k => [...a.querySelectorAll(".alert")].find(e => e.textContent.includes(k));
  return [/fxa-sandbox-ctl stop fxa-auto-1/.test(row("FXA-41")?.textContent), /shorten the ticket and requeue/.test(row("FXA-42")?.textContent),
    row("FXA-45")?.classList.contains("warn"), !/fxa-sandbox-ctl stop/.test(row("FXA-46")?.textContent ?? "x"), /stop fxa-auto-9/.test(row("agent-fxa-auto-9")?.textContent),
    !/stop/.test(row("agent-x;id")?.textContent ?? "x") && !/stop/.test(row("gke-pool-1")?.textContent ?? "x"), h.includes("&lt;img"), !h.includes("<img src=x")].join("|")')"
# Needs you (i378, i379): one number on the card, the rail badge and the tab title; a stray adds a sandbox
# part that moves the focus to #attn; a stale agents feed makes it unknown, never 0.
ck "Needs you: card, badge and title agree; a stray adds a sandbox part that focuses #attn; a stale feed gives ?" "true|true|true|1 sandbox alert|attn|?|true" "$(bash "$p" '#overview' --fixture "$F" --width 1280 --probe '
  const big = () => document.querySelector("#ov-mini .big").textContent, b = beltGroups().needs.length;
  const r1 = [big() === String(b), document.getElementById("n-overview").textContent === (b ? String(b) : document.querySelectorAll("#attn .alert").length ? "!" : ""), document.title.startsWith(b ? `(${b}) ` : "")];
  AGENTS.instances = [...(AGENTS.instances ?? []), { name: "agent-zz9", state: "running", age_seconds: 300 }]; render();
  const sb = [...document.querySelectorAll("#ov-mini .sub a")].find(a => a.hasAttribute("data-attn")); sb?.click();
  const r2 = [sb?.textContent, document.activeElement?.id];
  STATE.agents_age_seconds = 1200; STATE.agents_interval = 30; render();
  return [...r1, ...r2, big(), /unknown, agents feed/.test(document.querySelector("#ov-mini .sub").textContent)].join("|")')"
exit $fail
