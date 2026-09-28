"""Relay a session's Linux desktop to its owner, and the dashboard, behind IAP.

IAP signs in the person and signs each request with their email. The gateway
checks that signature. /d/<key> reads the session's record from GCS (owner,
runner IP, VNC password) and relays noVNC's pages and WebSocket to the runner.
Every other path goes to the manager VM's dashboard (MANAGER_URL).
"""
import asyncio
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
    if time.time() - _certs["at"] > 3600:
        async with request.app["http"].get(IAP_KEYS_URL) as r:
            _certs.update(at=time.time(), keys=await r.json())
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
        rec = json.loads(await r.text()) if r.status == 200 else None
    _records[key] = (time.time(), rec)
    return rec


async def authorize(request):
    key = request.match_info["key"]
    if not KEY.fullmatch(key):
        raise web.HTTPNotFound()
    email = await iap_email(request)
    if not email:
        raise web.HTTPForbidden(text="Not signed in through IAP.")
    rec = await record(request.app, key)
    if not rec or rec.get("expires", 0) < time.time():
        raise web.HTTPNotFound(text="This session has no open desktop. It may have ended; ask for a new link with !desktop.")
    if email != (rec.get("owner_email") or "").lower():
        print(f"refused {email} for {key}", flush=True)
        raise web.HTTPForbidden(text="This desktop belongs to another person.")
    return key, rec


async def start(request):
    key, rec = await authorize(request)
    # The VNC password goes in the fragment, which the browser never sends back.
    raise web.HTTPFound(f"/d/{key}/fxa.html#password={rec['vnc_password']}")


async def page(request):
    key, rec = await authorize(request)
    tail = request.match_info["tail"]
    if tail == "websockify":
        return await relay(request, rec)
    url = f"http://{rec['ip']}:{NOVNC_PORT}/{tail}"
    async with request.app["http"].get(url, params=request.query) as r:
        body = await r.read()
        return web.Response(status=r.status, body=body, content_type=r.content_type,
                            headers={"Cache-Control": "no-store", "X-Content-Type-Options": "nosniff"})


async def relay(request, rec):
    ws = web.WebSocketResponse(protocols=("binary",), heartbeat=30)
    await ws.prepare(request)
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
    app["http"] = aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=None, sock_connect=10))
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
