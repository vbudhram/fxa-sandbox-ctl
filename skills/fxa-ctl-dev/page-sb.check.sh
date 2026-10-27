#!/usr/bin/env bash
# The Sandboxes cards, panel and Recently completed, and the chart colors (split from page.check.sh, so the check pool runs the page probes in parallel).
#   bash skills/fxa-ctl-dev/page-sb.check.sh
set -u
p="$(dirname "$0")/page.sh"; fail=0
bash "$p" '#teams' --probe 'return 1' >/dev/null 2>&1; [ $? = 3 ] && { echo "SKIP (no Chrome): the page probes did not run; set CHROME to run them"; exit 0; }
ck() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want [$2] got [$3]"; fail=1; fi; }
B="$(dirname "$0")/page-fixture-sandboxes.json"
O="$(dirname "$0")/page-fixture-overview.json"
# i407 sb-cards: the cards read the 7 day Stats rows and the agents feed, say what the host costs, and never show a 0 for an unknown feed.
C="$(dirname "$0")/page-fixture-sb-cards.json"
ck "i407 cards: 7 day runs and sessions, the cost lines, the host state from fc_state, a GCE session, and an unknown stats feed" "true|true|true|true|true|true|true|true|true|true|true" "$(bash "$p" '#runners' --fixture "$C" --width 1280 --probe '
  const now = Date.now() / 1000, iso = s => new Date((now - s) * 1000).toISOString(), n = document.getElementById("sb-cards");
  const rows = []; for (let i = 0; i < 41; i++) rows.push({ at: iso(3600 * (i + 1)), src: "pipeline", key: "EX-" + i, min: i ? 92 : 100, profile: "example" });
  const sl = (i, o) => Object.assign({ at: iso(3600 * (i + 1)), src: "slack", key: "agent-s" + i, profile: "example", backend: null, t0: null, end: null, boot_s: null }, o);
  for (let i = 0; i < 20; i++) rows.push(sl(i, i === 0 ? { boot_s: 30 } : i === 1 ? { boot_s: 41 } : i === 2 ? { boot_s: 60 } : {}));
  rows.push(sl(20, { backend: "firecracker", t0: now - 36000, end: now - 28800 }), sl(21, { backend: "firecracker", t0: now - 32400, end: now - 25200 }), sl(22, { backend: "gce", t0: now - 18000, end: now - 14400 }), { at: iso(9 * 86400), src: "pipeline", key: "EX-OLD", min: 500 });
  STATS.rows = rows; STATS.load = { cap: 4, days: [{ day: new Date().toISOString().slice(0, 10), peak: 3 }] }; STATS_ERR = null;
  const t = () => n.textContent.replace(/\s+/g, " "), hostKv = () => [...n.querySelectorAll(".kv")].some(k => /Firecracker/.test(k.textContent) && /always on|%/.test(k.textContent));
  renderSbCards(); const a = t(), noHostAlways = !hostKv() && !/%/.test(a);
  AGENTS.sessions[0].boot_backend = "firecracker"; renderSbCards(); const b = t();
  AGENTS.infra.fc_state = "none"; renderSbCards(); const c = t();
  AGENTS.sessions.push({ key: "agent-ex0002", state: "active", boot_backend: "gce", created: now - 60 }); renderSbCards(); const d = t(), gseg = !!n.querySelector(".sbstrip i.gce");
  STATS_ERR = "stats read failed"; renderSbCards(); const e = t();
  return [/7 days: 41 runs, 63 h/.test(a), /7 days: 23 sessions, peak 3 of 4 · boot median 41 s/.test(a), /Manager ?\$0\.21\/h · \$35 in 7 days, always on/.test(a), /Firecracker host ?stopped: it starts for the next session/.test(a),
    /Sessions used the host 3 h in 7 days/.test(a), /GCE sandboxes now ?\$0\.13\/h/.test(a), noHostAlways, /Firecracker host ?state unknown: the host did not answer/.test(b), !/Firecracker/.test(c),
    /2 of 4 busy/.test(d) && /1 on GCE/.test(d) && gseg, /7 days: unknown: Stats read failed/.test(e) && !/7 days: 0|used the host 0/.test(e)].join("|")')"
ck "i407 cards: an old agents feed gives ? on each card, not a 0" "3|false" "$(bash "$p" '#runners' --fixture "$C" --width 1280 --probe '
  const n = document.getElementById("sb-cards"); STATE.agents_age_seconds = 99999; renderSbCards();
  return [...n.querySelectorAll(".big")].filter(b => b.textContent === "?").length + "|" + /\b0 of|\$0\.00/.test(n.textContent)')"
ck "i407 cards review: the stats load repaints Sandboxes; an open row with no end adds no host hours; the strip label says free slots unknown; no peak is '?'; before the first stats poll it says Loading" "true|true|true|true|true" "$(bash "$p" '#runners' --fixture "$C" --width 1280 --probe '
  await new Promise(r => setTimeout(r, 400)); const n = document.getElementById("sb-cards"), t = () => n.textContent.replace(/\s+/g, " "), now = Date.now() / 1000;
  const loaded = /7 days: \d+ runs/.test(t());
  STATS.rows = [{ at: new Date((now - 3600) * 1000).toISOString(), src: "slack", key: "agent-s1", backend: "firecracker", t0: now - 3 * 86400, end: null, live: false }]; STATS_ERR = null; STATE.stats_age_seconds = 1; renderSbCards();
  const noOpen = !/Sessions used the host [1-9]/.test(t());
  AGENTS.free_slots = null; renderSbCards(); const aria = /free slots unknown/.test(n.querySelector(".sbstrip")?.getAttribute("aria-label") || "");
  AGENTS.free_slots = []; STATS.load = undefined; renderSbCards(); const pk = /peak \? of/.test(t()) && !/peak (0|NaN)/.test(t());
  STATS = null; STATS_ERR = null; renderSbCards(); const ld = /7 days: Loading the stats…/.test(t()) && !/could not be read/.test(t());
  return [loaded, noOpen, aria, pk, ld].join("|")')"
# Sandboxes panel (i407 sb-panel): a selected row opens the panel; when a poll drops it, the selection clears, the drawer closes
# and the focus goes to the list. sbRows() is stubbed here until sb-list-fixes builds it.
SP="$(dirname "$0")/page-fixture-sb-panel.json"
ck "sb-panel: a fix row opens with its command; when the row leaves, SEL.runners clears, showright is off, the focus is in #sb-list" "true|true|true|true" "$(bash "$p" '#runners' --fixture "$SP" --width 1200 --probe '
  const rows = { live: [], fix: [{ id: "fix:agent-def456", src: "slack", key: "agent-def456", fix: { why: "The runner is still up 10 min after its session stopped.", cmd: "fxa-sandbox-ctl stop agent-def456", steps: null } }] };
  window.sbRows = () => rows; window.sbTabHas = () => true;
  if (!document.getElementById("sb-list")) { const d = document.createElement("div"); d.id = "sb-list"; document.querySelector("main").appendChild(d); }
  SEL.runners = "fix:agent-def456"; document.body.classList.add("showright"); renderRight();
  const open = document.getElementById("right").innerHTML.includes("<code>fxa-sandbox-ctl stop agent-def456</code>");
  document.getElementById("rclose")?.focus(); rows.fix = []; renderRight();
  return [open, SEL.runners === undefined, !document.body.classList.contains("showright"), document.getElementById("sb-list").contains(document.activeElement)].join("|")')"
D="$(dirname "$0")/page-fixture-sb-done.json"
ck "Sandboxes Recently completed: ended runs newest first, the PR link, and a phone-width table scrolls in its own box" "agent-sl0001,EX-1|true|true|true" "$(bash "$p" '#runners' --fixture "$D" --width 500 --probe '
  let s = document.getElementById("s-sb"); if (!s) { s = document.createElement("section"); s.id = "s-sb"; s.className = "wide"; document.getElementById("main").append(s); }
  let d = document.getElementById("sb-done"); if (!d) { d = document.createElement("div"); d.id = "sb-done"; d.className = "sb-done"; s.append(d); }
  d.style.width = "360px"; await loadSbDone();
  const box = d.querySelector(".sbd-scroll");
  return [[...d.querySelectorAll("[data-sbdone]")].map(x => x.dataset.sbdone).join(","), !!d.querySelector("a[href=\"https://github.com/example/repo/pull/41\"]"),
    !!box && box.scrollWidth > box.clientWidth && getComputedStyle(box).overflowX === "auto", document.documentElement.scrollWidth <= innerWidth].join("|")')"
ck "Sandboxes review: at 1440 px a long For title ends in an ellipsis and every column, the Result too, fits without a side scroll" "true|true" "$(bash "$p" '#runners' --fixture "$D" --width 1440 --probe '
  await loadSbDone(); SB_DONE.runs[0].title = "A very long sample request that keeps going and going so that it would push every later column of the table off to the right side"; renderSbDone();
  const box = document.querySelector("#sb-done .sbd-scroll"), res = document.querySelector("#sb-done tbody tr td:last-child");
  return [box.scrollWidth <= box.clientWidth, res.getBoundingClientRect().right <= box.getBoundingClientRect().right + 1].join("|")')"
ck "Overview review: a routine run the server gated (no key, team or cost) still renders in Recent runs" "true|false" "$(bash "$p" '#overview' --fixture "$O" --width 1280 --probe '
  RUNS = [{ at: new Date().toISOString(), src: "slack", kind: "session", key: "", title: "Scheduled run", team: "", outcome: "answered", pr_url: null, pr_number: null, pr_state: null, usd: null, min: null, routine: true }]; RUNS_ERR = null;
  safeRender(renderOvRuns, "ov-runs"); const t = document.getElementById("ov-runs").textContent;
  return [/Scheduled run/.test(t), /undefined|NaN|\$0\.00|did not render/.test(t)].join("|")')"
ck "only the short GCE states count as moving, and a moving instance with no age and no run is unknown, not hidden" "false|true|stopping|true" "$(bash "$p" '#runners' --fixture "$B" --width 1280 --probe '
  const m = [instMoving({ state: "stopped" }), instMoving({ state: "suspending" }), movingWord({ state: "suspending" })];
  AGENTS.instances = [...(AGENTS.instances ?? []), { name: "agent-agent-nn0001", state: "staging", age_seconds: null }];
  const r = sbRows(); return [...m, r.unknown.some(x => x.slot === "agent-agent-nn0001")].join("|")')"
w=""; for v in '#overview' '#runners' '#pipeline' '#stats' '#teams' '#sessions'; do w="$w$(bash "$p" "$v" --fixture "$O" --width 1440 --probe 'return document.documentElement.scrollWidth <= innerWidth')"; done
ck "no view scrolls sideways at 1440 px: a hidden right panel takes no width" "truetruetruetruetruetrue" "$w"
# WCAG 1.4.11: a chart series needs 3:1 against the card, in both themes.
cc='const v = n => getComputedStyle(document.documentElement).getPropertyValue(n).trim(), L = h => { const c = [1, 3, 5].map(i => parseInt(h.slice(i, i + 2), 16) / 255).map(x => x <= 0.03928 ? x / 12.92 : ((x + 0.055) / 1.055) ** 2.4); return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]; };
  const cr = (a, b) => { const [x, y] = [L(a), L(b)].sort((p, q) => q - p); return (x + 0.05) / (y + 0.05); };
  return ["light", "dark"].map(t => { document.documentElement.dataset.theme = t; return [1, 2, 3, 4].filter(i => cr(v(`--chart-${i}`), v("--panel")) < 3).join(",") || "ok"; }).join("|")'
ck "every chart series token reaches 3:1 on the panel, light and dark" "ok|ok" "$(bash "$p" '#overview' --fixture "$O" --width 1280 --probe "$cc")"
exit $fail
