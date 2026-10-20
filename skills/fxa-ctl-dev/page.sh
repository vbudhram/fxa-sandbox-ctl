#!/usr/bin/env bash
# Render the dashboard in headless Chrome with fetch stubbed from a fixture, for UI checks with no server.
#   bash skills/fxa-ctl-dev/page.sh '#teams/example' [--fixture f.json] [--probe 'async js'] [--shot out.png] [--width 1280] [--height 900]
# --probe is the body of an async function, run after the page settles; what it returns is printed.
# PAGE_BUDGET: Chrome's virtual time budget in ms (default 6000), for a probe that waits through several poll intervals.
# Headless Chrome keeps the window at least 500 px wide: a narrower --width renders at 500. Test a phone
# layout by the element's own width (a container query), not by --width under 500.
# --shot writes a screenshot. With neither, it prints the rendered DOM.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"; page="$here/../../dashboard/index.html"
hash="${1:?usage: page.sh <#route> [--fixture f] [--probe js] [--shot png] [--width n]}"; shift
fixture="$here/page-fixture.json" probe="" shot="" width=1280 height=900
while [ $# -gt 0 ]; do
  case "$1" in --fixture) fixture="$2" ;; --probe) probe="$2" ;; --shot) shot="$2" ;; --width) width="$2" ;; --height) height="$2" ;;
    *) echo "page.sh: unknown option $1" >&2; exit 2 ;; esac; shift 2
done
chrome="${CHROME:-}"
for c in "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" google-chrome chromium chromium-browser; do
  [ -n "$chrome" ] && break; { [ -x "$c" ] || command -v "$c" >/dev/null 2>&1; } && chrome="$c"
done
[ -n "$chrome" ] || { echo "skip: no Chrome (set CHROME)"; exit 3; }
dir="$(mktemp -d "${TMPDIR:-/tmp}/fxa-page.XXXXXX")"; trap 'rm -rf "$dir"' EXIT
python3 - "$page" "$fixture" "$probe" "$dir/p.html" <<'PY'
import json, sys
page, fixture, probe, out = sys.argv[1:]
fx = json.load(open(fixture))
# Times relative to the run: "@iso-3600" is an ISO time an hour ago, "@epoch+600" an epoch 10 min ahead.
import re, time, datetime
def rel(v):
    if isinstance(v, dict): return {k: rel(x) for k, x in v.items()}
    if isinstance(v, list): return [rel(x) for x in v]
    m = re.fullmatch(r"@(iso|epoch)([+-]\d+)", v) if isinstance(v, str) else None
    if not m: return v
    t = time.time() + int(m.group(2))
    return int(t) if m.group(1) == "epoch" else datetime.datetime.fromtimestamp(t, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
fx = rel(fx)
# The longest fixture key that the URL path starts with wins; a miss answers [] for a list-like path, else {}.
stub = """<script>const __F=%s;window.fetch=async(u)=>{const p=new URL(String(u),location.href).pathname;
const k=Object.keys(__F).filter(k=>p===k||p.startsWith(k+"/")).sort((a,b)=>b.length-a.length)[0];
const body=k?__F[k]:(/sessions/.test(p)?{sessions:[],cursor:null}:/routines|errors|lessons/.test(p)?[]:{});
return {ok:true,status:200,json:async()=>body,text:async()=>JSON.stringify(body)};};</script>""" % json.dumps(fx)
html = open(page).read().replace("<head>", "<head>" + stub, 1)
if probe:
    html += """<script>setTimeout(async()=>{let t;try{t=String(await (async()=>{%s})())}catch(e){t="ERR "+e.message}
const d=document.createElement("pre");d.id="__probe";d.textContent=t;document.body.appendChild(d);},2500)</script>""" % probe
open(out, "w").write(html)
PY
args=(--headless=new --disable-gpu --no-sandbox --virtual-time-budget=${PAGE_BUDGET:-6000} "--window-size=${width},${height}")
if [ -n "$shot" ]; then "$chrome" "${args[@]}" --screenshot="$shot" "file://$dir/p.html$hash" >/dev/null 2>&1; echo "$shot"
else
  dom="$("$chrome" "${args[@]}" --dump-dom "file://$dir/p.html$hash" 2>/dev/null)"
  if [ -n "$probe" ]; then python3 -c 'import html,re,sys; m=re.search(r"<pre id=\"__probe\">(.*?)</pre>", sys.stdin.read(), re.S); print(html.unescape(m.group(1)) if m else "no probe result")' <<< "$dom"
  else printf '%s\n' "$dom"; fi
fi
