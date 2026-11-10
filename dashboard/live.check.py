#!/usr/bin/env python3
"""The /api/live hub (live.py) and its routes in server.py: each C1 fixture replays through the hub, the order and
resume rules, reset, redaction per viewer, bye, the LIVE cap, ping, seen(), tails, the store reads and the stats frames.
  python3 dashboard/live.check.py
"""
import collections
import contextlib
import copy
import glob
import io
import json
import os
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
TMP = tempfile.mkdtemp(prefix="live-check.")
# Before the import: the server must never read the real store, sessions, errors or team records.
os.environ.update(FXA_DB=f"{TMP}/fxa.db", FXA_SESSION_DIR=f"{TMP}/sessions", FXA_ERRORS_FILE=f"{TMP}/state/errors.jsonl",
                  FXA_DASHBOARD_HMAC_FILE=f"{TMP}/hmac", FXA_TEAMS_DIR=f"{TMP}/teams", TEAM_ADMINS="admin@example.com",
                  FXA_ERRORS_URI="")
for d in ("sessions", "state", "teams"):
    os.makedirs(f"{TMP}/{d}")


def write(path, text):
    with open(path, "w") as f:
        f.write(text if isinstance(text, str) else json.dumps(text))


write(f"{TMP}/hmac", "k1")
sys.path.insert(0, HERE)
import server  # noqa: E402  first: it puts lib/ on the path
import live  # noqa: E402
import live_schema  # noqa: E402
import testkit  # noqa: E402

FIXTURES = sorted(glob.glob(os.path.join(ROOT, "dashboard-v2", "fixtures", "live", "*.ndjson")))
GOLDEN = os.path.join(ROOT, "dashboard-v2", "test", "golden")
ADMIN = {"user": "admin@example.com", "admin": True, "teams": []}
USER = {"user": "user@example.com", "admin": False, "teams": []}
ANON = {"user": None, "admin": False, "teams": []}


def feed(name, data, at=None, interval=60):
    f = server.Feed(name, [], interval, 30)
    f.data, f.fetched_at = data, time.time() if at is None else at
    return f


def records(**teams):
    write(f"{TMP}/teams/index.json", {"teams": {t: dict({"status": "active", "queue": True, "jira": "EX"}, **r) for t, r in teams.items()}})


def reset_server():
    server.CTL, server.PIPELINE = f"{TMP}/no-ctl", "test"
    server.FULL, server.AGENTS, server.STATS = feed("snapshot", {}), feed("agents", {"sessions": []}), feed("stats", None)
    server.TEAMS = feed("teams", [{"profile": "fxa", "private": False}, {"profile": "example", "private": True},
                                  {"profile": "example-secret", "private": True}, {"profile": "crew", "private": False}])
    server.TEAM_FEEDS.clear()
    server._REC_ADMINS.clear()
    for f in glob.glob(f"{TMP}/teams/*"):
        os.remove(f)
    records(example={}, **{"example-secret": {"secret": True}})
    hub = server.HUB = live.LiveHub(server)
    return hub


def pull(gen):
    """The next frame of a stream, past the idle seconds."""
    while True:
        f = next(gen)
        if f is not None:
            return f


def problems(frames):
    return [p for f in frames for p in live_schema.frame_problems(f)] or live_schema.stream_problems(frames)


# The fields a non-admin never gets, put back in the fixture rows: the hub must take them out again.
PRIV = {"request": "a sample request", "media": [], "last_text": "sample text", "last_tool": "Bash sample"}
FIX = {"fix_pr": "123", "fix_trigger": "label", "fix_actor": "user@example.com", "pr_url": "https://github.com/example/repo/pull/123"}


def raw_session(s, private_teams):
    if s.get("fix_run"):
        return dict({k: v for k, v in s.items() if k != "fix_run"}, **PRIV, **FIX)
    if s.get("profile") in private_teams:
        out = dict(s, **PRIV)
        if isinstance(s.get("agent"), dict):
            out["agent"] = dict(s["agent"], last_text="sample text")
        return out
    return s


def raw_team(counts):
    """A team snapshot whose counts are these: a non-admin of a private team gets counts only."""
    item = lambda n, i: {"key": f"EX-{n}{i}", "summary": "a sample ticket"}
    return {"team": {"profile": "example", "name": "Example"}, "queue": {k: [item(k, i) for i in range(counts[k])] for k in ("ready", "skipped")},
            **{k: [item(k, i) for i in range(counts[k])] for k in server.SNAP_LISTS}}


def raw(event, d, viewer):
    """The hub's input for one fixture frame: for a non-admin, the data before the redaction."""
    if viewer["admin"]:
        return d
    priv = {"example"}
    if event == "snapshot":
        feeds = {n: raw("feed", f, viewer) for n, f in d["feeds"].items()}
        feeds["snapshot:example-secret"] = dict(feeds.get("snapshot:example") or {}, name="snapshot:example-secret")
        return dict(d, feeds=feeds, sessions=[raw_session(s, priv) for s in d["sessions"]])
    if event == "feed" and d["name"] == "agents" and isinstance(d.get("data"), dict):
        return dict(d, data=dict(d["data"], sessions=[raw_session(s, priv) for s in d["data"].get("sessions") or []]))
    if event == "feed" and d["name"].startswith("snapshot:") and (d.get("data") or {}).get("redacted"):
        return dict(d, data=raw_team(d["data"]["counts"]))
    if event == "delta" and d["tbl"] == "sessions":
        return dict(d, rows=[raw_session(s, priv) for s in d["rows"]])
    return d


def set_state(hub, snap):
    hub.feeds = {n: copy.deepcopy(f) for n, f in snap["feeds"].items()}
    hub.sessions = {s["key"]: s for s in snap["sessions"]}
    hub.errors, hub.flow = snap["errors"], collections.deque(snap["flow"], maxlen=1440)


def normal(frames):
    """The fixture and the hub agree after the epoch, the sid and the snapshot feed ages are made the same."""
    out = []
    for f in copy.deepcopy(frames):
        if "id" in f:
            f["id"] = "E-" + f["id"].split("-", 1)[1]
        if f["event"] == "hello":
            f["data"].update(epoch="E", sid="S")
        if f["event"] == "snapshot":
            for x in f["data"]["feeds"].values():
                x["age_seconds"] = None
        out.append(f)
    return out


def replay(path):
    """Play one fixture through the hub with the fixture's data as the inputs; return the frames the stream sent."""
    with open(path) as fh:
        want = [json.loads(line) for line in fh if line.strip()]
    got, hub, gen, viewer, last = [], None, None, None, None
    for i, f in enumerate(want):
        ev, d = f["event"], f["data"]
        if ev == "hello":
            if hub is None or d["epoch"] != epoch:
                hub, epoch = reset_server(), d["epoch"]
                nxt = want[i + 1]
                hub.n = int(nxt["id"].split("-")[1]) - 1
                resets = [j for j, x in enumerate(want) if x["event"] == "reset"]
                if resets:  # the fixture's lost events fill the queue to one past its size
                    j = resets[0]
                    hub.queue_max = int(want[j + 1]["id"].split("-")[1]) - int(want[j - 1]["id"].split("-")[1]) - 2
                since = None if last is None else f"{last.split('-')[0]}-{last.split('-')[1]}"
            else:
                hub.close(stream)
                since = f"{hub.epoch}-{last.split('-')[1]}"
            viewer = d["viewer"]
            stream = hub.open(viewer, since)
            gen = stream.frames()
            got.append(pull(gen))
            continue
        if ev == "snapshot":
            set_state(hub, raw(ev, d, viewer))
        elif ev == "reset":
            for _ in range(hub.queue_max + 1):
                hub.publish("delta", {"tbl": "history", "rows": [{"key": "agent-ex0001"}], "deleted": []})
        elif ev == "ping":
            hub.broadcast("ping", d)
        elif ev == "bye":
            if d["reason"] == "max_life":
                stream.deadline = 0
            else:
                hub.shutdown(d["reason"])
        else:
            hub.publish(ev, raw(ev, d, viewer))
        got.append(pull(gen))
        last = got[-1].get("id", last)
    return want, got


class Replay(unittest.TestCase):
    def test_each_fixture_replays_equal(self):
        self.assertEqual(len(FIXTURES), 6)
        for path in FIXTURES:
            want, got = replay(path)
            self.assertEqual(problems(got), [], path)
            self.assertEqual(normal(got), normal(want), path)

    def test_the_replay_fails_on_a_wrong_hub(self):
        # The comparison can fail: a hub that drops the redaction sends the raw rows to a non-admin.
        keep = server.session_for
        server.session_for = lambda s, admin: s
        try:
            want, got = replay(next(f for f in FIXTURES if f.endswith("private-team.ndjson")))
            self.assertNotEqual(normal(got), normal(want))
        finally:
            server.session_for = keep


class Stream(unittest.TestCase):
    def setUp(self):
        self.hub = reset_server()

    def test_resume_replays_the_ring_and_a_miss_or_another_epoch_gets_a_snapshot(self):
        h = self.hub
        s = h.open(ADMIN)
        g = s.frames()
        pull(g), pull(g)
        for k in ("agent-a1", "agent-a2"):
            h.publish("delta", {"tbl": "history", "rows": [{"key": k}], "deleted": []})
        first = pull(g)
        h.close(s)
        r = h.open(ADMIN, first["id"]).frames()
        self.assertEqual([pull(r)["event"], pull(r)["data"]["rows"]], ["hello", [{"key": "agent-a2"}]])
        for since in (f"other-{h.n}", f"{h.epoch}-{h.n + 5}", "junk", None):
            o = h.open(ADMIN, since).frames()
            self.assertEqual([pull(o)["event"], pull(o)["event"]], ["hello", "snapshot"], since)
        h.trimmed = h.n  # the ring lost the events after first
        o = h.open(ADMIN, first["id"]).frames()
        self.assertEqual([pull(o)["event"], pull(o)["event"]], ["hello", "snapshot"])

    def test_a_full_queue_is_a_reset_then_a_snapshot(self):
        h = self.hub
        h.queue_max = 3
        g = h.open(ADMIN).frames()
        pull(g), pull(g)
        for i in range(5):
            h.publish("delta", {"tbl": "history", "rows": [{"key": f"agent-b{i}"}], "deleted": []})
        f = [pull(g), pull(g)]
        self.assertEqual([f[0], f[1]["event"], f[1]["id"]], [{"event": "reset", "data": {"reason": "queue_full"}}, "snapshot", f"{h.epoch}-{h.n}"])

    def test_bye_at_max_life_and_at_shutdown(self):
        h = self.hub
        h.max_life_s = 0
        g = h.open(ADMIN).frames()
        self.assertEqual([pull(g)["event"], pull(g)["event"], pull(g)], ["hello", "snapshot", {"event": "bye", "data": {"reason": "max_life"}}])
        self.assertRaises(StopIteration, next, g)
        h.max_life_s = 900
        g = h.open(ADMIN).frames()
        pull(g), pull(g)
        server.HUB = h
        keep, server.time.sleep = server.time.sleep, lambda s: None
        try:
            self.assertRaises(SystemExit, server.on_sigterm, 15, None)
        finally:
            server.time.sleep = keep
        self.assertEqual(pull(g), {"event": "bye", "data": {"reason": "shutdown"}})

    def test_ping_every_15_s_seen_and_a_flow_point_each_minute(self):
        h = self.hub
        g = h.open(ADMIN).frames()
        pull(g), pull(g)
        server.LAST_SEEN[0] = 0
        server.FULL = feed("snapshot", {"review": [{"key": "EX-1", "state": "CLOSED"}], "merged_prs": [{}, {}]})
        h.flowed = 0
        h.timers(1000.0)
        self.assertEqual(pull(g), {"event": "ping", "data": {"at": 1000}})
        self.assertGreater(server.LAST_SEEN[0], 0)
        self.assertEqual(pull(g)["data"], {"at": 1000, "stops": [0, 0, 0, 0, 0, 0, 0, 0, 1], "merged": 2, "closed": 1})
        h.timers(1010.0)
        h.publish("delta", {"tbl": "history", "rows": [{"key": "agent-c1"}], "deleted": []})
        self.assertEqual(pull(g)["event"], "delta")  # no second ping inside 15 s
        h.timers(1015.0)
        self.assertEqual(pull(g)["event"], "ping")

    def test_redaction_per_viewer(self):
        h = self.hub
        records(example={}, crew={}, **{"example-secret": {"secret": True}})
        row = dict({"key": "agent-p1", "profile": "example", "owner_image": "x", "agent": {"last_text": "t", "turns": 1}}, **PRIV)
        fix = dict({"key": "agent-f1", "profile": "fxa"}, **FIX)
        h.sessions = {"agent-p1": row}
        rec_admin = {"user": "user@example.com", "admin": False, "teams": ["crew"]}
        streams = {n: h.open(v).frames() for n, v in (("admin", ADMIN), ("user", USER), ("crew", rec_admin))}
        for g in streams.values():
            pull(g), pull(g)
        h.publish("delta", {"tbl": "sessions", "rows": [row, fix], "deleted": []})
        h.publish("tail", {"key": "agent-p1", "start": 0, "lines": ["private words"]})
        h.publish("feed", {"name": "snapshot:example-secret", "age_seconds": 0, "interval": 300, "error": None, "refreshing": False, "fetched_at": 1,
                           "data": {"team": {"profile": "example-secret"}}})
        h.publish("feed", {"name": "team-test:crew", "age_seconds": 0, "interval": 1, "error": None, "refreshing": False, "fetched_at": 1, "data": {"lines": []}})
        h.publish("delta", {"tbl": "routines", "rows": [{"id": 1, "team": "crew"}, {"id": 2, "team": "example"}], "deleted": []}, {"teams": ["crew", "example"]})
        h.publish("delta", {"tbl": "team_audit", "rows": [{"team": "crew", "at": 3, "actor": "user@example.com", "action": "update"}], "deleted": []}, {"teams": ["crew"]})
        h.publish("delta", {"tbl": "history", "rows": [{"key": "agent-p1"}], "deleted": []})
        a = [pull(streams["admin"]) for _ in range(7)]
        self.assertEqual([x["event"] for x in a], ["delta", "tail", "feed", "feed", "delta", "delta", "delta"])
        self.assertEqual(a[5]["data"]["tbl"], "team_audit")
        self.assertEqual(a[0]["data"]["rows"][0]["request"], PRIV["request"])
        self.assertNotIn("owner_image", a[0]["data"]["rows"][0])
        u = [pull(streams["user"]) for _ in range(2)]
        self.assertEqual([x["event"] for x in u], ["delta", "delta"])
        self.assertEqual(u[1]["data"]["tbl"], "history")
        p, f = u[0]["data"]["rows"]
        self.assertFalse(set(p) & set(PRIV) or set(p["agent"]) & set(PRIV), p)
        self.assertFalse(set(f) & server.FIX_PRIVATE, f)
        self.assertTrue(f["fix_run"])
        c = [pull(streams["crew"]) for _ in range(3)]
        self.assertEqual(c[0]["data"]["rows"], u[0]["data"]["rows"])
        self.assertEqual(c[1]["data"]["rows"], [{"id": 1, "team": "crew"}])
        self.assertEqual(c[2]["data"]["tbl"], "history")  # a record admin gets no audit rows, as /api/teams/<t>/audit
        self.assertEqual(problems([{"event": "hello", "data": {"v": 1, "epoch": h.epoch, "sid": "s", "viewer": ADMIN, "retention_s": 300, "max_life_s": 900}},
                                   {"id": f"{h.epoch}-1", "event": "snapshot", "data": {"feeds": {}, "sessions": [], "errors": [], "stats": None, "flow": []}}] + a), [])

    def test_a_narrowed_session_and_an_agents_reply_are_private(self):
        records(example={})
        open_row = {"key": "agent-n1", "profile": "fxa", "state": "running"}
        narrow = dict(open_row, key="agent-n2", watch_narrow="1", wrap_reply="r", summary="s", agent={"last_say": "x"})
        self.assertEqual(server.session_for(open_row, False)["state"], "running")
        self.assertFalse({"wrap_reply", "summary"} & set(server.session_for(narrow, False)))
        self.assertNotIn("last_say", server.session_for(narrow, False)["agent"])
        self.assertEqual(server.session_for(narrow, True)["wrap_reply"], "r")
        private = dict(narrow, key="agent-n3", profile="example", watch_narrow="")
        self.assertFalse({"wrap_reply", "summary"} & set(server.session_for(private, False)))
        self.hub.sessions = {"agent-n1": open_row, "agent-n2": narrow}
        self.assertEqual((self.hub.private_key("agent-n1"), self.hub.private_key("agent-n2")), (False, True))
        write(f"{TMP}/sessions/agent-n4.json", dict(narrow, key="agent-n4"))
        self.assertTrue(server.session_private("agent-n4"))

    def test_a_team_feed_with_no_data_yet_still_shows_its_error(self):
        f = {"name": "snapshot:example", "age_seconds": None, "interval": 300, "error": "jira: 500", "refreshing": False, "fetched_at": None, "data": None}
        for v in (ADMIN, USER):
            self.assertEqual(self.hub.feed_view(f, v), f)
            self.assertEqual(self.hub.snapshot({"feeds": {f["name"]: f}, "sessions": [], "errors": [], "flow": []}, v)["feeds"], {f["name"]: f})

    def test_feed_frames_send_data_only_when_it_changed(self):
        h = self.hub
        h.tick()
        first = [it for _, it in h.ring]
        self.assertEqual(sorted(it[2]["name"] for it in first), ["agents", "snapshot", "teams"])
        self.assertTrue(all("data" in it[2] for it in first))
        self.assertEqual([t["profile"] for t in h.feeds["teams"]["data"]][:2], ["fxa", "example"])
        self.assertIn("issues", h.feeds["teams"]["data"][0])
        n = h.n
        h.tick()
        self.assertEqual(h.n, n)
        server.AGENTS.error = "RuntimeError: sample"
        h.tick()
        self.assertEqual(h.ring[-1][1][2], {"name": "agents", "age_seconds": 0, "interval": 60, "error": "RuntimeError: sample",
                                           "refreshing": False, "fetched_at": server.AGENTS.fetched_at})
        server.AGENTS.data, server.AGENTS.fetched_at = {"sessions": [{"key": "agent-d1", "profile": "fxa"}]}, time.time() + 1
        h.tick()
        self.assertEqual(h.ring[-1][1][2]["data"], server.AGENTS.data)
        self.assertEqual(list(h.sessions), ["agent-d1"])

    def test_a_team_test_is_a_feed(self):
        h = self.hub
        write(f"{TMP}/teams/crew.json", "{}")
        write(f"{TMP}/teams/crew.test.log", "step one\n")
        h.read_files(time.time())
        it = h.ring[-1][1]
        self.assertEqual((it[2]["name"], it[2]["data"]["lines"]), ("team-test:crew", ["step one"]))
        n = h.n
        h.read_files(time.time())
        self.assertEqual(h.n, n)


class Tails(unittest.TestCase):
    def test_new_lines_once_for_all_viewers_and_the_whole_window_when_it_moves(self):
        h = reset_server()
        lines = {"agent-t1": ["a", "b"]}
        keep, server.agent_tail = server.agent_tail, lambda k: list(lines[k])
        calls = []
        try:
            s1, s2 = h.open(ADMIN), h.open(USER)
            for s in (s1, s2):
                g = s.frames()
                pull(g), pull(g)
            h.subscribe(s1, ["agent-t1"])
            h.subscribe(s2, ["agent-t1"])
            server.agent_tail = lambda k: calls.append(k) or list(lines[k])
            h.read_tails()
            lines["agent-t1"] += ["c"]
            h.read_tails()
            h.read_tails()
            lines["agent-t1"] = ["b", "c", "d"]
            h.read_tails()
            h.subscribe(h.open(ADMIN), ["agent-t1"])
            h.read_tails()
            tails = [it[2] for _, it in h.ring if it[1] == "tail"]
            self.assertEqual(tails, [{"key": "agent-t1", "start": 0, "lines": ["a", "b"]}, {"key": "agent-t1", "start": 2, "lines": ["c"]},
                                     {"key": "agent-t1", "start": 0, "lines": ["b", "c", "d"]}, {"key": "agent-t1", "start": 0, "lines": ["b", "c", "d"]}])
            self.assertEqual(calls, ["agent-t1"] * 5)  # one read for the two viewers
            h.close(s1), h.close(s2)
            for s in list(h.streams.values()):
                h.close(s)
            h.read_tails()
            self.assertEqual(h.tails, {})
        finally:
            server.agent_tail = keep


def db_init():
    if os.path.exists(os.environ["FXA_DB"]):
        os.remove(os.environ["FXA_DB"])
    subprocess.run(["bash", "-c", f'source "{ROOT}/lib/db.sh"; db_init >/dev/null'], check=True)
    return sqlite3.connect(os.environ["FXA_DB"], isolation_level=None)


@unittest.skipUnless(shutil.which("sqlite3") and shutil.which("jq"), "needs sqlite3 and jq")
class Store(unittest.TestCase):
    def setUp(self):
        self.hub, self.con = reset_server(), db_init()
        self.hub.read_store()  # the first read takes the cursor and the errors

    def tearDown(self):
        self.con.close()

    def deltas(self):
        return [it[2] for _, it in self.hub.ring if it[1] == "delta"]

    def test_no_key_is_lost_past_1000_changes(self):
        self.con.executemany("INSERT INTO sessions (key, data) VALUES (?, json(?))",
                             [(f"agent-k{i:04d}", json.dumps({"key": f"agent-k{i:04d}", "state": "active", "created": i})) for i in range(2500)])
        self.hub.read_store()
        d = self.deltas()
        self.assertEqual(len(d), 1)
        self.assertEqual([r["key"] for r in d[0]["rows"]], [f"agent-k{i:04d}" for i in range(2500)])
        self.assertEqual(d[0]["rows"][0]["media"], [])
        ro = server.fxadb.connect(readonly=True)
        a = server.fxadb.sessions_since(ro, 0, TMP, limit=1000)
        b = server.fxadb.sessions_since(ro, a["cursor"], TMP, limit=1000)
        c = server.fxadb.sessions_since(ro, b["cursor"], TMP, limit=1000)
        self.assertEqual(len({r["key"] for r in a["rows"] + b["rows"] + c["rows"]}), 2500)
        self.assertEqual(server.fxadb.sessions_since(ro, c["cursor"], TMP)["rows"], [])
        ro.close()

    def test_each_table_gives_its_delta(self):
        c, h = self.con, self.hub
        h.sessions = {"agent-s1": {"key": "agent-s1", "agent": {"turns": 4}, "agent_alive": True}}
        c.execute("INSERT INTO sessions (key, data) VALUES ('agent-s1', json('{\"key\":\"agent-s1\",\"state\":\"active\",\"profile\":\"fxa\"}'))")
        c.execute("INSERT INTO sessions (key, data) VALUES ('agent-s2', json('{\"key\":\"agent-s2\",\"state\":\"stopped\",\"owner\":\"U-DRYRUN\"}'))")
        c.execute("INSERT INTO history (key, at, role, text) VALUES ('agent-s1', 1, 'user', 'x')")
        c.execute("INSERT INTO routines (id, team, data) VALUES (5, 'crew', '{\"name\":\"Sample\"}')")
        c.execute("INSERT INTO routines (id, team, data) VALUES (6, 'crew', '{}')")
        c.execute("DELETE FROM routines WHERE id = 6")
        c.execute("INSERT INTO routine_runs (id, routine_id, period, state) VALUES (1, 5, 'p1', 'ok'), (2, 5, 'p2', 'started')")
        c.execute("INSERT INTO routine_tick_env (env, at) VALUES ('live', 9)")
        c.execute("INSERT INTO team_audit (at, actor, team, action) VALUES (3, 'user@example.com', 'crew', 'update')")
        c.execute("INSERT INTO ingest (tbl, j) VALUES ('errors', ?)", (json.dumps({"at": "2026-11-03T00:00:00Z", "source": "ctl", "kind": "crash", "key": "agent-s1",
                                                                                   "where": "x", "message": "sample", "log": None, "sig": "abc"}),))
        c.execute("INSERT INTO runs (issue, kind) VALUES ('EX-1', 'run')")
        h.read_store()
        d = {x["tbl"]: x for x in self.deltas()}
        s = d["sessions"]
        self.assertEqual((s["rows"][0]["agent"], s["rows"][0]["agent_alive"], s["deleted"]), ({"turns": 4}, True, ["agent-s2"]))
        self.assertEqual(d["history"]["rows"], [{"key": "agent-s1"}])
        self.assertEqual((d["routines"]["rows"], d["routines"]["deleted"]), ([{"id": 5, "team": "crew", "name": "Sample", "paused": False, "version": 1}], ["6"]))
        self.assertEqual([(r["routine_id"], r["id"], r["state"]) for r in d["routine_runs"]["rows"]], [(5, 2, "started")])
        self.assertEqual(d["routine_tick"]["rows"], [{"env": "live", "at": 9}])
        self.assertEqual(d["team_audit"]["rows"][0]["action"], "update")
        self.assertEqual(d["errors"]["rows"], h.errors)
        self.assertTrue(h.due)
        for tbl in ("routines", "routine_runs", "team_audit"):
            self.assertEqual(next(it[3] for _, it in h.ring if it[1] == "delta" and it[2]["tbl"] == tbl)["teams"], ["crew"])
        self.assertEqual(problems([{"id": f"e1-{i + 1}", "event": "delta", "data": x} for i, x in enumerate(self.deltas())])[:1],
                         ["frame 1 (delta): a stream starts with hello"])

    def test_errors_in_process_equal_the_ctl(self):
        now = time.time()
        old = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now - 30 * 86400))
        new = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now - 60))
        lines = [{"at": new, "source": "ctl", "kind": "crash", "key": f"agent-e{i}", "where": "w", "message": "m", "log": "l", "sig": "s1"} for i in range(7)]
        lines += [{"at": old, "source": "bot", "kind": "post", "key": None, "where": "b", "message": "quiet one", "log": None, "sig": "s2"},
                  {"at": old, "source": "bot", "kind": "post", "key": None, "where": "b", "message": "fixed", "log": None, "sig": "s3"},
                  {"at": new, "source": "bot", "kind": "post", "key": None, "where": "b", "message": "back", "log": None, "sig": "s4"}]
        for x in lines:
            self.con.execute("INSERT INTO ingest (tbl, j) VALUES ('errors', ?)", (json.dumps(x),))
        for sig in ("s3", "s4"):
            self.con.execute("INSERT INTO ingest (tbl, j) VALUES ('error_resolutions', ?)", (json.dumps({"sig": sig, "at": old[:-1] + "1Z" if sig == "s4" else new, "note": "n"}),))
        out = subprocess.run(["bash", "-c", f'source "{ROOT}/lib/db.sh"; source "{ROOT}/lib/errors.sh"; cmd_errors --json'], capture_output=True, text=True, check=True).stdout
        ro = server.fxadb.connect(readonly=True)
        mine = server.fxadb.errors_rows(ro, now)
        ro.close()
        self.assertEqual(mine, json.loads(out))
        self.assertEqual(sorted(e["status"] for e in mine), ["open", "quiet", "reopened", "resolved"])
        self.assertEqual(next(e for e in mine if e["sig"] == "s1")["keys"], [f"agent-e{i}" for i in range(2, 7)])

    def test_an_error_turns_quiet_with_the_clock_with_no_store_change(self):
        h, now = self.hub, time.time()
        at = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now - 7 * 86400 + 30))
        self.con.execute("INSERT INTO ingest (tbl, j) VALUES ('errors', ?)", (json.dumps({"at": at, "source": "ctl", "kind": "crash", "key": None,
                                                                                          "where": "w", "message": "m", "log": None, "sig": "q1"}),))
        h.read_store(now)
        self.assertEqual([e["status"] for e in h.errors], ["open"])
        n = h.n
        h.read_store(now + 10)
        self.assertEqual(h.n, n)
        h.read_store(now + 61)
        self.assertEqual([e["status"] for e in h.errors], ["quiet"])
        self.assertEqual(self.deltas()[-1], {"tbl": "errors", "rows": h.errors, "deleted": []})
        self.assertEqual(json.loads(testkit.request(f"{BASE}/api/errors")[2])[0]["status"], "quiet")

    def test_api_errors_reads_the_hub_and_record_admins_read_the_file(self):
        self.hub.read_store()
        self.assertEqual(json.loads(testkit.request(f"{BASE}/api/errors")[2]), [])
        write(f"{TMP}/teams/crew.json", {"admins": [{"email": "Crew@Example.com"}, {"slack": "U0EXAMPLE"}]})
        self.assertEqual(server.team_record_admins("crew"), frozenset({"crew@example.com"}))  # CTL is a missing file: no ctl ran
        server.HUB, server._REC_ADMINS = None, {}
        self.assertEqual(server.team_record_admins("crew"), frozenset())


class Stats(unittest.TestCase):
    def test_stats_frames_chain_etags_and_inproc_answers_the_copy(self):
        h = reset_server()
        copies = [{"rows": [{"k": 1}], "llm": {"a": 1}, "top": []}, {"rows": [{"k": 1}, {"k": 2}], "llm": {"a": 2}, "top": []},
                  {"rows": [{"k": 9}], "llm": {"a": 2}, "top": []}]
        h.compute = lambda con, files: copies.pop(0)
        g = h.open(ANON).frames()
        pull(g), pull(g)
        h.recompute()
        e1 = h.stats_etag
        st = testkit.request(f"{BASE}/api/stats?inproc=1")
        self.assertEqual((st[0], st[1].get("ETag"), json.loads(st[2])), (200, e1, {"rows": [{"k": 1}], "llm": {"a": 1}, "top": []}))
        h.recompute()
        f = pull(g)
        self.assertEqual(f["data"], {"base": e1, "etag": h.stats_etag, "rows_add": [{"k": 2}], "llm": {"a": 2}})
        e2 = h.stats_etag
        h.recompute()
        self.assertEqual(pull(g)["data"], {"base": e2, "etag": h.stats_etag, "reload": True})
        self.assertEqual(problems([{"id": "e1-1", "event": "stats", "data": f["data"]}])[:1], ["frame 1 (stats): a stream starts with hello"])
        server.STATS = feed("stats", {"rows": ["shell"]})
        self.assertEqual(json.loads(testkit.request(f"{BASE}/api/stats")[2]), {"rows": ["shell"]})

    def test_the_port_runs_only_with_its_flag_and_logs_its_diff_each_hour(self):
        server.STATS = feed("stats", {"rows": ["shell"], "llm": {}})
        self.assertIs(reset_server().compute(None, {}), server.STATS.data)
        os.environ["FXA_STATS_INPROC"] = "1"
        try:
            h = reset_server()
        finally:
            del os.environ["FXA_STATS_INPROC"]
        self.assertIs(h.compute, live.stats.compute)
        server.STATS = feed("stats", {"rows": ["shell"], "llm": {}})
        h.compute, err = (lambda con, files: {"rows": ["shell"], "llm": {"a": 1}}), io.StringIO()
        with contextlib.redirect_stderr(err):
            h.recompute()
            h.recompute()
        self.assertEqual(err.getvalue(), "stats: 1 keys differ between the shell and the in-process copy: llm\n")

    def test_the_hub_gives_stats_compute_the_files_it_reads(self):
        h = reset_server()
        self.assertEqual(set(h.files()), set(live.stats.files("fxa")))
        server.PIPELINE = "fxa-ai-fixme"
        self.assertEqual(h.files()["state"], live.stats.files("fxa")["state"])


def golden_inputs():
    """(name, SNAP, AGENTS, the v1 laneRows) of each golden file, the fixture times at the golden clock."""
    for path in sorted(glob.glob(os.path.join(GOLDEN, "*.json"))):
        with open(path) as a, open(os.path.join(ROOT, "skills", "fxa-ctl-dev", os.path.basename(path))) as b:
            g, fx = json.load(a), json.load(b)
        now = g["now"] / 1000
        snap = g["pipeSnap"] if isinstance(g["pipeSnap"], dict) else None  # "undefined": the page had no snapshot
        yield os.path.basename(path), snap, rel(fx, now).get("/api/snapshot", {}).get("agents"), g["laneRows"]


def rel(v, now):
    import datetime
    import re
    if isinstance(v, dict):
        return {k: rel(x, now) for k, x in v.items()}
    if isinstance(v, list):
        return [rel(x, now) for x in v]
    m = re.fullmatch(r"@(iso|epoch|day)([+-]\d+)", v) if isinstance(v, str) else None
    if not m:
        return v
    if m.group(1) == "day":
        return (datetime.datetime.fromtimestamp(now, datetime.timezone.utc).date() + datetime.timedelta(days=int(m.group(2)))).isoformat()
    t = now + int(m.group(2))
    return int(t) if m.group(1) == "epoch" else datetime.datetime.fromtimestamp(t, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


class Flow(unittest.TestCase):
    def test_belt_stops_equal_the_v1_lane_rows(self):
        seen = 0
        for name, snap, agents, lanes in golden_inputs():
            if isinstance(lanes, dict):  # the v1 function threw on this fixture
                continue
            seen += len(lanes)
            self.assertEqual(sorted(live.belt_stops(snap, agents), key=str), sorted(((r["t"].get("key"), r["st"]) for r in lanes), key=str), name)
        self.assertGreater(seen, 10)


class Http(unittest.TestCase):
    def setUp(self):
        self.hub = reset_server()

    def tearDown(self):
        self.hub.shutdown()

    def open(self, path="/api/live", headers=None):
        return urllib.request.urlopen(urllib.request.Request(BASE + path, headers={"Host": "localhost", **(headers or {})}), timeout=10)

    def frame(self, r):
        f = {}
        while True:
            line = r.readline().decode()
            if not line:
                return f or None
            line = line.rstrip("\n")
            if not line:
                if f:
                    return f
                continue
            k, _, v = line.partition(": ")
            f[k] = json.loads(v) if k == "data" else v

    def test_off_is_one_bye_with_the_stream_headers(self):
        server.HUB = None
        r = self.open()
        self.assertEqual((r.status, r.headers["Content-Type"], r.headers["Cache-Control"], r.headers["X-Accel-Buffering"]),
                         (200, "text/event-stream", "no-store", "no"))
        self.assertEqual(r.read(), b'event: bye\ndata: {"reason":"off"}\n\n')

    def test_a_signed_admin_gets_hello_snapshot_then_deltas_and_resumes_with_since_or_last_event_id(self):
        h = self.hub
        write(f"{TMP}/teams/example.json", {"admins": [{"email": "admin@example.com"}]})
        h.sessions = {"agent-h1": {"key": "agent-h1", "profile": "example", "request": "words"}}
        r = self.open(headers=testkit.sig("admin@example.com", "GET", "/api/live"))
        hello, snap = self.frame(r), self.frame(r)
        self.assertEqual(hello["data"]["viewer"], {"user": "admin@example.com", "admin": True, "teams": ["example"]})
        self.assertEqual((snap["event"], snap["data"]["sessions"][0]["request"]), ("snapshot", "words"))
        h.publish("delta", {"tbl": "history", "rows": [{"key": "agent-h1"}], "deleted": []})
        d = self.frame(r)
        h.publish("delta", {"tbl": "history", "rows": [{"key": "agent-h2"}], "deleted": []})
        self.assertEqual(self.frame(r)["data"]["rows"], [{"key": "agent-h2"}])
        for x in (self.open(f"/api/live?since={d['id']}"), self.open(headers={"Last-Event-ID": d["id"]})):
            self.assertEqual([self.frame(x)["event"], self.frame(x)["data"]["rows"]], ["hello", [{"key": "agent-h2"}]])
        anon = self.open()
        self.assertEqual(self.frame(anon)["data"]["viewer"], ANON)
        self.assertNotIn("request", self.frame(anon)["data"]["sessions"][0])
        self.assertEqual(problems([hello, snap, d]), [])

    def test_the_cap_answers_bye_full(self):
        held = 0
        while server.LIVE.acquire(blocking=False):
            held += 1
        try:
            self.assertEqual(self.open().read(), b'event: bye\ndata: {"reason":"full","retry_s":30}\n\n')
        finally:
            for _ in range(held):
                server.LIVE.release()
        self.assertGreater(held, 0)

    def test_tails_post_checks(self):
        r = self.open(headers=testkit.sig("user@example.com", "GET", "/api/live"))
        sid = self.frame(r)["data"]["sid"]
        self.frame(r)
        self.hub.sessions = {"agent-p9p9": {"key": "agent-p9p9", "profile": "example"}, "agent-ex01": {"key": "agent-ex01", "profile": "fxa"}}
        post = lambda body, user="user@example.com", ctype="application/json": testkit.request(
            f"{BASE}/api/live/tails", "POST", json.dumps(body).encode(),
            {"Content-Type": ctype, **(testkit.sig(user, "POST", "/api/live/tails") if user else {})})[0::2]
        self.assertEqual(post({"sid": sid, "keys": []}, ctype="text/plain")[0], 415)
        self.assertEqual(post({"sid": sid, "keys": ["agent-1"] * 9})[0], 400)
        self.assertEqual(post({"sid": sid, "keys": ["../x"]})[0], 400)
        self.assertEqual(post({"keys": []})[0], 400)
        self.assertEqual(post({"sid": "nope", "keys": []})[0], 403)
        self.assertEqual(post({"sid": sid, "keys": []}, user="other@example.com")[0], 403)
        self.assertEqual(post({"sid": sid, "keys": []}, user=None)[0], 403)
        self.assertEqual(post({"sid": sid, "keys": ["agent-p9p9"]})[0], 403)
        self.assertEqual(json.loads(post({"sid": sid, "keys": ["AGENT-ex01", "FXA-12"]})[1]), {"ok": True, "keys": ["agent-ex01", "FXA-12"]})
        self.assertEqual(self.hub.streams[sid].keys, {"agent-ex01", "FXA-12"})
        server.HUB = None
        self.assertEqual(post({"sid": sid, "keys": []})[0], 404)


BASE = testkit.start(server.Handler)

if __name__ == "__main__":
    try:
        unittest.main()
    finally:
        shutil.rmtree(TMP, ignore_errors=True)
