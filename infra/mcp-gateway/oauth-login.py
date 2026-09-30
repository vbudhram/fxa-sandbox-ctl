#!/usr/bin/env python3
"""Sign fxa-mcp-gateway in to an MCP OAuth server (Runlayer) in your browser.

  python3 oauth-login.py [issuer] | <write it where the gateway reads MCP_GATEWAY_OAUTH>

bash infra/gce/manager.sh oauth runs this and sends the result to the manager.
It registers a public client, signs in with PKCE, and prints
{token_endpoint, client_id, refresh_token} to stdout, which must not be a
terminal. The token names (RFC 8707) each connector in
~/.config/fxa/mcp-gateway.json that uses ${RUNLAYER_OAUTH_TOKEN}; after sign-in
each is tried and only its HTTP status is shown. Standard library only.
"""
import base64
import hashlib
import http.server
import json
import os
import secrets
import sys
import urllib.error
import urllib.parse
import urllib.request
import webbrowser

ISSUER = sys.argv[1] if len(sys.argv) > 1 else "https://mozilla.runlayer.com"
CONFIG = os.environ.get("MCP_GATEWAY_CONFIG", os.path.expanduser("~/.config/fxa/mcp-gateway.json"))


def post(url, data, form=False, headers=None):
    body = urllib.parse.urlencode(data, doseq=True).encode() if form else json.dumps(data).encode()
    ctype = "application/x-www-form-urlencoded" if form else "application/json"
    req = urllib.request.Request(url, body, {"content-type": ctype, "accept": "application/json", **(headers or {})})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)


def main():
    if sys.stdout.isatty():
        sys.exit("oauth-login: stdout is a terminal; pipe it so the refresh token is not shown")
    try:
        with open(CONFIG) as f:
            connectors = json.load(f).get("connectors", {})
    except (OSError, ValueError) as e:
        sys.exit("oauth-login: cannot read %s: %s" % (CONFIG, e))
    mine = {n: s["url"] for n, s in connectors.items() if "${RUNLAYER_OAUTH_TOKEN}" in json.dumps(s.get("headers") or {})}
    if not mine:
        sys.exit("oauth-login: no connector in %s uses ${RUNLAYER_OAUTH_TOKEN}" % CONFIG)
    resources = sorted(set(mine.values()))
    with urllib.request.urlopen(ISSUER + "/.well-known/oauth-authorization-server", timeout=30) as r:
        meta = json.load(r)

    got = {}

    class Callback(http.server.BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def do_GET(self):
            q = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
            got.update({k: v[0] for k, v in q.items()})
            self.send_response(200)
            self.send_header("content-type", "text/plain")
            self.end_headers()
            self.wfile.write(b"fxa-mcp-gateway: signed in. You can close this tab.")

    srv = http.server.HTTPServer(("127.0.0.1", 0), Callback)
    redirect = "http://127.0.0.1:%d/callback" % srv.server_port
    client = post(meta["registration_endpoint"], {
        "client_name": "fxa-mcp-gateway", "redirect_uris": [redirect], "grant_types": ["authorization_code", "refresh_token"],
        "response_types": ["code"], "token_endpoint_auth_method": "none"})
    verifier = secrets.token_urlsafe(64)
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
    state = secrets.token_urlsafe(16)
    url = meta["authorization_endpoint"] + "?" + urllib.parse.urlencode([
        ("response_type", "code"), ("client_id", client["client_id"]), ("redirect_uri", redirect), ("scope", "mcp:proxy"),
        ("code_challenge", challenge), ("code_challenge_method", "S256"), ("state", state)] + [("resource", u) for u in resources])
    sys.stderr.write("Sign in in your browser. If it does not open, visit:\n%s\n" % url)
    webbrowser.open(url)
    while "code" not in got and "error" not in got:
        srv.handle_request()
    if got.get("state") != state or "code" not in got:
        sys.exit("oauth-login: sign-in failed: %s" % got.get("error", "state mismatch"))
    tok = post(meta["token_endpoint"], {
        "grant_type": "authorization_code", "code": got["code"], "redirect_uri": redirect,
        "client_id": client["client_id"], "code_verifier": verifier, "resource": resources}, form=True)
    if not tok.get("refresh_token"):
        sys.exit("oauth-login: the server issued no refresh token")

    init = {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
        "protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "fxa-mcp-gateway", "version": "1"}}}
    for name, u in mine.items():
        req = urllib.request.Request(u, json.dumps(init).encode(), {
            "content-type": "application/json", "accept": "application/json, text/event-stream",
            "authorization": "Bearer " + tok["access_token"]})
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                status = r.status
        except urllib.error.HTTPError as e:
            status = e.code
        except OSError as e:
            status = e.__class__.__name__
        sys.stderr.write("%s: HTTP %s\n" % (name, status))

    json.dump({"token_endpoint": meta["token_endpoint"], "client_id": client["client_id"],
               "refresh_token": tok["refresh_token"], "resource": resources}, sys.stdout)


if __name__ == "__main__":
    main()
