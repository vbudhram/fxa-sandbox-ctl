"""Relay a session's Linux desktop to its owner, and the dashboard, behind IAP.

IAP signs in the person and signs each request with their email. The gateway
checks that signature. /d/<key> reads the session's record from GCS (owner,
runner IP, VNC password) and relays noVNC's pages and WebSocket to the runner.
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
    app.router.add_route("GET", "/{tail:.*}", dashboard)
    app.router.add_route("POST", "/{tail:.*}", dashboard)
    web.run_app(app, port=int(os.environ.get("PORT", "8080")))


if __name__ == "__main__":
    main()
