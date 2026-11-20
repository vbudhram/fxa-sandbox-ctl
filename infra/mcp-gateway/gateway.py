#!/usr/bin/env python3
"""fxa-mcp-gateway: the only holder of MCP credentials for runners.

A runner reaches one MCP endpoint here with a per-run token. The gateway
serves the tools of the connectors that token was granted, each renamed
`<connector>__<tool>`, and forwards a call to that connector's upstream MCP
server (Runlayer, or any Streamable HTTP server) with the upstream credential.

Every connector is read-only by construction: only the tools on its `tools`
allowlist exist, its `rules` check or rewrite arguments before a call leaves,
its `deny_result` patterns withhold an answer before it reaches the runner, and
its `redact` [pattern, replacement] pairs and `redact_keys` pattern rewrite it.
Its `prune_keys` pattern removes keys at any depth from a JSON answer (noise such
as Kubernetes managedFields), its `prune_items` patterns remove list entries that
fit them (ArgoCD resources that are Healthy and Synced), and `max_result_bytes` turns a bigger answer into
an error with `max_result_hint`, so one call cannot fill an agent's context.
The upstream account's own permissions stay the real limit; this is the second.

Config (MCP_GATEWAY_CONFIG), see connectors.example.json:
  {"connectors": {"<name>": {"url", "headers", "tools", "rules", "deny_result", "redact", "redact_keys",
                             "prune_keys", "prune_items", "max_result_bytes", "max_result_hint", "tool_note"}}}
A connector with "type": "github-app" has no upstream: the gateway serves GitHub read tools itself
with the controller's GitHub App (GitHubApp below). "type": "circleci" serves CircleCI read tools the
same way, with the token in its Circle-Token header (CircleCI below).
Header values expand ${VAR} from the environment, so secrets stay in .env.
${RUNLAYER_OAUTH_TOKEN} is an access token renewed from the refresh token in
MCP_GATEWAY_OAUTH {token_endpoint, client_id, refresh_tokens: {url: token},
clients: {url: {token_endpoint, client_id}}}, which oauth-login.py writes. A URL
in clients signs in to its own server (ArgoCD); the others use the top-level one.

Tokens: <dir>/tokens/<token>.json  {run, created, expires, connectors, cap_calls, calls}
written by the controller (lib/mcp-token.sh), updated here. One line per call
goes to <dir>/calls.jsonl. Standard library only.
"""
import base64
import hashlib
import sys
import http.client
import http.server
import json
import os
import re
import subprocess
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
    projects = [project] if isinstance(project, str) else list(project)
    base = ("project = %s" % projects[0] if len(projects) == 1 else "project in (%s)" % ", ".join(projects)) + " AND level IS EMPTY"
    if exclude_labels:
        # Jira keeps a label's case, so each case form is its own label.
        forms = list(dict.fromkeys(f for l in exclude_labels for f in (l, l.lower(), l.upper(), l.capitalize())))
        # NOT IN alone also drops issues with no labels.
        base += " AND (labels IS EMPTY OR labels NOT IN (%s))" % ", ".join(json.dumps(l) for l in forms)
    scoped = base if not where else "%s AND (%s)" % (base, where)
    return (scoped + " " + order).strip()


PROJECT_RE = re.compile(r"^[A-Z][A-Z0-9]{1,9}$")
SLUG_RE = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
CHANNEL_RE = re.compile(r"^C[A-Z0-9]{6,}$")


def team_rules(rules, scope):
    """A team's run reads its own Jira projects and repos, not the connector's FxA ones (the token's
    scope, from the controller). No scope: the connector's rules as written."""
    if not isinstance(scope, dict):
        return rules
    projects = [p for p in scope.get("jira_projects") or [] if isinstance(p, str) and PROJECT_RE.match(p)]
    chans = [c for c in scope.get("slack_channels") or [] if isinstance(c, str) and CHANNEL_RE.match(c)]
    repos = [r.lower() for r in scope.get("repos") or [] if isinstance(r, str) and SLUG_RE.match(r)]
    out, pair = [], False
    for rule in rules:
        if "jql_project" in rule and projects:
            rule = dict(rule, jql_project=projects)
        elif chans and rule.get("arg") == "channel_id" and "one_of" in rule:
            rule = dict(rule, one_of=chans)
        elif repos and rule.get("arg") in ("owner", "repo") and ("equals" in rule or "one_of" in rule):
            # Owner and repo together, for every tool that takes them: a rule bound to one tool must not
            # leave the others with no repo limit, and a mix of two allowed repos is not allowed.
            if not pair:
                out.append({"tool": "*", "arg": "repo", "pair": "owner", "one_of": repos})
                pair = True
            continue
        out.append(rule)
    # A read of one issue stays in the team's projects too, not only a search (keys only, not numeric IDs).
    if projects and any("jql_project" in r for r in rules):
        out.append({"tool": "getJiraIssue", "arg": "issueIdOrKey", "match": "(%s)-[0-9]+" % "|".join(projects)})
    return out


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
        elif "pair" in rule:
            owner = args.get(rule["pair"])
            if not isinstance(owner, str) or not isinstance(val, str) or ("%s/%s" % (owner, val)).lower() not in rule["one_of"]:
                raise Denied("%s/%s is outside what this team may read" % (rule["pair"], arg))
        elif "match" in rule:
            if val is None and rule.get("optional"):
                continue
            if not isinstance(val, str) or not re.fullmatch(rule["match"], val):
                raise Denied("%s is outside what this connector may read" % arg)
        elif "equals" in rule or "one_of" in rule:
            allowed = [rule["equals"]] if "equals" in rule else rule["one_of"]
            if not isinstance(val, str) or val.lower() not in [a.lower() for a in allowed]:
                raise Denied("%s must be one of %s" % (arg, ", ".join(allowed)))
    return args


def scrub(value, patterns, keys):
    """The value with each pattern replaced in its text and each matching key's value redacted."""
    if isinstance(value, str):
        for p, r in patterns:
            value = p.sub(r, value)
        return value
    if isinstance(value, list):
        return [scrub(v, patterns, keys) for v in value]
    if isinstance(value, dict):
        if value.get("type") in ("image", "audio"):  # bytes, which a text pattern would corrupt
            return value
        return {k: "[redacted]" if keys and keys.fullmatch(k) else scrub(v, patterns, keys) for k, v in value.items()}
    return value


def _fits(value, pat):
    """value has every key and value of pat; a None in pat means the key is absent."""
    if isinstance(pat, dict):
        return isinstance(value, dict) and all(
            (k not in value) if p is None else (k in value and _fits(value[k], p)) for k, p in pat.items())
    return value == pat


def _drop(value, keys, items=()):
    if isinstance(value, list):
        return [_drop(v, keys, items) for v in value if not any(_fits(v, p) for p in items)]
    if isinstance(value, dict):
        return {k: _drop(v, keys, items) for k, v in value.items() if not (keys and keys.fullmatch(k))}
    return value


def prune(result, keys, items=()):
    """The result with each key matching keys, and each list entry that fits one of items, removed:
    in structuredContent and in text content that is JSON."""
    if not (keys or items) or not isinstance(result, dict):
        return result
    out = dict(result)
    if "structuredContent" in out:
        out["structuredContent"] = _drop(out["structuredContent"], keys, items)
    content = []
    for c in out.get("content") or []:
        if isinstance(c, dict) and c.get("type") == "text":
            try:
                c = dict(c, text=json.dumps(_drop(json.loads(c["text"]), keys, items), separators=(",", ":")))
            except (ValueError, TypeError):
                pass
        content.append(c)
    if "content" in out:
        out["content"] = content
    return out


def capped(result, limit, hint):
    """The result, or an error when it is over limit bytes (0: no limit)."""
    size = len(json.dumps(result))
    if not limit or size <= limit:
        return result
    return tool_error("the answer is %d KB, over this connector's %d KB limit. %s" % (size // 1024, limit // 1024, hint))


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
        self.names = {}  # resource URL -> connector name, for the sign-in command in an error
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
            client = st.get("clients", {}).get(resource, st)
            body = urllib.parse.urlencode({"grant_type": "refresh_token", "refresh_token": old,
                                           "client_id": client["client_id"], "resource": resource}).encode()
            req = urllib.request.Request(client["token_endpoint"], body, {"accept": "application/json"})
            with urllib.request.urlopen(req, timeout=UPSTREAM_TIMEOUT) as r:
                doc = json.load(r)
            self.access[resource] = doc["access_token"]
        except urllib.error.HTTPError as e:
            # The server's reason (an expired, revoked or reused token) tells a lifetime from a bug.
            try:
                doc = json.loads(e.read(4000) or b"{}")
                why = str(doc.get("error") or "") + (": " + str(doc["error_description"]) if doc.get("error_description") else "")
            except (ValueError, OSError, AttributeError):
                why = ""
            name = self.names.get(resource, "<connector>")
            report("oauth", None, "%s: the OAuth server refused the gateway's refresh token; run FXA_OAUTH_ONLY=%s bash infra/gce/manager.sh oauth" % (name, name),
                   " (HTTP %d%s for %s)" % (e.code, " " + why.strip()[:200] if why.strip() else "", resource))
            raise UpstreamError("oauth: the token endpoint answered HTTP %d; run manager.sh oauth again" % e.code)
        except KeyError:
            report("oauth", None, "the gateway has no sign-in for a connector; run infra/gce/manager.sh oauth", " (%s)" % resource)
            raise UpstreamError("oauth: not signed in for this connector")
        except (OSError, ValueError) as e:
            raise UpstreamError("oauth: %s" % e.__class__.__name__)
        self.until[resource] = time.time() + int(doc.get("expires_in") or 300)
        if doc.get("refresh_expires_in"):
            sys.stderr.write("fxa-mcp-gateway: %s signed in; its refresh token lasts %s s\n" % (self.names.get(resource, resource), doc["refresh_expires_in"]))
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
        OAUTH.names[self.resource] = name
        for v in self.headers.values():
            expand(v, resource=self.resource)
        self.tools_allowed = list(spec.get("tools") or [])
        self.rules = list(spec.get("rules") or [])
        self.deny_result = list(spec.get("deny_result") or [])
        for p in self.deny_result:
            re.compile(p)
        self.redact = [(re.compile(p), r) for p, r in spec.get("redact") or []]
        self.redact_keys = re.compile(spec["redact_keys"]) if spec.get("redact_keys") else None
        self.prune_keys = re.compile(spec["prune_keys"]) if spec.get("prune_keys") else None
        self.prune_items = list(spec.get("prune_items") or [])
        # Facts the agent needs that do not belong in a public repo (ArgoCD's app names).
        self.note = (spec.get("tool_note") or "").strip()
        self.max_result = int(spec.get("max_result_bytes") or 0)
        self.max_hint = spec.get("max_result_hint") or "Ask for less."
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


# The read tools of a "github-app" connector: (description, the argument that names the item).
GH_TOOLS = {
    "get_pull_request": ("A pull request: title, state, author, branches, head commit and body.", "pull_number"),
    "get_pull_request_checks": ("The checks and statuses on a pull request's head commit, with the job_id of each GitHub "
                                "Actions job (for get_job_logs), each check's details_url and the annotations of a failed one.", "pull_number"),
    "get_commit_checks": ("The checks and statuses on a branch or commit SHA (ref), as get_pull_request_checks gives them: "
                          "for a branch with no pull request, or to see if main is red.", "ref"),
    "get_pull_request_comments": ("A pull request's comments and review comments, oldest first.", "pull_number"),
    "get_issue": ("An issue: title, state, author, body and comments.", "issue_number"),
    "get_job_logs": ("A GitHub Actions job's log: the lines that name a failure, then its end (tail_lines, default 200).", "job_id"),
}
# Read only, whatever the App may do elsewhere: GitHub refuses a token for a permission the App lacks.
GH_READ = {"metadata": "read", "contents": "read", "pull_requests": "read", "checks": "read", "statuses": "read"}
GH_NAME_RE = re.compile(r"^[A-Za-z0-9_-][A-Za-z0-9_.-]{0,99}$")
# A branch or SHA: no "..", no leading "/", nothing a URL would read as a query.
GH_REF_RE = re.compile(r"(?!.*\.\.)(?!/)[A-Za-z0-9._/-]{1,200}")
GH_FAIL_RE = re.compile(r"FAILED|FAIL |Error|error(\[|:)|panicked|assert|Traceback|exit code")


def log_tail(lines, tail_lines):
    """The lines that name a failure, then the last tail_lines (default 200, 20 to 1000)."""
    tail = min(max(int(tail_lines or 200), 20), 1000) if str(tail_lines or "200").isdigit() else 200
    if len(lines) > tail:
        lines = [ln for ln in lines[:-tail] if GH_FAIL_RE.search(ln)][:80] + ["--- the end of the log:"] + lines[-tail:]
    return lines


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k):
        return None


class GitHubApp(Upstream):
    """GitHub read tools served here, with the controller's GitHub App: for each call, an installation token
    for that one repo with read permissions only, reused for 50 minutes. Config: {"type": "github-app",
    "app_id", "pem_file", "tools", "rules"}; the rules pin owner and repo, as for an upstream connector."""

    def __init__(self, name, spec):
        super().__init__(name, dict(spec, url=spec.get("api") or "https://api.github.com", headers={}))
        self.api = self.resource.rstrip("/")
        self.app_id = expand(str(spec.get("app_id") or ""), live=True)
        self.pem = expand(str(spec.get("pem_file") or ""), live=True)
        if not self.app_id.isdigit() or not os.path.isfile(self.pem):
            raise ValueError("app_id must be a number and pem_file a readable key")
        self.tokens = {}

    def _http(self, method, url, auth=None, body=None, follow=True):
        req = urllib.request.Request(url, method=method, data=json.dumps(body).encode() if body is not None else None,
                                     headers={"accept": "application/vnd.github+json", "user-agent": "fxa-mcp-gateway",
                                              **({"authorization": "Bearer " + auth} if auth else {})})
        opener = urllib.request.build_opener() if follow else urllib.request.build_opener(_NoRedirect)
        try:
            with opener.open(req, timeout=UPSTREAM_TIMEOUT) as r:
                return r.read()
        except urllib.error.HTTPError as e:
            if not follow and e.code in (301, 302, 303, 307, 308) and e.headers.get("location"):
                # The log is on a signed storage URL: fetch it without the GitHub token.
                e.close()
                return self._http("GET", e.headers["location"])
            raise UpstreamError("%s answered HTTP %d" % (self.name, e.code))
        except (OSError, ValueError) as e:
            raise UpstreamError("%s: %s" % (self.name, e.__class__.__name__))

    def _jwt(self):
        b64 = lambda b: base64.urlsafe_b64encode(b).rstrip(b"=")
        now = int(time.time())
        head = b64(b'{"alg":"RS256","typ":"JWT"}') + b"." + b64(json.dumps({"iat": now - 60, "exp": now + 540, "iss": self.app_id}).encode())
        sig = subprocess.run(["openssl", "dgst", "-sha256", "-sign", self.pem], input=head, capture_output=True, check=True).stdout
        return (head + b"." + b64(sig)).decode()

    def _token(self, owner, repo):
        slug = ("%s/%s" % (owner, repo)).lower()
        tok, at = self.tokens.get(slug, (None, 0))
        if tok and time.time() - at < 3000:
            return tok
        try:
            jwt = self._jwt()
        except (OSError, subprocess.CalledProcessError):
            raise UpstreamError("%s: could not sign the App key" % self.name)
        inst = json.loads(self._http("GET", "%s/repos/%s/%s/installation" % (self.api, owner, repo), jwt)).get("id")
        doc = json.loads(self._http("POST", "%s/app/installations/%s/access_tokens" % (self.api, inst), jwt,
                                    {"repositories": [repo], "permissions": GH_READ}))
        self.tokens[slug] = (doc["token"], time.time())
        return doc["token"]

    def list_tools(self):
        if self.tools is None:
            self.tools = {}
            for n, (desc, num) in GH_TOOLS.items():
                if n in self.tools_allowed:
                    props = {"owner": {"type": "string"}, "repo": {"type": "string"}, num: {"type": "string" if num == "ref" else "integer"}}
                    if n == "get_job_logs":
                        props["tail_lines"] = {"type": "integer"}
                    self.tools[n] = {"name": n, "description": desc,
                                     "inputSchema": {"type": "object", "properties": props, "required": ["owner", "repo", num]}}
        return self.tools

    def rpc(self, method, params):
        if method != "tools/call" or params.get("name") not in self.list_tools():
            raise UpstreamError("%s: no such tool" % self.name)
        try:
            return self._call(params["name"], params.get("arguments") or {})
        except (ValueError, KeyError, TypeError, AttributeError):  # an answer not shaped as GitHub documents
            raise UpstreamError("%s: unexpected answer" % self.name)

    def _call(self, tool, args):
        owner, repo, num = args.get("owner"), args.get("repo"), args.get(GH_TOOLS[tool][1])
        if not all(isinstance(v, str) and GH_NAME_RE.match(v) for v in (owner, repo)):
            raise UpstreamError("%s: owner and repo must be plain names" % self.name)
        if tool == "get_commit_checks":
            if not isinstance(num, str) or not GH_REF_RE.fullmatch(num):
                raise UpstreamError("%s: ref must be a branch name or a commit SHA" % self.name)
        else:
            if isinstance(num, str) and num.isdigit():
                num = int(num)
            if not isinstance(num, int) or isinstance(num, bool) or num <= 0:
                raise UpstreamError("%s: %s must be a positive number" % (self.name, GH_TOOLS[tool][1]))
        tok, base = self._token(owner, repo), "%s/repos/%s/%s" % (self.api, owner, repo)
        get = lambda path: json.loads(self._http("GET", base + path, tok))
        user = lambda d: (d.get("user") or {}).get("login")

        def checks(ref):
            runs, failed = [], 0
            for c in get("/commits/%s/check-runs?per_page=100" % ref).get("check_runs", []):
                # A CircleCI check run has its job or workflow link only in details_url.
                row = {"name": c.get("name"), "status": c.get("status"), "conclusion": c.get("conclusion"), "url": c.get("html_url"),
                       "details_url": c.get("details_url")}
                if (c.get("app") or {}).get("slug") == "github-actions":
                    row["job_id"] = c.get("id")  # an Actions check run's id is its job's id
                if c.get("conclusion") in ("failure", "timed_out") and failed < 3:
                    failed += 1
                    row["annotations"] = [{"path": a.get("path"), "line": a.get("start_line"), "message": (a.get("message") or "")[:500]}
                                          for a in get("/check-runs/%d/annotations?per_page=20" % c["id"])]
                runs.append(row)
            statuses = [{"context": s.get("context"), "state": s.get("state"), "url": s.get("target_url")}
                        for s in get("/commits/%s/status" % ref).get("statuses", [])]
            return {"check_runs": runs, "statuses": statuses}

        if tool == "get_job_logs":
            text = self._http("GET", "%s/actions/jobs/%d/logs" % (base, num), tok, follow=False).decode("utf-8", "replace")
            lines = [re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", re.sub(r"^\S+Z ", "", ln)) for ln in text.splitlines()]
            return {"content": [{"type": "text", "text": "\n".join(log_tail(lines, args.get("tail_lines")))}]}
        if tool == "get_commit_checks":
            out = {"ref": num, **checks(urllib.parse.quote(num, safe="/"))}
        elif tool == "get_issue":
            d = get("/issues/%d" % num)
            out = {"title": d.get("title"), "state": d.get("state"), "author": user(d), "body": (d.get("body") or "")[:8000],
                   "comments": [{"author": user(c), "at": c.get("created_at"), "body": (c.get("body") or "")[:3000]}
                                for c in get("/issues/%d/comments?per_page=50" % num)]}
        else:
            pr = get("/pulls/%d" % num)
            if tool == "get_pull_request":
                out = {"title": pr.get("title"), "state": pr.get("state"), "draft": pr.get("draft"), "merged": pr.get("merged"),
                       "author": user(pr), "head": (pr.get("head") or {}).get("ref"), "base": (pr.get("base") or {}).get("ref"),
                       "head_sha": (pr.get("head") or {}).get("sha"), "body": (pr.get("body") or "")[:8000]}
            elif tool == "get_pull_request_comments":
                out = {"comments": [{"author": user(c), "at": c.get("created_at"), "body": (c.get("body") or "")[:3000]}
                                    for c in get("/issues/%d/comments?per_page=50" % num)],
                       "review_comments": [{"author": user(c), "path": c.get("path"), "line": c.get("line"),
                                            "body": (c.get("body") or "")[:3000]} for c in get("/pulls/%d/comments?per_page=50" % num)]}
            else:
                sha = (pr.get("head") or {}).get("sha")
                out = {"head_sha": sha, **checks(sha)}
        return {"content": [{"type": "text", "text": json.dumps(out, indent=1)}]}


# The read tools of a "circleci" connector: (description, its arguments besides owner and repo). No rerun,
# cancel, approve or config call exists here: the shared token can do all of them.
CI_TOOLS = {
    "get_workflow_jobs": ("A CircleCI workflow's jobs: name, status and job_number of each (for get_job).", {"workflow_id": "string"}),
    "get_job": ("A CircleCI job: its name and status, up to 50 failed tests, and the end of up to 3 failed steps "
                "(tail_lines, default 200). step: read the steps whose name contains this text, passed or failed, "
                "on each parallel node. match: keep only the log lines that contain this text and the 10 lines after "
                "each, such as \"Flaky tests\" in a Playwright step.",
                {"job_number": "integer", "tail_lines": "integer", "step": "string", "match": "string"}),
    "get_test_metrics": ("CircleCI's test metrics for one workflow on one branch (default main), over its last runs: "
                         "the slowest tests by p95 seconds and the tests that failed most, each with its job, spec, runs "
                         "and failed runs. Only a workflow that runs on that branch has data, such as nightly on main.",
                         {"workflow": "string", "branch": "string"}),
    "get_job_artifacts": ("The paths of a CircleCI job's artifacts (for get_artifact_text).", {"job_number": "integer"}),
    "get_artifact_text": ("The text of one .md, .txt, .log, .xml or .json artifact of a CircleCI job, up to 40 KB, "
                          "such as a Playwright error-context.md.", {"job_number": "integer", "path": "string"}),
    "list_pipelines": ("A CircleCI project's newest pipelines on one branch (default main), newest first: number, created_at, "
                       "trigger (schedule for a nightly, webhook for a push), commit, and each workflow's name, status and id "
                       "(for get_workflow_jobs). trigger=schedule keeps only the scheduled runs. limit: 1 to 20, default 10.",
                       {"branch": "string", "trigger": "string", "limit": "integer"}),
}
CI_OPTIONAL = {"tail_lines", "branch", "trigger", "limit", "step", "match"}
CI_WORKFLOW_RE = re.compile(r"[A-Za-z0-9_.-]{1,60}")
CI_UUID_RE = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
CI_TEXT_RE = re.compile(r"(?i).+\.(md|txt|log|xml|json)")
CI_MAX = 20 << 20  # bytes of one download


class CircleCI(Upstream):
    """CircleCI read tools served here, with one API token (headers: {"Circle-Token": "${CIRCLECI_TOKEN}"}).
    Every tool takes owner and repo, so the rules pin the project as for GitHub. The token goes only to
    CircleCI's own https hosts and never across a redirect; an error names no URL."""
    # The hosts that get the token; a test points this at its fake server.
    TOKEN_URL = re.compile(r"https://(circleci\.com|([a-z0-9-]+\.)+circle-artifacts\.com)(/|$)")

    def __init__(self, name, spec):
        super().__init__(name, dict(spec, url=spec.get("api") or "https://circleci.com"))
        self.api = self.resource.rstrip("/")
        if "Circle-Token" not in self.headers:
            raise ValueError("headers needs Circle-Token")

    def _get(self, url, limit=CI_MAX, auth=True):
        if urllib.parse.urlsplit(url).scheme not in ("http", "https"):
            raise UpstreamError("%s: refused a link that is not http" % self.name)
        auth = bool(auth and self.TOKEN_URL.match(url))
        headers = {"accept": "application/json", "user-agent": "fxa-mcp-gateway"}
        if auth:
            headers["Circle-Token"] = expand(self.headers["Circle-Token"], live=True)
        opener = urllib.request.build_opener(_NoRedirect) if auth else urllib.request.build_opener()
        try:
            with opener.open(urllib.request.Request(url, headers=headers), timeout=UPSTREAM_TIMEOUT) as r:
                return r.read(limit)
        except urllib.error.HTTPError as e:
            loc = e.headers.get("location") if auth and e.code in (301, 302, 303, 307, 308) else None
            e.close()
            if loc:
                # An artifact is on signed storage: fetch it without the token.
                return self._get(urllib.parse.urljoin(url, loc), limit, auth=False)
            raise UpstreamError("%s answered HTTP %d" % (self.name, e.code))
        except (OSError, ValueError) as e:
            raise UpstreamError("%s: %s" % (self.name, e.__class__.__name__))

    def _pages(self, path, most=10):
        """The items of a paged v2 list, at most `most` pages."""
        items, token = [], None
        for _ in range(most):
            doc = json.loads(self._get(self.api + path + ("?page-token=" + urllib.parse.quote(token) if token else "")))
            items += doc.get("items") or []
            token = doc.get("next_page_token")
            if not token:
                break
        return items

    def list_tools(self):
        if self.tools is None:
            self.tools = {}
            for n, (desc, extra) in CI_TOOLS.items():
                if n in self.tools_allowed:
                    props = {"owner": {"type": "string"}, "repo": {"type": "string"}, **{k: {"type": t} for k, t in extra.items()}}
                    self.tools[n] = {"name": n, "description": desc, "inputSchema": {
                        "type": "object", "properties": props, "required": ["owner", "repo"] + [k for k in extra if k not in CI_OPTIONAL]}}
        return self.tools

    def rpc(self, method, params):
        if method != "tools/call" or params.get("name") not in self.list_tools():
            raise UpstreamError("%s: no such tool" % self.name)
        try:
            return self._call(params["name"], params.get("arguments") or {})
        except (ValueError, KeyError, TypeError, AttributeError):  # an answer not shaped as CircleCI documents
            raise UpstreamError("%s: unexpected answer" % self.name)

    def _call(self, tool, args):
        owner, repo = args.get("owner"), args.get("repo")
        if not all(isinstance(v, str) and GH_NAME_RE.match(v) for v in (owner, repo)):
            raise UpstreamError("%s: owner and repo must be plain names" % self.name)
        slug = "%s/%s" % (owner, repo)
        if tool == "get_workflow_jobs":
            wf = args.get("workflow_id")
            if not isinstance(wf, str) or not CI_UUID_RE.fullmatch(wf):
                raise UpstreamError("%s: workflow_id must be a workflow's UUID" % self.name)
            # The path names no project, so the answer must: another team's workflow stops here.
            doc = json.loads(self._get("%s/api/v2/workflow/%s" % (self.api, wf)))
            if str(doc.get("project_slug") or "").lower() not in ("gh/" + slug.lower(), "github/" + slug.lower()):
                raise UpstreamError("%s: that workflow is not in %s" % (self.name, slug))
            out = {"name": doc.get("name"), "status": doc.get("status"),
                   "jobs": [{"name": j.get("name"), "status": j.get("status"), "job_number": j.get("job_number")}
                            for j in self._pages("/api/v2/workflow/%s/job" % wf)]}
            return {"content": [{"type": "text", "text": json.dumps(out, indent=1)}]}
        if tool == "list_pipelines":
            return {"content": [{"type": "text", "text": json.dumps(self._pipelines(slug, args), indent=1)}]}
        if tool == "get_test_metrics":
            return {"content": [{"type": "text", "text": json.dumps(self._test_metrics(slug, args), indent=1)}]}
        n = args.get("job_number")
        if isinstance(n, str) and n.isdigit():
            n = int(n)
        if not isinstance(n, int) or isinstance(n, bool) or n <= 0:
            raise UpstreamError("%s: job_number must be a positive number" % self.name)
        v2 = "/api/v2/project/gh/%s" % slug
        arts = lambda: [(a.get("path"), a.get("url")) for a in self._pages("%s/%d/artifacts" % (v2, n))]
        if tool == "get_job_artifacts":
            paths = [p for p, _ in arts()]
            out = {"paths": paths[:300], **({"more": len(paths) - 300} if len(paths) > 300 else {})}
            return {"content": [{"type": "text", "text": json.dumps(out, indent=1)}]}
        if tool == "get_artifact_text":
            path = args.get("path")
            if not isinstance(path, str) or not CI_TEXT_RE.fullmatch(path):
                raise UpstreamError("%s: path must be a .md, .txt, .log, .xml or .json artifact" % self.name)
            # Only a link from this job's own list: never one the caller made up.
            url = next((u for p, u in arts() if p == path and isinstance(u, str)), None)
            if not url:
                raise UpstreamError("%s: job %d has no artifact %s" % (self.name, n, path))
            body = self._get(url, 40001)
            text = body[:40000].decode("utf-8", "replace") + ("\n[cut at 40 KB]" if len(body) > 40000 else "")
            return {"content": [{"type": "text", "text": text}]}
        job = json.loads(self._get("%s%s/job/%d" % (self.api, v2, n)))
        parts = ["Job %d: %s, %s" % (n, job.get("name"), job.get("status"))]
        failed = [t for t in self._pages("%s/%d/tests" % (v2, n)) if t.get("result") == "failure"]
        if failed:
            parts.append("Failed tests:")
            parts += ["- %s %s: %s" % (t.get("classname"), t.get("name"),
                                       re.sub(r"\[\[ATTACHMENT\|[^]]*\]\]\s*", "", t.get("message") or "")[:300]) for t in failed[:50]]
        # v2 has no step logs; v1.1 lists each step with a signed link to its output, read with no token.
        build = json.loads(self._get("%s/api/v1.1/project/github/%s/%d" % (self.api, slug, n)))
        want, match = args.get("step"), args.get("match")
        for v, what in ((want, "step"), (match, "match")):
            if v is not None and (not isinstance(v, str) or not 1 <= len(v) <= 80):
                raise UpstreamError("%s: %s must be 1 to 80 characters of text" % (self.name, what))
        acts = [(s.get("name"), a) for s in build.get("steps") or [] for a in s.get("actions") or [] if isinstance(a, dict)]
        if want:
            # A named step, passed or failed, on each parallel node: a Playwright step that passed lists its flaky tests.
            steps = [(n_, a) for n_, a in acts if want.lower() in str(n_ or "").lower()][:12]
            if not steps:
                parts.append('No step name contains "%s".' % want)
        else:
            steps = [(n_, a) for n_, a in acts if a.get("failed") is True][:3]
        quiet = 0
        for name, a in steps:
            url = a.get("output_url")
            if not (isinstance(url, str) and url):
                continue
            msgs = json.loads(self._get(url, auth=False))
            text = "".join(m.get("message") or "" for m in msgs if isinstance(m, dict))
            lines = [re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", ln) for ln in text.splitlines()]
            if match:
                keep = sorted({j for i, ln in enumerate(lines) if match.lower() in ln.lower() for j in range(i, min(i + 11, len(lines)))})[:60]
                if not keep:
                    quiet += 1
                    continue
                lines = [lines[j] for j in keep]
            else:
                lines = log_tail(lines, args.get("tail_lines"))
            head = 'Step "%s", node %s:' % (name, a.get("index", 0)) if want else 'End of the failed step "%s":' % name
            parts += [head] + lines
        if match and quiet:
            parts.append('%d step logs have no line with "%s".' % (quiet, match))
        return {"content": [{"type": "text", "text": "\n".join(parts)}]}

    def _test_metrics(self, slug, args):
        wf, br = args.get("workflow"), args.get("branch") or "main"
        if not isinstance(wf, str) or not CI_WORKFLOW_RE.fullmatch(wf):
            raise UpstreamError("%s: workflow must be a workflow's name" % self.name)
        if not isinstance(br, str) or not GH_REF_RE.fullmatch(br):
            raise UpstreamError("%s: branch must be a plain branch name" % self.name)
        doc = json.loads(self._get("%s/api/v2/insights/gh/%s/workflows/%s/test-metrics?%s" % (
            self.api, slug, urllib.parse.quote(wf, safe=""), urllib.parse.urlencode({"branch": br}))))

        def rows(key):
            return [{"job": t.get("job_name"), "spec": t.get("file") or t.get("classname"), "test": str(t.get("test_name") or "")[:200],
                     "p95_s": round(float(t.get("p95_duration") or 0), 1), "runs": t.get("total_runs"), "failed": t.get("failed_runs")}
                    for t in (doc.get(key) or [])[:40] if isinstance(t, dict)]
        return {"workflow": wf, "branch": br, "runs": doc.get("total_test_runs"), "average_test_count": doc.get("average_test_count"),
                "slowest": rows("slowest_tests"), "most_failed": rows("most_failed_tests")}

    def _pipelines(self, slug, args):
        br, trig, lim = args.get("branch") or "main", args.get("trigger") or None, args.get("limit") or 10
        if not isinstance(br, str) or not GH_REF_RE.fullmatch(br):
            raise UpstreamError("%s: branch must be a plain branch name" % self.name)
        if trig not in (None, "schedule", "webhook", "api"):
            raise UpstreamError("%s: trigger must be schedule, webhook or api" % self.name)
        if isinstance(lim, bool) or not isinstance(lim, int) or not 1 <= lim <= 20:
            raise UpstreamError("%s: limit must be 1 to 20" % self.name)
        out, token = [], None
        # A nightly is about one pipeline in 20 on main, so a schedule filter reads up to 10 pages.
        for _ in range(10):
            q = {"branch": br, **({"page-token": token} if token else {})}
            doc = json.loads(self._get("%s/api/v2/project/gh/%s/pipeline?%s" % (self.api, slug, urllib.parse.urlencode(q))))
            for p in doc.get("items") or []:
                t = (p.get("trigger") or {}).get("type")
                if trig and t != trig:
                    continue
                pid = str(p.get("id") or "")
                if not CI_UUID_RE.fullmatch(pid):
                    continue
                wfs = self._pages("/api/v2/pipeline/%s/workflow" % pid, most=2)
                out.append({"number": p.get("number"), "created_at": p.get("created_at"), "state": p.get("state"), "trigger": t,
                            "commit": str((p.get("vcs") or {}).get("revision") or "")[:12],
                            "workflows": [{"name": w.get("name"), "status": w.get("status"), "id": w.get("id")} for w in wfs]})
                if len(out) >= lim:
                    return {"pipelines": out}
            token = doc.get("next_page_token")
            if not token:
                break
        return {"pipelines": out}


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
            ups[name] = {"github-app": GitHubApp, "circleci": CircleCI}.get(spec.get("type"), Upstream)(name, spec)
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
                          "description": "[%s, read-only] %s%s" % (c, UPSTREAMS[c].note + " " if UPSTREAMS[c].note else "",
                                                                    t.get("description", ""))})
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
        args = apply_rules(team_rules(up.rules, rec.get("scope")), tool, schema, args)
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
    return capped(scrub(prune(result, up.prune_keys, up.prune_items), up.redact, up.redact_keys), up.max_result, up.max_hint)


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
