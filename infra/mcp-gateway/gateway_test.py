#!/usr/bin/env python3
"""Offline check for gateway.py against a fake upstream MCP server:
python3 infra/mcp-gateway/gateway_test.py"""
import http.client
import http.server
import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
CALLS = []  # (path, method, params, headers) of every upstream request
MODE = {"sse": False, "expire": False}
SESSIONS = [0]
TOOLS = [
    {"name": "read_issue", "description": "Read an issue", "inputSchema": {"type": "object", "properties": {"key": {}, "fields": {}}}},
    {"name": "search", "description": "Search", "inputSchema": {"type": "object", "properties": {"jql": {}}}},
    {"name": "write_issue", "description": "Write", "inputSchema": {"type": "object", "properties": {"key": {}}}},
    {"name": "get_pr", "description": "A PR", "inputSchema": {"type": "object", "properties": {"owner": {}, "repo": {}}}},
]


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
        msg = json.loads(self.rfile.read(int(self.headers["content-length"])))
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
            "jira": {"url": base + "/jira", "headers": auth, "tools": ["read_issue", "search"],
                     "rules": [{"tool": "search", "arg": "jql", "jql_project": "FXA"},
                               {"arg": "fields", "include": ["security"], "default": ["summary"]}],
                     "deny_result": ["\"security\"\\s*:\\s*\\{"]},
            "github": {"url": base + "/github", "headers": auth, "tools": ["get_pr"],
                       "rules": [{"arg": "owner", "equals": "mozilla"}, {"arg": "repo", "equals": "fxa"}]},
            "slack": {"url": base + "/slack", "headers": {"Authorization": "Bearer ${UNSET_SLACK_TOKEN}"}, "tools": ["read_issue"]},
        }}
        cfg = os.path.join(cls.dir, "gateway.json")
        with open(cfg, "w") as f:
            json.dump(conf, f)
        cls.port = free_port()
        env = dict(os.environ, MCP_GATEWAY_DIR=cls.dir, MCP_GATEWAY_CONFIG=cfg, RUNLAYER_AGENT_TOKEN="rl-secret",
                   MCP_GATEWAY_LISTEN="127.0.0.1:%d" % cls.port)
        env.pop("UNSET_SLACK_TOKEN", None)
        cls.proc = subprocess.Popen([sys.executable, os.path.join(HERE, "gateway.py")], env=env, stderr=subprocess.DEVNULL)
        for _ in range(50):
            try:
                socket.create_connection(("127.0.0.1", cls.port), 0.1).close()
                break
            except OSError:
                time.sleep(0.1)

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

    def test_initialize_and_notifications(self):
        tok = self.token("a")
        status, doc = self.rpc(tok, "initialize", {"protocolVersion": "2025-03-26"})
        self.assertEqual(status, 200)
        self.assertEqual(doc["result"]["protocolVersion"], "2025-03-26")
        self.assertEqual(self.rpc(tok, "notifications/initialized", mid=None), (202, None))

    def test_tools_list_is_the_granted_allowlist_only(self):
        names = [t["name"] for t in self.rpc(self.token("b", ["jira"]), "tools/list")[1]["result"]["tools"]]
        self.assertEqual(names, ["jira__read_issue", "jira__search"])  # no write_issue, no github
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
                         'project = FXA AND level IS EMPTY AND (text ~ "order by") ORDER BY created DESC')
        self.call(tok, "jira__search", {"jql": ""})
        self.assertEqual(self.upstream_calls("/jira")[-1][2]["arguments"]["jql"], "project = FXA AND level IS EMPTY")

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

    def test_a_matching_answer_is_withheld(self):
        result = self.call(self.token("j"), "jira__read_issue", {"key": "FXA-SEC"})
        self.assertTrue(result["isError"])
        self.assertNotIn("Embargoed", json.dumps(result))

    def test_a_list_argument_always_includes_its_values(self):
        tok = self.token("m")
        self.assertTrue(self.call(tok, "jira__read_issue", {"key": "FXA-SEC", "fields": ["summary"]})["isError"])
        self.call(tok, "jira__read_issue", {"key": "FXA-1"})
        self.assertEqual(self.upstream_calls("/jira")[-1][2]["arguments"]["fields"], ["summary", "security"])
        self.call(tok, "jira__read_issue", {"key": "FXA-1", "fields": ["status", "security"]})
        self.assertEqual(self.upstream_calls("/jira")[-1][2]["arguments"]["fields"], ["status", "security"])

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

    def test_every_call_is_audited(self):
        tok = self.token("n")
        self.call(tok, "jira__write_issue", {"key": "FXA-1"})
        self.call(tok, "jira__read_issue", {"key": "FXA-1"})
        with open(os.path.join(self.dir, "calls.jsonl")) as f:
            mine = [json.loads(l) for l in f if '"run": "n"' in l]
        self.assertEqual([l["outcome"] for l in mine], ["denied:tool", "ok"])


if __name__ == "__main__":
    unittest.main(verbosity=1)
