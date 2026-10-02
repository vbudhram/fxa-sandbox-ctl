#!/usr/bin/env python3
"""fxa-llm-proxy: the only holder of the Anthropic API key.

Runners reach Claude through here with a per-run token (ANTHROPIC_API_KEY in
the runner is that token; ANTHROPIC_BASE_URL points here). The proxy checks
the token, allows only the Messages and Models API, swaps in the real key, and
streams the answer back as it arrives. It counts each run's tokens and cost,
and refuses a run past its cap.

Tokens: <dir>/tokens/<token>.json  {run, created, expires, cap_usd, spent_usd}
written by the controller (lib/llm-token.sh), updated here. Usage lines go to
<dir>/usage.jsonl. Standard library only.
"""
import http.client
import http.server
import json
import os
import queue
import re
import sys
import threading
import time
import urllib.parse

DIR = os.environ.get("LLM_PROXY_DIR", os.path.expanduser("~/.claude/state/llm-proxy"))
UPSTREAM = urllib.parse.urlsplit(os.environ.get("LLM_PROXY_UPSTREAM", "https://api.anthropic.com"))
KEY = os.environ.get("ANTHROPIC_API_KEY", "")
LISTEN = os.environ.get("LLM_PROXY_LISTEN", "0.0.0.0:8788")

# Only what Claude Code needs; anything else on the key is refused.
ALLOWED = [("POST", re.compile(r"^/v1/messages(/count_tokens)?$")), ("GET", re.compile(r"^/v1/models(/[\w.-]+)?$"))]
# $ per million tokens: input, output, cache write, cache read (as lib/telemetry.sh).
PRICES = [("claude-fable-5-1", (10, 50, 12.5, 0.25)), ("claude-fable-5", (10, 50, 12.5, 1)),
          ("claude-opus-5-5", (4, 20, 5, 0.2)), ("claude-opus-5", (5, 25, 6.25, 0.5)),
          ("claude-sonnet-5", (2, 10, 2.5, 0.2)), ("claude-haiku-4-5", (1, 5, 1.25, 0.1))]
UNKNOWN = (10, 50, 12.5, 1)  # the dearest row: an unknown model never looks cheap
HOP = {"connection", "keep-alive", "transfer-encoding", "te", "trailer", "upgrade", "proxy-authorization", "content-length", "host"}
# Not asked for: a compressed stream hides the usage the proxy counts.
DROP = HOP | {"x-api-key", "authorization", "accept-encoding"}
TOKEN_RE = re.compile(r"^fxl_[A-Za-z0-9]{32}$")

locks, locks_guard = {}, threading.Lock()
# Idle upstream connections: a call reuses one and skips the TCP and TLS handshake.
POOL = queue.LifoQueue(maxsize=8)


def price(model):
    for prefix, p in PRICES:
        if model.startswith(prefix):
            return p
    return UNKNOWN


def cost(model, u):
    p = price(model or "")
    return (u.get("input_tokens", 0) * p[0] + u.get("output_tokens", 0) * p[1]
            + u.get("cache_creation_input_tokens", 0) * p[2] + u.get("cache_read_input_tokens", 0) * p[3]) / 1e6


def token_lock(tok):
    with locks_guard:
        return locks.setdefault(tok, threading.Lock())


def load(tok):
    """The token's record, or None when unknown, revoked or expired."""
    if not TOKEN_RE.match(tok or ""):
        return None
    try:
        with open(os.path.join(DIR, "tokens", tok + ".json")) as f:
            rec = json.load(f)
    except (OSError, ValueError):
        return None
    return rec if rec.get("expires", 0) > time.time() else None


def charge(tok, model, usage):
    usd = cost(model, usage)
    with token_lock(tok):
        rec = load(tok)
        if rec is not None:
            rec["spent_usd"] = round(rec.get("spent_usd", 0) + usd, 6)
            path = os.path.join(DIR, "tokens", tok + ".json")
            with open(path + ".tmp", "w") as f:
                json.dump(rec, f)
            os.replace(path + ".tmp", path)
    line = {"at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "run": (rec or {}).get("run"), "model": model,
            "usd": round(usd, 6),
            # The cache-write part on its own: the largest share of spend, and what an idle gap costs.
            "usd_cache_write": round(usage.get("cache_creation_input_tokens", 0) * price(model or "")[2] / 1e6, 6),
            **{k: usage.get(k, 0) for k in ("input_tokens", "output_tokens",
                                                                   "cache_creation_input_tokens", "cache_read_input_tokens")}}
    with open(os.path.join(DIR, "usage.jsonl"), "a") as f:
        f.write(json.dumps(line) + "\n")


def connect():
    cls = http.client.HTTPSConnection if UPSTREAM.scheme == "https" else http.client.HTTPConnection
    return cls(UPSTREAM.hostname, UPSTREAM.port, timeout=600)


def take():
    try:
        return POOL.get_nowait()
    except queue.Empty:
        return connect()


def give(conn, resp):
    """Keep a connection whose answer was read in full and that the far end keeps open."""
    if resp.will_close or not resp.isclosed():
        conn.close()
        return
    try:
        POOL.put_nowait(conn)
    except queue.Full:
        conn.close()


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"  # close after each answer: a streamed body needs no length

    def log_message(self, fmt, *args):  # one short line per call, no headers
        sys.stderr.write("%s %s\n" % (self.command, fmt % args))

    def refuse(self, code, kind, msg):
        body = json.dumps({"type": "error", "error": {"type": kind, "message": msg}}).encode()
        self.send_response(code)
        self.send_header("content-type", "application/json")
        self.end_headers()
        self.wfile.write(body)

    def handle_any(self):
        path = urllib.parse.urlsplit(self.path).path
        if not any(m == self.command and r.match(path) for m, r in ALLOWED):
            return self.refuse(403, "permission_error", "fxa-llm-proxy: only the Messages and Models API are allowed")
        auth = self.headers.get("x-api-key") or self.headers.get("authorization", "").removeprefix("Bearer ").strip()
        rec = load(auth)
        if rec is None:
            return self.refuse(401, "authentication_error", "fxa-llm-proxy: unknown, revoked or expired run token")
        if rec.get("cap_usd") and rec.get("spent_usd", 0) >= rec["cap_usd"]:
            # 403, not 429: a client retries a 429, and a capped run must stop, not hang.
            return self.refuse(403, "permission_error", "fxa-llm-proxy: this run reached its spend cap of $%s" % rec["cap_usd"])
        body = self.rfile.read(int(self.headers.get("content-length", 0) or 0))
        headers = {k: v for k, v in self.headers.items() if k.lower() not in DROP}
        headers["x-api-key"] = KEY
        for attempt in (1, 2):  # a pooled connection the far end closed: retry once on a new one
            conn = take() if attempt == 1 else connect()
            try:
                conn.request(self.command, self.path, body=body or None, headers=headers)
                resp = conn.getresponse()
                break
            except (http.client.HTTPException, OSError):
                conn.close()
                if attempt == 2:
                    return self.refuse(502, "api_error", "fxa-llm-proxy: could not reach the Anthropic API")
        self.send_response(resp.status)
        for k, v in resp.getheaders():
            if k.lower() not in HOP:
                self.send_header(k, v)
        self.end_headers()
        try:
            self.relay(resp, auth, path)
        except (http.client.HTTPException, OSError):
            conn.close()
            raise
        give(conn, resp)

    def relay(self, resp, tok, path):
        """Pass the answer through as it arrives, and read its usage on the way."""
        stream = "text/event-stream" in (resp.getheader("content-type") or "")
        model, usage, buf, whole = None, {}, b"", []
        while True:
            chunk = resp.read1(65536)
            if not chunk:
                break
            try:
                self.wfile.write(chunk)
                self.wfile.flush()
            except OSError:
                break  # the runner went away; still count what was used
            if stream:
                buf += chunk
                *lines, buf = buf.split(b"\n")
                for line in lines:
                    if not line.startswith(b"data:"):
                        continue
                    try:
                        ev = json.loads(line[5:])
                    except ValueError:
                        continue
                    if ev.get("type") == "message_start":
                        msg = ev.get("message", {})
                        model, usage = msg.get("model"), dict(msg.get("usage", {}))
                    elif ev.get("type") == "message_delta" and ev.get("usage"):
                        usage.update({k: v for k, v in ev["usage"].items() if isinstance(v, int)})
            else:
                whole.append(chunk)
        resp.read()  # drain, so the connection can go back to the pool
        if not stream and path.startswith("/v1/messages") and not path.endswith("count_tokens"):
            try:
                doc = json.loads(b"".join(whole))
                model, usage = doc.get("model"), doc.get("usage", {})
            except ValueError:
                pass
        if usage:
            charge(tok, model, usage)

    do_GET = do_POST = handle_any

    def do_HEAD(self):
        # Claude Code's reachability check; answered here, nothing forwarded.
        self.send_response(200 if urllib.parse.urlsplit(self.path).path == "/api/hello" else 404)
        self.end_headers()


def main():
    if not KEY:
        sys.exit("fxa-llm-proxy: ANTHROPIC_API_KEY is not set")
    os.makedirs(os.path.join(DIR, "tokens"), exist_ok=True)
    host, port = LISTEN.rsplit(":", 1)
    server = http.server.ThreadingHTTPServer((host, int(port)), Handler)
    server.daemon_threads = True
    sys.stderr.write("fxa-llm-proxy on %s, upstream %s\n" % (LISTEN, UPSTREAM.geturl()))
    server.serve_forever()


if __name__ == "__main__":
    main()
