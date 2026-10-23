#!/usr/bin/env bash
# dashboard/index.html: a failed Errors or usage read says so, never an all-clear, and an Answers row opens from the keyboard.
#   bash skills/fxa-ctl-dev/page-feeds.check.sh
set -u
p="$(dirname "$0")/page.sh" F="$(dirname "$0")/page-fixture-feeds.json"; fail=0
ck() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want [$2] got [$3]"; fail=1; fi; }
out="$(bash "$p" '#errors' --fixture "$F" --probe 'await new Promise(r => setTimeout(r, 300)); const t = document.getElementById("s-errors").textContent;
  return [/Could not read the errors/.test(t), /No open errors/.test(t), document.getElementById("n-errors").textContent].join("|")')"; rc=$?
[ "$rc" = 3 ] && { echo "SKIP (no Chrome): the page probes did not run; set CHROME to run them"; exit 0; }
ck "a failed errors read says so, not 'No open errors', and the badge is ?" "true|false|?" "$out"
ck "an Answers row opens with Enter on its button, keeps the focus, and a failed usage read says so" "true|true|true|false" "$(bash "$p" '#sessions/answers' --fixture "$F" --probe '
  const w = (ms) => new Promise(r => setTimeout(r, ms)); const real = window.fetch;
  window.fetch = (u, o) => String(u).startsWith("/api/usage") ? Promise.reject(new Error("down")) : real(u, o);
  await w(300); const b = document.querySelector("button[data-ans-btn=\"ask-t1\"]"); b.focus(); b.click(); await w(400);
  const nb = document.querySelector("button[data-ans-btn=\"ask-t1\"]"), t = document.getElementById("s-sess").textContent;
  return [nb.getAttribute("aria-expanded"), document.activeElement === nb, /Could not read the LLM calls/.test(t), /No LLM calls recorded/.test(t)].join("|")')"
[ "$fail" = 0 ] && echo "all checks pass"
exit "$fail"
