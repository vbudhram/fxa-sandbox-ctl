#!/usr/bin/env bash
# dashboard/index.html: the page frame keeps the keyboard focus on the List and Details buttons, returns it on
# Escape, and names the theme button as the theme, on a phone too.
#   bash skills/fxa-ctl-dev/page-frame.check.sh
set -u
p="$(dirname "$0")/page.sh"; fail=0
ck() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want [$2] got [$3]"; fail=1; fi; }
w='await new Promise(r => setTimeout(r, 700)); const t = ms => new Promise(r => setTimeout(r, ms)); const id = () => document.activeElement.id || document.activeElement.tagName;'
out="$(bash "$p" '#errors' --probe "$w"' const o = []; for (const s of ["tside", "tright"]) { const b = document.getElementById(s); b.focus(); b.click(); await t(100); o.push(id()); } return o.join(",")')"; rc=$?
[ "$rc" = 3 ] && { echo "SKIP (no Chrome): the page probes did not run; set CHROME to run them"; exit 0; }
ck "List and Details keep the focus on the button pressed" "tside,tright" "$out"
ck "at a narrow width, List opens the list on its search box, and Escape returns the focus to List" "q|tside" \
  "$(bash "$p" '#errors' --width 500 --probe "$w"' const b = document.getElementById("tside"); b.focus(); b.click(); await t(100); const a = id();
    document.activeElement.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true })); await t(100); return a + "|" + id()')"
ck "the theme button is named as the theme; the help button as shortcuts" "Theme: System|Shortcuts" \
  "$(bash "$p" '#errors' --probe "$w"' return document.getElementById("theme").getAttribute("aria-label") + "|" + document.getElementById("helpbtn").textContent.trim()')"
ck "a phone keeps the theme button" "true" \
  "$(bash "$p" '#errors' --width 500 --probe "$w"' const r = document.getElementById("theme").getBoundingClientRect(); return r.width > 0 && r.bottom <= innerHeight')"
exit "$fail"
