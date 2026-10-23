"""For the dashboard API checks: a local server, the gateway's signed headers, and one request.
A change to the signed string in server.py changes sig() here only."""
import hashlib, hmac, threading, time, urllib.error, urllib.request
from http.server import ThreadingHTTPServer


def start(handler):
    """Serve handler on a free local port; returns the base URL."""
    srv = ThreadingHTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return f"http://127.0.0.1:{srv.server_port}"


def sig(user, method, path, ts=None, key=b"k1"):
    ts = str(int(time.time()) if ts is None else ts)
    return {"X-Fxa-User": user, "X-Fxa-Time": ts,
            "X-Fxa-Sig": hmac.new(key, f"{user}|{ts}|{method}|{path}".encode(), hashlib.sha256).hexdigest()}


def request(url, method="GET", data=None, headers=None, timeout=20):
    """(status, response headers, body bytes): an HTTP error is an answer here, not a raise."""
    req = urllib.request.Request(url, data=data, method=method, headers={"Host": "localhost", **(headers or {})})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, r.headers, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.headers, e.read()
