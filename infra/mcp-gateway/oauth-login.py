#!/usr/bin/env python3
"""Sign fxa-mcp-gateway in to its MCP OAuth servers in your browser.

  python3 oauth-login.py [issuer] | <write it where the gateway reads MCP_GATEWAY_OAUTH>
  FXA_OAUTH_ONLY=argocd python3 oauth-login.py | <merge it into that file>

A connector's oauth_issuer names its server (ArgoCD); the others use [issuer],
Runlayer by default. FXA_OAUTH_ONLY signs in only the named connectors, and the
output then has only their part, to merge into the gateway's file.

bash infra/gce/manager.sh oauth runs this and sends the result to the manager.
It registers a public client, signs in with PKCE, and prints
{token_endpoint, client_id, refresh_tokens: {url: token}} to stdout, which must not be a
terminal. The server binds a sign-in to one resource (RFC 8707), so each URL
in ~/.config/fxa/mcp-gateway.json that uses ${RUNLAYER_OAUTH_TOKEN} gets its
own; connectors on one URL share it. Each URL is then tried and only its HTTP
status is shown. Standard library only.
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
    body = urllib.parse.urlencode(data).encode() if form else json.dumps(data).encode()
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
    only = [n for n in os.environ.get("FXA_OAUTH_ONLY", "").replace(",", " ").split() if n]
    mine = {n: s["url"] for n, s in connectors.items() if "${RUNLAYER_OAUTH_TOKEN}" in json.dumps(s.get("headers") or {})
            and (not only or n in only)}
    if not mine or (only and set(only) - set(mine)):
        sys.exit("oauth-login: no OAuth connector named %s in %s" % (" ".join(sorted(set(only) - set(mine))) or "", CONFIG))
    issuer_of = {s["url"]: s.get("oauth_issuer") or ISSUER for n, s in connectors.items() if n in mine}
    # A server that allows only a registered callback (ArgoCD's Dex: localhost:9382) names its port.
    port_of = {s.get("oauth_issuer") or ISSUER: int(s.get("oauth_callback_port") or 0) for n, s in connectors.items() if n in mine}

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

    servers = {}
    for issuer in sorted(set(issuer_of.values())):
        srv = http.server.HTTPServer(("127.0.0.1", port_of[issuer]), Callback)
        redirect = "http://%s:%d/callback" % ("localhost" if port_of[issuer] else "127.0.0.1", srv.server_port)
        with urllib.request.urlopen(issuer + "/.well-known/oauth-authorization-server", timeout=30) as r:
            meta = json.load(r)
        servers[issuer] = (meta, srv, redirect, post(meta["registration_endpoint"], {
            "client_name": "fxa-mcp-gateway", "redirect_uris": [redirect], "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"], "token_endpoint_auth_method": "none"}))
    resources = sorted(issuer_of)
    init = {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
        "protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "fxa-mcp-gateway", "version": "1"}}}
    refresh = {}
    # The server binds a sign-in to one resource, so each URL gets its own.
    for i, resource in enumerate(resources, 1):
        meta, srv, redirect, client = servers[issuer_of[resource]]
        got.clear()
        verifier = secrets.token_urlsafe(64)
        challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
        state = secrets.token_urlsafe(16)
        url = meta["authorization_endpoint"] + "?" + urllib.parse.urlencode({
            "response_type": "code", "client_id": client["client_id"], "redirect_uri": redirect, "scope": "mcp:proxy",
            "code_challenge": challenge, "code_challenge_method": "S256", "state": state, "resource": resource})
        names = ", ".join(n for n, u in mine.items() if u == resource)
        sys.stderr.write("Sign-in %d of %d (%s). If the browser does not open, visit:\n%s\n" % (i, len(resources), names, url))
        webbrowser.open(url)
        while "code" not in got and "error" not in got:
            srv.handle_request()
        if got.get("state") != state or "code" not in got:
            sys.exit("oauth-login: sign-in failed: %s" % (got.get("error_description") or got.get("error", "state mismatch")))
        try:
            tok = post(meta["token_endpoint"], {
                "grant_type": "authorization_code", "code": got["code"], "redirect_uri": redirect,
                "client_id": client["client_id"], "code_verifier": verifier, "resource": resource}, form=True)
        except urllib.error.HTTPError as e:
            err = json.loads(e.read() or b"{}")
            sys.exit("oauth-login: token exchange refused (HTTP %d): %s" % (e.code, err.get("error_description") or err.get("error")))
        if not tok.get("refresh_token"):
            sys.exit("oauth-login: the server issued no refresh token")
        refresh[resource] = tok["refresh_token"]
        req = urllib.request.Request(resource, json.dumps(init).encode(), {
            "content-type": "application/json", "accept": "application/json, text/event-stream",
            "authorization": "Bearer " + tok["access_token"]})
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                status = r.status
        except urllib.error.HTTPError as e:
            status = e.code
        except OSError as e:
            status = e.__class__.__name__
        sys.stderr.write("%s: HTTP %s\n" % (names, status))

    out = {"refresh_tokens": refresh,
           "clients": {r: {"token_endpoint": servers[issuer_of[r]][0]["token_endpoint"],
                           "client_id": servers[issuer_of[r]][3]["client_id"]} for r in resources if issuer_of[r] != ISSUER}}
    if ISSUER in servers:  # the top-level pair stays Runlayer's, for the connectors with no clients entry
        out.update(token_endpoint=servers[ISSUER][0]["token_endpoint"], client_id=servers[ISSUER][3]["client_id"])
    json.dump(out, sys.stdout)


if __name__ == "__main__":
    main()
