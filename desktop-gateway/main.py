"""Relay a session's Linux desktop to its owner, and the dashboard, behind IAP.

IAP signs in the person and signs each request with their email. The gateway
checks that signature. /d/<key> reads the session's record from GCS (owner,
runner IP, VNC password) and relays noVNC's pages and WebSocket to the runner.
/w/<thread> shows what the agent in a Slack thread is doing, read-only, to anyone IAP lets in.
Every other path goes to the manager VM's dashboard (MANAGER_URL).
"""
import asyncio
import html
import json
import os
import re
import time

import aiohttp
import google.auth
from aiohttp import web
from google.auth import jwt
from google.auth.transport.requests import Request

AUDIENCE = os.environ["IAP_AUDIENCE"]
BUCKET = os.environ["DESKTOP_BUCKET"]
KEY = re.compile(r"agent-[a-z0-9]{4,12}")
THREAD = re.compile(r"[A-Z0-9]+:\d+\.\d+")
IAP_KEYS_URL = "https://www.gstatic.com/iap/verify/public_key"
NOVNC_PORT = 6080
MANAGER_URL = os.environ.get("MANAGER_URL", "").rstrip("/")
# Empty: anyone IAP lets in may see the dashboard. Else only these emails.
DASHBOARD_USERS = {e.strip().lower() for e in os.environ.get("DASHBOARD_USERS", "").split(",") if e.strip()}

_certs = {"at": 0.0, "keys": {}}
_records = {}  # key -> (fetched at, record or None)
_creds, _ = google.auth.default(scopes=["https://www.googleapis.com/auth/devstorage.read_only"])


async def iap_email(request):
    """The signed-in email IAP vouches for, or None."""
    token = request.headers.get("x-goog-iap-jwt-assertion", "")
    if not token:
        return None
    try:
        kid = jwt.decode_header(token).get("kid")
    except Exception:
        return None
    age = time.time() - _certs["at"]
    # IAP rotates its keys: a new kid fetches them again, at most once a minute.
    if age > 3600 or (kid not in _certs["keys"] and age > 60):
        try:
            async with request.app["http"].get(IAP_KEYS_URL) as r:
                r.raise_for_status()
                _certs.update(at=time.time(), keys=await r.json())
        except Exception as exc:
            print(f"iap keys fetch failed: {type(exc).__name__}: {exc}", flush=True)
            _certs["at"] = max(_certs["at"], time.time() - 3540)  # try again in a minute, not on every request
    try:
        claims = jwt.decode(token, certs=_certs["keys"], audience=AUDIENCE)
    except Exception as exc:
        # The audience format differs between IAP front ends; say what came in.
        unverified = jwt.decode(token, verify=False) if token.count(".") == 2 else {}
        print(f"iap token rejected: {type(exc).__name__}: {exc}; aud={unverified.get('aud')}", flush=True)
        return None
    if claims.get("iss") != "https://cloud.google.com/iap":
        return None
    return (claims.get("email") or "").lower() or None


async def record(app, key):
    """The session's desktop record from GCS; cached briefly so a page load is one read."""
    at, rec = _records.get(key, (0.0, None))
    if time.time() - at < 10:
        return rec
    if not _creds.valid:
        await asyncio.to_thread(_creds.refresh, Request())
    url = f"https://storage.googleapis.com/storage/v1/b/{BUCKET}/o/desktops%2F{key}.json?alt=media"
    async with app["http"].get(url, headers={"Authorization": f"Bearer {_creds.token}"}) as r:
        # Only a 404 means no desktop; any other error must not look like one.
        if r.status not in (200, 404):
            print(f"desktop record {key}: GCS status {r.status}", flush=True)
            raise error(web.HTTPServiceUnavailable, "Could not look up the desktop. Try again in a moment.")
        rec = json.loads(await r.text()) if r.status == 200 else None
    _records[key] = (time.time(), rec)
    return rec


def error(cls, message, extra=""):
    """An HTTP error as a small page that reads well on a phone."""
    return cls(content_type="text/html", text=(
        '<!doctype html><meta name="viewport" content="width=device-width"><title>FxA desktop</title>'
        '<body style="font:18px/1.5 system-ui,sans-serif;max-width:36em;margin:2em auto;padding:0 1em">'
        f"<p>{message}</p>{extra}"))


async def authorize(request):
    key = request.match_info["key"]
    if not KEY.fullmatch(key):
        raise web.HTTPNotFound()
    email = await iap_email(request)
    if not email:
        raise error(web.HTTPForbidden, "Not signed in through IAP.")
    rec = await record(request.app, key)
    if not rec or rec.get("expires", 0) < time.time():
        raise error(web.HTTPNotFound, "This session has no open desktop. It may have ended; ask for a new link with !desktop.")
    if email != (rec.get("owner_email") or "").lower():
        print(f"refused {email} for {key}", flush=True)
        raise error(web.HTTPForbidden, f"You are signed in as {html.escape(email)}. This desktop belongs to the person who typed !desktop.",
                    '<p><a href="?gcp-iap-mode=CLEAR_LOGIN_COOKIE">Use another account</a></p>')
    return key, rec, email


async def start(request):
    key, rec, _ = await authorize(request)
    # The VNC password goes in the fragment, which the browser never sends back.
    raise web.HTTPFound(f"/d/{key}/fxa.html#password={rec['vnc_password']}")


async def page(request):
    key, rec, email = await authorize(request)
    tail = request.match_info["tail"]
    if tail == "websockify":
        return await relay(request, rec, key, email)
    url = f"http://{rec['ip']}:{NOVNC_PORT}/{tail}"
    try:
        async with request.app["http"].get(url, params=request.query) as r:
            body = await r.read()
    except (aiohttp.ClientError, asyncio.TimeoutError):
        raise error(web.HTTPBadGateway, "The desktop is not answering. The session may be paused: reply in the Slack thread, then type !desktop there for a new link.")
    # noVNC's core files do not change under one /d/<key>/; only our page does.
    cache = "private, max-age=86400" if r.status == 200 and r.content_type != "text/html" else "no-store"
    resp = web.Response(status=r.status, body=body, content_type=r.content_type,
                        headers={"Cache-Control": cache, "X-Content-Type-Options": "nosniff"})
    resp.enable_compression()
    return resp


async def relay(request, rec, key, email):
    # VNC data is already zlib or JPEG; deflate again costs CPU for nothing.
    ws = web.WebSocketResponse(protocols=("binary",), heartbeat=30, compress=False)
    await ws.prepare(request)
    began, why = time.time(), "closed"
    print(f"desktop open {key} {email}", flush=True)
    try:
        async with request.app["http"].ws_connect(f"ws://{rec['ip']}:{NOVNC_PORT}/websockify", protocols=("binary",)) as up:
            async def pump(src, dst):
                async for msg in src:
                    if msg.type == aiohttp.WSMsgType.BINARY:
                        await dst.send_bytes(msg.data)
                    elif msg.type == aiohttp.WSMsgType.TEXT:
                        await dst.send_str(msg.data)
                    else:
                        break
                await dst.close()
            await asyncio.gather(pump(ws, up), pump(up, ws), return_exceptions=True)
    except (aiohttp.ClientError, asyncio.TimeoutError) as exc:
        why = f"runner unreachable: {type(exc).__name__}"
        await ws.close()
    finally:
        print(f"desktop close {key} {email} after {time.time() - began:.0f}s code={ws.close_code} {why}", flush=True)
    return ws


async def dashboard(request):
    if not MANAGER_URL:
        raise web.HTTPNotFound()
    email = await iap_email(request)
    if not email or (DASHBOARD_USERS and email not in DASHBOARD_USERS):
        raise web.HTTPForbidden(text="Not allowed to see the dashboard.")
    # The dashboard accepts only loopback Host names; the gateway is its proxy.
    # A browser's cross-site signals pass through, so its CSRF check still works;
    # only the gateway's own origin is dropped, because it is same-site here.
    headers = {"Host": "localhost"}
    for h in ("Sec-Fetch-Site", "Content-Type"):
        if h in request.headers:
            headers[h] = request.headers[h]
    origin = request.headers.get("Origin")
    if origin and origin.split("//", 1)[-1] != request.host:
        headers["Origin"] = origin
    body = await request.read() if request.method == "POST" else None
    async with request.app["http"].request(request.method, f"{MANAGER_URL}{request.path_qs}", headers=headers, data=body) as r:
        keep = {k: v for k, v in r.headers.items() if k.lower() in ("content-type", "content-security-policy", "cache-control", "x-content-type-options", "referrer-policy")}
        return web.Response(status=r.status, body=await r.read(), headers=keep)


WATCH_PAGE = r"""<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>fxa-agent</title>
<style>
:root { --bg:#141414; --fg:#e6e6e6; --dim:#8b8b8b; --line:#2a2a2a; --ok:#4eba65; --err:#ff6b80; --run:#b1b9f9; --brand:#d77757; --add:#22381f; --del:#3d1f24; }
* { box-sizing:border-box; }
html, body { margin:0; background:var(--bg); color:var(--fg); }
body { font:13px/1.5 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace; }
header { position:sticky; top:0; z-index:1; background:var(--bg); border-bottom:1px solid var(--line); padding:8px 16px; display:flex; gap:10px; flex-wrap:wrap; color:var(--dim); }
header b { color:var(--brand); font-weight:600; }
#log { padding:12px 16px 64px; }
.row { display:flex; gap:8px; margin-top:10px; white-space:pre-wrap; overflow-wrap:anywhere; }
.row > .dot { flex:none; width:1ch; }
.row > .body { min-width:0; flex:1; }
.tool .name { font-weight:600; }
.tool .dot { color:var(--dim); } .tool.run .dot { color:var(--run); animation:blink 1s steps(2) infinite; }
.tool.ok .dot { color:var(--ok); } .tool.err .dot { color:var(--err); }
.out { color:var(--dim); white-space:pre-wrap; overflow-wrap:anywhere; margin-left:2ch; }
.out::before { content:"⎿  "; }
.err .out { color:var(--err); }
.diff { margin:4px 0 0 4ch; white-space:pre-wrap; overflow-wrap:anywhere; }
.diff .a { background:var(--add); } .diff .d { background:var(--del); } .diff .m { color:var(--dim); }
.sub { margin-left:4ch; opacity:.75; }
.todos { margin-left:2ch; color:var(--dim); } .todos .in_progress { color:var(--fg); font-weight:600; } .todos .completed { text-decoration:line-through; }
.msg.live .body::after { content:"▋"; color:var(--brand); animation:blink 1s steps(2) infinite; }
.end { color:var(--dim); margin-top:10px; }
footer { position:fixed; left:0; right:0; bottom:0; background:var(--bg); border-top:1px solid var(--line); padding:8px 16px; color:var(--brand); }
footer span { color:var(--dim); }
@keyframes blink { 50% { opacity:0; } }
</style>
<header><b>fxa-agent</b><span id="who">connecting…</span></header>
<div id="log"></div>
<footer id="st">✻ connecting…</footer>
<script>
const log = document.getElementById("log"), who = document.getElementById("who"), st = document.getElementById("st");
let tools = {}, live = null, key = "", state = "", model = "", last = Date.now(), status = "", es = null;
const SPIN = "·✢✳✶✻✽";
function el(cls, text) { const d = document.createElement("div"); d.className = cls; if (text != null) d.textContent = text; return d; }
function row(cls, dot, body) { const r = el("row " + cls); r.append(el("dot", dot)); const b = el("body"); if (body != null) b.append(body); r.append(b); return r; }
function add(node, sub) {
  if (sub) node.classList.add("sub");
  const stick = innerHeight + scrollY >= document.body.scrollHeight - 80;
  log.append(node); if (stick) scrollTo(0, document.body.scrollHeight);
}
function out(text, more) { return el("out", (text || "(no output)") + (more ? `\n… +${more} lines` : "")); }
function secs(s) { return s >= 60 ? `${Math.floor(s / 60)}m ${s % 60}s` : `${s}s`; }
function on(e) {
  last = Date.now();
  if (e.t === "init") { model = e.model || ""; head(); }
  else if (e.t === "thinking") status = "Thinking…";
  else if (e.t === "text_start") { live = row("msg live", "⏺", ""); add(live); status = "Writing…"; }
  else if (e.t === "delta") { if (!live) { live = row("msg live", "⏺", ""); add(live); } live.lastChild.textContent += e.text; }
  else if (e.t === "text") {
    if (live && !e.sub) { live.lastChild.textContent = e.text; live.classList.remove("live"); live = null; }
    else add(row("msg", "⏺", e.text), e.sub);
  }
  else if (e.t === "tool") {
    const b = document.createDocumentFragment(), n = el("name", e.name); b.append(n, `(${e.arg})`);
    const r = row("tool run", "⏺", b);
    if (e.diff) { const d = el("diff"); for (const l of e.diff) d.append(el(l[0] === "+" ? "a" : l[0] === "-" ? "d" : "m", l)); r.lastChild.append(d); }
    tools[e.id] = r; add(r, e.sub); status = `${e.name}…`;
  }
  else if (e.t === "done") {
    const r = tools[e.id];
    if (r) { r.classList.remove("run"); r.classList.add(e.ok ? "ok" : "err"); r.lastChild.append(out(e.out, e.more)); }
    else add(out(e.out, e.more), e.sub);
    status = "Working…";
  }
  else if (e.t === "todos") {
    const t = el("todos");
    for (const i of e.items) t.append(el(i.status, (i.status === "completed" ? "☒ " : i.status === "in_progress" ? "◼ " : "☐ ") + i.content));
    add(row("tool ok", "⏺", "Update Todos"), e.sub); add(t, e.sub);
  }
  else if (e.t === "turn_end") {
    add(el("end", `✻ Turn ${e.error ? "ended with an error" : "done"} in ${secs(e.secs)}` + (e.cost != null ? ` · $${e.cost.toFixed(2)}` : "")));
    status = "idle"; live = null;
  }
}
function head() { who.textContent = [key, state, model].filter(Boolean).join(" · "); }
function connect() {
  es = new EventSource(location.pathname.replace(/\/$/, "") + "/events");
  es.addEventListener("session", (m) => {
    const s = JSON.parse(m.data); key = s.key; state = s.state; head();
    log.textContent = ""; tools = {}; live = null; status = state === "active" || state === "starting" ? "Working…" : "";
  });
  es.onmessage = (m) => { try { on(JSON.parse(m.data)); } catch {} };
  es.addEventListener("end", () => { es.close(); if (status !== "idle") status = "ended"; setTimeout(connect, 10000); });
}
setInterval(() => {
  const ago = Math.round((Date.now() - last) / 1000), running = state === "active" || state === "starting";
  if (!key) st.textContent = "✻ connecting…";
  else if (!running) st.innerHTML = `<span>The session is ${state}. Reply in the Slack thread to pick it up; this page follows.</span>`;
  else if (status === "idle") st.innerHTML = "<span>Waiting for a reply in the Slack thread.</span>";
  else if (status === "ended") st.innerHTML = "<span>Reconnecting…</span>";
  else { st.textContent = `${SPIN[Math.floor(Date.now() / 150) % SPIN.length]} ${status} `; const sp = document.createElement("span"); sp.textContent = `(${ago}s since the last event)`; st.append(sp); }
}, 150);
connect();
</script>"""


async def watch(request):
    thread = request.match_info["thread"]
    if not THREAD.fullmatch(thread):
        raise web.HTTPNotFound()
    if not await iap_email(request):
        raise error(web.HTTPForbidden, "Not signed in through IAP.")
    if not request.match_info.get("events"):
        return web.Response(text=WATCH_PAGE, content_type="text/html", headers={"Cache-Control": "no-store"})
    if not MANAGER_URL:
        raise web.HTTPNotFound()
    # The dashboard's server-sent events, passed on as they come.
    async with request.app["http"].get(f"{MANAGER_URL}/api/watch/events", params={"thread": thread}, headers={"Host": "localhost"}) as r:
        if r.status != 200:
            return web.Response(status=r.status, body=await r.read(), content_type="application/json")
        resp = web.StreamResponse(headers={"Content-Type": "text/event-stream", "Cache-Control": "no-store", "X-Accel-Buffering": "no"})
        await resp.prepare(request)
        try:
            async for chunk in r.content.iter_any():
                await resp.write(chunk)
        except (ConnectionResetError, aiohttp.ClientError):
            pass  # the viewer or the dashboard left; closing r stops the dashboard's ssh
        return resp


async def desktop_link(request):
    # The dashboard's local /desktop/<key> link: here the desktop lives at /d/<key>.
    raise web.HTTPFound(f"/d/{request.match_info['key']}")


async def healthz(_):
    return web.Response(text="ok")


async def session(app):
    app["http"] = aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=None, sock_connect=3))
    yield
    await app["http"].close()


def main():
    app = web.Application()
    app.cleanup_ctx.append(session)
    app.router.add_get("/healthz", healthz)
    app.router.add_get("/d/{key}", start)
    app.router.add_get("/d/{key}/", start)
    app.router.add_get("/d/{key}/{tail:.+}", page)
    app.router.add_get("/desktop/{key}", desktop_link)
    app.router.add_get("/w/{thread}", watch)
    app.router.add_get("/w/{thread}/{events:events}", watch)
    app.router.add_route("GET", "/{tail:.*}", dashboard)
    app.router.add_route("POST", "/{tail:.*}", dashboard)
    web.run_app(app, port=int(os.environ.get("PORT", "8080")))


if __name__ == "__main__":
    main()
