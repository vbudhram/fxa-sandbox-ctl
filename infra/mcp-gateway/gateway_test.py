#!/usr/bin/env python3
"""Offline check for gateway.py against a fake upstream MCP server:
python3 infra/mcp-gateway/gateway_test.py"""
import base64
import http.client
import http.server
import json
import os
import re
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
CALLS = []  # (path, method, params, headers) of every upstream request
MODE = {"sse": False, "expire": False}
OAUTH = {"refresh": "rt-0", "access": None, "n": 0}  # the fake token endpoint's current pair
SESSIONS = [0]
TOOLS = [
    {"name": "read_issue", "description": "Read an issue", "inputSchema": {"type": "object", "properties": {"key": {}, "fields": {}}}},
    {"name": "search", "description": "Search", "inputSchema": {"type": "object", "properties": {"jql": {}}}},
    {"name": "write_issue", "description": "Write", "inputSchema": {"type": "object", "properties": {"key": {}}}},
    {"name": "get_pr", "description": "A PR", "inputSchema": {"type": "object", "properties": {"owner": {}, "repo": {}}}},
    {"name": "get_sentry_resource", "description": "A Sentry issue", "inputSchema": {"type": "object", "properties": {"resourceId": {}}}},
]
# A Sentry issue as mcp.sentry.dev formats it, with every kind of personal data seen there (fake values).
SENTRY_TEXT = """**Event ID**: dcdf9d1d5b2f4c6cb38bbe602c10f986
**Culprit**: POST /v1/session/destroy
Error: account user@example.com not found for +15555550100
**URL:** https://accounts.firefox.com/oauth?client_id=5882386c6d801776&email=other%40example.com&login_hint=x&code=abc123
### User
**user**: id:0123456789abcdef0123456789abcdef, email:user@example.com, ip:203.0.113.7
**user.geo**: IR, Mashhad, 09
**user.id**: 0123456789abcdef0123456789abcdef
- **user.email**: user@example.com
**release**: 1.346.7
**request_headers**: {
  "x-forwarded-for": "203.0.113.7, 198.51.100.2",
  "x-sigsci-client-geo-city": "mashhad",
  "x-sigsci-client-geo-country-code": "IR",
  "client-ja3": "6f7889b9fb1a62a9577e685c1fcfa919",
  "client-ja4": "t13d1717h2_5b57614c22b0_3cbfd9057e0d",
  "ohfp": "aB:a6:aT:aR",
  "h2fp": "1:65536;2:0",
  "cookie": "session=abc",
  "fastly-ff": "08cnrWzA=!FRA!cache-fra-1",
  "x-forwarded-server": "cache-fra-1",
  "asn": "31549",
  "user-agent": "Mozilla/5.0 Firefox/140.0"
}
**hapi_event**: {"uid": "0123456789abcdef0123456789abcdef", "user": {"id": "fedcba9876543210fedcba9876543210", "name": "Pat"}}
sessionToken 00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff
Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.c2lnbmF0dXJlLXZhbHVl
peer 2001:db8::8a2e:370:7334 and 2001:0db8:85a3:0000:0000:8a2e:0370:7334
/fxa/node_modules/@opentelemetry/instrumentation-hapi/build/src/instrumentation.js:257:28
trace_id: "94addfbdc1cffcef54f4f8031488e103" at 13:03:47.566 on Debian 12.14
**headers**: [["Cookie", "session=xyz"], ["Authorization", "Token abcdefghijkl"]]
Cookie: sid=qqq
"""
SENTRY_PII = ["user@example.com", "other%40example.com", "+15555550100", "203.0.113.7", "198.51.100.2", "6f7889b9",
              "t13d1717", "aB:a6", "65536", "session=abc", "00112233445566778899", "eyJhbGci", "2001:db8", "2001:0db8", "abc123", "session=xyz",
              "abcdefghijkl", "sid=qqq"]
# Slack readers debug with these, so the gateway leaves them; finish keeps them out of GitHub.
SENTRY_KEEP = ["dcdf9d1d5b2f4c6cb38bbe602c10f986", "POST /v1/session/destroy", "1.346.7", "client_id=5882386c6d801776",
               "Firefox/140.0", "@opentelemetry/instrumentation-hapi", "instrumentation.js:257:28",
               "94addfbdc1cffcef54f4f8031488e103", "13:03:47.566", "Debian 12.14", "id:0123456789abcdef0123456789abcdef",
               "IR, Mashhad, 09", "mashhad", "fedcba9876543210fedcba9876543210", "FRA", "31549"]


class Upstream(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def send(self, code, doc=None, headers=None):
        if doc is not None and MODE["sse"]:
            note = {"jsonrpc": "2.0", "method": "notifications/progress", "params": {}}
            body = ("event: message\ndata: %s\n\nevent: message\ndata: %s\n\n" % (json.dumps(note), json.dumps(doc))).encode()
            ctype = "text/event-stream"
        else:
            body, ctype = (json.dumps(doc).encode() if doc is not None else b""), "application/json"
        self.send_response(code)
        self.send_header("content-type", ctype)
        self.send_header("content-length", str(len(body)))
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        body = self.rfile.read(int(self.headers["content-length"]))
        if self.path == "/token":
            form = urllib.parse.parse_qs(body.decode())
            if (form.get("grant_type") != ["refresh_token"] or form.get("refresh_token") != [OAUTH["refresh"]] or form.get("client_id") != ["c2"]
                    or not form.get("resource", [""])[0].endswith("/oauth")):
                return self.send(400, {"error": "invalid_grant", "error_description": "Refresh token expired"})
            OAUTH["n"] += 1
            OAUTH.update(refresh="rt-%d" % OAUTH["n"], access="at-%d" % OAUTH["n"])
            return self.send(200, {"access_token": OAUTH["access"], "refresh_token": OAUTH["refresh"], "expires_in": 3600})
        if self.path == "/oauth" and self.headers.get("Authorization") != "Bearer %s" % OAUTH["access"]:
            return self.send(401, {"error": "invalid_token"})
        msg = json.loads(body)
        CALLS.append((self.path, msg.get("method"), msg.get("params"), dict(self.headers)))
        method, mid = msg.get("method"), msg.get("id")
        if method == "initialize":
            SESSIONS[0] += 1
            return self.send(200, {"jsonrpc": "2.0", "id": mid, "result": {"protocolVersion": "2025-06-18", "capabilities": {"tools": {}},
                             "serverInfo": {"name": "fake"}}}, {"mcp-session-id": "s%d" % SESSIONS[0]})
        if not self.headers.get("mcp-session-id"):
            return self.send(400, {"error": "no session"})
        if MODE["expire"]:
            MODE["expire"] = False
            return self.send(404, {"error": "session expired"})
        if mid is None:
            return self.send(202)
        if method == "tools/list":
            return self.send(200, {"jsonrpc": "2.0", "id": mid, "result": {"tools": TOOLS}})
        if method == "tools/call":
            args = msg["params"]["arguments"]
            text = json.dumps({"tool": msg["params"]["name"], "args": args})
            # Like Jira, the security level comes back only when fields asks for it.
            if args.get("key") == "FXA-SEC" and "security" in (args.get("fields") or []):
                text = '{"key": "FXA-SEC", "fields": {"security": {"name": "Embargoed"}}}'
            if args.get("key") == "FXA-H1" and "labels" in (args.get("fields") or []):
                text = '{"key": "FXA-H1", "fields": {"summary": "Takeover", "labels": ["no-sync", "HackerOne"]}}'
            if args.get("key") == "FXA-h1" and "labels" in (args.get("fields") or []):
                text = '{"key": "FXA-h1", "fields": {"summary": "Lowercase", "labels": ["hackerone"]}}'
            if args.get("key") == "FXA-S" and "labels" in (args.get("fields") or []):
                text = '{"key": "FXA-S", "fields": {"labels": ["security"]}}'
            if self.path == "/sentry":
                return self.send(200, {"jsonrpc": "2.0", "id": mid, "result": {
                    "content": [{"type": "text", "text": SENTRY_TEXT}, {"type": "image", "data": "a+15555550100/203.0.113.7"}],
                    "structuredContent": {"eventId": "e1", "user": {"email": "user@example.com", "id": "u1"}, "tags": [{"geo.city": "Mashhad"}]}}})
            return self.send(200, {"jsonrpc": "2.0", "id": mid, "result": {"content": [{"type": "text", "text": text}]}})
        self.send(200, {"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": "nope"}})


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


class GatewayTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.dir = tempfile.mkdtemp()
        os.makedirs(os.path.join(cls.dir, "tokens"))
        up = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Upstream)
        threading.Thread(target=up.serve_forever, daemon=True).start()
        base = "http://127.0.0.1:%d" % up.server_port
        auth = {"Authorization": "Bearer ${RUNLAYER_AGENT_TOKEN}"}
        conf = {"connectors": {
            "jira": {"url": base + "/jira", "headers": auth, "tools": ["read_issue", "search"], "tool_note": "Projects: FXA.",
                     "rules": [{"tool": "search", "arg": "jql", "jql_project": "FXA", "exclude_labels": ["HackerOne", "security"]},
                               {"arg": "fields", "include": ["security", "labels"], "deny": ["issuelinks"], "default": ["summary"]}],
                     "deny_result": ["\"security\"\\s*:\\s*\\{", "(?i)\"labels\"\\s*:\\s*\\[[^\\]]*\"(HackerOne|security)\""]},
            "github": {"url": base + "/github", "headers": auth, "tools": ["get_pr"],
                       "rules": [{"arg": "owner", "equals": "mozilla"}, {"arg": "repo", "equals": "fxa"},
                                 {"tool": "get_pr", "arg": "url", "drop": True}]},
            "slack": {"url": base + "/slack", "headers": {"Authorization": "Bearer ${UNSET_SLACK_TOKEN}"}, "tools": ["read_issue"]},
            "sentry": dict(json.load(open(os.path.join(HERE, "connectors.example.json")))["connectors"]["sentry"],
                           url=base + "/sentry", headers=auth, tools=["get_sentry_resource"]),
            "figma": {"url": base + "/oauth", "headers": {"Authorization": "Bearer ${RUNLAYER_OAUTH_TOKEN}"}, "tools": ["read_issue"]},
        }}
        cls.oauth = os.path.join(cls.dir, "oauth.json")
        with open(cls.oauth, "w") as f:
            json.dump({"token_endpoint": base + "/no-token", "client_id": "c1", "refresh_tokens": {base + "/oauth": "rt-0"},
                       "clients": {base + "/oauth": {"token_endpoint": base + "/token", "client_id": "c2"}}}, f)
        cfg = os.path.join(cls.dir, "gateway.json")
        with open(cfg, "w") as f:
            json.dump(conf, f)
        cls.port = free_port()
        env = dict(os.environ, MCP_GATEWAY_DIR=cls.dir, MCP_GATEWAY_CONFIG=cfg, RUNLAYER_AGENT_TOKEN="rl-secret", MCP_GATEWAY_OAUTH=cls.oauth,
                   FXA_ERRORS_FILE=os.path.join(cls.dir, "errors.jsonl"),
                   MCP_GATEWAY_LISTEN="127.0.0.1:%d" % cls.port)
        env.pop("UNSET_SLACK_TOKEN", None)
        cls.proc = subprocess.Popen([sys.executable, os.path.join(HERE, "gateway.py")], env=env, stderr=subprocess.DEVNULL)
        # Up to 30 s: a busy CI runner took more than the old 5 s, and the first tests then met a closed port.
        for _ in range(300):
            try:
                socket.create_connection(("127.0.0.1", cls.port), 0.1).close()
                break
            except OSError:
                if cls.proc.poll() is not None:
                    raise RuntimeError(f"the server under test exited with {cls.proc.returncode} before it listened")
                time.sleep(0.1)
        else:
            raise RuntimeError("the server under test did not listen within 30 s")

    @classmethod
    def tearDownClass(cls):
        cls.proc.terminate()

    def setUp(self):
        MODE.update(sse=False, expire=False)

    def token(self, name, connectors=("jira", "github", "slack"), cap=100):
        tok = "fxm_" + (name * 32)[:32]
        with open(os.path.join(self.dir, "tokens", tok + ".json"), "w") as f:
            json.dump({"run": name, "created": 0, "expires": time.time() + 60, "connectors": list(connectors),
                       "cap_calls": cap, "calls": 0}, f)
        return tok

    def rpc(self, tok, method, params=None, mid=1):
        c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        msg = {"jsonrpc": "2.0", "method": method, "params": params or {}}
        if mid is not None:
            msg["id"] = mid
        c.request("POST", "/mcp", body=json.dumps(msg), headers={"authorization": "Bearer " + tok, "content-type": "application/json"})
        r = c.getresponse()
        body = r.read()
        c.close()
        return r.status, (json.loads(body) if body else None)

    def call(self, tok, name, args):
        status, doc = self.rpc(tok, "tools/call", {"name": name, "arguments": args})
        self.assertEqual(status, 200)
        return doc["result"]

    def upstream_calls(self, path):
        return [c for c in CALLS if c[0] == path and c[1] == "tools/call"]

    def test_unknown_or_expired_token_is_refused(self):
        self.assertEqual(self.rpc("fxm_" + "z" * 32, "tools/list")[0], 401)
        self.assertEqual(self.rpc("rl-secret", "tools/list")[0], 401)
        tok = self.token("x")
        with open(os.path.join(self.dir, "tokens", tok + ".json"), "w") as f:
            json.dump({"run": "x", "expires": 0, "connectors": ["jira"]}, f)
        self.assertEqual(self.rpc(tok, "tools/list")[0], 401)

    def test_an_llm_proxy_token_is_refused_and_no_token_reaches_a_log(self):
        tok = self.token("l")
        self.assertEqual(self.rpc(tok, "tools/list")[0], 200)
        llm = "fxl_" + tok[4:]
        os.rename(os.path.join(self.dir, "tokens", tok + ".json"), os.path.join(self.dir, "tokens", llm + ".json"))
        self.assertEqual(self.rpc(llm, "tools/list")[0], 401)
        for root, _, files in os.walk(self.dir):
            for n in files:
                if os.path.basename(root) != "tokens":
                    with open(os.path.join(root, n), errors="replace") as f:
                        self.assertNotIn(tok[4:], f.read(), n)

    def test_initialize_and_notifications(self):
        tok = self.token("a")
        status, doc = self.rpc(tok, "initialize", {"protocolVersion": "2025-03-26"})
        self.assertEqual(status, 200)
        self.assertEqual(doc["result"]["protocolVersion"], "2025-03-26")
        self.assertEqual(self.rpc(tok, "notifications/initialized", mid=None), (202, None))

    def test_tools_list_is_the_granted_allowlist_only(self):
        names = [t["name"] for t in self.rpc(self.token("b", ["jira"]), "tools/list")[1]["result"]["tools"]]
        self.assertEqual(names, ["jira__read_issue", "jira__search"])  # no write_issue, no github
        desc = self.rpc(self.token("bn", ["jira"]), "tools/list")[1]["result"]["tools"][0]["description"]
        self.assertTrue(desc.startswith("[jira, read-only] Projects: FXA. "), desc)  # the private note leads
        names = [t["name"] for t in self.rpc(self.token("c"), "tools/list")[1]["result"]["tools"]]
        self.assertNotIn("slack__read_issue", names)  # its credential is unset, so the connector is off

    def test_the_upstream_sees_its_credential_never_the_run_token(self):
        tok = self.token("d")
        self.call(tok, "jira__read_issue", {"key": "FXA-1"})
        headers = self.upstream_calls("/jira")[-1][3]
        self.assertEqual(headers.get("Authorization"), "Bearer rl-secret")

    def test_a_tool_off_the_allowlist_never_reaches_the_upstream(self):
        tok = self.token("e")
        before = len(self.upstream_calls("/jira"))
        result = self.call(tok, "jira__write_issue", {"key": "FXA-1"})
        self.assertTrue(result["isError"])
        self.assertEqual(len(self.upstream_calls("/jira")), before)

    def test_a_connector_not_granted_is_refused(self):
        result = self.call(self.token("f", ["jira"]), "github__get_pr", {"owner": "mozilla", "repo": "fxa"})
        self.assertTrue(result["isError"])

    def test_jql_is_scoped_to_the_project(self):
        tok = self.token("g")
        self.call(tok, "jira__search", {"jql": 'text ~ "order by" ORDER BY created DESC'})
        self.assertEqual(self.upstream_calls("/jira")[-1][2]["arguments"]["jql"],
                         'project = FXA AND level IS EMPTY AND (labels IS EMPTY OR labels NOT IN ("HackerOne", "hackerone", "HACKERONE", "Hackerone", "security", "SECURITY", "Security")) AND (text ~ "order by") ORDER BY created DESC')
        self.call(tok, "jira__search", {"jql": ""})
        self.assertEqual(self.upstream_calls("/jira")[-1][2]["arguments"]["jql"], "project = FXA AND level IS EMPTY AND (labels IS EMPTY OR labels NOT IN (\"HackerOne\", \"hackerone\", \"HACKERONE\", \"Hackerone\", \"security\", \"SECURITY\", \"Security\"))")

    def test_jql_that_escapes_its_group_is_refused(self):
        tok = self.token("h")
        before = len(self.upstream_calls("/jira"))
        for jql in ['a = 1) OR project = SEC OR (b = 2', 'summary ~ "x', "a = 1 ORDER BY x) OR (y"]:
            self.assertTrue(self.call(tok, "jira__search", {"jql": jql})["isError"], jql)
        self.assertEqual(len(self.upstream_calls("/jira")), before)

    def test_argument_values_are_pinned(self):
        tok = self.token("i")
        self.assertFalse(self.call(tok, "github__get_pr", {"owner": "Mozilla", "repo": "fxa"}).get("isError"))
        self.assertTrue(self.call(tok, "github__get_pr", {"owner": "mozilla", "repo": "other"})["isError"])
        self.assertTrue(self.call(tok, "github__get_pr", {"repo": "fxa"})["isError"])  # a missing owner is not a pass

    def test_a_dropped_argument_never_reaches_the_upstream(self):
        self.call(self.token("dr"), "github__get_pr", {"owner": "mozilla", "repo": "fxa", "url": "https://example.com/other"})
        self.assertNotIn("url", self.upstream_calls("/github")[-1][2]["arguments"])

    def test_sentry_answers_lose_secrets_and_contact_data_and_keep_debug_data(self):
        result = self.call(self.token("se", ("sentry",)), "sentry__get_sentry_resource", {"resourceType": "issue", "resourceId": "FXA-AUTH-1"})
        text = result["content"][0]["text"] + json.dumps(result["structuredContent"])
        for v in SENTRY_PII:
            self.assertNotIn(v, text)
        for v in SENTRY_KEEP:
            self.assertIn(v, text)
        self.assertEqual(result["structuredContent"]["eventId"], "e1")
        self.assertEqual(result["structuredContent"]["user"], {"email": "[redacted]", "id": "u1"})
        self.assertEqual(result["content"][1]["data"], "a+15555550100/203.0.113.7")  # an image is bytes, not text

    def test_the_sentry_patterns_stay_fast_on_a_long_run(self):
        sys.path.insert(0, HERE)
        import gateway
        c = json.load(open(os.path.join(HERE, "connectors.example.json")))["connectors"]["sentry"]
        pats = [(re.compile(p), r) for p, r in c["redact"]]
        t0 = time.time()
        out = gateway.scrub("a" * 200000 + " x a.b@ex.com", pats, None)
        self.assertLess(time.time() - t0, 1.0)
        self.assertTrue(out.endswith("x [email]"))

    def test_a_matching_answer_is_withheld(self):
        result = self.call(self.token("j"), "jira__read_issue", {"key": "FXA-SEC"})
        self.assertTrue(result["isError"])
        self.assertNotIn("Embargoed", json.dumps(result))
        result = self.call(self.token("j2"), "jira__read_issue", {"key": "FXA-H1"})
        self.assertTrue(result["isError"])
        self.assertNotIn("Takeover", json.dumps(result))
        result = self.call(self.token("j3"), "jira__read_issue", {"key": "FXA-S"})
        self.assertTrue(result["isError"])

    def test_a_label_in_any_case_is_withheld(self):
        result = self.call(self.token("lc"), "jira__read_issue", {"key": "FXA-h1"})
        self.assertTrue(result["isError"])
        self.assertNotIn("Lowercase", json.dumps(result))

    def test_fields_that_show_other_issues_are_refused(self):
        tok = self.token("lf")
        before = len(self.upstream_calls("/jira"))
        for fields in (["summary", "issuelinks"], ["*all"], ["*navigable"]):
            self.assertTrue(self.call(tok, "jira__read_issue", {"key": "FXA-1", "fields": fields})["isError"], fields)
        self.assertEqual(len(self.upstream_calls("/jira")), before)

    def test_an_exclusion_of_a_required_field_is_dropped(self):
        self.call(self.token("ex"), "jira__read_issue", {"key": "FXA-1", "fields": ["summary", "-labels", "-security"]})
        self.assertEqual(self.upstream_calls("/jira")[-1][2]["arguments"]["fields"], ["summary", "security", "labels"])

    def test_a_list_argument_always_includes_its_values(self):
        tok = self.token("q")
        self.assertTrue(self.call(tok, "jira__read_issue", {"key": "FXA-SEC", "fields": ["summary"]})["isError"])
        self.call(tok, "jira__read_issue", {"key": "FXA-1"})
        self.assertEqual(self.upstream_calls("/jira")[-1][2]["arguments"]["fields"], ["summary", "security", "labels"])
        self.call(tok, "jira__read_issue", {"key": "FXA-1", "fields": ["status", "security"]})
        self.assertEqual(self.upstream_calls("/jira")[-1][2]["arguments"]["fields"], ["status", "security", "labels"])

    def test_a_run_past_its_cap_is_refused(self):
        tok = self.token("k", cap=2)
        self.assertFalse(self.call(tok, "jira__read_issue", {"key": "FXA-1"}).get("isError"))
        self.assertFalse(self.call(tok, "jira__read_issue", {"key": "FXA-2"}).get("isError"))
        self.assertIn("cap", self.call(tok, "jira__read_issue", {"key": "FXA-3"})["content"][0]["text"])

    def test_a_streamed_answer_is_read(self):
        MODE["sse"] = True
        result = self.call(self.token("l"), "jira__read_issue", {"key": "FXA-7"})
        self.assertIn("FXA-7", result["content"][0]["text"])

    def test_an_expired_upstream_session_is_renewed(self):
        tok = self.token("m")
        self.call(tok, "jira__read_issue", {"key": "FXA-1"})
        inits = SESSIONS[0]
        MODE["expire"] = True
        self.assertFalse(self.call(tok, "jira__read_issue", {"key": "FXA-2"}).get("isError"))
        self.assertEqual(SESSIONS[0], inits + 1)

    def test_an_oauth_connector_keeps_the_rotated_refresh_token(self):
        tok = self.token("r", ["figma"])
        self.assertFalse(self.call(tok, "figma__read_issue", {"key": "FXA-1"}).get("isError"))
        self.assertEqual(self.upstream_calls("/oauth")[-1][3]["Authorization"], "Bearer " + OAUTH["access"])
        with open(self.oauth) as f:
            self.assertEqual(list(json.load(f)["refresh_tokens"].values()), [OAUTH["refresh"]])
        OAUTH["access"] = "revoked"  # the upstream refuses the token; the gateway renews it once
        self.assertFalse(self.call(tok, "figma__read_issue", {"key": "FXA-2"}).get("isError"))
        with open(self.oauth) as f:
            self.assertEqual(list(json.load(f)["refresh_tokens"].values()), [OAUTH["refresh"]])

    def test_a_withheld_answer_and_a_refused_sign_in_reach_the_error_log(self):
        self.call(self.token("s"), "jira__read_issue", {"key": "FXA-SEC"})
        tok = self.token("t", ["figma"])
        saved = dict(OAUTH)
        OAUTH.update(access="revoked", refresh="gone")  # the refresh token no longer works
        self.assertTrue(self.call(tok, "figma__read_issue", {"key": "FXA-1"})["isError"])
        self.assertTrue(self.call(tok, "figma__read_issue", {"key": "FXA-2"})["isError"])
        OAUTH.update(saved)
        with open(os.path.join(self.dir, "errors.jsonl")) as f:
            lines = f.read().splitlines()
        rows = [r for r in map(json.loads, lines) if r["key"] in ("s", None)]  # other tests withhold too
        self.assertEqual([(r["source"], r["kind"], r["key"]) for r in rows], [("gateway", "withheld", "s"), ("gateway", "oauth", None)])
        self.assertIn("manager.sh oauth", rows[1]["message"])
        # It names the connector and its exact sign-in command first (the DM shows 180 characters),
        # then why the server refused, and never a refresh token.
        self.assertTrue(rows[1]["message"].startswith("figma: the OAuth server refused the gateway's refresh token; run FXA_OAUTH_ONLY=figma bash infra/gce/manager.sh oauth"))
        self.assertIn("HTTP 400 invalid_grant: Refresh token expired", rows[1]["message"])
        self.assertNotIn("gone", rows[1]["message"])
        self.assertTrue(all('"sig":"' in l for l in lines))  # errors resolve greps compact JSON

    def test_every_call_is_audited(self):
        tok = self.token("n")
        self.call(tok, "jira__write_issue", {"key": "FXA-1"})
        self.call(tok, "jira__read_issue", {"key": "FXA-1"})
        with open(os.path.join(self.dir, "calls.jsonl")) as f:
            mine = [json.loads(l) for l in f if '"run": "n"' in l]
        self.assertEqual([l["outcome"] for l in mine], ["denied:tool", "ok"])


class Trim(unittest.TestCase):
    """prune_keys and max_result_bytes: the same answer is cut the same way every time."""

    @classmethod
    def setUpClass(cls):
        sys.path.insert(0, HERE)
        import gateway
        cls.g = gateway

    def test_pruned_keys_go_at_any_depth_and_the_rest_stays(self):
        body = {"status": 200, "body": {"metadata": {"name": "fxa", "managedFields": [{"x": 1}],
                "annotations": {"kubectl.kubernetes.io/last-applied-configuration": "{...}", "team": "fxa"}},
                "items": [{"liveState": "a", "normalizedLiveState": "a"}]}}
        result = {"content": [{"type": "text", "text": json.dumps(body)}, {"type": "text", "text": "not json"}]}
        keys = re.compile("managedFields|kubectl\\.kubernetes\\.io/last-applied-configuration|normalizedLiveState")
        out = self.g.prune(result, keys)
        self.assertEqual(json.loads(out["content"][0]["text"]), {"status": 200, "body": {"metadata": {"name": "fxa",
                         "annotations": {"team": "fxa"}}, "items": [{"liveState": "a"}]}})
        self.assertEqual(out["content"][1]["text"], "not json")

    def test_list_entries_that_match_a_pattern_go(self):
        res = [{"kind": "A", "status": "Synced", "health": {"status": "Healthy"}},
               {"kind": "B", "status": "Synced"},
               {"kind": "C", "health": {"status": "Healthy"}},
               {"kind": "D", "status": "Synced", "health": {"status": "Degraded", "message": "x"}},
               {"kind": "E", "status": "OutOfSync", "health": {"status": "Healthy"}}]
        pats = [{"status": "Synced", "health": {"status": "Healthy"}}, {"status": "Synced", "health": None},
                {"status": None, "health": {"status": "Healthy"}}]
        result = {"content": [{"type": "text", "text": json.dumps({"body": {"status": {"resources": res, "health": {"status": "Degraded"}}}})}]}
        out = json.loads(self.g.prune(result, None, pats)["content"][0]["text"])
        self.assertEqual([r["kind"] for r in out["body"]["status"]["resources"]], ["D", "E"])
        self.assertEqual(out["body"]["status"]["health"], {"status": "Degraded"})  # only list entries go

    def test_an_answer_over_the_limit_becomes_an_error_with_the_hint(self):
        big = {"content": [{"type": "text", "text": "x" * 5000}]}
        out = self.g.capped(big, 1000, "Ask for one resource.")
        self.assertTrue(out["isError"])
        self.assertIn("Ask for one resource.", out["content"][0]["text"])
        self.assertIs(self.g.capped(big, 0, ""), big)
        self.assertIs(self.g.capped(big, 10000, ""), big)


class ArgoRules(unittest.TestCase):
    """The ArgoCD connector's rules from connectors.example.json: reads of FxA apps only."""

    @classmethod
    def setUpClass(cls):
        sys.path.insert(0, HERE)
        import gateway
        cls.g = gateway
        cls.rules = json.load(open(os.path.join(HERE, "connectors.example.json")))["connectors"]["argocd"]["rules"]
        cls.schema = {"properties": {"method": {}, "path": {}, "query_params": {}, "body": {}}}

    def run_rules(self, args):
        return self.g.apply_rules(self.rules, "execute_operation", self.schema, args)

    def test_a_read_of_an_fxa_app_passes_as_a_get_with_no_body(self):
        out = self.run_rules({"method": "POST", "path": "/api/v1/applications/fxa-example-app/sync", "body": "{}"})
        self.assertEqual((out["method"], "body" in out), ("GET", False))

    def test_a_refresh_is_refused_and_other_query_params_pass(self):
        path = "/api/v1/applications/fxa-example-app"
        for q in ('{"refresh":"hard"}', '{"Refresh": "normal"}'):
            with self.assertRaises(self.g.Denied, msg=q):
                self.run_rules({"method": "GET", "path": path, "query_params": q})
        self.assertEqual(self.run_rules({"method": "GET", "path": path + "/pods/p1/logs", "query_params": '{"tailLines":"50"}'})["query_params"], '{"tailLines":"50"}')
        self.assertNotIn("query_params", self.run_rules({"method": "GET", "path": path}))
        self.assertEqual(self.run_rules({"method": "GET", "path": path, "query_params": '{"refresh": "false"}'})["query_params"], '{"refresh": "false"}')

    def test_other_apps_a_list_and_a_climb_out_are_refused(self):
        for path in ("/api/v1/applications/other-example-app", "/api/v1/applications",
                     "/api/v1/applications/fxa-example-app/../../clusters", "/api/v1/clusters", None):
            with self.assertRaises(self.g.Denied, msg=path):
                self.run_rules({"method": "GET", "path": path})


class TeamScope(unittest.TestCase):
    """A team's token scope: its own Jira projects and repos replace the connector's FxA ones."""

    @classmethod
    def setUpClass(cls):
        sys.path.insert(0, HERE)
        import gateway
        cls.g = gateway
        conns = json.load(open(os.path.join(HERE, "connectors.example.json")))["connectors"]
        cls.jira, cls.github = conns["jira"]["rules"], conns["github"]["rules"]
        cls.gschema = {"properties": {"owner": {}, "repo": {}}}

    def test_a_team_reads_its_own_slack_channels_not_fxas(self):
        slack = [{"arg": "channel_id", "one_of": ["CFXA0001"]}]
        rules = self.g.team_rules(slack, {"jira_projects": ["STOR"], "slack_channels": ["CSTOR1234", "bad id"]})
        self.assertEqual(self.g.apply_rules(rules, "slack_read_thread", {"properties": {"channel_id": {}}}, {"channel_id": "CSTOR1234"})["channel_id"], "CSTOR1234")
        with self.assertRaises(self.g.Denied):
            self.g.apply_rules(rules, "slack_read_thread", {"properties": {"channel_id": {}}}, {"channel_id": "CFXA0001"})
        self.assertEqual(self.g.team_rules(slack, {"repos": ["mozilla/fxa"]}), slack)

    def test_no_scope_keeps_the_rules_as_written(self):
        self.assertIs(self.g.team_rules(self.github, None), self.github)
        out = self.g.apply_rules(self.g.team_rules(self.jira, None), "searchJiraIssuesUsingJql", {}, {"jql": "status = Open"})
        self.assertTrue(out["jql"].startswith("project = FXA AND level IS EMPTY"))

    def test_fxa_with_repos_and_no_project_keeps_its_jira_rules(self):
        out = self.g.apply_rules(self.g.team_rules(self.jira, {"jira_projects": [], "repos": ["mozilla/fxa"]}), "searchJiraIssuesUsingJql", {}, {"jql": "x = 1"})
        self.assertTrue(out["jql"].startswith("project = FXA AND level IS EMPTY AND (labels IS EMPTY OR labels NOT IN"))

    def test_a_team_searches_its_own_projects_and_keeps_the_label_and_security_rules(self):
        rules = self.g.team_rules(self.jira, {"jira_projects": ["PAY", "ENT"]})
        out = self.g.apply_rules(rules, "searchJiraIssuesUsingJql", {}, {"jql": "status = Open"})
        self.assertTrue(out["jql"].startswith("project in (PAY, ENT) AND level IS EMPTY AND (labels IS EMPTY OR labels NOT IN"))
        self.assertIn("(status = Open)", out["jql"])

    def test_a_bad_project_in_the_scope_is_ignored(self):
        rules = self.g.team_rules(self.jira, {"jira_projects": ["PAY) OR (project = SEC"]})
        out = self.g.apply_rules(rules, "searchJiraIssuesUsingJql", {}, {"jql": "x = 1"})
        self.assertTrue(out["jql"].startswith("project = FXA "))

    def test_a_team_reads_its_repos_as_owner_and_repo_together(self):
        rules = self.g.team_rules(self.github, {"repos": ["mozilla/PyFxA", "mozilla-services/syncstorage-rs"]})
        ok = lambda o, r: self.g.apply_rules(rules, "get_file_contents", self.gschema, {"owner": o, "repo": r})
        self.assertEqual(ok("mozilla", "pyfxa")["repo"], "pyfxa")
        self.assertEqual(ok("mozilla-services", "syncstorage-rs")["owner"], "mozilla-services")
        for o, r in (("mozilla", "fxa"), ("mozilla", "syncstorage-rs"), ("mozilla-services", "PyFxA")):
            with self.assertRaises(self.g.Denied):
                ok(o, r)

    def test_the_pair_rule_binds_every_tool_even_when_the_first_repo_rule_is_bound_to_one(self):
        rules = [{"tool": "get_job_logs", "arg": "repo", "one_of": ["fxa"]}, {"arg": "owner", "equals": "mozilla"}, {"arg": "repo", "equals": "fxa"}]
        scoped = self.g.team_rules(rules, {"repos": ["mozilla/pyfxa"]})
        with self.assertRaises(self.g.Denied):
            self.g.apply_rules(scoped, "get_file_contents", self.gschema, {"owner": "evil", "repo": "private"})

    def test_a_team_reads_one_issue_only_in_its_projects(self):
        rules = self.g.team_rules(self.jira, {"jira_projects": ["PAY"]})
        schema = {"properties": {"issueIdOrKey": {}, "cloudId": {}, "fields": {}}}
        self.assertEqual(self.g.apply_rules(rules, "getJiraIssue", schema, {"issueIdOrKey": "PAY-12"})["issueIdOrKey"], "PAY-12")
        for key in ("FXA-1", "12345", "PAY-1 OR x"):
            with self.assertRaises(self.g.Denied):
                self.g.apply_rules(rules, "getJiraIssue", schema, {"issueIdOrKey": key})

class GitHubAppConnector(unittest.TestCase):
    """The gateway's own GitHub tools: a read-only token for one repo, minted with the App key."""
    SEEN = []

    @classmethod
    def setUpClass(cls):
        sys.path.insert(0, HERE)
        import gateway
        cls.g = gateway
        seen = cls.SEEN

        class GH(http.server.BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def send(self, doc, code=200, raw=None):
                body = raw if raw is not None else json.dumps(doc).encode()
                self.send_response(code)
                self.send_header("content-length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_GET(self):
                seen.append(("GET", self.path, self.headers.get("authorization"), None))
                p = self.path
                if p == "/repos/mozilla/fxa/installation":
                    return self.send({"id": 7})
                if p == "/repos/mozilla/fxa/pulls/5":
                    return self.send({"title": "t", "state": "open", "head": {"ref": "b", "sha": "abc"}, "base": {"ref": "main"}, "body": "x" * 9000})
                if p.startswith("/repos/mozilla/fxa/commits/abc/check-runs") or p.startswith("/repos/mozilla/fxa/commits/main/check-runs"):
                    return self.send({"check_runs": [
                        {"id": 41, "name": "e2e", "status": "completed", "conclusion": "failure", "app": {"slug": "github-actions"}},
                        {"id": 42, "name": "lint", "status": "completed", "conclusion": "success", "app": {"slug": "github-actions"}},
                        {"id": 43, "name": "unit", "status": "completed", "conclusion": "success", "app": {"slug": "circleci-checks"},
                         "details_url": "https://circleci.com/gh/mozilla/fxa/711803"}]})
                if p.startswith("/repos/mozilla/fxa/check-runs/41/annotations"):
                    return self.send([{"path": "a.py", "start_line": 3, "message": "assert 1 == 2"}])
                if p in ("/repos/mozilla/fxa/commits/abc/status", "/repos/mozilla/fxa/commits/main/status"):
                    return self.send({"statuses": [{"context": "ci/circleci", "state": "failure", "target_url": "u"}]})
                if p == "/repos/mozilla/fxa/actions/jobs/41/logs":
                    self.send_response(302)
                    self.send_header("location", "http://127.0.0.1:%d/blob/41?sig=1" % self.server.server_port)
                    self.send_header("content-length", "0")
                    return self.end_headers()
                if p == "/blob/41?sig=1":
                    lines = ["2026-10-28T13:30:0%dZ line %d" % (i % 10, i) for i in range(300)]
                    lines[10] = "2026-10-28T13:30:00Z \x1b[31mFAILED\x1b[0m test_x - AssertionError"
                    return self.send(None, raw="\n".join(lines).encode())
                self.send({"message": "Not Found"}, 404)

            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers.get("content-length") or 0)) or b"null")
                seen.append(("POST", self.path, self.headers.get("authorization"), body))
                if self.path == "/app/installations/7/access_tokens":
                    return self.send({"token": "ghs_installation"})
                self.send({}, 404)

        srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), GH)
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        cls.dir = tempfile.mkdtemp()
        pem = os.path.join(cls.dir, "app.pem")
        subprocess.run(["openssl", "genrsa", "-out", pem, "2048"], check=True, capture_output=True)
        spec = {"type": "github-app", "api": "http://127.0.0.1:%d" % srv.server_port, "app_id": "123", "pem_file": pem,
                "tools": list(gateway.GH_TOOLS), "rules": [{"arg": "owner", "equals": "mozilla"}, {"arg": "repo", "equals": "fxa"}]}
        cls.up = gateway.GitHubApp("github", spec)

    def text(self, tool, **args):
        return self.up.rpc("tools/call", {"name": tool, "arguments": dict(owner="mozilla", repo="fxa", **args)})["content"][0]["text"]

    def test_the_token_is_for_one_repo_read_only_and_made_with_the_app_key(self):
        self.text("get_pull_request", pull_number=5)
        post = [s for s in self.SEEN if s[0] == "POST"][0]
        self.assertEqual(post[3], {"repositories": ["fxa"], "permissions": self.g.GH_READ})
        self.assertTrue(all(v == "read" for v in self.g.GH_READ.values()))
        self.assertEqual(post[2].split(".")[0], "Bearer " + base64.urlsafe_b64encode(b'{"alg":"RS256","typ":"JWT"}').rstrip(b"=").decode())
        self.assertIn(("GET", "/repos/mozilla/fxa/pulls/5", "Bearer ghs_installation", None), self.SEEN)

    def test_a_pr_body_is_cut(self):
        self.assertEqual(len(json.loads(self.text("get_pull_request", pull_number=5))["body"]), 8000)

    def test_checks_give_the_job_id_and_the_failed_annotations(self):
        out = json.loads(self.text("get_pull_request_checks", pull_number=5))
        self.assertEqual([(r["name"], r.get("job_id"), r.get("annotations")) for r in out["check_runs"]],
                         [("e2e", 41, [{"path": "a.py", "line": 3, "message": "assert 1 == 2"}]), ("lint", 42, None), ("unit", None, None)])
        self.assertEqual(out["statuses"][0]["context"], "ci/circleci")
        self.assertEqual(out["check_runs"][2]["details_url"], "https://circleci.com/gh/mozilla/fxa/711803")

    def test_commit_checks_read_a_branch_and_refuse_a_ref_that_climbs_or_queries(self):
        out = json.loads(self.text("get_commit_checks", ref="main"))
        self.assertEqual((out["ref"], out["check_runs"][2]["details_url"]), ("main", "https://circleci.com/gh/mozilla/fxa/711803"))
        n = len(self.SEEN)
        for ref in ("main/../../other", "main?x=1", "/main", "main#x", "", 5, None, "main\n"):
            with self.assertRaises(self.g.UpstreamError, msg=ref):
                self.text("get_commit_checks", ref=ref)
        self.assertEqual(len(self.SEEN), n)
        self.assertEqual(self.up.list_tools()["get_commit_checks"]["inputSchema"]["properties"]["ref"], {"type": "string"})

    def test_a_job_log_follows_its_redirect_without_the_token_and_keeps_the_failure(self):
        out = self.text("get_job_logs", job_id=41)
        blob = [s for s in self.SEEN if s[1].startswith("/blob/")][-1]
        self.assertIsNone(blob[2])
        self.assertIn("FAILED test_x - AssertionError", out.split("--- the end of the log:")[0])
        self.assertTrue(out.endswith("line 299"))
        self.assertNotIn("2026-10-28T", out)

    def test_bad_names_and_numbers_never_reach_github(self):
        n = len(self.SEEN)
        for args in ({"owner": "../x", "repo": "fxa", "pull_number": 5}, {"owner": "mozilla", "repo": "fxa", "pull_number": -1},
                     {"owner": "mozilla", "repo": "fxa", "pull_number": True}):
            with self.assertRaises(self.g.UpstreamError):
                self.up.rpc("tools/call", {"name": "get_pull_request", "arguments": args})
        self.assertEqual(len(self.SEEN), n)

    def test_the_team_rules_pin_owner_and_repo(self):
        schema = self.up.list_tools()["get_job_logs"]["inputSchema"]
        with self.assertRaises(self.g.Denied):
            self.g.apply_rules(self.g.team_rules(self.up.rules, None), "get_job_logs", schema, {"owner": "mozilla", "repo": "fxa-private", "job_id": 1})
        scoped = self.g.team_rules(self.up.rules, {"repos": ["mozilla-services/syncstorage-rs"]})
        self.assertEqual(self.g.apply_rules(scoped, "get_job_logs", schema, {"owner": "mozilla-services", "repo": "syncstorage-rs", "job_id": 1})["job_id"], 1)


class CircleCIConnector(unittest.TestCase):
    """The gateway's own CircleCI tools: one project per call, and the token only on CircleCI's own host."""
    SEEN = []  # (host, path, Circle-Token header) of every request to either fake host
    WF, WF_OTHER = "48a37f1d-c27d-4de2-af96-3b954c8b4be3", "0b6e0e8c-0000-4000-8000-000000000001"
    P1, P2, P3 = ("11111111-0000-4000-8000-00000000000%d" % i for i in (1, 2, 3))
    KEY = "-----BEGIN RSA PRIVATE KEY-----\nMIIEfakefakefake\nAAAA\n-----END RSA PRIVATE KEY-----"
    GHP = "ghp_" + "A1" * 18
    DIGEST = "sha256:" + "ab" * 32

    @classmethod
    def setUpClass(cls):
        sys.path.insert(0, HERE)
        import gateway
        cls.g = gateway
        seen, t = cls.SEEN, cls

        def server(routes, host):
            class H(http.server.BaseHTTPRequestHandler):
                def log_message(self, *a):
                    pass

                def do_GET(self):
                    seen.append((host, self.path, self.headers.get("circle-token")))
                    code, body, loc = routes(self.path)
                    body = body if isinstance(body, bytes) else json.dumps(body).encode()
                    self.send_response(code)
                    if loc:
                        self.send_header("location", loc)
                    self.send_header("content-length", str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)
            srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
            threading.Thread(target=srv.serve_forever, daemon=True).start()
            return "http://127.0.0.1:%d" % srv.server_port

        def store(p):
            if p == "/out/7":
                log = "\n".join(["\x1b[31mFAILED\x1b[0m test_x"] + ["line %d" % i for i in range(300)] + ["image " + t.DIGEST, "token " + t.GHP, t.KEY])
                return 200, [{"message": log}], None
            if p == "/signed/ec":
                return 200, b"# Error details: element(s) not found", None
            if p in ("/out/pw0", "/out/pw1"):
                flaky = ["⚠️ Flaky tests (1):", "  tests/a.spec.ts:signs in", ""] if p.endswith("1") else []
                return 200, [{"message": "\n".join(["Running 3 tests"] + ["ok %d" % i for i in range(40)] + flaky + ["3 passed"])}], None
            return 404, {}, None
        st = server(store, "store")

        def cci(p):
            # Two pages of main's pipelines: a push, a nightly, then a nightly on page 2.
            if p == "/api/v2/project/gh/mozilla/fxa/pipeline?branch=main":
                return 200, {"items": [{"id": t.P1, "number": 3, "state": "created", "trigger": {"type": "webhook"}, "vcs": {"revision": "a" * 40}},
                                       {"id": t.P2, "number": 2, "state": "created", "trigger": {"type": "schedule"}, "vcs": {"revision": "b" * 40}}],
                             "next_page_token": "pg2"}, None
            if p == "/api/v2/project/gh/mozilla/fxa/pipeline?branch=main&page-token=pg2":
                return 200, {"items": [{"id": t.P3, "number": 1, "state": "created", "trigger": {"type": "schedule"}, "vcs": {"revision": "c" * 40}}],
                             "next_page_token": None}, None
            if p.startswith("/api/v2/pipeline/") and p.endswith("/workflow"):
                return 200, {"items": [{"name": "nightly", "status": "failed" if t.P2 in p else "success", "id": t.WF}], "next_page_token": None}, None
            if p == "/api/v2/workflow/%s" % t.WF:
                return 200, {"project_slug": "gh/mozilla/fxa", "name": "test_pull_request", "status": "failed"}, None
            if p == "/api/v2/workflow/%s" % t.WF_OTHER:
                return 200, {"project_slug": "gh/mozilla/fxa-private", "name": "secret", "status": "failed"}, None
            if p.startswith("/api/v2/workflow/%s/job" % t.WF):
                return 200, {"items": [{"name": "unit", "status": "failed", "job_number": 7}], "next_page_token": None}, None
            if p == "/api/v2/project/gh/mozilla/fxa/job/7":
                return 200, {"name": "unit", "status": "failed"}, None
            if p.startswith("/api/v2/project/gh/mozilla/fxa/7/tests"):
                return 200, {"items": [{"result": "success", "classname": "a", "name": "ok"},
                                       {"result": "failure", "classname": "b.spec.ts", "name": "shows x", "message": "Timeout 10000ms"}]}, None
            if p == "/api/v1.1/project/github/mozilla/fxa/7":
                return 200, {"steps": [{"name": "checkout", "actions": [{"failed": None}]},
                                       {"name": "run tests", "actions": [{"failed": True, "output_url": st + "/out/7"}]},
                                       {"name": "Running Playwright tests", "actions": [{"index": 0, "failed": None, "output_url": st + "/out/pw0"},
                                                                                        {"index": 1, "failed": None, "output_url": st + "/out/pw1"}]}]}, None
            if p == "/api/v2/insights/gh/mozilla/fxa/workflows/nightly/test-metrics?branch=main":
                row = {"job_name": "Playwright (nightly)", "classname": "../tests/a.spec.ts", "file": "", "test_name": "signs in",
                       "p95_duration": 157.94, "total_runs": 88, "failed_runs": 2, "flaky": False}
                return 200, {"total_test_runs": 88, "average_test_count": 16046, "slowest_tests": [row] * 45,
                             "most_failed_tests": [dict(row, file="/p/b.spec.ts")]}, None
            if p.startswith("/api/v2/project/gh/mozilla/fxa/7/artifacts"):
                return 200, {"items": [{"path": "artifacts/x/error-context.md", "url": base + "/art/ec"},
                                       {"path": "artifacts/x/trace.zip", "url": base + "/art/tz"}]}, None
            if p == "/art/ec":
                return 302, b"", st + "/signed/ec"
            return 404, {"message": "Not Found"}, None
        base = server(cci, "cci")
        os.environ["CIRCLECI_TOKEN"] = "cci-secret-token"
        spec = dict(json.load(open(os.path.join(HERE, "connectors.example.json")))["connectors"]["circleci"], api=base)
        cls.up = gateway.CircleCI("circleci", spec)
        cls.up.TOKEN_URL = re.compile(re.escape(base) + "/")
        # The whole call path, in process: rules, cap, redaction and the audit line.
        cls.dir = tempfile.mkdtemp()
        os.makedirs(os.path.join(cls.dir, "tokens"))
        gateway.DIR, gateway.fxadb.PATH = cls.dir, os.path.join(cls.dir, "no.db")
        gateway.UPSTREAMS = {"circleci": cls.up}

    def call(self, tool, scope=None, **args):
        tok = "fxm_" + "c" * 32
        rec = {"run": "ci-run", "expires": time.time() + 60, "connectors": ["circleci"], "cap_calls": 100, "calls": 0}
        if scope:
            rec["scope"] = scope
        with open(os.path.join(self.dir, "tokens", tok + ".json"), "w") as f:
            json.dump(rec, f)
        return self.g.call_tool(tok, rec, {"name": "circleci__" + tool, "arguments": dict({"owner": "mozilla", "repo": "fxa"}, **args)})

    def test_a_job_gives_its_failed_tests_and_failed_steps_end(self):
        text = self.call("get_job", job_number=7)["content"][0]["text"]
        self.assertTrue(text.startswith("Job 7: unit, failed\nFailed tests:\n- b.spec.ts shows x: Timeout 10000ms"), text)
        self.assertNotIn(" a ok", text)
        self.assertIn('End of the failed step "run tests":', text)
        self.assertIn("FAILED test_x", text.split("--- the end of the log:")[0])
        self.assertNotIn("/out/7", text)  # no output_url

    def test_a_log_loses_a_private_key_and_a_github_token_and_keeps_an_image_digest(self):
        text = self.call("get_job", job_number=7)["content"][0]["text"]
        self.assertNotIn("MIIEfake", text)
        self.assertNotIn(self.GHP, text)
        self.assertIn("[private key]", text)
        self.assertIn(self.DIGEST, text)

    def test_a_workflow_of_another_project_is_refused(self):
        out = json.loads(self.call("get_workflow_jobs", workflow_id=self.WF)["content"][0]["text"])
        self.assertEqual(out["jobs"], [{"name": "unit", "status": "failed", "job_number": 7}])
        res = self.call("get_workflow_jobs", workflow_id=self.WF_OTHER)
        self.assertTrue(res["isError"])
        self.assertNotIn("secret", json.dumps(res))
        self.assertTrue(self.call("get_workflow_jobs", workflow_id="../job/1")["isError"])

    def test_an_artifact_comes_only_from_the_jobs_own_list_and_its_redirect_gets_no_token(self):
        out = json.loads(self.call("get_job_artifacts", job_number=7)["content"][0]["text"])
        self.assertEqual(out, {"paths": ["artifacts/x/error-context.md", "artifacts/x/trace.zip"]})
        del self.SEEN[:]
        self.assertEqual(self.call("get_artifact_text", job_number=7, path="artifacts/x/error-context.md")["content"][0]["text"],
                         "# Error details: element(s) not found")
        self.assertIn(("cci", "/art/ec", "cci-secret-token"), self.SEEN)
        self.assertEqual([s for s in self.SEEN if s[0] == "store"], [("store", "/signed/ec", None)])
        for path in ("artifacts/y/error-context.md", "artifacts/x/trace.zip", "../../etc/passwd.md"):
            self.assertTrue(self.call("get_artifact_text", job_number=7, path=path)["isError"], path)
        self.assertFalse(any(s[0] == "store" and s[1] != "/signed/ec" for s in self.SEEN))

    def test_a_step_log_is_read_with_no_token(self):
        del self.SEEN[:]
        self.call("get_job", job_number=7)
        self.assertEqual([s[2] for s in self.SEEN if s[0] == "store"], [None])
        self.assertTrue(all(s[2] == "cci-secret-token" for s in self.SEEN if s[0] == "cci"))

    def test_the_token_never_reaches_an_answer_an_error_or_the_audit_log(self):
        outs = [self.call("get_job", job_number=7), self.call("get_job", job_number=99), self.call("get_artifact_text", job_number=7, path="nope.md"),
                self.call("get_workflow_jobs", workflow_id=self.WF_OTHER)]
        self.assertTrue(outs[1]["isError"])
        self.assertIn("HTTP 404", outs[1]["content"][0]["text"])
        with open(os.path.join(self.dir, "calls.jsonl")) as f:
            audit = f.read()
        for text in [json.dumps(o) for o in outs] + [audit]:
            self.assertNotIn("cci-secret-token", text)
            self.assertNotIn("127.0.0.1", text)  # no URL either

    def test_a_team_scope_swaps_the_project_pin(self):
        schema = self.up.list_tools()["get_job"]["inputSchema"]
        rules = self.g.team_rules(self.up.rules, {"repos": ["mozilla-services/syncstorage-rs"]})
        self.assertEqual(self.g.apply_rules(rules, "get_job", schema, {"owner": "mozilla-services", "repo": "syncstorage-rs", "job_number": 1})["repo"], "syncstorage-rs")
        with self.assertRaises(self.g.Denied):
            self.g.apply_rules(rules, "get_job", schema, {"owner": "mozilla", "repo": "fxa", "job_number": 1})
        self.assertTrue(self.call("get_job", scope={"repos": ["mozilla/pyfxa"]}, job_number=7)["isError"])

    def test_list_pipelines_finds_the_nightlies_across_pages_with_their_workflows(self):
        out = json.loads(self.call("list_pipelines", trigger="schedule")["content"][0]["text"])["pipelines"]
        self.assertEqual([(p["number"], p["trigger"], p["commit"]) for p in out], [(2, "schedule", "b" * 12), (1, "schedule", "c" * 12)])
        self.assertEqual(out[0]["workflows"], [{"name": "nightly", "status": "failed", "id": self.WF}])
        every = json.loads(self.call("list_pipelines", limit=1)["content"][0]["text"])["pipelines"]
        self.assertEqual([p["number"] for p in every], [3])

    def test_list_pipelines_refuses_a_bad_branch_trigger_or_limit_and_another_project(self):
        for args in ({"branch": "main?x=1"}, {"branch": "../x"}, {"trigger": "manual"}, {"limit": 21}, {"limit": True}):
            self.assertTrue(self.call("list_pipelines", **args)["isError"], args)
        self.assertTrue(self.call("list_pipelines", scope={"repos": ["mozilla/pyfxa"]})["isError"])
        self.assertEqual(self.up.list_tools()["list_pipelines"]["inputSchema"]["required"], ["owner", "repo"])

    def test_a_named_step_that_passed_gives_its_log_on_each_node(self):
        text = self.call("get_job", job_number=7, step="playwright", tail_lines=20)["content"][0]["text"]
        self.assertIn('Step "Running Playwright tests", node 0:', text)
        self.assertIn('Step "Running Playwright tests", node 1:', text)
        self.assertNotIn("End of the failed step", text)
        self.assertNotIn("/out/pw", text)
        self.assertIn('No step name contains "nope".', self.call("get_job", job_number=7, step="nope")["content"][0]["text"])

    def test_match_keeps_the_flaky_list_and_counts_the_nodes_without_one(self):
        text = self.call("get_job", job_number=7, step="Running Playwright tests", match="flaky tests")["content"][0]["text"]
        self.assertIn('node 1:\n⚠️ Flaky tests (1):\n  tests/a.spec.ts:signs in', text)
        self.assertNotIn("node 0:", text)
        self.assertNotIn("ok 1", text)
        self.assertIn('1 step logs have no line with "flaky tests".', text)
        for args in ({"step": ""}, {"step": "x" * 81}, {"match": 5}):
            self.assertTrue(self.call("get_job", job_number=7, **args)["isError"], args)

    def test_test_metrics_give_the_slowest_and_most_failed_tests_of_one_workflow(self):
        out = json.loads(self.call("get_test_metrics", workflow="nightly")["content"][0]["text"])
        self.assertEqual((out["runs"], len(out["slowest"])), (88, 40))
        self.assertEqual(out["slowest"][0], {"job": "Playwright (nightly)", "spec": "../tests/a.spec.ts", "test": "signs in", "p95_s": 157.9, "runs": 88, "failed": 2})
        self.assertEqual(out["most_failed"][0]["spec"], "/p/b.spec.ts")
        for args in ({"workflow": "a/../b"}, {"workflow": "nightly", "branch": "main?x=1"}, {}):
            self.assertTrue(self.call("get_test_metrics", **args)["isError"], args)
        self.assertTrue(self.call("get_test_metrics", scope={"repos": ["mozilla/pyfxa"]}, workflow="nightly")["isError"])

    def test_only_read_tools_exist(self):
        self.assertEqual(sorted(self.up.list_tools()), ["get_artifact_text", "get_job", "get_job_artifacts", "get_test_metrics", "get_workflow_jobs", "list_pipelines"])
        self.assertFalse(re.search(r"rerun|cancel|approve|POST", open(os.path.join(HERE, "gateway.py")).read().split("class CircleCI")[1].split("def load_upstreams")[0]))


if __name__ == "__main__":
    unittest.main(verbosity=1)
