#!/usr/bin/env python3
"""Offline check for proxy.py against a fake upstream: python3 infra/llm-proxy/proxy_test.py"""
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
SEEN = []  # the headers the fake upstream received


class Upstream(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["content-length"])))
        SEEN.append(dict(self.headers))
        if body.get("stream"):
            events = [{"type": "message_start", "message": {"model": "claude-opus-5-5", "usage": {"input_tokens": 1000000, "output_tokens": 1}}},
                      {"type": "content_block_delta", "delta": {"type": "text_delta", "text": "hi"}},
                      {"type": "message_delta", "usage": {"output_tokens": 100000}}]
            data = b"".join(b"event: x\ndata: " + json.dumps(e).encode() + b"\n\n" for e in events)
            self.send_response(200)
            self.send_header("content-type", "text/event-stream")
            self.send_header("content-length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        else:
            data = json.dumps({"model": "claude-opus-5-5", "usage": {"input_tokens": 500000, "output_tokens": 0}}).encode()
            self.send_response(200)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


class ProxyTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.dir = tempfile.mkdtemp()
        os.makedirs(os.path.join(cls.dir, "tokens"))
        up = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Upstream)
        threading.Thread(target=up.serve_forever, daemon=True).start()
        cls.port = free_port()
        env = dict(os.environ, LLM_PROXY_DIR=cls.dir, LLM_PROXY_UPSTREAM="http://127.0.0.1:%d" % up.server_port,
                   ANTHROPIC_API_KEY="sk-real-key", LLM_PROXY_LISTEN="127.0.0.1:%d" % cls.port)
        cls.proc = subprocess.Popen([sys.executable, os.path.join(HERE, "proxy.py")], env=env, stderr=subprocess.DEVNULL)
        for _ in range(50):
            try:
                socket.create_connection(("127.0.0.1", cls.port), 0.1).close()
                break
            except OSError:
                time.sleep(0.1)

    @classmethod
    def tearDownClass(cls):
        cls.proc.terminate()

    def token(self, name, cap=50):
        tok = "fxl_" + (name * 32)[:32]
        with open(os.path.join(self.dir, "tokens", tok + ".json"), "w") as f:
            json.dump({"run": name, "created": 0, "expires": time.time() + 60, "cap_usd": cap, "spent_usd": 0}, f)
        return tok

    def call(self, tok, path="/v1/messages", body=None):
        c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        c.request("POST", path, body=json.dumps(body or {"stream": False}),
                  headers={"x-api-key": tok, "content-type": "application/json", "accept-encoding": "gzip, br"})
        r = c.getresponse()
        return r.status, r.read()

    def spent(self, tok):
        with open(os.path.join(self.dir, "tokens", tok + ".json")) as f:
            return json.load(f)["spent_usd"]

    def test_json_answer_swaps_the_key_and_charges(self):
        tok = self.token("a")
        status, _ = self.call(tok)
        self.assertEqual(status, 200)
        self.assertEqual(SEEN[-1].get("x-api-key"), "sk-real-key")  # the upstream never sees the run token
        # Uncompressed: a compressed answer would hide its usage. http.client sends identity itself.
        self.assertEqual(SEEN[-1].get("Accept-Encoding", "identity"), "identity")
        self.assertAlmostEqual(self.spent(tok), 2.0)  # 0.5 M input at $4

    def test_stream_passes_through_and_charges(self):
        tok = self.token("b")
        status, body = self.call(tok, body={"stream": True})
        self.assertEqual(status, 200)
        self.assertIn(b"text_delta", body)
        self.assertAlmostEqual(self.spent(tok), 6.0)  # 1 M input at $4 + 0.1 M output at $20

    def test_unknown_token_is_refused(self):
        self.assertEqual(self.call("fxl_" + "z" * 32)[0], 401)
        self.assertEqual(self.call("sk-real-key")[0], 401)

    def test_other_paths_are_refused(self):
        self.assertEqual(self.call(self.token("c"), path="/v1/files")[0], 403)

    def test_a_run_past_its_cap_is_refused(self):
        tok = self.token("d", cap=1)
        self.assertEqual(self.call(tok)[0], 200)  # this call takes it to $2
        self.assertEqual(self.call(tok)[0], 429)


if __name__ == "__main__":
    unittest.main(verbosity=1)
