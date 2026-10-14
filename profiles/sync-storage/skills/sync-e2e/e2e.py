"""End-to-end check of local Sync: a new FxA account gets a Sync token as Firefox does, the
token server assigns a node, and a record goes into storage and back. Run with the venv from
boot.sh: ~/.syncstorage-venv/bin/python e2e.py"""
import base64, hashlib, hmac, json, os, sys, time, urllib.error, urllib.request
from urllib.parse import urlparse
from fxa import core, oauth

AUTH, TOKEN, MAIL = "http://localhost:9000/v1", "http://localhost:8000/1.0/sync/1.5", "http://localhost:9001/mail"
FIREFOX, SCOPE = "5882386c6d801776", "https://identity.mozilla.com/apps/oldsync"


def http(method, url, headers=None, body=None):
    req = urllib.request.Request(url, data=body, method=method, headers=headers or {})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()


def hawk(creds, method, url, body=b""):
    """A Hawk header for one storage request (the scheme the token server's key signs)."""
    u = urlparse(url)
    ts, nonce = str(int(time.time())), base64.b64encode(os.urandom(6)).decode()
    ph = ""
    if body:
        ph = base64.b64encode(hashlib.sha256(b"hawk.1.payload\napplication/json\n" + body + b"\n").digest()).decode()
    norm = "\n".join(["hawk.1.header", ts, nonce, method, u.path + (("?" + u.query) if u.query else ""),
                      u.hostname, str(u.port or 80), ph, "", ""])
    mac = base64.b64encode(hmac.new(creds["key"].encode(), norm.encode(), hashlib.sha256).digest()).decode()
    h = f'Hawk id="{creds["id"]}", ts="{ts}", nonce="{nonce}", mac="{mac}"'
    return h + (f', hash="{ph}"' if ph else "")


def confirm(session, email):
    """Confirm the account with the sign-up code from the local mail helper, as a person would."""
    user = email.split("@")[0]
    for _ in range(30):
        code, out = http("GET", f"{MAIL}/{user}")
        mails = json.loads(out) if code == 200 and out.startswith("[") else []
        for m in mails:
            h = {k.lower(): v for k, v in m.get("headers", {}).items()}
            if h.get("x-verify-short-code"):
                session.apiclient.post("/session/verify_code", {"code": h["x-verify-short-code"]}, auth=session._auth)
                return
            if h.get("x-verify-code"):
                session.apiclient.post("/recovery_email/verify_code", {"uid": h["x-uid"], "code": h["x-verify-code"]})
                return
        time.sleep(1)
    sys.exit("no sign-up code in the local mail helper after 30 s")


def main():
    email = f"sync-e2e-{os.urandom(4).hex()}@restmail.net"
    session = core.Client(server_url=AUTH).create_account(email, "sync-e2e-password-1", keys=True)
    confirm(session, email)
    token = oauth.Client(FIREFOX, server_url=AUTH).authorize_token(session, SCOPE)
    print(f"1. FxA: account {email}, Sync token for the Firefox client")
    # The key id, as Firefox sends it: when the Sync key last changed, and the first 16 bytes
    # of a hash of kB (the "client state"). The token server stores both for the user.
    session.fetch_keys()
    kb = session.keys[1]
    data = session.apiclient.post("/account/scoped-key-data", {"client_id": FIREFOX, "scope": SCOPE}, auth=session._auth)
    kca = data[SCOPE]["keyRotationTimestamp"]
    kid = f"{kca}-{base64.urlsafe_b64encode(hashlib.sha256(kb).digest()[:16]).decode().rstrip('=')}"
    code, out = http("GET", TOKEN, {"Authorization": f"Bearer {token}", "X-KeyID": kid})
    if code != 200:
        sys.exit(f"token server: HTTP {code}: {out[:300]}")
    creds = json.loads(out)
    print(f"2. token server: node {creds['api_endpoint']}, uid {creds['uid']}")
    url = creds["api_endpoint"] + "/storage/bookmarks/e2e-record"
    body = json.dumps({"id": "e2e-record", "payload": "hello from the sandbox"}).encode()
    code, out = http("PUT", url, {"Authorization": hawk(creds, "PUT", url, body), "Content-Type": "application/json"}, body)
    if code != 200:
        sys.exit(f"storage PUT: HTTP {code}: {out[:300]}")
    code, out = http("GET", url, {"Authorization": hawk(creds, "GET", url)})
    if code != 200 or json.loads(out).get("payload") != "hello from the sandbox":
        sys.exit(f"storage GET: HTTP {code}: {out[:300]}")
    print("3. storage: wrote a bookmarks record and read it back")
    print("sync e2e: ok")


if __name__ == "__main__":
    main()
