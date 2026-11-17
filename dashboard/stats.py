#!/usr/bin/env python3
"""The Stats feed in-process: a port of `fxa-sandbox-ctl snapshot --stats` (snapshot_stats_json in lib/snapshot.sh).
It reads the same store tables and files as the shell, and it gives the same JSON. stats.check.py runs both on
one fixture and compares them key by key. A change to the shell's stats needs the same change here.

  compute(con, files) -> dict | None   the whole /api/stats copy; None when the run log is empty, as the shell's null
  parts(old, new) -> dict | None       a C1 stats frame from old to new, or None when nothing changed
  files(pipeline) -> dict              the paths and settings the shell takes from its env and the ctl's .env
  Live                                 the hub's copy: a debounced recompute in its own thread, and the hourly diff

con is a store connection (fxadb.connect), or None where the shell's db_on is false: then the sessions, the LLM
calls and the dropped requests come from their files. The port never calls gh: the shell refreshes prs.json.

The jq helpers below copy jq 1.7 where Python differs: round is half away from zero, sort and group_by use
jq's order of types, `//` passes over null and false only, and a non-string object key is an error.
"""
import calendar
import glob
import hashlib
import json
import math
import os
import re
import sys
import threading
import time

from live_schema import STATS_PARTS

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEBOUNCE_S = 5
DIFF_S = 3600
MON = ("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec")


# jq semantics

def alt(v, d):
    return d if v is None or v is False else v


def true(v):
    return v is not None and v is not False


def g(o, *ks):
    for k in ks:
        if o is None:
            return None
        if not isinstance(o, dict):
            raise TypeError(f"cannot index {type(o).__name__}")
        o = o.get(k)
    return o


def jkey(v):
    if v is None:
        return (0,)
    if v is False:
        return (1,)
    if v is True:
        return (2,)
    if isinstance(v, (int, float)):
        return (3, v)
    if isinstance(v, str):
        return (4, v)
    if isinstance(v, list):
        return (5, [jkey(x) for x in v])
    ks = sorted(v)
    return (6, ks, [jkey(v[k]) for k in ks])


def sort_by(xs, f=lambda x: x):
    return sorted(xs, key=lambda x: jkey(f(x)))


def group_by(xs, f):
    out, last = [], object()
    for x in sort_by(xs, f):
        k = jkey(f(x))
        if out and k == last:
            out[-1].append(x)
        else:
            out.append([x])
            last = k
    return out


def unique(xs):
    return [grp[0] for grp in group_by(xs, lambda x: x)]


def jmax(xs):
    return max(xs, key=jkey) if xs else None


def jmin(xs):
    return min(xs, key=jkey) if xs else None


def add(xs):
    s = None
    for x in xs:
        s = x if s is None else s if x is None else s + x
    return s


def jround(x):
    a = abs(x)
    f = math.floor(a)
    r = f + 1 if a - f >= 0.5 else f
    return int(-r if x < 0 else r)


def r2(x):
    return jround(x * 100) / 100


def med(xs):
    xs = sort_by(xs)
    return xs[len(xs) // 2] if xs else None


def from_entries(pairs):
    out = {}
    for k, v in pairs:
        if not isinstance(k, str):
            raise TypeError("an object key must be a string")
        out[k] = v
    return out


def sl(v, a=None, b=None):
    return None if v is None else v[a:b]


def todate(t):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t))


def fromdate(s):
    if not isinstance(s, str):
        raise TypeError("fromdate needs a string")
    return calendar.timegm(time.strptime(s, "%Y-%m-%dT%H:%M:%SZ"))


def fromdate_or(s, d):
    try:
        return fromdate(s)
    except (TypeError, ValueError):
        return d


def bd(t):
    """strftime("%b %-d") in the C locale."""
    tm = time.gmtime(t)
    return f"{MON[tm.tm_mon - 1]} {tm.tm_mday}"


def tonum(v):
    """jq's `n`: null or "" is null, else tonumber? // null."""
    if v is None or v == "":
        return None
    if isinstance(v, bool):
        return None
    if isinstance(v, (int, float)):
        return v
    if isinstance(v, str) and re.fullmatch(r"-?[0-9]+", v):
        return int(v)
    if isinstance(v, str) and re.fullmatch(r"-?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][+-]?[0-9]+)?", v):
        return float(v)
    return None


def fromjson_or(v, d):
    if not isinstance(v, str):
        return d
    try:
        return alt(json.loads(v), d)
    except ValueError:
        return d


def raw(v):
    """A value as `jq -r` prints it."""
    return v if isinstance(v, str) else json.dumps(v, separators=(",", ":"))


def values(text):
    """Each JSON value in the text in turn, as jq reads a stream; raises at the first bad one."""
    dec, i = json.JSONDecoder(), 0
    while True:
        while i < len(text) and text[i] in " \t\r\n":
            i += 1
        if i >= len(text):
            return
        v, i = dec.raw_decode(text, i)
        yield v


def read(path):
    with open(path, errors="replace") as f:
        return f.read()


def slurp(path):
    """Every JSON value in the file, as `jq -s` reads it; raises on a bad value."""
    return list(values(read(path)))


def nonempty(p):
    try:
        return os.path.getsize(p) > 0
    except OSError:
        return False


def lines(path):
    """The lines of a file as grep prints them: none for an empty file, the last one without its newline too."""
    try:
        t = read(path)
    except OSError:
        return []
    ls = t.split("\n")
    return ls[:-1] if t.endswith("\n") else ls if t else []


# The rows: one pipeline run, one pass or triage job

def runrow(r):
    pr = alt(r.get("pr"), "")
    m = re.search(r"/pull/(?P<n>[0-9]+)$", pr) if isinstance(pr, str) else None
    rr = re.search(r"github.com/(?P<r>[^/]+/[^/]+)/pull/", pr) if isinstance(pr, str) else None
    wall, launched = alt(r.get("wall_seconds"), 0), alt(r.get("launched_at"), 0)
    model = alt(r.get("model"), "")
    return {"at": r.get("recorded_at"), "src": "pipeline", "key": r.get("issue"), "kind": alt(r.get("kind"), "not recorded"),
            "usd": r2(alt(r.get("cost_usd"), 0)), "min": jround(r["wall_seconds"] / 60) if wall > 0 else None,
            "model": "" if model == "<synthetic>" else model, "models": alt(r.get("cost_models"), None),
            "main_only": alt(r.get("cost_source"), "") != "proxy", "pr": pr != "",
            "prn": int(m["n"]) if m else None, "prr": rr["r"] if rr else None,
            "end": math.floor(r["launched_at"] + r["wall_seconds"]) if launched > 0 and wall > 0
            else fromdate_or(alt(r.get("recorded_at"), ""), None)}


def jobrow(j, llm):
    ms = alt(j.get("models"), [])
    model = alt(alt(next((m for m in ms if not re.search("haiku", m)), None), ms[0] if ms else None), "")
    return {"at": j.get("at"), "src": "pass", "key": j.get("job"), "kind": j.get("job"),
            "usd": r2(alt(alt(g(llm, "runs", alt(j.get("run"), "")), j.get("cost_usd")), 0)),
            "min": jround(alt(j.get("duration_ms"), 0) / 60000), "model": model, "pr": False}


# snapshot_stats_json: the run log

def _wk(r):
    t = calendar.timegm(time.strptime(r["recorded_at"][0:10], "%Y-%m-%d"))
    return t - ((t // 86400 + 3) % 7) * 86400


def _mins(rs):
    m = med([w for w in (alt(r.get("wall_seconds"), 0) for r in rs) if w > 0])
    return None if m is None else jround(m / 60)


def _cost(rs):
    return add([alt(r.get("cost_usd"), 0) for r in rs])


def _models(rs):
    return [m for m in (alt(r.get("model"), "") for r in rs) if m != "" and not m.startswith("<")]


def _summary(rs):
    by = group_by(rs, lambda r: r.get("issue"))
    pt = med([_cost(x) for x in by])
    return {"runs": len(rs), "tickets": len(unique([r.get("issue") for r in rs])), "spend": r2(alt(_cost(rs), 0)),
            "median_min": _mins(rs), "per_ticket": None if pt is None else r2(pt), "max_runs": jmax([len(x) for x in by]),
            "from": bd(jmin([r["wk"] for r in rs])), "to": sl(jmax([r.get("recorded_at") for r in rs]), 0, 10)}


def _ticket(rs):
    kinds = group_by(rs, lambda r: alt(r.get("kind"), "not recorded"))
    return {"runs": len(rs), "cost": r2(_cost(rs)), "turns": add([alt(r.get("messages"), 0) for r in rs]),
            "models": unique(_models(rs)),
            "kinds": from_entries((alt(x[0].get("kind"), "not recorded"), len(x)) for x in kinds),
            "median_min": _mins(rs), "files": alt(g(sort_by(rs, lambda r: r.get("recorded_at"))[-1], "files_changed"), None),
            "last": jmax([r.get("recorded_at") for r in rs])}


def _base(runs):
    al = [dict(r, wk=_wk(r)) for r in runs]
    weeks = unique([r["wk"] for r in al])
    w5, w2 = (weeks[-5] if len(weeks) >= 5 else weeks[0]), (weeks[-2] if len(weeks) >= 2 else weeks[0])
    issues = group_by(al, lambda r: r.get("issue"))
    return {
        "rows": [runrow(r) for r in al],
        "weeks": [{"start": time.strftime("%Y-%m-%d", time.gmtime(x[0]["wk"])), "label": bd(x[0]["wk"]), "runs": len(x),
                   "spend": r2(_cost(x))} for x in group_by(al, lambda r: r["wk"])],
        "ranges": {"all": _summary(al), "w5": _summary([r for r in al if r["wk"] >= w5]),
                   "w2": _summary([r for r in al if r["wk"] >= w2])},
        "kinds": sort_by([{"kind": alt(x[0].get("kind"), "not recorded"), "runs": len(x), "avg": r2(_cost(x) / len(x)),
                           "median_min": _mins(x)} for x in group_by(al, lambda r: alt(r.get("kind"), ""))], lambda k: -k["runs"]),
        "top": sort_by([{"issue": x[0].get("issue"), "cost": r2(_cost(x)), "runs": len(x)} for x in issues], lambda t: -t["cost"])[0:5],
        "models": sort_by([{"model": x[0], "runs": len(x)} for x in group_by(_models(al), lambda m: m)], lambda m: -m["runs"]),
        "tickets": from_entries((x[0].get("issue"), _ticket(x)) for x in issues),
    }


# _stats_add_rounds

def _rounds(s, con, f):
    r = {}
    for p in sum((sorted(glob.glob(os.path.join(f["state"], "*." + w)))
                  for w in ("attempts", "feedback-rounds", "feedback-admin-rounds", "feedback-waiting")), []):
        m = re.fullmatch(r"(?P<k>[^/.:]+)\.(?P<w>[^/:]+)", os.path.basename(p))
        for n in lines(p) if m else []:
            n = re.sub(r"[^0-9]", "", n)[0:10]
            r.setdefault(m["k"], {})[m["w"]] = int(n) if n else 0
    now = int(time.time())
    for k, v in s["tickets"].items():
        left = alt(g(r.get(k), "feedback-waiting"), 0) - now
        v.update(attempts=alt(g(r.get(k), "attempts"), 0), feedback_rounds=alt(g(r.get(k), "feedback-rounds"), 0),
                 admin_rounds=alt(g(r.get(k), "feedback-admin-rounds"), 0), review_waiting=left if left > 0 else None)
    return s


# _stats_add_rows

def _records(con, f):
    """(records, bad): the session records, from the store or the folder; bad when one did not parse (jq stops there)."""
    out = []
    try:
        texts = [r[0] for r in con.execute("SELECT data FROM sessions ORDER BY key")] if con is not None else []
    except Exception:  # noqa: BLE001  the shell's read prints nothing then
        texts = []
    if con is None:
        for p in sorted(glob.glob(os.path.join(f["sessions"], "agent-*.json"))):
            try:
                texts.append(read(p))
            except OSError:
                pass
    try:
        for v in values("\n".join(texts)):
            out.append(v)
    except ValueError:
        return out, True
    return out, False


def _test_ids(recs, f):
    """The ids of test runs: dev bot and dry-run sessions, dev answers and hand-run CLI asks."""
    ids = [raw(r.get("key")) for r in recs if r.get("owner") == "U-DRYRUN" or r.get("env") == "dev"]
    a = os.path.join(f["state"], "answers.jsonl")
    if nonempty(a):
        try:
            for x in values(read(a)):
                if x.get("env") == "dev" or not re.search(r"^ask-[0-9a-f]{6}$", x["id"]):
                    ids.append(raw(x.get("id")))
        except (ValueError, TypeError, KeyError, AttributeError):
            pass  # jq stops at the bad line; the ids before it count
    return [i for i in ids if re.search(r"^[A-Za-z0-9._-]+$", i)]



_LLM_SQL = """SELECT json_object(
  'runs', (SELECT json_group_object(run, u) FROM (SELECT run, round(sum(usd), 2) AS u FROM llm_calls WHERE run IS NOT NULL GROUP BY run)),
  'run_models', (SELECT json_group_object(run, json(m)) FROM (SELECT run, json_group_object(model, u) AS m FROM
      (SELECT run, model, round(sum(usd), 2) AS u FROM llm_calls WHERE run IS NOT NULL AND model IS NOT NULL GROUP BY run, model) GROUP BY run)),
  'days', (SELECT json_group_array(json_object('day', day, 'usd', usd, 'calls', calls, 'cache_write_usd', cw)) FROM (SELECT * FROM
           (SELECT substr(at, 1, 10) AS day, round(sum(usd), 2) AS usd, count(*) AS calls, round(sum(coalesce(usd_cache_write, 0)), 2) AS cw
            FROM llm_calls WHERE $keep GROUP BY 1 ORDER BY 1 DESC LIMIT 30) ORDER BY day)),
  'hour_usd', (SELECT coalesce(round(sum(usd), 2), 0) FROM llm_calls WHERE $keep AND unixepoch(at) > unixepoch('now') - 3600),
  'gap_usd', (SELECT round(coalesce(sum(usd_cache_write), 0), 2) FROM (SELECT usd_cache_write, at, lag(at) OVER (PARTITION BY run ORDER BY at, id) AS prev
           FROM llm_calls WHERE run IS NOT NULL AND $keep) WHERE (unixepoch(at) - unixepoch(prev)) > 300),
  'models', (SELECT json_group_array(json_object('day', day, 'model', model, 'calls', calls, 'usd', usd, 'input', i, 'cache_read', cr, 'cache_write', cw, 'output', o))
           FROM (SELECT substr(at, 1, 10) AS day, coalesce(model, '') AS model, count(*) AS calls, round(sum(coalesce(usd, 0)), 2) AS usd,
             sum(coalesce(input_tokens, 0)) AS i, sum(coalesce(cache_read_input_tokens, 0)) AS cr, sum(coalesce(cache_creation_input_tokens, 0)) AS cw,
             sum(coalesce(output_tokens, 0)) AS o FROM llm_calls
             WHERE $keep AND substr(at, 1, 10) IN (SELECT DISTINCT substr(at, 1, 10) FROM llm_calls ORDER BY 1 DESC LIMIT 14)
             GROUP BY 1, 2 ORDER BY 1, 2))) AS llm""".replace("$keep", "(run IS NULL OR run NOT IN (SELECT value FROM json_each(:t)))")


def _llm_file(path, test):
    u = [x for x in slurp(path) if x.get("run") is None or x.get("run") not in test]
    run = [x for x in u if x.get("run") is not None]
    now = time.time()

    def gap(c):
        c = sort_by(c, lambda x: x.get("at"))
        return alt(add([alt(c[i].get("usd_cache_write"), 0) for i in range(1, len(c)) if fromdate(c[i]["at"]) - fromdate(c[i - 1]["at"]) > 300]), 0)
    days = unique([sl(x.get("at"), 0, 10) for x in u])[-14:]
    return {
        "runs": from_entries((x[0]["run"], r2(add([y.get("usd") for y in x]))) for x in group_by(run, lambda x: x["run"])),
        "run_models": from_entries((x[0]["run"], from_entries((m[0]["model"], r2(add([y.get("usd") for y in m])))
                                                              for m in group_by(x, lambda y: y["model"])))
                                   for x in group_by([x for x in run if x.get("model") is not None], lambda x: x["run"])),
        "days": [{"day": sl(x[0].get("at"), 0, 10), "usd": r2(add([y.get("usd") for y in x])), "calls": len(x),
                  "cache_write_usd": r2(add([alt(y.get("usd_cache_write"), 0) for y in x]))}
                 for x in group_by(u, lambda x: sl(x.get("at"), 0, 10))][-30:],
        "hour_usd": r2(alt(add([alt(x.get("usd"), 0) for x in u
                                if fromdate_or(alt(sl(x.get("at"), 0, 19), "") + "Z", 0) > now - 3600]), 0)),
        "gap_usd": r2(alt(add([gap(x) for x in group_by(run, lambda x: x["run"])]), 0)),
        "models": [{"day": sl(x[0].get("at"), 0, 10), "model": alt(x[0].get("model"), ""), "calls": len(x),
                    "usd": r2(add([alt(y.get("usd"), 0) for y in x])),
                    "input": add([alt(y.get("input_tokens"), 0) for y in x]), "cache_read": add([alt(y.get("cache_read_input_tokens"), 0) for y in x]),
                    "cache_write": add([alt(y.get("cache_creation_input_tokens"), 0) for y in x]), "output": add([alt(y.get("output_tokens"), 0) for y in x])}
                   for x in group_by([x for x in u if sl(x.get("at"), 0, 10) in days], lambda x: [sl(x.get("at"), 0, 10), alt(x.get("model"), "")])],
    }


def _llm(con, f, test):
    try:
        if con is not None:
            return json.loads(con.execute(_LLM_SQL, {"t": json.dumps(test)}).fetchone()[0])
        return _llm_file(f["usage"], test) if nonempty(f["usage"]) else {}
    except Exception:  # noqa: BLE001  the shell's `|| llm='{}'`
        return {}


def _session_rows(recs, llm, f):
    rf = from_entries((r.get("key"), alt(r.get("resume_from"), None)) for r in recs)

    def root(k):
        for _ in range(50):
            n = alt(rf.get(k), None)
            if n is None or n == k:
                break
            k = n
        return k
    out = []
    for r in recs:
        if r.get("owner") == "U-DRYRUN" or r.get("env") == "dev":
            continue
        s, fp, key = fromjson_or(alt(r.get("summary"), "{}"), {}), alt(r.get("fix_pr"), ""), r.get("key")
        fx = raw(fp) != ""
        pu = alt(r.get("pr_url"), "")
        m = None if fx else re.search(r"/pull/(?P<n>[0-9]+)$", pu)
        rr = None if fx else re.search(r"github.com/(?P<r>[^/]+/[^/]+)/pull/", pu)
        rm = g(llm, "run_models", key)
        n = {k: tonum(r.get(k)) for k in ("runner_s", "busy_s", "idle_s", "boot_s", "compute_usd", "verify_runs", "verify_full", "verify_s",
                                         "verify_fail_runs", "stack_starts", "stack_s", "stack_fails", "queued_s")}
        t0 = tonum(r.get("created"))
        out.append({"at": todate(math.floor(alt(r.get("created"), 0))), "src": "depfix" if fx else "slack", "key": key, "conv": root(key),
                    "kind": "session", "usd": alt(alt(g(llm, "runs", key), g(s, "cost")), 0), "min": alt(g(s, "minutes"), None),
                    "model": f["codex_model"] if r.get("runtime") == "codex" else f["agent_model"], "models": alt(rm, None),
                    "main_only": rm is None, "pr": (not fx) and pu != "", "who": None if fx else alt(r.get("owner_name"), None),
                    "prn": int(m["n"]) if m else None, "prr": rr["r"] if rr else None, "profile": alt(r.get("profile"), "fxa"),
                    "runner_s": n["runner_s"], "busy_s": n["busy_s"], "idle_s": n["idle_s"], "boot_s": n["boot_s"],
                    "backend": alt(r.get("boot_backend"), None), "stop": alt(r.get("stop_reason"), None),
                    "peak": fromjson_or(alt(r.get("res_peak"), ""), None), "compute_usd": n["compute_usd"],
                    "verify_runs": n["verify_runs"], "verify_full": n["verify_full"], "verify_s": n["verify_s"],
                    "verify_fail_runs": n["verify_fail_runs"], "stack_starts": n["stack_starts"], "stack_s": n["stack_s"],
                    "stack_fails": n["stack_fails"], "t0": None if t0 is None else math.floor(t0), "end": tonum(r.get("stopped_at")),
                    "queued_s": n["queued_s"], "live": alt(r.get("state"), "") in ("starting", "active", "wrapping")})
    return out


def _answer_rows(f, con, llm):
    a = os.path.join(f["state"], "answers.jsonl")
    if not nonempty(a):
        return []
    th = {}
    if con is not None:
        try:
            th = from_entries((r[0], r[1]) for r in con.execute(
                "SELECT run, max(thread) AS thread FROM llm_calls WHERE run LIKE 'ask-%' AND thread IS NOT NULL GROUP BY run"))
        except Exception:  # noqa: BLE001
            th = {}
    try:
        return [{"at": x.get("at"), "src": "answer", "key": x.get("id"),
                 "kind": "upgraded" if true(x.get("upgrade")) else "failed" if true(x.get("error")) else "answered",
                 "usd": r2(alt(alt(g(llm, "runs", x.get("id")), x.get("cost_usd")), 0)), "min": jround(alt(x.get("secs"), 0) / 60),
                 "secs": x.get("secs"), "turns": x.get("turns"), "model": "", "models": alt(g(llm, "run_models", x.get("id")), None),
                 "pr": False, "thread": alt(x.get("thread"), th.get(x.get("id"))), "q": alt(x.get("q"), None)}
                for x in slurp(a) if x.get("env") != "dev" and re.search(r"^ask-[0-9a-f]{6}$", x["id"])]
    except Exception:  # noqa: BLE001
        return []


def _rows(s, con, f):
    recs, bad = _records(con, f)
    test = _test_ids(recs, f)
    llm = _llm(con, f, test)
    try:
        sess = [] if bad else _session_rows(recs, llm, f)
    except Exception:  # noqa: BLE001
        sess = []
    jobs, jc = [], os.path.join(f["state"], "job-costs.jsonl")
    if nonempty(jc):
        try:
            jobs = [jobrow(j, llm) for j in slurp(jc)]
        except Exception:  # noqa: BLE001
            jobs = []
    s["rows"] += sess + jobs + _answer_rows(f, con, llm)
    s["llm"] = llm
    return s


# _stats_add_teams

# _stats_teams: the other teams with a state folder, as (name, folder).
def _other_teams(f):
    names = set()
    for d, suf in ((f["profiles"], None), (f["teams"], ".json")):
        try:
            ls = [n for n in os.listdir(d) if not n.startswith(".")]
        except OSError:
            ls = []
        names |= {n for n in ls if suf is None} | {n[: -len(suf)] for n in ls if suf and n.endswith(suf)}
    for p in sorted(names):
        d = os.path.join(f["home"], ".claude", "state", p)
        if re.fullmatch(r"[a-z0-9-]+", p) and p != f["profile"] and os.path.isdir(d) and d != f["state"]:
            yield p, d


def _teams(s, con, f):
    for p, d in _other_teams(f):
        try:
            r, j, ps = (slurp(os.path.join(d, n)) if os.path.exists(os.path.join(d, n)) else []
                        for n in ("agent-runs.jsonl", "job-costs.jsonl", "passes.jsonl"))
            llm = alt(s.get("llm"), {})
            rows = [dict(runrow(x), profile=p) for x in r] + [dict(jobrow(x, llm), profile=p) for x in j]
            c = time.time() - 7 * 86400
            w = [x for x in ps if alt(x.get("at"), 0) >= c]
            tp = {"passes": len(w), "work": len([x for x in w if true(x.get("work"))]), "last": jmax([x.get("at") for x in ps])}
        except Exception:  # noqa: BLE001  the shell keeps the input when a team's jq fails
            continue
        s["rows"] += rows
        s.setdefault("team_passes", {})[p] = tp
    for r in s["rows"]:
        r["profile"] = alt(r.get("profile"), f["profile"])
    return s


# _stats_add_prs

def _prs_list(d, team, repo):
    """_stats_prs_list: the folder's PR list with each PR's repo and team, or None when there is none."""
    p = os.path.join(d, "prs.json")
    if not nonempty(p):
        return None
    jm = {}
    try:
        for q in sorted(glob.glob(os.path.join(d, "*.jira.json"))):
            for x in slurp(q):
                jm[re.sub(r"\.jira\.json$", "", os.path.basename(q))] = x
    except Exception:  # noqa: BLE001
        jm = {}

    def key(h):
        return h.upper() if re.search(r"^[A-Za-z][A-Za-z0-9]+-[0-9]+$", h) and not h.startswith("agent-") else h

    def repo_of(u):
        m = re.search(r"github.com/(?P<r>[^/]+/[^/]+)/pull/", alt(u, ""))
        return m.group("r") if m else repo
    try:
        (lst,) = slurp(p)
        prs = [{"n": x.get("number"), "title": x.get("title"), "state": x.get("state"), "created": x.get("createdAt"),
                "merged": x.get("mergedAt"), "closed": x.get("closedAt"), "by": alt(g(x, "mergedBy", "login"), None),
                "add": x.get("additions"), "del": x.get("deletions"), "repo": repo_of(x.get("url")), "team": team,
                "src": "slack" if x["headRefName"].startswith("agent-") else "pipeline", "key": key(x["headRefName"])} for x in lst]
        for x in prs:
            x["jira"] = alt(jm.get(x["key"]), None)
    except Exception:  # noqa: BLE001
        return None
    return prs


def _prs(s, con, f):
    lists = [_prs_list(f["state"], f["profile"], f["repo"])] + [_prs_list(d, p, "") for p, d in _other_teams(f)]
    lists = [x for x in lists if x is not None]
    if not lists:
        s["prs"] = s["prs_at"] = None
        return s
    # One PR per (repo, number), the first list's; its team is the team of the work on it, else its list's.
    tm = {f"{r['prr']}#{r['prn']}": r.get("profile") for r in s["rows"] if r.get("prn") is not None and r.get("prr") is not None}
    one = {}
    for x in (x for lst in lists for x in lst):
        one.setdefault(f"{x['repo']}#{x['n']}", x)
    for k, x in one.items():
        x["team"] = alt(tm.get(k), x["team"])
    p = os.path.join(f["state"], "prs.json")
    s["prs"], s["prs_at"] = sort_by(one.values(), lambda x: x.get("created"))[::-1], int(os.stat(p).st_mtime) if nonempty(p) else None
    return s


# _stats_add_pipeline

def _pipeline(s, con, f):
    pf = os.path.join(f["state"], "passes.jsonl")
    passes = []
    if nonempty(pf):
        try:
            for x in group_by(slurp(pf), lambda x: todate(x["at"])[0:10]):
                woke = group_by([e for y in x for e in alt(y.get("woke"), {}).items()], lambda e: e[0])
                passes.append({"day": todate(x[0]["at"])[0:10], "passes": len(x), "work": len([y for y in x if true(y.get("work"))]),
                               "max_queued": jmax([y.get("queued") for y in x]), "inflight": x[-1].get("inflight"),
                               "awaiting": x[-1].get("awaiting"), "merged": add([alt(y.get("merged"), 0) for y in x]),
                               "rejected": add([alt(y.get("rejected"), 0) for y in x]),
                               "woke": from_entries((e[0][0], add([v for _, v in e])) for e in woke)})
            passes = passes[-14:]
        except Exception:  # noqa: BLE001
            passes = []
    waits = []
    try:
        runs = slurp(f["runs"])
        first = {raw(x[0].get("issue")): jmin([y["recorded_at"] for y in x])
                 for x in group_by([r for r in runs if r.get("recorded_at") is not None], lambda r: r.get("issue"))}
        for p in sorted(glob.glob(os.path.join(f["state"], "*.queued-at"))):
            k = os.path.basename(p)[: -len(".queued-at")]
            for ln in lines(p) if k and ":" not in k else []:
                q = re.sub(r"[^0-9]", "", ln)
                if q == "" or first.get(k) is None:
                    continue
                q = int(q)
                waits.append({"key": k, "q": q, "hours": jround((fromdate_or(first[k], q) - q) / 3600 * 10) / 10})
    except Exception:  # noqa: BLE001
        waits = []

    def h(t, q):
        if t is None:
            return None
        v = (alt(fromdate_or(t, None), q) - q) / 3600
        return None if v < 0 else jround(v * 10) / 10
    pr = {x.get("key"): x for x in alt(s.get("prs"), [])}
    pu = from_entries((sl(x[0].get("at"), 0, 10), r2(add([alt(y.get("usd"), 0) for y in x])))
                      for x in group_by([r for r in s["rows"] if r.get("src") == "pass" and r.get("kind") == "pass"], lambda r: sl(r.get("at"), 0, 10)))
    ws = []
    for w in waits:
        if w["hours"] >= 0:
            r = pr.get(w["key"])
            ws.append({"key": w["key"], "hours": w["hours"], "pr_hours": h(g(r, "created"), w["q"]), "merge_hours": h(g(r, "merged"), w["q"])})
    s["pipeline"] = {"days": [dict(d, usd=alt(pu.get(d["day"]), 0)) for d in passes], "waits": ws,
                     "retried": len([t for t in s["tickets"].values() if alt(t.get("attempts"), 0) > 1]), "tickets": len(s["tickets"])}
    return s


# _stats_add_load

def _load(s, con, f):
    drops = []
    try:
        if con is not None:
            drops = [{"day": r[0], "n": r[1]} for r in con.execute(
                "SELECT substr(at, 1, 10) AS day, count(*) AS n FROM errors WHERE kind = 'queue_dropped' GROUP BY 1")]
        elif nonempty(f["errors"]):
            drops = [{"day": sl(x[0].get("at"), 0, 10), "n": len(x)}
                     for x in group_by([e for e in slurp(f["errors"]) if e.get("kind") == "queue_dropped"], lambda e: sl(e.get("at"), 0, 10))]
    except Exception:  # noqa: BLE001
        drops = []
    now = int(time.time())
    sl_rows = [r for r in s["rows"] if r.get("src") in ("slack", "depfix")]
    live = [r for r in sl_rows if r.get("t0") is not None and (r.get("end") is not None or true(r.get("live")))]
    ev = sort_by([e for r in live for e in ({"t": r["t0"], "d": 1}, {"t": alt(r.get("end"), now), "d": -1})], lambda e: [e["t"], e["d"]])
    cur, peak = 0, {}
    for e in ev:
        day = todate(math.floor(e["t"]))[0:10]
        peak[day] = jmax([alt(peak.get(day), cur), cur + e["d"]])
        cur += e["d"]
    q = from_entries((x[0]["at"][0:10], {"queued": len(x), "wait_max_s": jmax([y["queued_s"] for y in x])})
                     for x in group_by([r for r in sl_rows if alt(r.get("queued_s"), 0) > 0], lambda r: sl(r.get("at"), 0, 10)))
    dr = from_entries((d["day"], d["n"]) for d in drops)
    days = unique(sorted(peak) + sorted(q) + sorted(dr))[-14:]
    s["load"] = {"cap": f["cap"], "days": [{"day": d, "peak": alt(peak.get(d), 0), "queued": alt(g(q.get(d), "queued"), 0),
                                            "wait_max_s": alt(g(q.get(d), "wait_max_s"), 0), "dropped": alt(dr.get(d), 0)} for d in days]}
    return s


# _stats_add_memory

def _memory(s, con, f):
    m = None
    if nonempty(f["memory"]):
        try:
            al = slurp(f["memory"])
            c = time.time() - 30 * 86400
            r = [x for x in al if x.get("run") != "digest" and fromdate_or(x.get("at"), 0) >= c]
            m = {"saves": from_entries((x[0].get("result"), len(x)) for x in group_by(r, lambda x: x.get("result"))),
                 "added": alt(add([x.get("added") for x in r]), 0), "inbox": alt(add([x.get("inbox") for x in r]), 0),
                 "dropped": alt(add([x.get("dropped") for x in r]), 0),
                 "last_digest": alt(([x for x in al if x.get("run") == "digest"] or [None])[-1], None)}
        except Exception:  # noqa: BLE001
            m = None
    s["memory"] = m
    return s


def compute(con, files):
    """The whole /api/stats copy, as `snapshot --stats` prints it: None when the run log is empty."""
    f = files
    if not nonempty(f["runs"]):
        return None
    s = _base(slurp(f["runs"]))
    # The shell's order: the pipeline step reads the PRs, the load step the session rows.
    for step in (_rounds, _rows, _teams, _prs, _pipeline, _load, _memory):
        step(s, con, f)
    return s


# The C1 frames


def etag(d):
    """The ETag that server.py _send gives this copy as JSON (when MASK finds nothing in it)."""
    return f'"{hashlib.sha1(json.dumps(d).encode("utf-8")).hexdigest()[:20]}"'


def same(a, b):
    """Equal as JSON values: 1 equals 1.0, but true is not 1."""
    if isinstance(a, bool) or isinstance(b, bool):
        return a is b
    if isinstance(a, (int, float)) and isinstance(b, (int, float)):
        return a == b
    if isinstance(a, dict) and isinstance(b, dict):
        return a.keys() == b.keys() and all(same(a[k], b[k]) for k in a)
    if isinstance(a, list) and isinstance(b, list):
        return len(a) == len(b) and all(same(x, y) for x, y in zip(a, b))
    return type(a) is type(b) and a == b


def diff(a, b):
    """The top-level keys whose values differ between two copies (rows counts as one key)."""
    a, b = a or {}, b or {}
    return sorted(k for k in set(a) | set(b) if k not in a or k not in b or not same(a[k], b[k]))


def parts(old, new):
    """The stats frame from old to new: rows_add and each changed part whole, or reload when a past row changed.
    None when nothing changed."""
    if old is not None and new is not None and same(old, new):
        return None
    base, tag = etag(old), etag(new)
    if old is None or new is None or set(old) - set(new) or set(new) - set(old) - set(STATS_PARTS):
        return {"base": base, "etag": tag, "reload": True}
    left = {}
    for r in old.get("rows") or []:
        k = json.dumps(r, sort_keys=True)
        left[k] = left.get(k, 0) + 1
    add_ = []
    for r in new.get("rows") or []:
        k = json.dumps(r, sort_keys=True)
        if left.get(k):
            left[k] -= 1
        else:
            add_.append(r)
    if any(left.values()):
        return {"base": base, "etag": tag, "reload": True}
    fr = {"base": base, "etag": tag, **{k: new[k] for k in STATS_PARTS if k in new and (k not in old or not same(old[k], new[k]))}}
    if add_:
        fr["rows_add"] = add_
    return fr


# Paths and settings, as the ctl reads them

def _dotenv():
    out = {}
    try:
        with open(os.path.join(ROOT, ".env")) as fh:
            for ln in fh:
                k, _, v = ln.rstrip("\n").partition("=")
                if k and not k.startswith("#"):
                    v = v[:-1] if v.endswith('"') else v
                    v = v[1:] if v.startswith('"') else v
                    v = v[:-1] if v.endswith("'") else v
                    out[k] = v[1:] if v.startswith("'") else v
    except OSError:
        pass
    return out


def files(pipeline="fxa", env=None):
    """The files and settings snapshot_stats_json reads, from env (os.environ) and the ctl's .env, which fills unset names."""
    e = dict(os.environ if env is None else env)
    for k, v in _dotenv().items():
        if not e.get(k):
            e[k] = v
    home = e.get("HOME") or os.path.expanduser("~")
    st = os.path.join(home, ".claude", "state")
    if pipeline == "fxa":
        state = e.get("FXA_FIXME_STATE") or os.path.join(st, "fxa-ai-fixme")
        runs = e.get("FXA_FIXME_RUNS") or os.path.join(state, "agent-runs.jsonl")
    else:
        state = os.path.join(st, pipeline)
        runs = os.path.join(state, "agent-runs.jsonl")
    cap = int(e.get("FXA_SESSION_MAX") or 4)
    if e.get("FXA_FC_HOST") and int(e.get("FXA_FC_SLOTS") or 4) > cap:
        cap = int(e.get("FXA_FC_SLOTS") or 4)
    # The repo of a PR list read before its url was: the shell's PIPE_REPO_SLUG.
    repo = e.get("PIPE_REPO_SLUG") or ("mozilla/fxa" if pipeline == "fxa" else "")
    return {"state": state, "runs": runs, "home": home, "profile": pipeline, "cap": cap, "repo": repo,
            "sessions": e.get("FXA_SESSION_DIR") or os.path.join(st, "agent-sessions"),
            "usage": os.path.join(e.get("FXA_LLM_PROXY_DIR") or os.path.join(st, "llm-proxy"), "usage.jsonl"),
            "errors": e.get("FXA_ERRORS_FILE") or os.path.join(st, "fxa-ai-fixme", "errors.jsonl"),
            "memory": e.get("FXA_MEMORY_LOG") or os.path.join(st, "memory.jsonl"),
            "profiles": e.get("FXA_PROFILES_DIR") or os.path.join(ROOT, "profiles"),
            "teams": e.get("FXA_TEAMS_DIR") or os.path.join(st, "teams"),
            "agent_model": e.get("FXA_AGENT_MODEL") or "claude-opus-5-5", "codex_model": e.get("FXA_CODEX_MODEL") or "gpt-6-astra"}


class Live:
    """The hub's in-process copy. poke() after a runs, passes, job_costs or llm change, or a new prs.json mtime:
    one recompute runs DEBOUNCE_S later in its own thread, and send(frame) gets the stats frame when the copy changed.
    hourly(shell) compares with the shell's copy at most once an hour and logs the count of keys that differ."""

    def __init__(self, connect, files, send):
        self.connect, self.files, self.send = connect, files, send
        self.data = self.tag = self.error = None
        self._lock, self._timer, self._diffed = threading.Lock(), None, 0.0

    def poke(self):
        # A timer that waits already covers this change: a steady stream of changes still gives one recompute per 5 s.
        with self._lock:
            if self._timer is None:
                self._timer = threading.Timer(DEBOUNCE_S, self.recompute)
                self._timer.daemon = True
                self._timer.start()

    def recompute(self):
        with self._lock:
            self._timer = None
        con = None
        try:
            con = self.connect()
            new = compute(con, self.files)
        except Exception as exc:  # noqa: BLE001  the last copy stays; the error shows as the shell feed's does
            self.error = f"stats failed: {type(exc).__name__}: {exc}"
            return
        finally:
            if con is not None:
                con.close()
        old, self.data, self.tag, self.error = self.data, new, etag(new), None
        fr = parts(old, new) if old is not None else None
        if fr:
            self.send(fr)

    def hourly(self, shell):
        if shell is None or self.data is None or time.time() - self._diffed < DIFF_S:
            return None
        self._diffed = time.time()
        d = diff(shell, self.data)
        print(f"stats: {len(d)} keys differ between the shell and the in-process copy{': ' + ' '.join(d) if d else ''}", file=sys.stderr, flush=True)
        return len(d)


if __name__ == "__main__":
    # python3 dashboard/stats.py [pipeline]: the copy for this host, as `fxa-sandbox-ctl snapshot --stats` prints it.
    sys.path.insert(0, os.path.join(ROOT, "lib"))
    import fxadb  # noqa: E402
    f = files(sys.argv[1] if len(sys.argv) > 1 else "fxa")
    c = fxadb.connect(readonly=True) if nonempty(fxadb.PATH) else None
    print(json.dumps(compute(c, f), separators=(",", ":")))
