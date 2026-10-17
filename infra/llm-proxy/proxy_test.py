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
BODIES = []  # the request bodies the fake upstream received
PEERS = []  # the client address of each call, one per upstream connection
DROP = []  # when set, the fake upstream closes the connection after its answer


class Upstream(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["content-length"])))
        SEEN.append(dict(self.headers))
        BODIES.append(body)
        PEERS.append(self.client_address)
        if DROP:
            DROP.clear()
            self.close_connection = True  # silently, as a server that times out an idle socket
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
                   ANTHROPIC_API_KEY="sk-real-key", LLM_PROXY_LISTEN="127.0.0.1:%d" % cls.port,
                   LLM_PROXY_WARM_SECONDS="1", LLM_PROXY_WARM_TICK="0.2", LLM_PROXY_WARM_MAX="2")
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

    def token(self, name, cap=50, **extra):
        tok = "fxl_" + (name * 32)[:32]
        with open(os.path.join(self.dir, "tokens", tok + ".json"), "w") as f:
            json.dump({"run": name, "created": 0, "expires": time.time() + 60, "cap_usd": cap, "spent_usd": 0, **extra}, f)
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

    def test_usage_line_carries_the_thread(self):
        tok = self.token("t", thread="C0AB12CD3:1791135361.015169")
        self.assertEqual(self.call(tok)[0], 200)
        with open(os.path.join(self.dir, "usage.jsonl")) as f:
            line = [json.loads(ln) for ln in f if '"run": "t"' in ln][-1]
        self.assertEqual(line["thread"], "C0AB12CD3:1791135361.015169")

    def test_unknown_token_is_refused(self):
        self.assertEqual(self.call("fxl_" + "z" * 32)[0], 401)
        self.assertEqual(self.call("sk-real-key")[0], 401)

    def test_an_mcp_gateway_token_is_refused_and_no_token_reaches_a_log(self):
        tok = self.token("m")
        self.assertEqual(self.call(tok)[0], 200)
        mcp = "fxm_" + tok[4:]
        os.rename(os.path.join(self.dir, "tokens", tok + ".json"), os.path.join(self.dir, "tokens", mcp + ".json"))
        self.assertEqual(self.call(mcp)[0], 401)
        for root, _, files in os.walk(self.dir):
            for n in files:
                if os.path.basename(root) != "tokens":
                    with open(os.path.join(root, n), errors="replace") as f:
                        self.assertNotIn(tok[4:], f.read(), n)

    def test_other_paths_are_refused(self):
        self.assertEqual(self.call(self.token("c"), path="/v1/files")[0], 403)

    def test_a_run_past_its_cap_is_refused(self):
        tok = self.token("d", cap=1)
        self.assertEqual(self.call(tok)[0], 200)  # this call takes it to $2
        self.assertEqual(self.call(tok)[0], 403)  # not 429, which a client retries

    def team_caps(self, team, **caps):
        os.makedirs(os.path.join(self.dir, "teams"), exist_ok=True)
        with open(os.path.join(self.dir, "teams", team + ".json"), "w") as f:
            json.dump(caps, f)

    def team_spent(self, team):
        with open(os.path.join(self.dir, "teams", team + ".spend.json")) as f:
            return json.load(f)

    def test_a_team_spend_adds_up_over_its_runs_and_its_usage_lines_name_it(self):
        a, b = self.token("ta1", team="tsum"), self.token("ta2", team="tsum")
        self.assertEqual(self.call(a)[0], 200)
        self.assertEqual(self.call(b)[0], 200)
        s = self.team_spent("tsum")
        self.assertAlmostEqual(s["day_usd"], 4.0)
        self.assertAlmostEqual(s["month_usd"], 4.0)
        with open(os.path.join(self.dir, "usage.jsonl")) as f:
            self.assertEqual([json.loads(ln)["team"] for ln in f if '"run": "ta2"' in ln][-1], "tsum")

    def test_a_team_at_its_daily_cap_is_refused_and_another_team_is_not(self):
        self.team_caps("tcap", day_usd=3)
        a, other = self.token("tc1", team="tcap"), self.token("tc2", team="tfree")
        self.assertEqual(self.call(a)[0], 200)  # $2 of $3
        self.assertEqual(self.call(self.token("tc3", team="tcap"))[0], 200)  # starts below the cap: $4 after
        status, body = self.call(self.token("tc4", team="tcap"))  # a fresh run of the same team
        self.assertEqual(status, 403)
        self.assertIn(b"team tcap reached its daily spend cap of $3", body)
        self.assertEqual(self.call(other)[0], 200)

    def test_a_monthly_cap_holds_and_yesterday_does_not_count_for_today(self):
        self.team_caps("tmon", day_usd=3, month_usd=100)
        with open(os.path.join(self.dir, "teams", "tmon.spend.json"), "w") as f:
            json.dump({"day": "2000-01-01", "day_usd": 50, "month": time.strftime("%Y-%m", time.gmtime()), "month_usd": 99}, f)
        self.assertEqual(self.call(self.token("tm1", team="tmon"))[0], 200)  # yesterday's 50 is gone; the month is at 99
        status, body = self.call(self.token("tm2", team="tmon"))
        self.assertEqual(status, 403)
        self.assertIn(b"monthly spend cap", body)

    def test_a_team_with_no_caps_or_a_bad_name_is_never_capped_by_team(self):
        self.assertEqual(self.call(self.token("tn1", team="tnone"))[0], 200)
        self.assertEqual(self.call(self.token("tn2", team="../x"))[0], 200)

    def test_calls_reuse_one_upstream_connection(self):
        tok = self.token("e")
        del PEERS[:]
        for _ in range(10):
            self.assertEqual(self.call(tok)[0], 200)
        self.assertEqual(len(set(PEERS)), 1)

    def test_a_pooled_connection_the_far_end_closed_is_retried(self):
        tok = self.token("f")
        self.assertEqual(self.call(tok)[0], 200)
        DROP.append(1)
        self.assertEqual(self.call(tok)[0], 200)  # the upstream closes after this answer
        self.assertEqual(self.call(tok)[0], 200)  # the pooled socket is dead: one retry on a new one
        self.assertNotEqual(PEERS[-1], PEERS[-2])


    # A waiting Slack session's cache is kept warm with max_tokens 0 resends, and nothing else is.
    def warm_calls(self, since):
        return [b for b in BODIES[since:] if b.get("max_tokens") == 0]

    # Wait for the resends instead of sleeping a fixed time: a busy host runs the warm tick late.
    def wait_warm(self, since, n, timeout=15):
        end = time.time() + timeout
        while len(self.warm_calls(since)) < n and time.time() < end:
            time.sleep(0.1)
        time.sleep(1.5)  # one more WARM_SECONDS: a resend past the max would show by now

    def usage_rows(self, run):
        with open(os.path.join(self.dir, "usage.jsonl")) as f:
            return [json.loads(l) for l in f if json.loads(l).get("run") == run]

    def test_a_session_is_resent_with_max_tokens_0_without_stream_up_to_the_max(self):
        tok, n = self.token("w", run="agent-warm"), len(BODIES)
        self.call(tok, body={"model": "claude-opus-5-5", "stream": True, "max_tokens": 32000, "thinking": {"type": "adaptive"},
                             "messages": [{"role": "user", "content": "hi"}]})
        self.wait_warm(n, 2)
        warm = self.warm_calls(n)
        self.assertEqual(len(warm), 2)  # LLM_PROXY_WARM_MAX
        self.assertNotIn("stream", warm[0])
        self.assertEqual((warm[0]["thinking"], warm[0]["messages"]), ({"type": "adaptive"}, [{"role": "user", "content": "hi"}]))
        self.assertEqual([r.get("warm") for r in self.usage_rows("agent-warm")], [None, True, True])

    def test_a_new_call_starts_the_count_again(self):
        tok, n = self.token("r", run="agent-again"), len(BODIES)
        for i in range(2):
            self.call(tok, body={"model": "claude-opus-5-5", "stream": True, "max_tokens": 10, "messages": []})
            self.wait_warm(n, 2 * (i + 1))
        self.assertEqual(len(self.warm_calls(n)), 4)

    def test_other_runs_and_unwarmable_requests_are_not_resent(self):
        n = len(BODIES)
        self.call(self.token("p", run="FXA-1"), body={"model": "claude-opus-5-5", "stream": True, "max_tokens": 10, "messages": []})
        self.call(self.token("f", run="agent-format"), body={"model": "claude-opus-5-5", "max_tokens": 10, "messages": [],
                                                              "output_config": {"format": {"type": "json_schema"}}})
        tok = self.token("x", run="agent-revoked")
        self.call(tok, body={"model": "claude-opus-5-5", "stream": True, "max_tokens": 10, "messages": []})
        with open(os.path.join(self.dir, "tokens", tok + ".json")) as f:
            rec = json.load(f)
        with open(os.path.join(self.dir, "tokens", tok + ".json"), "w") as f:
            json.dump(dict(rec, expires=0), f)  # the session stopped
        time.sleep(2.5)
        self.assertEqual(self.warm_calls(n), [])


class PriceTest(unittest.TestCase):
    def setUp(self):
        sys.path.insert(0, HERE)
        import proxy
        self.cost = proxy.cost

    def test_haiku_5_5_and_its_long_prompt_tier(self):
        u = {"input_tokens": 1000, "output_tokens": 1000, "cache_creation_input_tokens": 1000, "cache_read_input_tokens": 10000}
        self.assertAlmostEqual(self.cost("claude-haiku-5-5", u), (100 + 500 + 125 + 100) / 1e6)
        big = dict(u, cache_read_input_tokens=200000)  # over 100K in the prompt: five times the rate
        self.assertAlmostEqual(self.cost("claude-haiku-5-5", big), (500 + 2500 + 625 + 10000) / 1e6)

    def test_sonnet_5_5_cache_reads_cost_half_of_sonnet_5(self):
        u = {"cache_read_input_tokens": 1000000}
        self.assertAlmostEqual(self.cost("claude-sonnet-5-5", u), 0.10)
        self.assertAlmostEqual(self.cost("claude-sonnet-5", u), 0.20)

    def test_a_1_hour_cache_write_costs_twice_the_base_input(self):
        u = {"cache_creation_input_tokens": 1000000, "cache_creation": {"ephemeral_5m_input_tokens": 400000, "ephemeral_1h_input_tokens": 600000}}
        self.assertAlmostEqual(self.cost("claude-opus-5-5", u), 0.4 * 5 + 0.6 * 8)

    def test_an_unknown_model_never_looks_cheap(self):
        self.assertAlmostEqual(self.cost("claude-new-model", {"output_tokens": 1000000}), 50)


if __name__ == "__main__":
    unittest.main(verbosity=1)
