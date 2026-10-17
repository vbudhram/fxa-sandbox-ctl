#!/usr/bin/env python3
"""One routine's config (epic i168, design 2026-10-17-routines.md): the one validator, and its run times.

  routine.py validate <routine.json> <team> --profile <profile show json> [--index <teams index>]
                      [--bot-env <bot .env>] [--count <other routines of the team>]
      Prints the normalized routine on success; else one "<field>: <reason>" line for each problem, exit 1.
  routine.py next <routine.json> [--from <epoch>] [--n <count>]   the next run times, as local ISO times
  routine.py period <routine.json> <epoch>                         the period key: the local date of that time
  routine.py templates [<dir>]                                     the built-in templates (templates/routines), as JSON

Run with python3 -I. The DST rules live only here: a time is a wall-clock time in the routine's zone.
"""
import datetime
import json
import os
import re
import sys
import zoneinfo

NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9 ._()-]{0,39}$")
SCHEDULE = re.compile(r"^(daily|weekdays|weekly (mon|tue|wed|thu|fri|sat|sun)) ([01][0-9]|2[0-3]):([0-5][0-9])$")
BRANCH = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._/-]{0,59}$")
CHANNEL = re.compile(r"^[CG][A-Z0-9]{6,}$")
LINK = re.compile(r"^https://[a-z0-9.-]+\.slack\.com/archives/([CG][A-Z0-9]{6,})/?(\?.*)?$")
ZONE = re.compile(r"^[A-Za-z][A-Za-z0-9_+-]*(/[A-Za-z0-9_+-]+){0,2}$")
TEMPLATES = ("code-review", "ux-review", "perf-review", "security-review", "blank")
MODES = ("report", "pr", "pr+notes")
DAYS = ("mon", "tue", "wed", "thu", "fri", "sat", "sun")
KEYS = {"name", "template", "prompt", "schedule", "zone", "repos", "branch", "channel", "mode", "max_usd",
        "skip_no_commits", "env"}
MOST = 8
PROMPT_BYTES = 4096


def ceiling():
    try:
        return float(os.environ.get("FXA_LLM_RUN_CAP_USD") or 50)
    except ValueError:
        return 50.0


def pairs(v):
    """Like the bot's profile.js pairs(): comma-separated k:v, empty parts dropped."""
    out = {}
    for part in (v or "").split(","):
        kv = part.strip().split(":")
        if len(kv) == 2 and kv[0] and kv[1]:
            out[kv[0]] = kv[1]
    return out


def bot_access(path):
    """PROFILE_* from the bot's .env: {key: raw value}, or None when it cannot be read (as the dashboard's
    read_access(): the channel rules then are unknown, so a save fails closed)."""
    out = {}
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                m = re.match(r"^PROFILE_(USERS|OPEN|CHANNELS|JIRA)=(.*)$", line.rstrip("\n"))
                if m:
                    out[m.group(1)] = m.group(2).strip().strip("'\"")
    except (OSError, UnicodeDecodeError):
        return None
    return out


def channels(team, index, env):
    """(the team's own bound channels, {channel: other team}) from the records and PROFILE_CHANNELS."""
    own, other = set(), {}
    for t, rec in (index.get("teams") or {}).items():
        for c in (rec.get("access") or {}).get("channels") or []:
            (own.add(c) if t == team else other.setdefault(c, t))
    for c, t in pairs(env.get("CHANNELS")).items():
        (own.add(c) if t == team else other.setdefault(c, t))
    return own, other


def kind(team, index, env):
    """record, env (an access entry in the bot .env) or folder."""
    if team in (index.get("teams") or {}):
        return "record"
    if team in {x.strip() for x in env.get("OPEN", "").split(",")} or team in pairs(env.get("USERS")) \
            or team in pairs(env.get("CHANNELS")).values() or team in pairs(env.get("JIRA")).values():
        return "env"
    return "folder"


def check(r, team, profile, index, env, count):
    """([field: reason lines], the normalized routine)."""
    if not isinstance(r, dict):
        return ["routine: must be a JSON object"], r
    bad = [f"{k}: is not a routine field" for k in sorted(set(r) - KEYS)]
    r = dict(r)
    name = r.get("name")
    if not isinstance(name, str) or not NAME.fullmatch(name):
        bad.append("name: Use letters, digits, spaces and . _ ( ) - in the name, at most 40 characters")
    tpl = r.get("template", "blank")
    if tpl not in TEMPLATES:
        bad.append(f"template: must be one of {', '.join(TEMPLATES)}")
    prompt = r.get("prompt")
    if not isinstance(prompt, str) or not prompt.strip():
        bad.append("prompt: The prompt is empty")
    elif len(prompt.encode()) > PROMPT_BYTES:
        bad.append("prompt: The prompt is over 4 KB")
    sched = r.get("schedule")
    if not isinstance(sched, str) or not SCHEDULE.fullmatch(sched):
        bad.append("schedule: Use daily HH:MM, weekdays HH:MM or weekly <mon..sun> HH:MM")
    zone = r.get("zone")
    try:
        if not isinstance(zone, str) or not ZONE.fullmatch(zone):
            raise ValueError
        zoneinfo.ZoneInfo(zone)
    except (ValueError, zoneinfo.ZoneInfoNotFoundError):
        bad.append(f"zone: {zone!r} is not a time zone, such as America/New_York")

    known = {x.get("slug", "").lower(): x for x in profile.get("repos") or []}
    repos = r.get("repos")
    if not isinstance(repos, list) or not repos or not all(isinstance(x, str) for x in repos):
        bad.append("repos: Pick at least one of this team's repos")
        repos = []
    for s in repos:
        if s.lower() not in known:
            bad.append(f"repos: Repo {s} is not one of this team's repos")
    if "branch" in r:
        if not isinstance(r["branch"], str) or not BRANCH.fullmatch(r["branch"]) or ".." in r["branch"]:
            bad.append("branch: Use letters, digits and . _ / - in the branch, at most 60 characters")
        elif len(repos) != 1:
            bad.append("branch: A branch needs exactly one repo")

    mode = r.get("mode")
    if mode not in MODES:
        bad.append("mode: must be report, pr or pr+notes")
    elif mode != "report":
        if tpl == "security-review":
            bad.append("mode: A security review only reports; it never opens a PR")
        elif profile.get("read_only"):
            bad.append("mode: Draft PR is not possible: this team gets diffs only, so a routine can only report")
        elif len(repos) != 1 or known.get(repos[0].lower(), {}).get("role") != "work":
            bad.append("mode: A draft PR mode needs exactly one work repo")

    ch = r.get("channel")
    m = LINK.fullmatch(ch) if isinstance(ch, str) else None
    if m:
        ch = r["channel"] = m.group(1)
    if not isinstance(ch, str) or not CHANNEL.fullmatch(ch):
        bad.append("channel: Use a Slack channel ID (C0123ABCD) or a link to the channel")
    else:
        own, other = channels(team, index, env)
        if ch in other:
            bad.append(f"channel: Channel {ch} belongs to team {other[ch]}")
        elif profile.get("private") and ch not in own:
            bad.append("channel: A team with a private repo posts only to one of this team's channels")
        elif tpl == "security-review" and kind(team, index, env) != "folder" and ch not in own:
            bad.append("channel: A security review posts only to one of this team's channels")

    cap, most = r.get("max_usd", 10), ceiling()
    if isinstance(cap, bool) or not isinstance(cap, (int, float)) or not 0 < cap <= most:
        bad.append(f"max_usd: The cost limit must be more than 0 and at most {most:g} USD")
    else:
        r["max_usd"] = cap
    if not isinstance(r.get("skip_no_commits", True), bool):
        bad.append("skip_no_commits: must be true or false")
    if r.get("env", "live") not in ("live", "dev"):
        bad.append("env: must be live or dev")
    if count >= MOST:
        bad.append(f"routine: A team has at most {MOST} routines")
    r.setdefault("template", "blank")
    r.setdefault("skip_no_commits", True)
    r.setdefault("env", "live")
    r.setdefault("max_usd", 10)
    return bad, r


def runs(r, start, n):
    """The next n run times after start (epoch), as aware datetimes in the routine's zone."""
    m = SCHEDULE.fullmatch(r["schedule"])
    tz = zoneinfo.ZoneInfo(r["zone"])
    hh, mm = int(m.group(3)), int(m.group(4))
    day = datetime.datetime.fromtimestamp(start, tz).date()
    out = []
    for _ in range(400):
        wd = day.weekday()
        if m.group(1) == "daily" or (m.group(1) == "weekdays" and wd < 5) or m.group(2) == DAYS[wd]:
            at = datetime.datetime(day.year, day.month, day.day, hh, mm, tzinfo=tz)
            # A time a DST change skips does not exist: zoneinfo reads it with the earlier offset,
            # and the round trip gives the wall clock it lands on, once.
            at = datetime.datetime.fromtimestamp(at.timestamp(), tz)
            if at.timestamp() > start:
                out.append(at)
                if len(out) == n:
                    break
        day += datetime.timedelta(days=1)
    return out


def templates(folder):
    """Each templates/routines/<name>.md: its header (name, mode, skip_no_commits, locked_mode) and prompt."""
    out = []
    for f in sorted(os.listdir(folder)) if os.path.isdir(folder) else []:
        if not f.endswith(".md") or f[:-3] not in TEMPLATES:
            continue
        with open(os.path.join(folder, f), encoding="utf-8") as fh:
            _, head, prompt = fh.read().split("---\n", 2)
        t = {"template": f[:-3], "prompt": prompt.strip()}
        for line in head.splitlines():
            k, _, v = line.partition(": ")
            t[k] = v == "true" if k == "skip_no_commits" else v
        out.append(t)
    return out


def opt(argv, flag, default=None):
    return argv[argv.index(flag) + 1] if flag in argv and argv.index(flag) + 1 < len(argv) else default


def load(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError) as e:
        sys.exit(f"{path}: cannot read: {e}")


def main(argv):
    if len(argv) >= 2 and argv[1] == "templates":
        here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        print(json.dumps(templates(argv[2] if len(argv) > 2 else os.path.join(here, "templates", "routines"))))
        return 0
    if len(argv) < 3 or argv[1] not in ("validate", "next", "period"):
        sys.exit(__doc__)
    cmd, r = argv[1], load(argv[2])
    if cmd == "validate":
        if len(argv) < 4 or not opt(argv, "--profile"):
            sys.exit(__doc__)
        index = load(opt(argv, "--index")) if opt(argv, "--index") and os.path.exists(opt(argv, "--index")) else {}
        try:
            count = int(opt(argv, "--count", "0"))
        except ValueError:
            count = MOST  # fail closed
        env = bot_access(opt(argv, "--bot-env", ""))
        if env is None:
            print("channel: cannot read the bot access rules", file=sys.stderr)
            return 1
        bad, out = check(r, argv[3], load(opt(argv, "--profile")), index, env, count)
        if bad:
            print("\n".join(bad), file=sys.stderr)
            return 1
        print(json.dumps(out, sort_keys=True))
    elif cmd == "next":
        start = float(opt(argv, "--from") or datetime.datetime.now().timestamp())
        for at in runs(r, start, int(opt(argv, "--n", "3"))):
            print(at.isoformat())
    else:
        print(datetime.datetime.fromtimestamp(float(argv[3]), zoneinfo.ZoneInfo(r["zone"])).date().isoformat())
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
