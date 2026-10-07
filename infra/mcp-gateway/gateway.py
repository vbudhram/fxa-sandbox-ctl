#!/usr/bin/env python3
"""fxa-mcp-gateway: the only holder of MCP credentials for runners.

A runner reaches one MCP endpoint here with a per-run token. The gateway
serves the tools of the connectors that token was granted, each renamed
`<connector>__<tool>`, and forwards a call to that connector's upstream MCP
server (Runlayer, or any Streamable HTTP server) with the upstream credential.

Every connector is read-only by construction: only the tools on its `tools`
allowlist exist, its `rules` check or rewrite arguments before a call leaves,
and its `deny_result` patterns withhold an answer before it reaches the runner.
The upstream account's own permissions stay the real limit; this is the second.

Config (MCP_GATEWAY_CONFIG), see connectors.example.json:
  {"connectors": {"<name>": {"url", "headers", "tools", "rules", "deny_result"}}}
Header values expand ${VAR} from the environment, so secrets stay in .env.
${RUNLAYER_OAUTH_TOKEN} is an access token renewed from the refresh token in
MCP_GATEWAY_OAUTH {token_endpoint, client_id, refresh_tokens: {url: token}}, which
oauth-login.py writes.

Tokens: <dir>/tokens/<token>.json  {run, created, expires, connectors, cap_calls, calls}
written by the controller (lib/mcp-token.sh), updated here. One line per call
goes to <dir>/calls.jsonl. Standard library only.
"""
import hashlib
import sys
import http.client
import http.server
import json
import os
import re
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "lib"))
import fxadb  # noqa: E402  the controller's store

DIR = os.environ.get("MCP_GATEWAY_DIR", os.path.expanduser("~/.claude/state/mcp-gateway"))
CONFIG = os.environ.get("MCP_GATEWAY_CONFIG", os.path.expanduser("~/.config/fxa/mcp-gateway.json"))
LISTEN = os.environ.get("MCP_GATEWAY_LISTEN", "0.0.0.0:8789")
OAUTH_FILE = os.environ.get("MCP_GATEWAY_OAUTH", os.path.expanduser("~/.config/fxa/mcp-gateway-oauth.json"))
OAUTH_VAR = "RUNLAYER_OAUTH_TOKEN"
# The controller's error log (lib/errors.sh): a new line there reaches the operator.
ERRORS_FILE = os.environ.get("FXA_ERRORS_FILE", os.path.expanduser("~/.claude/state/fxa-ai-fixme/errors.jsonl"))
TOKEN_RE = re.compile(r"^fxm_[A-Za-z0-9]{32}$")
SEP = "__"
# Methods a client may probe that this gateway has nothing for.
EMPTY_LISTS = {"resources/list": "resources", "resources/templates/list": "resourceTemplates", "prompts/list": "prompts"}
PROTOCOLS = ("2025-06-18", "2025-03-26", "2024-11-05")
TOOLS_TTL = 300  # seconds an upstream's tool list is reused
UPSTREAM_TIMEOUT = 60
MAX_BODY = 1 << 20

locks, locks_guard = {}, threading.Lock()
reported, reported_guard = {}, threading.Lock()


def now_iso():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def token_lock(tok):
    with locks_guard:
        return locks.setdefault(tok, threading.Lock())


def load(tok):
    """The token's record, or None when unknown, revoked or expired."""
    if not TOKEN_RE.match(tok or ""):
        return None
    try:
        with open(os.path.join(DIR, "tokens", tok + ".json")) as f:
            rec = json.load(f)
    except (OSError, ValueError):
        return None
    return rec if rec.get("expires", 0) > time.time() else None


def take_call(tok):
    """Count one call against the run's cap. False when the cap is reached."""
    path = os.path.join(DIR, "tokens", tok + ".json")
    with token_lock(tok):
        rec = load(tok)
        if rec is None:
            return False
        if rec.get("cap_calls") and rec.get("calls", 0) >= rec["cap_calls"]:
            return False
        rec["calls"] = rec.get("calls", 0) + 1
        with open(path + ".tmp", "w") as f:
            json.dump(rec, f)
        os.replace(path + ".tmp", path)
        return True


def report(kind, key, message, detail=""):
    """One line in the controller's error log, at most once per 10 minutes per
    kind and run. The signature hashes only the message, so repeats group."""
    with reported_guard:
        if time.time() - reported.get((kind, key), 0) < 600:
            return
        reported[(kind, key)] = time.time()
    line = {"at": now_iso(), "source": "gateway", "kind": kind, "key": key, "where": "mcp-gateway",
            "message": (message + detail)[:600], "log": None,
            "sig": hashlib.sha1(("mcp-gateway|%s|%s" % (kind, message)).encode()).hexdigest()[:10]}
    try:
        os.makedirs(os.path.dirname(ERRORS_FILE), exist_ok=True)
        with open(ERRORS_FILE, "a") as f:
            f.write(json.dumps(line, separators=(",", ":")) + "\n")  # errors resolve greps compact JSON
    except OSError:
        pass
    fxadb.ingest("errors", line)


def audit(run, connector, tool, outcome, ms=0, size=0, args=None):
    line = {"at": now_iso(), "run": run, "connector": connector, "tool": tool, "outcome": outcome,
            "ms": ms, "bytes": size, "args": json.dumps(args or {}, sort_keys=True)[:300]}
    with open(os.path.join(DIR, "calls.jsonl"), "a") as f:
        f.write(json.dumps(line) + "\n")
    fxadb.ingest("mcp_calls", line)


# ── Argument rules ────────────────────────────────────────────


class Denied(Exception):
    pass


def jql_scan(jql):
    """Index of a top-level ORDER BY, or len(jql). Raises Denied on unbalanced
    parentheses or quotes, which could close the wrapping group and escape it."""
    depth, quote, i, order = 0, None, 0, len(jql)
    while i < len(jql):
        c = jql[i]
        if quote:
            if c == "\\":
                i += 1
            elif c == quote:
                quote = None
        elif c in "\"'":
            quote = c
        elif c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth < 0:
                raise Denied("unbalanced parentheses in jql")
        elif depth == 0 and order == len(jql) and re.match(r"(?i)order\s+by\b", jql[i:]) \
                and (i == 0 or jql[i - 1].isspace()):
            order = i
        i += 1
    if quote or depth:
        raise Denied("unbalanced quotes or parentheses in jql")
    return order


def scope_jql(jql, project, exclude_labels=()):
    jql = (jql or "").strip()
    cut = jql_scan(jql)
    where, order = jql[:cut].strip(), jql[cut:].strip()
    base = "project = %s AND level IS EMPTY" % project
    if exclude_labels:
        # Jira keeps a label's case, so each case form is its own label.
        forms = list(dict.fromkeys(f for l in exclude_labels for f in (l, l.lower(), l.upper(), l.capitalize())))
        # NOT IN alone also drops issues with no labels.
        base += " AND (labels IS EMPTY OR labels NOT IN (%s))" % ", ".join(json.dumps(l) for l in forms)
    scoped = base if not where else "%s AND (%s)" % (base, where)
    return (scoped + " " + order).strip()


def applies(rule, tool, schema):
    if rule.get("tool", "*") not in ("*", tool):
        return False
    # A wildcard rule binds only tools that take the argument.
    return rule.get("tool") == tool or rule["arg"] in (schema.get("properties") or {})


def apply_rules(rules, tool, schema, args):
    args = dict(args or {})
    for rule in rules:
        if not applies(rule, tool, schema):
            continue
        arg, val = rule["arg"], args.get(rule["arg"])
        if "set" in rule:
            args[arg] = rule["set"]
        elif rule.get("drop"):
            args.pop(arg, None)
        elif "jql_project" in rule:
            if not isinstance(val, str):
                raise Denied("%s needs a jql string" % arg)
            args[arg] = scope_jql(val, rule["jql_project"], rule.get("exclude_labels", ()))
        elif "include" in rule:
            # An omitted list means the upstream's defaults, so start from them, not from empty.
            have = list(val) if isinstance(val, list) and val else list(rule.get("default", []))
            # A field such as issuelinks shows other issues without their labels, so deny_result
            # cannot judge them; "*all" and "*navigable" include those fields.
            bad = [str(v) for v in have if v in rule.get("deny", ()) or str(v).startswith("*")]
            if bad:
                raise Denied("%s may not include %s" % (arg, ", ".join(bad)))
            # "-labels" would exclude the very field deny_result reads.
            have = [v for v in have if not (isinstance(v, str) and v[1:] in rule["include"] and v.startswith("-"))]
            args[arg] = have + [v for v in rule["include"] if v not in have]
        elif "equals" in rule or "one_of" in rule:
            allowed = [rule["equals"]] if "equals" in rule else rule["one_of"]
            if not isinstance(val, str) or val.lower() not in [a.lower() for a in allowed]:
                raise Denied("%s must be one of %s" % (arg, ", ".join(allowed)))
    return args


def withheld(result, patterns):
    """True when any text of the result matches a deny_result pattern."""
    if not patterns:
        return False
    parts = [c.get("text", "") for c in result.get("content", []) if isinstance(c, dict)]
    if "structuredContent" in result:
        parts.append(json.dumps(result["structuredContent"]))
    text = "\n".join(parts)
    return any(re.search(p, text) for p in patterns)


# ── Upstream MCP client (Streamable HTTP) ─────────────────────


class UpstreamError(Exception):
    pass


class SessionGone(Exception):
    pass


class Unauthorized(Exception):
    pass


class OAuth:
    """Access tokens, one per upstream URL (the server binds each to one
    resource), from that URL's refresh token. The server may rotate a refresh
    token on each use, so the newest one goes back to the file at once."""

    def __init__(self, path):
        self.path, self.access, self.until = path, {}, {}
        self.lock = threading.Lock()

    def signed_in(self, resource):
        try:
            with open(self.path) as f:
                return resource in json.load(f).get("refresh_tokens", {})
        except (OSError, ValueError):
            return False

    def token(self, resource):
        with self.lock:
            if resource not in self.access or time.time() > self.until[resource] - 60:
                self._renew(resource)
            return self.access[resource]

    def drop(self, resource):
        with self.lock:
            self.access.pop(resource, None)

    def _renew(self, resource):
        try:
            with open(self.path) as f:
                st = json.load(f)
            old = st["refresh_tokens"][resource]
            body = urllib.parse.urlencode({"grant_type": "refresh_token", "refresh_token": old,
                                           "client_id": st["client_id"], "resource": resource}).encode()
            req = urllib.request.Request(st["token_endpoint"], body, {"accept": "application/json"})
            with urllib.request.urlopen(req, timeout=UPSTREAM_TIMEOUT) as r:
                doc = json.load(r)
            self.access[resource] = doc["access_token"]
        except urllib.error.HTTPError as e:
            report("oauth", None, "Runlayer refused the gateway's refresh token; run infra/gce/manager.sh oauth",
                   " (HTTP %d for %s)" % (e.code, resource))
            raise UpstreamError("oauth: the token endpoint answered HTTP %d; run manager.sh oauth again" % e.code)
        except KeyError:
            report("oauth", None, "the gateway has no sign-in for a connector; run infra/gce/manager.sh oauth", " (%s)" % resource)
            raise UpstreamError("oauth: not signed in for this connector")
        except (OSError, ValueError) as e:
            raise UpstreamError("oauth: %s" % e.__class__.__name__)
        self.until[resource] = time.time() + int(doc.get("expires_in") or 300)
        if doc.get("refresh_token") and doc["refresh_token"] != old:
            st["refresh_tokens"][resource] = doc["refresh_token"]
            fd = os.open(self.path + ".tmp", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, "w") as f:
                json.dump(st, f)
            os.replace(self.path + ".tmp", self.path)


OAUTH = OAuth(OAUTH_FILE)


def expand(value, live=False, resource=None):
    """Fill ${VAR} from the environment. Without live, only check that each is set."""
    missing = []

    def sub(m):
        if m.group(1) == OAUTH_VAR:
            if not live:
                if not OAUTH.signed_in(resource):
                    missing.append(OAUTH_VAR + " (not signed in; run manager.sh oauth)")
                return ""
            return OAUTH.token(resource)
        if m.group(1) not in os.environ:
            missing.append(m.group(1))
        return os.environ.get(m.group(1), "")
    out = re.sub(r"\$\{([A-Z0-9_]+)\}", sub, value)
    if missing:
        raise ValueError("unset: " + ", ".join(missing))
    return out


class Upstream:
    def __init__(self, name, spec):
        self.name, self.url = name, urllib.parse.urlsplit(spec["url"])
        self.resource, self.headers = spec["url"], dict(spec.get("headers") or {})
        for v in self.headers.values():
            expand(v, resource=self.resource)
        self.tools_allowed = list(spec.get("tools") or [])
        self.rules = list(spec.get("rules") or [])
        self.deny_result = list(spec.get("deny_result") or [])
        for p in self.deny_result:
            re.compile(p)
        self.session, self.protocol, self.next_id = None, None, 0
        self.tools, self.tools_at = None, 0
        self.lock = threading.Lock()

    def _post(self, msg, want_id):
        headers = {"content-type": "application/json", "accept": "application/json, text/event-stream",
                   **{k: expand(v, live=True, resource=self.resource) for k, v in self.headers.items()}}
        cls = http.client.HTTPSConnection if self.url.scheme == "https" else http.client.HTTPConnection
        conn = cls(self.url.hostname, self.url.port, timeout=UPSTREAM_TIMEOUT)
        if self.session:
            headers["mcp-session-id"] = self.session
        if self.protocol:
            headers["mcp-protocol-version"] = self.protocol
        try:
            conn.request("POST", self.url.path or "/", body=json.dumps(msg), headers=headers)
            resp = conn.getresponse()
            sid = resp.getheader("mcp-session-id")
            if resp.status == 404 and self.session:
                resp.read()
                raise SessionGone()
            if resp.status == 401:
                resp.read()
                raise Unauthorized()
            if resp.status >= 400:
                raise UpstreamError("%s answered HTTP %d" % (self.name, resp.status))
            if want_id is None:
                resp.read()
                return None, sid
            if "text/event-stream" in (resp.getheader("content-type") or ""):
                return self._sse(resp, want_id), sid
            return json.loads(resp.read() or b"null"), sid
        except (http.client.HTTPException, OSError, ValueError) as e:
            raise UpstreamError("%s: %s" % (self.name, e.__class__.__name__))
        finally:
            conn.close()

    @staticmethod
    def _sse(resp, want_id):
        """Read events until the answer to want_id; skip the server's own messages."""
        data = []
        for raw in resp:
            line = raw.decode("utf-8", "replace").rstrip("\r\n")
            if line.startswith("data:"):
                data.append(line[5:].lstrip(" "))
            elif not line and data:
                try:
                    msg = json.loads("\n".join(data))
                except ValueError:
                    msg = None
                data = []
                if isinstance(msg, dict) and msg.get("id") == want_id and ("result" in msg or "error" in msg):
                    return msg
        raise UpstreamError("stream ended without an answer")

    def _init(self):
        self.session, self.protocol = None, None
        self.next_id += 1
        msg = {"jsonrpc": "2.0", "id": self.next_id, "method": "initialize",
               "params": {"protocolVersion": PROTOCOLS[0], "capabilities": {},
                          "clientInfo": {"name": "fxa-mcp-gateway", "version": "1"}}}
        answer, sid = self._post(msg, self.next_id)
        if not answer or "result" not in answer:
            raise UpstreamError("%s refused initialize" % self.name)
        self.session, self.protocol = sid, answer["result"].get("protocolVersion", PROTOCOLS[0])
        self._post({"jsonrpc": "2.0", "method": "notifications/initialized"}, None)

    def rpc(self, method, params):
        with self.lock:
            for attempt in (1, 2):  # an expired session or access token: renew it, once
                try:
                    if self.protocol is None:
                        self._init()
                    self.next_id += 1
                    answer, _ = self._post({"jsonrpc": "2.0", "id": self.next_id, "method": method,
                                            "params": params}, self.next_id)
                    break
                except SessionGone:
                    self.protocol = None
                    if attempt == 2:
                        raise UpstreamError("%s: session lost" % self.name)
                except Unauthorized:
                    OAUTH.drop(self.resource)
                    self.protocol = None
                    if attempt == 2:
                        raise UpstreamError("%s answered HTTP 401" % self.name)
        if not isinstance(answer, dict) or "error" in answer:
            err = (answer or {}).get("error", {}) if isinstance(answer, dict) else {}
            raise UpstreamError("%s: %s" % (self.name, err.get("message", "bad answer")))
        return answer.get("result", {})

    def list_tools(self):
        """The allowlisted tools, by upstream name, with their definitions."""
        if self.tools is not None and time.time() - self.tools_at < TOOLS_TTL:
            return self.tools
        found, cursor = {}, None
        for _ in range(20):
            result = self.rpc("tools/list", {"cursor": cursor} if cursor else {})
            for t in result.get("tools", []):
                if t.get("name") in self.tools_allowed:
                    found[t["name"]] = t
            cursor = result.get("nextCursor")
            if not cursor:
                break
        self.tools, self.tools_at = found, time.time()
        return found


def load_upstreams():
    try:
        with open(CONFIG) as f:
            conf = json.load(f)
    except (OSError, ValueError) as e:
        sys.exit("fxa-mcp-gateway: cannot read %s: %s" % (CONFIG, e))
    ups = {}
    for name, spec in (conf.get("connectors") or {}).items():
        if not re.match(r"^[a-z0-9-]{1,20}$", name) or SEP in name:
            sys.exit("fxa-mcp-gateway: bad connector name %r" % name)
        if not spec.get("tools"):
            sys.stderr.write("fxa-mcp-gateway: %s has no tools allowlist; it serves nothing\n" % name)
        try:
            ups[name] = Upstream(name, spec)
        except (KeyError, ValueError, re.error) as e:
            sys.stderr.write("fxa-mcp-gateway: %s is off: %s\n" % (name, e))
    return ups


UPSTREAMS = {}


# ── The MCP server the runner sees ────────────────────────────


def granted(rec):
    return [c for c in rec.get("connectors", []) if c in UPSTREAMS]


def list_tools(rec):
    tools = []
    for c in granted(rec):
        try:
            found = UPSTREAMS[c].list_tools()
        except UpstreamError as e:
            sys.stderr.write("fxa-mcp-gateway: tools/list %s\n" % e)
            continue
        for name, t in sorted(found.items()):
            tools.append({**t, "name": c + SEP + name,
                          "description": "[%s, read-only] %s" % (c, t.get("description", ""))})
    return tools


def tool_error(text):
    return {"content": [{"type": "text", "text": "fxa-mcp-gateway: " + text}], "isError": True}


def call_tool(tok, rec, params):
    full, args = params.get("name", ""), params.get("arguments") or {}
    conn, _, tool = full.partition(SEP)
    run = rec.get("run")
    if conn not in granted(rec):
        audit(run, conn, tool, "denied:connector")
        return tool_error("connector %r is not granted to this run" % conn)
    up = UPSTREAMS[conn]
    try:
        schema = (up.list_tools().get(tool) or {}).get("inputSchema") or {}
    except UpstreamError as e:
        audit(run, conn, tool, "error:list")
        return tool_error(str(e))
    if tool not in up.tools_allowed or tool not in up.tools:
        audit(run, conn, tool, "denied:tool", args=args)
        return tool_error("%s is not an allowed tool" % full)
    try:
        args = apply_rules(up.rules, tool, schema, args)
    except Denied as e:
        audit(run, conn, tool, "denied:rule", args=args)
        return tool_error(str(e))
    if not take_call(tok):
        audit(run, conn, tool, "denied:cap", args=args)
        return tool_error("this run reached its cap of %s calls" % rec.get("cap_calls"))
    t0 = time.time()
    try:
        result = up.rpc("tools/call", {"name": tool, "arguments": args})
    except UpstreamError as e:
        audit(run, conn, tool, "error:upstream", int((time.time() - t0) * 1000), args=args)
        return tool_error(str(e))
    ms, size = int((time.time() - t0) * 1000), len(json.dumps(result))
    if withheld(result, up.deny_result):
        audit(run, conn, tool, "denied:result", ms, size, args)
        report("withheld", run, "the gateway withheld an answer by policy",
               ": %s__%s %s" % (conn, tool, json.dumps(args, sort_keys=True)[:200]))
        return tool_error("the answer was withheld by policy")
    audit(run, conn, tool, "ok", ms, size, args)
    return result


def handle(tok, rec, msg):
    """The answer to one JSON-RPC message, or None for a notification."""
    if not isinstance(msg, dict) or msg.get("jsonrpc") != "2.0" or "method" not in msg:
        return {"jsonrpc": "2.0", "id": None, "error": {"code": -32600, "message": "invalid request"}}
    if "id" not in msg:
        return None
    method, params, mid = msg["method"], msg.get("params") or {}, msg["id"]
    if method == "initialize":
        asked = params.get("protocolVersion")
        result = {"protocolVersion": asked if asked in PROTOCOLS else PROTOCOLS[0],
                  "capabilities": {"tools": {"listChanged": False}},
                  "serverInfo": {"name": "fxa-mcp-gateway", "version": "1"},
                  "instructions": "Read-only tools for: %s. Writes are not available here; "
                                  "say in your handoff what should be written." % ", ".join(granted(rec))}
    elif method == "ping":
        result = {}
    elif method == "tools/list":
        result = {"tools": list_tools(rec)}
    elif method == "tools/call":
        result = call_tool(tok, rec, params)
    elif method in EMPTY_LISTS:
        result = {EMPTY_LISTS[method]: []}
    else:
        return {"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": "method not found"}}
    return {"jsonrpc": "2.0", "id": mid, "result": result}


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):  # one short line per call, no headers
        sys.stderr.write("%s %s\n" % (self.command, fmt % args))

    def reply(self, code, doc=None):
        body = b"" if doc is None else json.dumps(doc).encode()
        self.send_response(code)
        if doc is not None:
            self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def auth(self):
        tok = self.headers.get("authorization", "").removeprefix("Bearer ").strip()
        return tok, load(tok)

    def do_POST(self):
        if urllib.parse.urlsplit(self.path).path != "/mcp":
            return self.reply(404, {"error": "not found"})
        tok, rec = self.auth()
        if rec is None:
            return self.reply(401, {"error": "fxa-mcp-gateway: unknown, revoked or expired run token"})
        size = int(self.headers.get("content-length", 0) or 0)
        if size > MAX_BODY:
            return self.reply(413, {"error": "too large"})
        try:
            body = json.loads(self.rfile.read(size))
        except ValueError:
            return self.reply(400, {"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "parse error"}})
        msgs = body if isinstance(body, list) else [body]
        answers = [a for a in (handle(tok, rec, m) for m in msgs) if a is not None]
        if not answers:
            return self.reply(202)
        self.reply(200, answers if isinstance(body, list) else answers[0])

    def do_GET(self):
        # No server-initiated stream: the spec's answer is 405.
        self.reply(405 if urllib.parse.urlsplit(self.path).path == "/mcp" else 404)

    def do_DELETE(self):
        self.reply(405 if urllib.parse.urlsplit(self.path).path == "/mcp" else 404)


def main():
    global UPSTREAMS
    UPSTREAMS = load_upstreams()
    os.makedirs(os.path.join(DIR, "tokens"), exist_ok=True)
    host, port = LISTEN.rsplit(":", 1)
    server = http.server.ThreadingHTTPServer((host, int(port)), Handler)
    server.daemon_threads = True
    sys.stderr.write("fxa-mcp-gateway on %s, connectors: %s\n" % (LISTEN, ", ".join(sorted(UPSTREAMS)) or "none"))
    server.serve_forever()


if __name__ == "__main__":
    main()
