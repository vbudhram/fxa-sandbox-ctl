"""Offline check: python check.py (needs the requirements). Fakes IAP, GCS and the runner."""
import asyncio
import os

os.environ.setdefault("IAP_AUDIENCE", "test")
os.environ.setdefault("DESKTOP_BUCKET", "test")
import google.auth
google.auth.default = lambda scopes=None: (type("C", (), {"valid": True, "token": "t"})(), None)
import aiohttp
from aiohttp import web
import main

RUNNER = 18765
fail = 0


def check(name, want, got):
    global fail
    ok = want == got
    fail |= not ok
    print(("ok   " if ok else "FAIL ") + name + ("" if ok else f": want {want!r} got {got!r}"))


async def runner():
    async def vnc(_):
        return web.Response(text="<html>novnc</html>", content_type="text/html")
    async def ws(request):
        w = web.WebSocketResponse(protocols=("binary",))
        await w.prepare(request)
        async for m in w:
            await w.send_bytes(b"echo:" + m.data)
        return w
    app = web.Application()
    app.router.add_get("/vnc.html", vnc)
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


async def main_check():
    await jwt_check()
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
        async with c.ws_connect(f"{base}/d/agent-abcd12/websockify", protocols=("binary",)) as w:
            await w.send_bytes(b"hi")
            check("websocket relays both ways", b"echo:hi", (await w.receive()).data)
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
        who["email"] = "someone@example.com"
        async with c.get(f"{base}/d/agent-abcd12/vnc.html") as x:
            check("another person: 403", 403, x.status)
        who["email"] = None
        async with c.get(f"{base}/d/agent-abcd12", allow_redirects=False) as x:
            check("no IAP identity: 403", 403, x.status)
    await r.cleanup()


asyncio.run(main_check())
print("all ok" if not fail else "")
raise SystemExit(fail)
