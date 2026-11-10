"""The hub of GET /api/live (C1: dashboard/live_schema.py and dashboard-v2/src/live/schema.ts).

One thread reads the store's changes, the feeds and a few files each second and puts events in a ring and on
each open stream's queue. A second thread reads the subscribed tails every 5 s. Each stream thread builds its own
snapshot and redacts each event for its own viewer; the hub never writes to a socket. server.py starts the hub
only with FXA_LIVE=1 and passes itself as srv, so this module reads the feeds and the redaction from there.
"""
import collections
import glob
import hashlib
import json
import os
import queue
import secrets
import sys
import threading
import time

import fxadb

try:
    import stats  # the in-process port of snapshot --stats
except ImportError:
    stats = None

RING_MAX, QUEUE_MAX, MAX_KEYS = 5000, 512, 8
RETENTION_S, MAX_LIFE_S, PING_S, TAIL_S, FLOW_S, SEEN_S, STATS_DELAY_S, ERRORS_S = 300, 900, 15, 5, 60, 60, 5, 60
STATS_TABLES = {"runs", "passes", "job_costs", "llm"}
# The tables that only a team admin reads (routines are admins only, D1); a record admin gets the rows of their teams,
# but not team_audit: /api/teams/<t>/audit is for team admins only.
ADMIN_TABLES = {"routines", "routine_runs", "routine_tick", "team_audit"}
STATS_PARTS = ("prs", "prs_at", "llm", "load", "pipeline", "memory", "tickets", "kinds", "models", "ranges", "team_passes", "top", "weeks")
STAGE_STOP = {"starting": 1, "watching": 2, "stalled": 2, "error": 2, "squashing": 3, "pushed": 4, "pr": 5}


def _num(v):
    return v if isinstance(v, (int, float)) and not isinstance(v, bool) else 0


def belt_stops(snap, agents):
    """(key, stop) of each belt, as v1 laneRows places it; the stop is an index in LANE_ST (Queue .. Merged)."""
    snap, agents = snap or {}, agents or {}
    inflight, runners = snap.get("inflight") or [], agents.get("runners") or []
    by, run = {t.get("key"): t for t in inflight}, {r.get("key") for r in runners}
    waiting = [t for t in inflight if t.get("key") not in run]
    cards = [dict(by.get(r.get("key")) or {}, **r) for r in runners] + [dict(t, ci=True) for t in waiting if t.get("stage") == "pr"]
    # merged(): a young start with no runner yet is booting, not a fault.
    cards += [t for t in waiting if t.get("stage") == "starting" and _num(t.get("elapsed_seconds") if t.get("elapsed_seconds") is not None else 1e18) < 600]
    out = [(c.get("key"), 6 if c.get("ci") else STAGE_STOP.get(c.get("stage"), 2)) for c in cards]
    seen = {k for k, _ in out}
    for r in snap.get("review") or []:
        if r.get("key") not in seen:
            busy = r.get("mergeable") == "CONFLICTING" or _num(r.get("fail")) > 0 or _num(r.get("running")) > 0
            out.append((r.get("key"), 8 if r.get("state") in ("MERGED", "CLOSED") else 6 if busy else 7))
    keys, blocked, prs = {k for k, _ in out}, {b.get("key") for b in snap.get("blocked") or []}, snap.get("open_prs") or []
    out += [(p["key"], 7 if p["key"] in blocked else 5) for p in prs if p.get("key") and p["key"] not in keys]
    return out + [(p.get("branch"), 7) for p in prs if not p.get("key")]


def flow_point(snap, agents, now):
    """One FlowPoint: the belts at each of the 9 stops, the merged PRs and the closed ones."""
    stops = [0] * 9
    for _, st in belt_stops(snap, agents):
        stops[st] += 1
    review = (snap or {}).get("review") or []
    return {"at": int(now), "stops": stops, "merged": len((snap or {}).get("merged_prs") or []),
            "closed": sum(1 for r in review if r.get("state") == "CLOSED")}


def stub_parts(old, new):
    """stats.parts until dashboard/stats.py lands: rows_add when the old rows lead the new ones, else reload."""
    o, n = old.get("rows") or [], new.get("rows") or []
    if n[:len(o)] != o:
        return {"reload": True}
    out = {k: new[k] for k in STATS_PARTS if k in new and new[k] != old.get(k)}
    return dict(out, rows_add=n[len(o):]) if len(n) > len(o) else out


class Stream:
    """One open /api/live connection: its viewer, its queue and the tails it shows."""

    def __init__(self, hub, viewer, since):
        self.hub, self.viewer, self.since = hub, viewer, since
        self.sid = secrets.token_urlsafe(12)
        self.q, self.reset, self.bye, self.keys = queue.Queue(hub.queue_max), False, None, set()
        self.deadline = time.time() + hub.max_life_s

    def put(self, item):
        """Called with the hub lock held. A full queue is dropped, and the stream sends reset and a new snapshot."""
        if self.reset:
            return
        try:
            self.q.put_nowait(item)
        except queue.Full:
            self.reset = True

    def frames(self):
        """hello, then a snapshot or the ring replay, then each event; None when a second passes with no event."""
        h, since = self.hub, self.since
        yield {"event": "hello", "data": {"v": 1, "epoch": h.epoch, "sid": self.sid, "viewer": self.viewer,
                                          "retention_s": h.retention_s, "max_life_s": h.max_life_s}}
        while True:
            replay, snap = h.attach(self, since)
            if snap:
                yield {"id": f"{h.epoch}-{snap[0]}", "event": "snapshot", "data": h.snapshot(snap[1], self.viewer)}
            for item in replay or ():
                f = self.render(item)
                if f:
                    yield f
            while not self.reset:
                if self.bye or time.time() > self.deadline:
                    yield {"event": "bye", "data": {"reason": self.bye or "max_life"}}
                    return
                try:
                    f = self.render(self.q.get(timeout=1))
                except queue.Empty:
                    f = None
                yield f
            yield {"event": "reset", "data": {"reason": "queue_full"}}
            since = None

    def render(self, item):
        n, event, data, meta = item
        data = self.hub.view(event, data, meta, self.viewer)
        if data is None:
            return None
        return {"event": event, "data": data} if n is None else {"id": f"{self.hub.epoch}-{n}", "event": event, "data": data}


class LiveHub:
    def __init__(self, srv):
        self.srv = srv
        self.epoch, self.n, self.trimmed = secrets.token_hex(4), 0, 0
        self.lock = threading.Lock()
        self.ring = collections.deque()  # (published at, (n, event, data, meta))
        self.streams = {}
        self.retention_s, self.max_life_s, self.queue_max = RETENTION_S, MAX_LIFE_S, QUEUE_MAX
        # The state a snapshot sends. Each is replaced, never changed in place, so a stream reads it with no lock.
        self.feeds, self.sessions, self.fresh, self.errors = {}, {}, {}, None
        self.flow = collections.deque(maxlen=1440)  # 24 h of minutes; a restart loses them
        self.stats = self.stats_etag = None
        self.cursor, self.due = None, None
        self.sig, self.hash, self.mtimes, self.tails, self.resend = {}, {}, {}, {}, set()
        self.pinged = self.seen_at = self.errors_at = 0.0
        self.flowed = time.time()
        self.closed = False
        self.stats_lock = threading.Lock()
        # FXA_STATS_INPROC=1 runs the port next to the shell feed and logs their diff each hour; else the hub sends the shell copy.
        self.differ = stats.Live(None, None, None) if stats and os.environ.get("FXA_STATS_INPROC") == "1" else None
        self.compute = stats.compute if self.differ else (lambda con, files: srv.STATS.read()[0])
        self.parts = stats.parts if stats else stub_parts

    # The ring and the streams.

    def publish(self, event, data, meta=None):
        """Put one ring event on every stream."""
        with self.lock:
            self.n += 1
            now, item = time.time(), (self.n, event, data, meta or {})
            self.ring.append((now, item))
            while self.ring and (len(self.ring) > RING_MAX or self.ring[0][0] < now - self.retention_s):
                self.trimmed = self.ring.popleft()[1][0]
            for s in self.streams.values():
                s.put(item)

    def broadcast(self, event, data):
        """Put one event that has no id (ping) on every stream."""
        with self.lock:
            for s in self.streams.values():
                s.put((None, event, data, {}))

    def open(self, viewer, since=None):
        return Stream(self, viewer, since)

    def attach(self, s, since):
        """Register s with a new queue. (ring events after since, None) when the ring still has them; else
        (None, (the snapshot's n, the state)): no since, another epoch, an n the ring lost, or after a reset."""
        with self.lock:
            s.q, s.reset = queue.Queue(self.queue_max), False
            self.streams[s.sid] = s
            ep, _, n = (since or "").partition("-")
            if ep == self.epoch and n.isdigit() and self.trimmed <= int(n) <= self.n:
                return [it for _, it in self.ring if it[0] > int(n)], None
            self.n += 1
            return None, (self.n, {"feeds": self.feeds, "sessions": list(self.sessions.values()), "errors": self.errors,
                                   "flow": list(self.flow)})

    def close(self, s):
        with self.lock:
            self.streams.pop(s.sid, None)

    def shutdown(self, reason="shutdown"):
        with self.lock:
            self.closed = True
            for s in self.streams.values():
                s.bye = reason

    def subscribe(self, s, keys):
        """The tails that stream s shows. A key another stream already reads sends its whole window again."""
        with self.lock:
            s.keys = set(keys[:MAX_KEYS])
            self.resend |= s.keys & set(self.tails)

    # What one viewer may see.

    def private_key(self, key):
        """True when the session's team is private; a ticket key is not a session."""
        if not key.startswith("agent-"):
            return False
        s = self.sessions.get(key)
        return self.srv.row_private(s) if isinstance(s, dict) else self.srv.session_private(key)

    def view(self, event, d, meta, v):
        """The data of one event for viewer v, or None to leave the event out."""
        srv, admin = self.srv, v["admin"]
        if event == "feed":
            return self.feed_view(d, v)
        if event == "tail":
            return d if admin or not self.private_key(d["key"]) else None
        if event != "delta":
            return d
        if d["tbl"] == "sessions":
            return dict(d, rows=[srv.session_for(r, admin) for r in d["rows"]])
        if d["tbl"] == "team_audit" and not admin:
            return None
        if d["tbl"] in ADMIN_TABLES and not admin:
            rows = [r for r, t in zip(d["rows"], meta.get("teams") or []) if t in v["teams"]]
            return dict(d, rows=rows) if v["teams"] and (rows or d["deleted"]) else None
        return d

    def feed_view(self, f, v):
        srv, admin, name = self.srv, v["admin"], f["name"]
        if name == "agents" and "data" in f:
            return dict(f, data=srv.agents_for(f["data"], admin))
        if name.startswith("team-test:"):
            return f if admin else None  # the log carries runner text, as /api/teams/<t>/test
        if name.startswith("snapshot:"):
            t, recs = name.split(":", 1)[1], srv.read_records()
            if t not in srv.pipeline_teams(recs) or (recs[t].get("secret") is True and not admin):
                return None
            if "data" in f:  # the secret check is above: a None here is a failed first read, which v1 sends with its error
                return dict(f, data=srv.team_snapshot(t, f["data"], recs[t], admin, srv.STATE_ROOT))
        return f

    def snapshot(self, state, v):
        now, feeds = time.time(), {}
        for name, f in state["feeds"].items():
            f = self.feed_view(dict(f, age_seconds=None if f["fetched_at"] is None else round(now - f["fetched_at"])), v)
            if f is not None:
                feeds[name] = f
        return {"feeds": feeds, "sessions": [self.srv.session_for(s, v["admin"]) for s in state["sessions"]],
                "errors": state["errors"] or [], "stats": None, "flow": state["flow"]}

    # The readers.

    def start(self):
        threading.Thread(target=self.recompute, daemon=True).start()
        for f, every in ((self.tick, 1), (self.read_tails, TAIL_S)):
            threading.Thread(target=self._loop, args=(f, every), daemon=True).start()

    def _loop(self, f, every):
        while not self.closed:
            try:
                f()
            except Exception as exc:  # noqa: BLE001  one bad read must not stop the stream
                print(f"live: {f.__name__} failed: {type(exc).__name__}: {exc}"[:300], file=sys.stderr, flush=True)
            time.sleep(every)

    def tick(self, now=None):
        now = now or time.time()
        self.read_feeds()
        self.read_store(now)
        self.read_files(now)
        self.timers(now)

    def read_feeds(self):
        """A feed frame when a feed's fetched_at, error or refreshing changes; its data only when the data changed."""
        srv = self.srv
        named = [("snapshot", srv.FULL), ("agents", srv.AGENTS), ("teams", srv.TEAMS)] + [(f"snapshot:{t}", f) for t, f in sorted(srv.TEAM_FEEDS.items())]
        for name, feed in named:
            data, age, err, busy = feed.read()
            if self.sig.get(name) == (feed.fetched_at, err, busy):
                continue
            self.sig[name] = (feed.fetched_at, err, busy)
            if name == "teams":
                data = srv.team_rows(data)[0]
            frame = {"name": name, "age_seconds": age, "interval": feed.interval, "error": err, "refreshing": busy, "fetched_at": feed.fetched_at}
            self.put_feed(frame, data)
            if name == "agents":
                self.sessions_from(data)

    def put_feed(self, frame, data):
        h = hashlib.sha1(json.dumps(data, sort_keys=True).encode()).hexdigest()  # the hash the ETags use
        new, self.hash[frame["name"]] = h != self.hash.get(frame["name"]), h
        self.feeds = dict(self.feeds, **{frame["name"]: dict(frame, data=data)})
        self.publish("feed", dict(frame, data=data) if new else frame)

    def sessions_from(self, ag):
        """The feed's sessions, with each store row that is newer than the feed's (v1's overlay())."""
        out = {s["key"]: s for s in (ag or {}).get("sessions") or [] if isinstance(s, dict) and s.get("key")}
        fresh = dict(self.fresh)
        for k, r in self.fresh.items():
            s = out.get(k)
            if r.get("deleted"):
                out.pop(k, None)
                fresh.pop(k)
            elif s and (s.get("last_activity") or 0) >= (r.get("last_activity") or 0):
                fresh.pop(k)  # the feed caught up
            else:
                out[k] = dict(r, agent=(s or {}).get("agent"), agent_alive=(s or {}).get("agent_alive") or False)
        self.sessions, self.fresh = out, fresh

    def read_store(self, now=None):
        if not os.path.exists(fxadb.PATH):
            return
        now = now or time.time()
        con = fxadb.connect(readonly=True)
        try:
            if self.cursor is None:
                self.cursor = con.execute("SELECT coalesce(max(version), 0) FROM changes").fetchone()[0]
                self.errors, self.errors_at = fxadb.errors_rows(con, now), now
                return
            self.cursor, changed = fxadb.changes_since(con, self.cursor)
            keys = {}
            for _, tbl, key in changed:
                keys.setdefault(tbl, {})[str(key)] = None  # an ordered set, as text (C1 delta.deleted)
            if keys.keys() & STATS_TABLES and not self.due:
                self.due = time.time() + STATS_DELAY_S
            for tbl in ("sessions", "history", "routines", "routine_runs", "routine_tick", "team_audit"):
                if tbl in keys:
                    self.read_table(con, tbl, list(keys[tbl]))
            if "errors" in keys or now - self.errors_at >= ERRORS_S:
                self.read_errors(con, now)
        finally:
            con.close()

    def read_errors(self, con, now):
        """The errors again, and a delta with each row that changed: a status turns quiet with the clock, not with a change."""
        old = {e["sig"]: e for e in self.errors or []}
        self.errors, self.errors_at = fxadb.errors_rows(con, now), now
        new = {e["sig"] for e in self.errors}
        rows, deleted = [e for e in self.errors if old.get(e["sig"]) != e], [k for k in old if k not in new]
        if rows or deleted:
            self.publish("delta", {"tbl": "errors", "rows": rows, "deleted": deleted}, {"teams": []})

    def read_table(self, con, tbl, keys):
        """One delta for the changed keys of one table: the current rows, and the keys that are gone."""
        rows, deleted, teams = [], [], []
        if tbl == "history":
            rows = [{"key": k} for k in keys]
        elif tbl == "sessions":
            sessions, fresh, d = dict(self.sessions), dict(self.fresh), str(self.srv.SESSION_DIR)
            for k in keys:
                r = con.execute("SELECT data FROM sessions WHERE key = ?", (k,)).fetchone()
                rec = json.loads(r[0]) if r else None
                if not isinstance(rec, dict) or fxadb.is_over_test(rec):
                    deleted.append(k)
                    sessions.pop(k, None)
                    fresh[k] = {"key": k, "deleted": True}
                    continue
                live = sessions.get(k) or {}
                row = dict(fxadb.session_row(rec, d), agent=live.get("agent"), agent_alive=live.get("agent_alive") or False)
                rows.append(row)
                sessions[k] = fresh[k] = row
            self.sessions, self.fresh = sessions, fresh
        else:
            sql = {"routines": "SELECT id, team, json_extract(data, '$.name') AS name, paused, version, team AS _team FROM routines WHERE id = ?",
                   "routine_runs": "SELECT r.routine_id, r.id, r.period, r.state, r.trigger, r.session, r.started_at, r.ended_at, r.cost_usd, t.team AS _team"
                                   " FROM routine_runs r LEFT JOIN routines t ON t.id = r.routine_id WHERE r.routine_id = ? ORDER BY r.id DESC LIMIT 1",
                   "routine_tick": "SELECT env, at, NULL AS _team FROM routine_tick_env WHERE env = ?",
                   "team_audit": "SELECT team, at, actor, action, old_gen, new_gen, changed, team AS _team FROM team_audit WHERE team = ? ORDER BY id DESC LIMIT 1"}[tbl]
            for k in keys:
                r = con.execute(sql, (k,)).fetchone()
                if r is None:
                    deleted.append(k)
                    continue
                r = dict(r)
                teams.append(r.pop("_team"))
                if tbl == "routines":
                    r["paused"] = bool(r["paused"])
                rows.append(r)
        if rows or deleted:
            self.publish("delta", {"tbl": tbl, "rows": rows, "deleted": deleted}, {"teams": teams})

    def read_files(self, now):
        """prs.json for the stats; each team test's files for its team-test:<team> feed."""
        srv = self.srv
        m = _mtime(os.path.join(os.path.dirname(srv.ERRORS_FILE), "prs.json"))
        if self.mtimes.setdefault("prs.json", m) != m:
            self.mtimes["prs.json"] = m
            self.due = self.due or now + STATS_DELAY_S
        teams = os.environ.get("FXA_TEAMS_DIR") or os.path.expanduser("~/.claude/state/teams")
        for log in sorted(glob.glob(os.path.join(teams, "*.test.log"))):
            t = os.path.basename(log)[:-len(".test.log")]
            sig = tuple(_mtime(os.path.join(teams, t + e)) for e in (".test.log", ".test.pid", ".tested"))
            if self.mtimes.get(t) == sig:
                continue
            self.mtimes[t] = sig
            data = srv.team_test_tail(t, now)
            if data is not None:
                self.put_feed({"name": f"team-test:{t}", "age_seconds": 0, "interval": 1, "error": None, "refreshing": False, "fetched_at": now}, data)

    def timers(self, now):
        if now - self.pinged >= PING_S:
            self.pinged = now
            self.broadcast("ping", {"at": int(now)})
        if self.streams and now - self.seen_at >= SEEN_S:
            self.seen_at = now
            self.srv.seen()  # a viewer with a stream open keeps the gated feeds awake
        if now - self.flowed >= FLOW_S:
            self.flowed = now
            p = flow_point(self.srv.FULL.read()[0], self.srv.AGENTS.read()[0], now)
            with self.lock:
                self.flow.append(p)
            self.publish("flow", p)
        if self.due and now >= self.due:
            self.due = None
            threading.Thread(target=self.recompute, daemon=True).start()

    def files(self):
        """The local files of stats.compute(con, files): the ones snapshot --stats reads for this server's pipeline."""
        p = getattr(self.srv, "PIPELINE", "fxa")
        return stats.files("fxa" if p == "fxa-ai-fixme" else p) if stats else {}

    def etag(self, obj):
        """The ETag that /api/stats?inproc=1 sends for obj (Handler._send)."""
        body = self.srv.MASK.sub(r"\1<masked>", json.dumps(obj)).encode()
        return f'"{hashlib.sha1(body).hexdigest()[:20]}"'

    def recompute(self):
        """The in-process stats again; a stats frame with the parts that changed since the last copy."""
        if not self.stats_lock.acquire(blocking=False):
            self.due = self.due or time.time() + STATS_DELAY_S
            return
        try:
            con = fxadb.connect(readonly=True) if os.path.exists(fxadb.PATH) else None
            try:
                new = self.compute(con, self.files())
            finally:
                if con:
                    con.close()
            if not isinstance(new, dict):
                return
            old, base, etag = self.stats, self.stats_etag, self.etag(new)
            self.stats, self.stats_etag = new, etag
            if self.differ:
                self.differ.data = new
                self.differ.hourly(self.srv.STATS.read()[0])
            if old is not None and etag != base:
                p = self.parts(old, new)
                if p is not None:
                    self.publish("stats", dict({"reload": True} if p.get("reload") else p, base=base, etag=etag))
        finally:
            self.stats_lock.release()

    def read_tails(self):
        """Each subscribed tail once for all viewers: the new lines, or the whole window when it moved."""
        with self.lock:
            keys = set().union(*(s.keys for s in self.streams.values()))
            resend, self.resend = self.resend, set()
        for k in set(self.tails) - keys:
            del self.tails[k]
        for k in sorted(keys):
            cur = self.srv.agent_tail(k)
            prev = None if k in resend else self.tails.get(k)
            self.tails[k] = cur
            # ponytail: a window that scrolled past 200 lines goes again whole; send an overlap if that costs too much.
            start = len(prev) if prev is not None and cur[:len(prev)] == prev else 0
            if prev is None or cur != prev:
                self.publish("tail", {"key": k, "start": start, "lines": cur[start:]})


def _mtime(p):
    try:
        return os.path.getmtime(p)
    except OSError:
        return None
