"""Offline check: python check.py (needs the requirements). Fakes IAP, GCS and the runner."""
import asyncio
import json
import os

os.environ.setdefault("IAP_AUDIENCE", "test")
os.environ.setdefault("DESKTOP_BUCKET", "test")
os.environ["MANAGER_URL"] = "http://127.0.0.1:18767"
import google.auth
google.auth.default = lambda scopes=None: (type("C", (), {"valid": True, "token": "t"})(), None)
import aiohttp
from aiohttp import web
import main

RUNNER = 18765
fail = 0


class FakeHttp:
    """Stands in for app["http"].get: answers with a status and a JSON body."""
    def __init__(self, status, body):
        self.status, self.body, self.calls = status, body, 0
    def get(self, *_, **__):
        self.calls += 1
        fake = self
        class R:
            status = fake.status
            async def __aenter__(self): return self
            async def __aexit__(self, *_): pass
            def raise_for_status(self):
                if self.status != 200: raise aiohttp.ClientError(self.status)
            async def json(self): return fake.body
            async def text(self): return json.dumps(fake.body)
        return R()


def check(name, want, got):
    global fail
    ok = want == got
    fail |= not ok
    print(("ok   " if ok else "FAIL ") + name + ("" if ok else f": want {want!r} got {got!r}"))


async def runner():
    async def vnc(_):
        return web.Response(text="<html>novnc</html>", content_type="text/html")
    async def js(_):
        return web.Response(text="export default 1;\n" * 200, content_type="application/javascript")
    async def ws(request):
        w = web.WebSocketResponse(protocols=("binary",))
        await w.prepare(request)
        async for m in w:
            await w.send_bytes(b"echo:" + m.data)
        return w
    app = web.Application()
    app.router.add_get("/vnc.html", vnc)
    app.router.add_get("/core/rfb.js", js)
    app.router.add_get("/websockify", ws)
    r = web.AppRunner(app); await r.setup(); await web.TCPSite(r, "127.0.0.1", RUNNER).start()


async def jwt_check():
    import time
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.hazmat.primitives import serialization
    from google.auth import crypt, jwt
    k = ec.generate_private_key(ec.SECP256R1())
    pem = k.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption())
    pub = k.public_key().public_bytes(serialization.Encoding.PEM, serialization.PublicFormat.SubjectPublicKeyInfo).decode()
    signer = crypt.ES256Signer.from_string(pem, key_id="k1")
    main._certs.update(at=time.time(), keys={"k1": pub})
    now = int(time.time())
    def req(claims):
        tok = jwt.encode(signer, {"iat": now, "exp": now + 600, **claims}).decode()
        return type("R", (), {"headers": {"x-goog-iap-jwt-assertion": tok}, "app": None})()
    good = {"aud": "test", "iss": "https://cloud.google.com/iap", "email": "Owner@Example.com"}
    check("a signed IAP token gives the email", "owner@example.com", await main.iap_email(req(good)))
    check("wrong audience is refused", None, await main.iap_email(req({**good, "aud": "other"})))
    check("wrong issuer is refused", None, await main.iap_email(req({**good, "iss": "https://evil.test"})))
    other = crypt.ES256Signer.from_string(ec.generate_private_key(ec.SECP256R1()).private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()), key_id="k1")
    forged = jwt.encode(other, {"iat": now, "exp": now + 600, **good}).decode()
    check("a token signed by another key is refused", None, await main.iap_email(type("R", (), {"headers": {"x-goog-iap-jwt-assertion": forged}, "app": None})()))
    # A rotated key: an unknown kid fetches the keys again, once a minute at most.
    k2 = ec.generate_private_key(ec.SECP256R1())
    pub2 = k2.public_key().public_bytes(serialization.Encoding.PEM, serialization.PublicFormat.SubjectPublicKeyInfo).decode()
    signer2 = crypt.ES256Signer.from_string(k2.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()), key_id="k2")
    http = FakeHttp(200, {"k1": pub, "k2": pub2})
    rotated = type("R", (), {"headers": {"x-goog-iap-jwt-assertion": jwt.encode(signer2, {"iat": now, "exp": now + 600, **good}).decode()}, "app": {"http": http}})()
    check("a new kid inside a minute does not fetch", None, await main.iap_email(rotated))
    main._certs["at"] = time.time() - 120
    check("a new kid after a minute fetches the keys again", "owner@example.com", await main.iap_email(rotated))
    main._certs.update(at=0.0, keys={})
    check("a failed key fetch is a refusal, not a crash", None, await main.iap_email(type("R", (), {"headers": rotated.headers, "app": {"http": FakeHttp(500, {})}})()))
    check("a garbage token is refused", None, await main.iap_email(type("R", (), {"headers": {"x-goog-iap-jwt-assertion": "x.y.z"}, "app": None})()))


async def record_check():
    app = {"http": FakeHttp(500, {})}
    try:
        await main.record(app, "agent-gcs500")
        got = None
    except web.HTTPServiceUnavailable:
        got = 503
    check("a GCS error is a 503, not 'no desktop'", 503, got)
    app["http"] = FakeHttp(200, {"owner_email": "o@example.com"})
    check("a GCS error is not cached", "o@example.com", (await main.record(app, "agent-gcs500"))["owner_email"])
    app["http"] = FakeHttp(404, {})
    check("a 404 is no desktop", None, await main.record(app, "agent-gone12"))
    await main.record(app, "agent-gone12")
    check("a 404 is cached", 1, app["http"].calls)


async def dashboard_check():
    seen = {}
    async def dash(request):
        seen.update(host=request.headers.get("Host"), origin=request.headers.get("Origin"), method=request.method)
        return web.Response(text="dash " + request.path, content_type="text/html", headers={"Content-Security-Policy": "default-src 'self'"})
    app = web.Application(); app.router.add_route("*", "/{tail:.*}", dash)
    r = web.AppRunner(app); await r.setup(); await web.TCPSite(r, "127.0.0.1", 18767).start()
    who = {"email": "owner@example.com"}
    async def fake_email(_):
        return who["email"]
    keep = main.iap_email; main.iap_email = fake_email
    g = web.Application(); g.cleanup_ctx.append(main.session)
    g.router.add_get("/desktop/{key}", main.desktop_link)
    g.router.add_route("GET", "/{tail:.*}", main.dashboard); g.router.add_route("POST", "/{tail:.*}", main.dashboard)
    gr = web.AppRunner(g); await gr.setup(); await web.TCPSite(gr, "127.0.0.1", 18768).start()
    base = "http://127.0.0.1:18768"
    async with aiohttp.ClientSession() as c:
        async with c.get(f"{base}/api/snapshot") as x:
            check("the dashboard comes through", "dash /api/snapshot", await x.text())
            check("its CSP comes through", "default-src 'self'", x.headers.get("Content-Security-Policy"))
        check("Host is loopback for the dashboard", "localhost", seen["host"])
        async with c.post(f"{base}/api/refresh", headers={"Origin": base}) as x:
            check("a same-site POST drops the gateway's own origin", None, seen["origin"])
        async with c.post(f"{base}/api/refresh", headers={"Origin": "https://evil.test"}) as x:
            check("a cross-site origin passes through for the dashboard to refuse", "https://evil.test", seen["origin"])
        async with c.get(f"{base}/desktop/agent-abcd12", allow_redirects=False) as x:
            check("the dashboard's desktop link goes to /d/", "/d/agent-abcd12", x.headers.get("Location"))
        main.DASHBOARD_USERS = {"someone@example.com"}
        async with c.get(f"{base}/") as x:
            check("an account not on the list: 403", 403, x.status)
        main.DASHBOARD_USERS = set()
        who["email"] = None
        async with c.get(f"{base}/") as x:
            check("no IAP identity: 403", 403, x.status)
    main.iap_email = keep
    await gr.cleanup(); await r.cleanup()


async def main_check():
    await jwt_check()
    await record_check()
    await dashboard_check()
    await runner()
    who = {"email": "owner@example.com"}
    async def fake_email(_):
        return who["email"]
    async def fake_record(_, key):
        return {"owner_email": "Owner@example.com", "ip": f"127.0.0.1:{RUNNER}".split(":")[0], "vnc_password": "pw123456", "expires": 4e9} if key == "agent-abcd12" else None
    main.iap_email, main.record, main.NOVNC_PORT = fake_email, fake_record, RUNNER
    app = web.Application(); app.cleanup_ctx.append(main.session)
    app.router.add_get("/d/{key}", main.start); app.router.add_get("/d/{key}/", main.start)
    app.router.add_get("/d/{key}/{tail:.+}", main.page)
    r = web.AppRunner(app); await r.setup(); await web.TCPSite(r, "127.0.0.1", 18766).start()
    base = "http://127.0.0.1:18766"
    async with aiohttp.ClientSession() as c:
        async with c.get(f"{base}/d/agent-abcd12", allow_redirects=False) as x:
            check("owner is sent to noVNC with the path and password", True,
                  x.status == 302 and x.headers["Location"] == "/d/agent-abcd12/fxa.html#password=pw123456")
        async with c.get(f"{base}/d/agent-abcd12/vnc.html") as x:
            check("pages relay from the runner", "<html>novnc</html>", await x.text())
            check("an html page is not cached", "no-store", x.headers.get("Cache-Control"))
        async with c.get(f"{base}/d/agent-abcd12/core/rfb.js", headers={"Accept-Encoding": "gzip"}) as x:
            check("noVNC js is cached", "private, max-age=86400", x.headers.get("Cache-Control"))
            check("noVNC js is gzipped", "gzip", x.headers.get("Content-Encoding"))
        async with c.get(f"{base}/d/agent-abcd12/core/none.js") as x:
            check("a missing file is not cached", "no-store", x.headers.get("Cache-Control"))
        async with c.ws_connect(f"{base}/d/agent-abcd12/websockify", protocols=("binary",)) as w:
            await w.send_bytes(b"hi")
            check("websocket relays both ways", b"echo:hi", (await w.receive()).data)
            check("websocket is not deflated again", 0, w.compress)
        main.NOVNC_PORT = RUNNER + 50
        async with c.get(f"{base}/d/agent-abcd12/vnc.html") as x:
            check("a paused runner: 502 that says so", (502, True), (x.status, "may be paused" in await x.text()))
        async with c.ws_connect(f"{base}/d/agent-abcd12/websockify", protocols=("binary",)) as w:
            check("a paused runner closes the websocket", aiohttp.WSMsgType.CLOSE, (await w.receive()).type)
        main.NOVNC_PORT = RUNNER
        async with c.get(f"{base}/d/agent-zzzz99/vnc.html") as x:
            check("no record: 404", 404, x.status)
        async with c.get(f"{base}/d/..%2Fetc/vnc.html") as x:
            check("bad key: 404", 404, x.status)
        async def old_record(_, key):
            return {"owner_email": "owner@example.com", "ip": "127.0.0.1", "vnc_password": "x", "expires": 1}
        main.record, keep = old_record, main.record
        async with c.get(f"{base}/d/agent-abcd12/vnc.html") as x:
            check("an expired record: 404", 404, x.status)
        main.record = keep
        who["email"] = "some<b>one@example.com"
        async with c.get(f"{base}/d/agent-abcd12/vnc.html") as x:
            body = await x.text()
            check("another person: 403", 403, x.status)
            check("it is a page for a phone", "text/html", x.content_type)
            check("it names the account, escaped", True, "some&lt;b&gt;one@example.com" in body)
            check("it links to another account", True, "?gcp-iap-mode=CLEAR_LOGIN_COOKIE" in body)
        who["email"] = None
        async with c.get(f"{base}/d/agent-abcd12", allow_redirects=False) as x:
            check("no IAP identity: 403", 403, x.status)
    await r.cleanup()


asyncio.run(main_check())
print("all ok" if not fail else "")
raise SystemExit(fail)
