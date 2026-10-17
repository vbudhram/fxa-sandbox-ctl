#!/usr/bin/env python3
"""A team record: one JSON object for each team, read as data, never sourced (self-service teams spec, phase 0).

  team_record.py validate <record.json> [<name>]   the problems, one a line; exit 1 when there is one
  team_record.py env <record.json> <name>          KEY<TAB>VALUE lines for pipeline_load (REPO for each repo row)
  team_record.py prompts <record.json> <dir>       write the team's CLAUDE.md, guide.md and goal.md into <dir>
  team_record.py unique <record.json> <dir>        clashes with the other records in <dir> and the built-in teams
  team_record.py stamp <record.json> <actor> <at> [<old record>]   the record with created and updated set
  team_record.py index <dir>                       the index of the records in <dir>, for the bot and the dashboard

A record names no host key (state, lock, URIs, credentials): pipeline_load derives those from the name.
"""
import hashlib
import json
import os
import re
import sys

NAME = re.compile(r"^[a-z][a-z0-9-]{1,30}$")
SLUG = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
PATH = re.compile(r"^/home/agent/[a-z0-9-]+$")
BRANCH = re.compile(r"^[A-Za-z0-9._/-]{1,60}$")
LABEL = re.compile(r"^[A-Za-z0-9 ._()-]{1,40}$")
USER = re.compile(r"^[UW][A-Z0-9]{6,}$")
CHANNEL = re.compile(r"^C[A-Z0-9]{6,}$")
EMAIL = re.compile(r"^[^@\s]{1,64}@[A-Za-z0-9.-]{1,190}\.[A-Za-z]{2,}$")
PROJECT = re.compile(r"^[A-Z][A-Z0-9]{1,9}$")
HOST = re.compile(r"^(?=.{1,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$")
CONNECTOR = re.compile(r"^[a-z0-9-]{1,30}$")
REVIEWERS = re.compile(r"^([A-Za-z0-9_.-]+/)?[A-Za-z0-9_.-]{0,60}$")
DESKTOP = re.compile(r"^http://localhost:[0-9]{2,5}/$")
STAMP = re.compile(r"^[0-9T:.Z+-]{10,32}$")

KEYS = {"schema", "name", "label", "status", "admins", "access", "repos", "stack", "runner",
        "egress", "mcp", "jira", "pr", "caps", "prompts", "skills", "boot", "secrets", "created", "updated"}
# A record names code only from this repo, where it is reviewed: skills/<name> on the catalog, and
# boot/<script>.sh pinned by its SHA-256, so an edit to the script needs a new pin.
REPO = os.environ.get("FXA_TEAM_REPO") or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = re.compile(r"^[a-z0-9][a-z0-9-]{0,39}$")
SHA = re.compile(r"^[0-9a-f]{64}$")
PROMPTS = {"claude_md": ("CLAUDE.md", 8192), "guide_md": ("guide.md", 16384), "goal_md": ("goal.md", 2560)}
# The goal is the team's steps plus a shared tail of about 1200 chars, and Claude refuses a /goal over 4000.
RESERVED = {"fxa", "index"}
# Hosts that take data out with no account: paste sites, file drops, tunnels and request catchers.
# An admin may approve other hosts; these are refused even then, with every subdomain.
EGRESS_DENY = ("pastebin.com", "paste.ee", "hastebin.com", "termbin.com", "ix.io", "dpaste.org", "rentry.co",
               "transfer.sh", "file.io", "0x0.st", "tmpfiles.org", "gofile.io", "wetransfer.com",
               "ngrok.io", "ngrok.app", "ngrok-free.app", "trycloudflare.com", "serveo.net", "localhost.run",
               "webhook.site", "requestbin.com", "pipedream.net", "beeceptor.com", "requestcatcher.com", "interact.sh", "oast.fun")  # index.json is the cache's index


def catalog():
    try:
        with open(os.path.join(REPO, "skills", "team-catalog.txt"), encoding="utf-8") as f:
            return {l.strip() for l in f if l.strip() and not l.startswith("#")}
    except OSError:
        return set()


def file_sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        h.update(f.read())
    return h.hexdigest()


def ceiling(key, default):
    try:
        return int(os.environ.get(key, default))
    except ValueError:
        return default


def check(rec, name=None):
    """The problems with a record, as short sentences. Empty means valid."""
    bad = []

    def obj(v, where, keys):
        if not isinstance(v, dict):
            bad.append(f"{where} must be an object")
            return {}
        for k in sorted(set(v) - keys):
            bad.append(f"{where}.{k} is not a known key")
        return v

    def strs(v, where, pat, most):
        if not isinstance(v, list) or not all(isinstance(x, str) for x in v):
            bad.append(f"{where} must be a list of strings")
            return []
        if len(v) > most:
            bad.append(f"{where} has more than {most} items")
        for x in v:
            if not pat.match(x):
                bad.append(f"{where}: {x!r} is not valid")
        if len(set(v)) != len(v):
            bad.append(f"{where} lists an item twice")
        return v

    def flag(v, where):
        if not isinstance(v, bool):
            bad.append(f"{where} must be true or false")

    if not isinstance(rec, dict):
        return ["the record must be a JSON object"]
    for k in sorted(set(rec) - KEYS):
        bad.append(f"{k} is not a known key (host keys such as the state dir come from the name)")
    if rec.get("schema") != 1:
        bad.append("schema must be 1")

    n = rec.get("name")
    if not isinstance(n, str) or not NAME.match(n) or "--" in n:
        bad.append("name must match ^[a-z][a-z0-9-]{1,30}$, with no -- (it separates a team's secrets)")
    else:
        if name is not None and n != name:
            bad.append(f"name {n!r} does not match the record's file name {name!r}")
        reserved = RESERVED | set(os.environ.get("FXA_RESERVED_TEAMS", "").split())
        if n in reserved:
            bad.append(f"name {n!r} is reserved (a built-in team)")

    if "label" in rec and (not isinstance(rec["label"], str) or not LABEL.match(rec["label"])):
        bad.append("label must be 1 to 40 letters, digits, spaces or ._()-")
    if rec.get("status", "draft") not in ("draft", "active", "disabled"):
        bad.append("status must be draft, active or disabled")

    admins = rec.get("admins", [])
    if not isinstance(admins, list):
        bad.append("admins must be a list")
        admins = []
    for i, a in enumerate(admins):
        a = obj(a, f"admins[{i}]", {"slack", "email"})
        if not USER.match(str(a.get("slack", ""))):
            bad.append(f"admins[{i}].slack must be a Slack user ID")
        if not EMAIL.match(str(a.get("email", ""))):
            bad.append(f"admins[{i}].email must be an email address")

    acc = obj(rec.get("access", {}), "access", {"open", "users", "channels", "jira_prefixes"})
    if "open" in acc:
        flag(acc["open"], "access.open")
    strs(acc.get("users", []), "access.users", USER, 200)
    strs(acc.get("channels", []), "access.channels", CHANNEL, 20)
    strs(acc.get("jira_prefixes", []), "access.jira_prefixes", PROJECT, 5)

    repos = rec.get("repos")
    if not isinstance(repos, list) or not 1 <= len(repos) <= 8:
        bad.append("repos must list 1 to 8 repos")
        repos = []
    slugs, paths, work = set(), set(), set()
    for i, r in enumerate(repos):
        r = obj(r, f"repos[{i}]", {"slug", "path", "role", "base", "default"})
        s = r.get("slug")
        if not isinstance(s, str) or not SLUG.match(s) or any(x in (".", "..") for x in s.split("/")):
            bad.append(f"repos[{i}].slug must be owner/name")
            continue
        p = r.get("path", default_path(s))
        if not isinstance(p, str) or not PATH.match(p):
            bad.append(f"repos[{i}].path must match ^/home/agent/[a-z0-9-]+$")
        if r.get("role") not in ("work", "dep", "data", "ref"):
            bad.append(f"repos[{i}].role must be work, dep, data or ref")
        if not BRANCH.match(str(r.get("base", "main"))):
            bad.append(f"repos[{i}].base is not a branch name")
        if "default" in r:
            flag(r["default"], f"repos[{i}].default")
        if s.lower() in slugs:
            bad.append(f"repos lists {s} twice")
        if p in paths:
            bad.append(f"two repos use {p}")
        slugs.add(s.lower())
        paths.add(p)
        if r.get("role") == "work":
            work.add(p)
    if repos and not any(isinstance(r, dict) and r.get("role") == "work" for r in repos):
        bad.append("repos needs at least one work repo")

    stack = obj(rec.get("stack", {}), "stack", {"kind"})
    if stack.get("kind", "none") not in ("fxa", "none"):
        bad.append("stack.kind must be fxa or none")
    if stack.get("kind") == "fxa" and "mozilla/fxa" not in slugs:
        bad.append("stack.kind fxa needs a mozilla/fxa repo row")
    if stack.get("kind", "none") != "fxa" and not str(rec.get("prompts", {}).get("goal_md", "")).strip():
        bad.append("a team without the FxA stack needs prompts.goal_md: FxA's goal names FxA's skills, lint and PR template")

    run = obj(rec.get("runner", {}), "runner", {"backend", "android", "desktop_url"})
    if run.get("backend", "gce") not in ("gce", "firecracker"):
        bad.append("runner.backend must be gce or firecracker")
    if "android" in run:
        flag(run["android"], "runner.android")
    if "desktop_url" in run and not DESKTOP.match(str(run["desktop_url"])):
        bad.append("runner.desktop_url must be http://localhost:<port>/")

    eg = obj(rec.get("egress", {}), "egress", {"requested", "approved"})
    strs(eg.get("requested", []), "egress.requested", HOST, 30)
    for h in strs(eg.get("approved", []), "egress.approved", HOST, 30):
        if any(h == d or h.endswith("." + d) for d in EGRESS_DENY):
            bad.append(f"egress host {h} can take data out with no account, so it is refused")
    strs(rec.get("mcp", []), "mcp", CONNECTOR, 10)

    jira = obj(rec.get("jira", {}), "jira", {"project", "queue"})
    if "project" in jira and not PROJECT.match(str(jira["project"])):
        bad.append("jira.project must be a Jira project key")
    if "queue" in jira:
        flag(jira["queue"], "jira.queue")
    if jira.get("queue") and "project" not in jira:
        bad.append("jira.queue needs jira.project")

    pr = obj(rec.get("pr", {}), "pr", {"open", "reviewers"})
    if "open" in pr:
        flag(pr["open"], "pr.open")
    if "reviewers" in pr and not REVIEWERS.match(str(pr["reviewers"])):
        bad.append("pr.reviewers must be a GitHub team or user name")

    caps = obj(rec.get("caps", {}), "caps", {"launches_per_day", "usd_per_day", "usd_per_month"})
    for k, env_key, default in (("usd_per_day", "TEAM_CAP_USD_PER_DAY", 200), ("usd_per_month", "TEAM_CAP_USD_PER_MONTH", 3000)):
        if k in caps:
            most, v = ceiling(env_key, default), caps[k]
            if not isinstance(v, (int, float)) or isinstance(v, bool) or not 0 < v <= most:
                bad.append(f"caps.{k} must be more than 0 and at most {most}")
    if "launches_per_day" in caps:
        most = ceiling("TEAM_CAP_LAUNCHES_PER_DAY", 40)
        v = caps["launches_per_day"]
        if not isinstance(v, int) or isinstance(v, bool) or not 0 <= v <= most:
            bad.append(f"caps.launches_per_day must be 0 to {most}")

    pro = obj(rec.get("prompts", {}), "prompts", set(PROMPTS))
    for k, (_, most) in PROMPTS.items():
        if k in pro and (not isinstance(pro[k], str) or len(pro[k].encode()) > most):
            bad.append(f"prompts.{k} must be text of at most {most} bytes")

    skills = strs(rec.get("skills", []), "skills", SCRIPT, 20)
    for k in sorted(set(skills) - catalog()):
        bad.append(f"skill {k!r} is not on skills/team-catalog.txt")
    if "boot" in rec:
        boot = obj(rec["boot"], "boot", {"script", "sha256"})
        sc, pin = str(boot.get("script", "")), str(boot.get("sha256", ""))
        path = os.path.join(REPO, "boot", sc + ".sh")
        if not SCRIPT.match(sc) or not os.path.isfile(path):
            bad.append("boot.script must name a script in boot/ of this repo")
        elif not SHA.match(pin):
            bad.append("boot.sha256 must be the script's SHA-256")
        elif file_sha(path) != pin:
            bad.append(f"boot/{sc}.sh changed since it was pinned: review it, then pin {file_sha(path)}")

    # Secrets are names in Secret Manager, never values, and only the team's own: fxa-team-<name>--<what>.
    # The -- is not allowed in a team name, so team pay cannot name a secret of team pay-x.
    sec = obj(rec.get("secrets", {}), "secrets", {"jira", "runtime"})
    if "jira" in sec and isinstance(n, str):
        if not re.match(rf"^fxa-team-{re.escape(n)}--[a-z0-9]+(-[a-z0-9]+)*$", str(sec["jira"])):
            bad.append(f"secrets.jira must be a Secret Manager name fxa-team-{n}--<what>")
    runtime = sec.get("runtime", [])
    if not isinstance(runtime, list) or len(runtime) > 10:
        bad.append("secrets.runtime must list at most 10 secrets")
        runtime = []
    for i, r in enumerate(runtime):
        r = obj(r, f"secrets.runtime[{i}]", {"secret", "path"})
        sp, pp = str(r.get("secret", "")), str(r.get("path", ""))
        if not isinstance(n, str) or not re.match(rf"^fxa-team-{re.escape(n)}--[a-z0-9]+(-[a-z0-9]+)*$", sp):
            bad.append(f"secrets.runtime[{i}].secret must be a Secret Manager name fxa-team-{n}--<what>")
        # Inside one of the team's own repo folders, so it lands where the stack reads it and nowhere else.
        if not re.match(r"^/home/agent/[a-z0-9-]+/[A-Za-z0-9._/-]{1,150}$", pp) or ".." in pp \
                or "/".join(pp.split("/")[:4]) not in paths:
            bad.append(f"secrets.runtime[{i}].path must be a file inside one of the team's repo folders")
        # A work repo's files go back to the host and into its PR; a runner's .git/info/exclude does not.
        elif "/".join(pp.split("/")[:4]) in work:
            bad.append(f"secrets.runtime[{i}].path is in a work repo, whose files can ship in a PR: use a dep, data or ref repo")

    for k in ("created", "updated"):
        if k in rec:
            st = obj(rec[k], k, {"by", "at"})
            if not EMAIL.match(str(st.get("by", ""))) or not STAMP.match(str(st.get("at", ""))):
                bad.append(f"{k} needs by (an email) and at (a UTC time)")
    return bad


def default_path(slug):
    return "/home/agent/" + re.sub(r"[^a-z0-9-]", "-", slug.split("/")[-1].lower())


def env(rec):
    """The PIPE_* values the controller reads today, from a valid record."""
    repos = rec["repos"]
    yield "PIPE_LABEL", rec.get("label", rec["name"])
    for r in repos:
        base = f" {r['base']}" if r.get("base") else ""
        yield "REPO", f"{r['slug']} {r.get('path', default_path(r['slug']))} {r['role']}{base}"
    work = [r for r in repos if r["role"] == "work"]
    yield "PIPE_BASE_BRANCH", work[0].get("base", "main")
    # Only rows marked default: a value makes every session a trees session, which a one-repo team is not.
    default = " ".join(r["slug"] for r in repos if r.get("default"))
    if default:
        yield "PIPE_STACK_DEFAULT", default
    if rec.get("stack", {}).get("kind") == "fxa":
        fxa = next(r for r in repos if r["slug"] == "mozilla/fxa")
        yield "PIPE_STACK_DIR", fxa.get("path", default_path(fxa["slug"]))
    run = rec.get("runner", {})
    yield "PIPE_VM_BACKEND", run.get("backend", "gce")
    if run.get("android"):
        yield "PIPE_ANDROID", "1"
    if run.get("desktop_url"):
        yield "PIPE_DESKTOP_URL", run["desktop_url"]
    yield "PIPE_EGRESS_EXTRA", " ".join(rec.get("egress", {}).get("approved", []))
    # Always set, so a team without connectors gets none, not the bot's FxA set.
    yield "PIPE_MCP", ",".join(rec.get("mcp", []))
    jira = rec.get("jira", {})
    if jira.get("project"):
        yield "PIPE_JIRA_PROJECT", jira["project"]
    pr = rec.get("pr", {})
    yield "PIPE_PR_OPEN", "1" if pr.get("open", True) else "0"
    if pr.get("reviewers"):
        yield "PIPE_PR_TEAM", pr["reviewers"]
    if rec.get("skills"):
        yield "PIPE_TEAM_SKILLS", " ".join(rec["skills"])
    if rec.get("boot"):
        yield "PIPE_BOOT_SCRIPT", rec["boot"]["script"]
        yield "PIPE_BOOT_SHA256", rec["boot"]["sha256"]
    if rec.get("secrets", {}).get("runtime"):
        yield "PIPE_RUNTIME_SECRETS", " ".join(f"{r['secret']}={r['path']}" for r in rec["secrets"]["runtime"])
    if rec.get("secrets", {}).get("jira"):
        yield "PIPE_JIRA_SECRET", rec["secrets"]["jira"]
    if "launches_per_day" in rec.get("caps", {}):
        yield "PIPE_MAX_LAUNCHES_PER_DAY", str(rec["caps"]["launches_per_day"])
    if "usd_per_day" in rec.get("caps", {}):
        yield "PIPE_TEAM_USD_DAY", str(rec["caps"]["usd_per_day"])
    if "usd_per_month" in rec.get("caps", {}):
        yield "PIPE_TEAM_USD_MONTH", str(rec["caps"]["usd_per_month"])


def unique(rec, folder):
    """Clashes with the other teams. FXA_BUILTIN_JIRA holds the built-in teams' "PROJECT:team" pairs."""
    bad, mine = [], rec["name"]
    taken = dict(p.split(":", 1) for p in os.environ.get("FXA_BUILTIN_JIRA", "").split() if ":" in p)
    chans = {}
    for f in sorted(os.listdir(folder)) if os.path.isdir(folder) else []:
        if not f.endswith(".json") or f == "index.json" or f[:-5] == mine:
            continue
        try:
            other = load(os.path.join(folder, f))
        except SystemExit:
            continue
        for p in [other.get("jira", {}).get("project")] + other.get("access", {}).get("jira_prefixes", []):
            if p:
                taken.setdefault(p, other.get("name", f[:-5]))
        for c in other.get("access", {}).get("channels", []):
            chans.setdefault(c, other.get("name", f[:-5]))
    acc = rec.get("access", {})
    for p in {rec.get("jira", {}).get("project")} | set(acc.get("jira_prefixes", [])):
        if p and taken.get(p, mine) != mine:
            bad.append(f"Jira project {p} belongs to team {taken[p]}")
    for c in acc.get("channels", []):
        if chans.get(c, mine) != mine:
            bad.append(f"channel {c} belongs to team {chans[c]}")
    return bad


def stamp(rec, actor, at, old=None):
    by = {"by": actor, "at": at} if EMAIL.match(actor) and STAMP.match(at) else None
    if old and "created" in old:
        rec["created"] = old["created"]
    elif by:
        rec["created"] = by
    if by:
        rec["updated"] = by
    return rec


def index(folder):
    """One entry for each valid record: what the bot and the dashboard read without loading a team."""
    teams = {}
    for f in sorted(os.listdir(folder)) if os.path.isdir(folder) else []:
        if not f.endswith(".json") or f == "index.json":
            continue
        try:
            rec = load(os.path.join(folder, f))
        except SystemExit:
            continue
        if check(rec, f[:-5]):
            continue
        gen = ""
        try:
            with open(os.path.join(folder, f[:-5] + ".gen"), encoding="utf-8") as g:
                gen = g.read().strip()
        except OSError:
            pass
        teams[rec["name"]] = {"label": rec.get("label", rec["name"]), "status": rec.get("status", "draft"),
                              "generation": gen, "access": rec.get("access", {}),
                              "jira": rec.get("jira", {}).get("project", ""), "queue": rec.get("jira", {}).get("queue") is True}
    return {"schema": 1, "teams": teams}


def load(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError) as e:
        sys.exit(f"{path}: cannot read the record: {e}")


def main(argv):
    if len(argv) < 3 or argv[1] not in ("validate", "env", "prompts", "unique", "stamp", "index"):
        sys.exit(__doc__)
    cmd, path = argv[1], argv[2]
    if cmd == "index":
        print(json.dumps(index(path), indent=1, sort_keys=True))
        return 0
    rec = load(path)
    name = argv[3] if len(argv) > 3 and cmd in ("validate", "env") else None
    bad = check(rec, name)
    if bad:
        print("\n".join(f"{os.path.basename(path)}: {b}" for b in bad), file=sys.stderr)
        return 1
    if cmd == "unique":
        clash = unique(rec, argv[3])
        if clash:
            print("\n".join(f"{os.path.basename(path)}: {c}" for c in clash), file=sys.stderr)
            return 1
    elif cmd == "stamp":
        old = load(argv[5]) if len(argv) > 5 and os.path.exists(argv[5]) else None
        print(json.dumps(stamp(rec, argv[3], argv[4], old), indent=1))
    elif cmd == "env":
        for k, v in env(rec):
            print(f"{k}\t{v}")
    elif cmd == "prompts":
        out = argv[3]
        os.makedirs(out, exist_ok=True)
        for k, (fname, _) in PROMPTS.items():
            target = os.path.join(out, fname)
            text = rec.get("prompts", {}).get(k, "")
            if text:
                with open(target, "w", encoding="utf-8") as f:
                    f.write(text if text.endswith("\n") else text + "\n")
            elif os.path.exists(target):
                os.remove(target)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
