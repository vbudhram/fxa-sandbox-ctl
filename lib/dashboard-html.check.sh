#!/usr/bin/env bash
# Offline check of the dashboard's component helpers: html`` escapes every value, and tag, dot, meter and card build the design system's markup.
#   bash lib/dashboard-html.check.sh
set -u
command -v node >/dev/null || { echo "skip: needs node"; exit 0; }
page="$(dirname "$0")/../dashboard/index.html"
fns="$(sed -n '/^const esc = /p; /^\/\/ Components:/,/^\/\/ End components\./p' "$page")"
# The style block: a rule cut in half leaves its tail outside any rule, and the browser then drops the next rule.
stray="$(sed -n '/<style>/,/<\/style>/p' "$page" | awk '{ if (d == 0 && $0 ~ /^[[:space:]]+[a-z-]+:[^{]*;/) print NR": "$0; o = gsub(/\{/, "{"); c = gsub(/\}/, "}"); d += o - c; if (d < 0) { print NR": a } with no rule open"; d = 0 } }')"
if [ -z "$stray" ]; then echo "ok   style: no CSS fragment outside a rule"; else echo "FAIL style: no CSS fragment outside a rule: want [] got [$(head -2 <<< "$stray" | cut -c1-120 | tr '\n' ' ')]"; css_fail=1; fi
node - "$fns" <<'JS'
process.argv.splice(1, 1);
eval(process.argv[1].replace(/^(let|const|class) (\w+)/gm, (m, k, n) => k === "class" ? `var ${n} = class ${n}` : `var ${n}`));
let fail = 0;
const t = (name, got, want) => { got = String(got); if (got === want) console.log("ok   " + name); else { console.log(`FAIL ${name}: want [${want}] got [${got}]`); fail = 1; } };
const bad = '<img src=x onerror="a()">';
t("html escapes a value", html`<b>${bad}</b>`, "<b>&lt;img src=x onerror=&quot;a()&quot;&gt;</b>");
t("html keeps a nested html result", html`<p>${html`<i>${"a&b"}</i>`}</p>`, "<p><i>a&amp;b</i></p>");
t("html joins an array and escapes each item", html`${["<a>", html`<b></b>`]}`, "&lt;a&gt;<b></b>");
t("html drops null, undefined and false, keeps 0", html`${null}${undefined}${false}${0}`, "0");
t("an html result is a string inside a plain template", `x${html`<i></i>`}`, "x<i></i>");
t("tag: tone and flags, text escaped", tag("<b>", "info", { run: true, live: true }), '<span class="tag info run live">&lt;b&gt;</span>');
t("tag: no tone", tag("Queued"), '<span class="tag">Queued</span>');
t("tag: a link escapes its href", tag("PR", "ok", { href: 'x" onclick="y' }), '<a class="tag ok" href="x&quot; onclick=&quot;y" target="_blank" rel="noreferrer">PR</a>');
t("dot", dot("info", true), '<span class="dot info live" aria-hidden="true"></span>');
t("meter: clamps and labels", meter(140, "bad", "140% of the budget"), '<span class="meter" role="img" aria-label="140% of the budget"><i class="bad" style="width:100%"></i></span>');
t("meter: a bad number is 0", meter(NaN), '<span class="meter" aria-hidden="true"><i style="width:0%"></i></span>');
t("card: body is HTML, sizes and tone", card(html`<h3>${"<x>"}</h3>`, { sm: true, flat: true, tone: "bad" }), '<div class="card sm flat bad"><h3>&lt;x&gt;</h3></div>');
t("card: a plain string body is HTML too (the page's older templates)", card("<b>1</b>"), '<div class="card"><b>1</b></div>');
t("kvRow: text escaped, na", kvRow("PR", "<none>", true), '<div class="kv"><span>PR</span><b class="na">&lt;none&gt;</b></div>');
t("table: head with a num column, rows as HTML", table(["Ticket", ["Cost", "num"]], [html`<tr><td>${"<a>"}</td><td class="num">1</td></tr>`], { figures: true }),
  '<table class="table figures"><thead><tr><th>Ticket</th><th class="num">Cost</th></tr></thead><tbody><tr><td>&lt;a&gt;</td><td class="num">1</td></tr></tbody></table>');
t("emptybox escapes", emptybox("No <runs>"), '<div class="emptybox">No &lt;runs&gt;</div>');
process.exit(fail);
JS
rc=$?; [ "${css_fail:-0}" = 0 ] || rc=1
# The Board's refused_ship step names the tooling approver and the saved change.
step='refused_ship: "An approver adds ai-fixme-allow-tooling. The ticket'"'"'s 🤖 comment says if the next pass ships the saved change or a requeue is needed. For other paths, a human relaunches with FXA_ALLOW_TOOLING_EDITS=1.",'
got="$(grep -cF "$step" "$page")|$(grep -c 'refused_ship: "a tooling approver"' "$page")|$(grep -c 'refused_ship: "a reviewer"' "$page")"
if [ "$got" = "1|1|0" ]; then echo "ok   Board: the refused_ship step and who acts"; else echo "FAIL Board: the refused_ship step and who acts: want [1|1|0] got [$got]"; rc=1; fi
# The Belt's first line for a run, from the page's own expression.
l1="$(sed -n '/^    const l1 = t.stage === "starting"/,/plainMd(a.last_tool/p' "$page")"
node - "$l1" <<'JS' || rc=1
const src = process.argv[2], plainMd = s => s, a = {};
const l1 = t => eval(src.replace(/^\s*const l1 = /, "").replace(/;\s*$/, ""));
let fail = 0;
const t = (name, got, want) => { if (got === want) console.log("ok   " + name); else { console.log(`FAIL ${name}: want [${want}] got [${got}]`); fail = 1; } };
t("Belt: a starting run with detail reship says Shipping saved change", l1({ stage: "starting", detail: "reship" }), "Shipping saved change");
t("Belt: with the scope on the progress line too (snapshot's detail)", l1({ stage: "starting", detail: "reship tooling=scripts" }), "Shipping saved change");
t("Belt: another boot step keeps Boot:", l1({ stage: "starting", detail: "checkout" }), "Boot: checkout");
process.exit(fail);
JS
# A reship from the feeds: an inflight row with no runner gets a Belt row, not a "no sandbox" fault.
fns="$(sed -n '/^function merged() {/,/^}/p; /^function laneRows() {/,/^}/p' "$page")"
node - "$fns" <<'JS' || rc=1
process.argv.splice(1, 1);
var SNAP = { inflight: [{ key: "FXA-1", stage: "starting", detail: "reship tooling=scripts", elapsed_seconds: 60 }], review: [], blocked: [], open_prs: [] }, AGENTS = { runners: [], sessions: [] };
eval(process.argv[1]);
const m = merged(), row = laneRows().find(r => r.t.key === "FXA-1");
const got = `${m.waiting.length}|${m.cards.filter(c => c.reship).length}|${row?.l1}`, want = "0|1|Shipping saved change";
if (got === want) console.log("ok   Belt: a reship with no runner is a card that says Shipping saved change, not a waiting fault");
else { console.log(`FAIL Belt: a reship with no runner: want [${want}] got [${got}]`); process.exit(1); }
JS
exit "$rc"
