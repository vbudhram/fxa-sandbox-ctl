#!/usr/bin/env bash
# Offline check of the dashboard's team routes (dashboard/server.py): a write needs the gateway's
# signed user and a TEAM_ADMINS email, and each route runs the matching profile command as that admin.
#   bash lib/teams-write.check.sh
set -u
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
# A fake ctl: logs its args, the actor and the record it was given; exits with $tmp/rc.
cat > "$tmp/ctl" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$tmp/args"; printf '%s\n' "\${FXA_TEAM_ACTOR:-}" >> "$tmp/actor"
for a in "\$@"; do [ -f "\$a" ] && { cat "\$a" > "$tmp/record"; echo "\$a" > "$tmp/recfile"; }; done
[ "\$2" = test ] && sleep 2
# validate: a WARN line on stdout, as teams_validate prints for a missing GitHub App.
[ "\$2" = validate ] && echo "WARN: the agent's GitHub App is not installed on a/b, so its changes ship as a diff"
# secret-set: keep stdin, and echo it back, so a check can see the answer leaves it out.
[ "\$2" = secret-set ] && { v="\$(cat)"; printf '%s' "\$v" > "$tmp/secretval"; echo "stored \$4 (\$v)"; exit 0; }
if [ "\$1" = memory ]; then
  [ "\$2" = list ] && echo '{"on":true,"entries":[]}' || echo "\$2 mem-0000aaaa"
  [ "\$(cat "$tmp/rc" 2>/dev/null || echo 0)" = 0 ] || { echo "ERROR: someone changed or removed this fact since you opened it; load it again" >&2; exit "\$(cat "$tmp/rc")"; }
  exit 0
fi
# routine: list, history and templates answer JSON; a stale set says so, as lib/routines.sh does.
if [ "\$1" = routine ]; then
  case "\$2" in list|history|templates|channels) echo '[{"id":5}]' ;; *) echo "done \$2" ;; esac
  [ "\$(cat "$tmp/rc" 2>/dev/null || echo 0)" = 0 ] || { echo "ERROR: Someone changed this routine since you opened it. Load it again to see their change." >&2; exit "\$(cat "$tmp/rc")"; }
  exit 0
fi
case "\$2" in get) echo '{"name":"rusty","generation":"7"}' ;; options) echo '{"skills":["s"]}' ;; audit) echo '[{"action":"create"}]' ;; *) echo "done \$2" ;; esac
[ "\$(cat "$tmp/rc" 2>/dev/null || echo 0)" = 0 ] || { echo "the store changed" >&2; exit "\$(cat "$tmp/rc")"; }
EOF
chmod +x "$tmp/ctl"; printf 'k1' > "$tmp/hmac"
mkdir -p "$tmp/teams"; echo '{}' > "$tmp/teams/rusty.json"
FXA_TEAMS_DIR="$tmp/teams" FXA_DASHBOARD_HMAC_FILE="$tmp/hmac" TEAM_ADMINS="admin@example.com, boss@example.com" python3 - "$(dirname "$0")/../dashboard" "$tmp" <<'PY'
import hashlib, hmac, json, os, sys, threading, time, urllib.error, urllib.request
sys.path.insert(0, sys.argv[1]); import server
from http.server import ThreadingHTTPServer
tmp = sys.argv[2]
server.CTL = f"{tmp}/ctl"
server.TEAMS = server.Feed("teams", ["profile", "list"], 300, 600)
srv = ThreadingHTTPServer(("127.0.0.1", 0), server.Handler); threading.Thread(target=srv.serve_forever, daemon=True).start()
fail = 0
def check(name, want, got):
    global fail
    print(("ok   " if want == got else "FAIL ") + name + ("" if want == got else f": want {want!r} got {got!r}")); fail |= want != got
def sig(user, method, path, ts=None, key=b"k1"):
    ts = str(int(time.time()) if ts is None else ts)
    return {"X-Fxa-User": user, "X-Fxa-Time": ts, "X-Fxa-Sig": hmac.new(key, f"{user}|{ts}|{method}|{path}".encode(), hashlib.sha256).hexdigest()}
def call(method, path, body=None, headers=None, raw=None):
    data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
    h = {"Host": "localhost", "Content-Type": "application/json", **(headers or {})}
    req = urllib.request.Request(f"http://127.0.0.1:{srv.server_port}{path}", data=data, method=method, headers=h)
    try:
        with urllib.request.urlopen(req) as r: return r.status, json.loads(r.read() or b"null")
    except urllib.error.HTTPError as e: return e.code, json.loads(e.read() or b"null")
# The last command a route ran; the teams list refresh that follows a write runs in the background, so skip it.
def args(): return ([l for l in open(f"{tmp}/args").read().splitlines() if l != "profile list"] or [""])[-1] if os.path.exists(f"{tmp}/args") else ""
rec = {"schema": 1, "name": "rusty", "repos": [{"slug": "a/b", "role": "work"}]}
A = "admin@example.com"

check("a write with no signed user: 401, and no command runs", (401, ""), (call("POST", "/api/teams", {"record": rec})[0], args()))
check("a forged signature: 401", 401, call("POST", "/api/teams", {"record": rec}, {**sig(A, "POST", "/api/teams"), "X-Fxa-Sig": "00"})[0])
check("a signature older than a minute: 401", 401, call("POST", "/api/teams", {"record": rec}, sig(A, "POST", "/api/teams", time.time() - 120))[0])
check("a signature for another path: 401", 401, call("POST", "/api/teams/rusty/delete", {}, sig(A, "POST", "/api/teams"))[0])
check("a signature by another key: 401", 401, call("POST", "/api/teams", {"record": rec}, sig(A, "POST", "/api/teams", key=b"k2"))[0])
check("a signed user who is not a team admin: 403, and no command runs", (403, ""),
      (call("POST", "/api/teams", {"record": rec}, sig("viewer@example.com", "POST", "/api/teams"))[0], args()))
s, b = call("POST", "/api/teams", {"record": rec}, sig(A, "POST", "/api/teams"))
check("an admin's create runs profile create as that admin, with the record, then removes the file",
      (200, "profile create", A, rec, False),
      (s, args().rsplit(" ", 1)[0], open(f"{tmp}/actor").read().split()[-1], json.load(open(f"{tmp}/record")), os.path.exists(open(f"{tmp}/recfile").read().strip())))
check("an admin email matches whatever its case", 200, call("POST", "/api/teams", {"record": rec}, sig("Boss@Example.com", "POST", "/api/teams"))[0])
check("a change with no generation is refused before any command", (400, "profile create"),
      (call("POST", "/api/teams/rusty", {"record": rec}, sig(A, "POST", "/api/teams/rusty"))[0], args().rsplit(" ", 1)[0]))
s, _ = call("POST", "/api/teams/rusty", {"record": rec, "generation": "7"}, sig(A, "POST", "/api/teams/rusty"))
check("a change runs profile set with the generation it edited", (200, "set rusty --generation 7"),
      (s, " ".join(w for w in args().split() if not w.endswith(".json"))[len("profile "):]))
open(f"{tmp}/rc", "w").write("2")
check("a stale generation comes back as 409", 409, call("POST", "/api/teams/rusty", {"record": rec, "generation": "6"}, sig(A, "POST", "/api/teams/rusty"))[0])
open(f"{tmp}/rc", "w").write("0")
check("a bad status is refused; active runs enable", (400, 200, "profile enable rusty"),
      (call("POST", "/api/teams/rusty/status", {"status": "on"}, sig(A, "POST", "/api/teams/rusty/status"))[0],
       call("POST", "/api/teams/rusty/status", {"status": "active"}, sig(A, "POST", "/api/teams/rusty/status"))[0], args()))
check("delete runs profile delete", (200, "profile delete rusty"), (call("POST", "/api/teams/rusty/delete", {}, sig(A, "POST", "/api/teams/rusty/delete"))[0], args()))
claims = []; server.TEAMS.claim = lambda: claims.append(1) or False
open(f"{tmp}/rc", "w").write("1")
st, b = call("POST", "/api/teams/validate", {"record": rec}, sig(A, "POST", "/api/teams/validate"))
open(f"{tmp}/rc", "w").write("0")
check("a failed validate also answers its WARN lines", (400, ["WARN: the agent's GitHub App is not installed on a/b, so its changes ship as a diff"]), (st, b.get("warn")))
call("POST", "/api/teams/validate", {"record": rec}, sig(A, "POST", "/api/teams/validate"))
check("a validate does not refresh the teams list; a delete does", (0, 1), (len(claims), (call("POST", "/api/teams/rusty/delete", {}, sig(A, "POST", "/api/teams/rusty/delete")), len(claims))[1]))
check("validate runs profile validate", (200, "profile validate"), (call("POST", "/api/teams/validate", {"record": rec}, sig(A, "POST", "/api/teams/validate"))[0], args().rsplit(" ", 1)[0]))
check("an admin reads a record and its audit as JSON", ((200, {"name": "rusty", "generation": "7"}), (200, [{"action": "create"}])),
      (call("GET", "/api/teams/rusty", headers=sig(A, "GET", "/api/teams/rusty")), call("GET", "/api/teams/rusty/audit", headers=sig(A, "GET", "/api/teams/rusty/audit"))))
check("a viewer cannot read a record, which names Slack users", 403, call("GET", "/api/teams/rusty", headers=sig("viewer@example.com", "GET", "/api/teams/rusty"))[0])
check("a form post is refused (JSON only); a record over 64 KB too", (415, 413),
      (call("POST", "/api/teams", headers={**sig(A, "POST", "/api/teams"), "Content-Type": "application/x-www-form-urlencoded"}, raw=b"a=1")[0],
       call("POST", "/api/teams", headers=sig(A, "POST", "/api/teams"), raw=b"x" * 70000)[0]))
check("a cross-site request is refused before the signature counts", 403, call("POST", "/api/teams", {"record": rec}, {**sig(A, "POST", "/api/teams"), "Origin": "https://evil.test"})[0])
check("the page learns who it is for: an admin, a viewer, nobody signed",
      ({"user": A, "admin": True}, {"user": "viewer@example.com", "admin": False}, {"user": None, "admin": False}),
      tuple(call("GET", "/api/team-admin", headers=h)[1] for h in (sig(A, "GET", "/api/team-admin"), sig("viewer@example.com", "GET", "/api/team-admin"), {})))
s1 = call("POST", "/api/teams/rusty/test", {}, sig(A, "POST", "/api/teams/rusty/test"))[0]
s2 = call("POST", "/api/teams/rusty/test", {}, sig(A, "POST", "/api/teams/rusty/test"))[0]
s3 = call("POST", "/api/teams/ghost/test", {}, sig(A, "POST", "/api/teams/ghost/test"))[0]
time.sleep(3)
check("a test starts in the background (202); a second one while it runs is refused (409); no record is 404",
      (202, 409, 404, "profile test rusty"), (s1, s2, s3, [l for l in open(f"{tmp}/args").read().splitlines() if "test" in l][-1]))
st, b = call("POST", "/api/teams/rusty/secret", {"secret": "fxa-team-rusty--jira", "value": "bot@example.com:s3cr3t"}, sig(A, "POST", "/api/teams/rusty/secret"))
check("a secret goes to profile secret-set on stdin, and the answer never carries the value",
      (200, "profile secret-set rusty fxa-team-rusty--jira", "bot@example.com:s3cr3t", False, True),
      (st, args(), open(f"{tmp}/secretval").read(), "s3cr3t" in json.dumps(b), "<value>" in json.dumps(b)))
check("a secret of another team, or with no value, is refused before any command", (400, 400),
      (call("POST", "/api/teams/rusty/secret", {"secret": "fxa-team-other--jira", "value": "x"}, sig(A, "POST", "/api/teams/rusty/secret"))[0],
       call("POST", "/api/teams/rusty/secret", {"secret": "fxa-team-rusty--jira", "value": ""}, sig(A, "POST", "/api/teams/rusty/secret"))[0]))
check("a viewer cannot set a secret", 403, call("POST", "/api/teams/rusty/secret", {"secret": "fxa-team-rusty--jira", "value": "x"}, sig("viewer@example.com", "POST", "/api/teams/rusty/secret"))[0])
# Routines (epic i168): admins only, for reads too; each route runs its routine command as the admin.
ran = lambda: [l for l in open(f"{tmp}/args").read().splitlines() if l.startswith("routine")] if os.path.exists(f"{tmp}/args") else []
R = {"name": "Code review", "template": "code-review", "prompt": "Review.", "schedule": "weekdays 09:00", "zone": "America/New_York",
     "repos": ["a/b"], "channel": "C0OWN00", "mode": "report"}
L, V = "/api/teams/rusty/routines", "viewer@example.com"
check("routines: unsigned gets 401, a signed non-admin 403, for a read and a write, and no routine command runs",
      (401, 403, 401, 403, "not a team admin", []),
      (call("GET", L)[0], call("GET", L, headers=sig(V, "GET", L))[0], call("POST", L, {"routine": R})[0], call("POST", L, {"routine": R}, sig(V, "POST", L))[0],
       call("POST", L, {"routine": R}, sig(V, "POST", L))[1].get("error"), ran()))
check("an admin reads the list, the templates and a history", ((200, [{"id": 5}]), (200, [{"id": 5}]), (200, [{"id": 5}]), ["routine list rusty", "routine templates", "routine history rusty 5"]),
      (call("GET", L, headers=sig(A, "GET", L)), call("GET", "/api/routine-templates", headers=sig(A, "GET", "/api/routine-templates")),
       call("GET", L + "/5/history", headers=sig(A, "GET", L + "/5/history")), ran()))
C = "/api/teams/rusty/routine-channels"
check("routine-channels: unsigned 401, a non-admin 403, an admin runs routine channels for the URL team",
      (401, 403, 200, "routine channels rusty"),
      (call("GET", C)[0], call("GET", C, headers=sig(V, "GET", C))[0], call("GET", C, headers=sig(A, "GET", C))[0], ran()[-1]))
M = "/api/teams/rusty/memory"
check("memory: unsigned 401, a non-admin 403, an admin runs memory list for the URL team and gets its JSON",
      (401, 403, (200, {"on": True, "entries": []}), "memory list rusty"),
      (call("GET", M)[0], call("GET", M, headers=sig(V, "GET", M))[0], call("GET", M, headers=sig(A, "GET", M)), args()))
O = "/api/teams/options"
check("options: unsigned 401, a non-admin 403, an admin gets profile options' JSON, never a team named options", (401, 403, (200, {"skills": ["s"]}), "profile options"),
      (call("GET", O)[0], call("GET", O, headers=sig(V, "GET", O))[0], call("GET", O, headers=sig(A, "GET", O)), args()))
PQ = "/api/teams/people/pat%20doe"
check("people: unsigned 401, a non-admin 403, an admin with no store gets an empty list, and a control character is 400", (401, 403, (200, {"at": None, "people": []}), 400),
      (call("GET", PQ)[0], call("GET", PQ, headers=sig(V, "GET", PQ))[0], call("GET", PQ, headers=sig(A, "GET", PQ)), call("GET", "/api/teams/people/a%0Ab", headers=sig(A, "GET", "/api/teams/people/a%0Ab"))[0]))
TS = "/api/teams/rusty/test/stop"
check("test stop: none running is 409", 409, call("POST", TS, {}, sig(A, "POST", TS))[0])
import subprocess as sp, signal as sg
pr = sp.Popen(["bash", "-c", "trap 'echo stopped > " + tmp + "/stopped; exit 143' TERM; while :; do sleep 0.1; done"]); time.sleep(0.3)
open(f"{tmp}/teams/rusty.test.pid", "w").write(str(pr.pid))
st = call("POST", TS, {}, sig(A, "POST", TS))[0]
try:
    pr.wait(5)
except sp.TimeoutExpired:
    pr.kill()  # no TERM came: the check fails below, and the loop must not keep the run open
check("test stop: a running test gets TERM, and its trap runs", (202, "stopped", 401), (st, open(f"{tmp}/stopped").read().strip() if os.path.exists(f"{tmp}/stopped") else "", call("POST", TS, {})[0]))
server.team_private = lambda p: p == "secret"
ME, MD = M + "/mem-0000aaaa", M + "/mem-0000aaaa/delete"
E = {"scope": "team", "kind": "trap", "text": "t", "cites": []}
check("memory write: unsigned 401, a non-admin 403, and no command runs", (401, 403, "profile options"),
      (call("POST", M, {"entry": E})[0], call("POST", M, {"entry": E}, sig(V, "POST", M))[0], args()))
st, body = call("POST", M, {"entry": E}, sig(A, "POST", M))
check("memory add: the admin's set runs with the entry in a record file, not argv, as the admin", (200, "memory set rusty ", E, A),
      (st, args().rsplit(" ", 1)[0], json.load(open(f"{tmp}/record"))["entry"], open(f"{tmp}/actor").read().split()[-1]))
st, _ = call("POST", ME, {"entry": E, "v": "0123456789ab"}, sig(A, "POST", ME))
check("memory edit: the id from the path and the version in the record", (200, "memory set rusty mem-0000aaaa", "0123456789ab"),
      (st, args().rsplit(" ", 1)[0], json.load(open(f"{tmp}/record"))["v"]))
check("memory edit or delete with no version: 400, and no command runs", (400, 400, "memory set rusty mem-0000aaaa"),
      (call("POST", ME, {"entry": E}, sig(A, "POST", ME))[0], call("POST", MD, {}, sig(A, "POST", MD))[0], args().rsplit(" ", 1)[0]))
open(f"{tmp}/rc", "w").write("2"); st, body = call("POST", MD, {"v": "0123456789ab", "scope": "team"}, sig(A, "POST", MD)); os.unlink(f"{tmp}/rc")
check("memory delete: runs delete, and a stale version is 409 with the command's words", (409, "memory delete rusty mem-0000aaaa", True),
      (st, args().rsplit(" ", 1)[0], "load it again" in body["error"]))
S, SD = "/api/teams/secret/memory", "/api/teams/secret/memory/mem-0000aaaa/delete"
check("memory: a private team takes no new text, but a delete still runs", (403, 200, "memory delete secret mem-0000aaaa"),
      (call("POST", S, {"entry": E}, sig(A, "POST", S))[0], call("POST", SD, {"v": "0123456789ab"}, sig(A, "POST", SD))[0], args().rsplit(" ", 1)[0]))
check("memory: text/plain is 415 and a bad id is not a memory route", (415, 404),
      (call("POST", M, raw=b"x", headers={**sig(A, "POST", M), "Content-Type": "text/plain"})[0], call("POST", M + "/mem-zz", {}, sig(A, "POST", M + "/mem-zz"))[0]))
st, _ = call("POST", L, {"routine": R}, sig(A, "POST", L))
check("an admin creates one: routine set with the routine in a file, as that admin", (200, "routine set rusty", R, A),
      (st, ran()[-1].rsplit(" ", 1)[0], json.load(open(f"{tmp}/record")), open(f"{tmp}/actor").read().splitlines()[-1]))
st, _ = call("POST", L + "/5", {"routine": R, "version": 3}, sig(A, "POST", L + "/5"))
check("an edit sends the version it edited", (200, "--id 5 --version 3"), (st, ran()[-1].split(".json ", 1)[-1]))
check("an edit with no version is refused before any command", (400, 1), (call("POST", L + "/5", {"routine": R}, sig(A, "POST", L + "/5"))[0], len([l for l in ran() if "--version" in l])))
open(f"{tmp}/rc", "w").write("2")
st, b = call("POST", L + "/5", {"routine": R, "version": 3}, sig(A, "POST", L + "/5"))
check("a stale version comes back as 409 with the stale-edit text", (409, True), (st, "Someone changed this routine since you opened it" in b.get("error", "")))
open(f"{tmp}/rc", "w").write("0")
check("pause, resume and delete run their routine command", (200, 200, 200, ["routine pause rusty 5", "routine resume rusty 5", "routine delete rusty 5"]),
      (call("POST", L + "/5/pause", {}, sig(A, "POST", L + "/5/pause"))[0], call("POST", L + "/5/resume", {}, sig(A, "POST", L + "/5/resume"))[0],
       call("POST", L + "/5/delete", {}, sig(A, "POST", L + "/5/delete"))[0], ran()[-3:]))
check("run and stop: a non-admin gets 403 and nothing runs; an admin's run runs run-now, stop runs stop, with the URL team",
      (403, 200, 200, ["routine run-now rusty 5", "routine stop rusty 5"]),
      (call("POST", L + "/5/run", {}, sig(V, "POST", L + "/5/run"))[0], call("POST", L + "/5/run", {}, sig(A, "POST", L + "/5/run"))[0],
       call("POST", L + "/5/stop", {}, sig(A, "POST", L + "/5/stop"))[0], ran()[-2:]))
check("a routine write that is not JSON, or over 64 KB, is refused", (415, 413),
      (call("POST", L, raw=b"x", headers={**sig(A, "POST", L), "Content-Type": "text/plain"})[0], call("POST", L, raw=b"{" + b" " * 70000 + b"}", headers=sig(A, "POST", L))[0]))
import http.client
def raw_len(length, path=None):
    c = http.client.HTTPConnection("127.0.0.1", srv.server_port, timeout=5)
    c.putrequest("POST", path or L); c.putheader("Host", "localhost"); c.putheader("Content-Type", "application/json"); c.putheader("Content-Length", length)
    for k, v in sig(A, "POST", path or L).items(): c.putheader(k, v)
    c.endheaders(); r = c.getresponse(); return r.status
n_ran = len(ran())
n_args = len(open(f"{tmp}/args").read().splitlines())
check("a team write with a negative or bad Content-Length gets 400 and runs nothing", (400, 400, n_args),
      (raw_len("-1", "/api/teams"), raw_len("x", "/api/teams/rusty"), len(open(f"{tmp}/args").read().splitlines())))
open(f"{tmp}/teams/rusty.test.log", "w").write("== rusty at generation 7: booting agent-x (a few minutes)\nok   the runner booted and the agent answered\n")
T = "/api/teams/rusty/test"; st, b = call("GET", T, headers=sig(A, "GET", T))
check("the test route: unsigned 401, a viewer 403, an admin the log tail, and no ctl runs", (401, 403, 200, "ok   the runner booted and the agent answered", n_args),
      (call("GET", T)[0], call("GET", T, headers=sig("viewer@example.com", "GET", T))[0], st, (b.get("lines") or [""])[-1], len(open(f"{tmp}/args").read().splitlines())))
check("a negative or bad Content-Length, and a body that is not an object, get 400 and run nothing", (400, 400, 400, 400, n_ran),
      (raw_len("-1"), raw_len("x"), call("POST", L, raw=b"[1]", headers=sig(A, "POST", L))[0], call("POST", L + "/5", raw=b'"x"', headers=sig(A, "POST", L + "/5"))[0], len(ran())))
os.environ["TEAM_ADMINS"] = ""
check("no TEAM_ADMINS: nobody may write", 403, call("POST", "/api/teams", {"record": rec}, sig(A, "POST", "/api/teams"))[0])
os.environ["TEAM_ADMINS"] = A; os.unlink(f"{tmp}/hmac")
check("no key on the server: no write, even signed", 401, call("POST", "/api/teams", {"record": rec}, sig(A, "POST", "/api/teams"))[0])
srv.shutdown(); sys.exit(fail)
PY
