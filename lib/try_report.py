"""Summarize Claude Code transcripts after a trial run: the main agent's models and
tools, whether it read the guide or the request again, and each subagent's model,
tools and task. Used by `session try` (on the runner) and agent-try.sh (locally).
    python3 try_report.py [<projects dir, or one project's dir>]   (default ~/.claude/projects)
"""
import collections
import glob
import json
import os
import sys


def summarize(path):
    models, tools, first, rereads = collections.Counter(), collections.Counter(), "", 0
    for line in open(path, errors="replace"):
        try:
            o = json.loads(line)
        except ValueError:
            continue
        m = o.get("message") or {}
        if o.get("type") == "user" and not first and isinstance(m.get("content"), str):
            first = m["content"]
        if o.get("type") != "assistant":
            continue
        models[m.get("model")] += 1
        for c in m.get("content") or []:
            if isinstance(c, dict) and c.get("type") == "tool_use":
                i = c.get("input") or {}
                tools[f"Agent:{i.get('subagent_type')}" if c["name"] in ("Agent", "Task") else c["name"]] += 1
                if "vm-agent-guide" in json.dumps(i) or ".fxa-jira-context" in json.dumps(i):
                    rereads += 1
    return models, tools, first, rereads


def main(base):
    # base is the projects folder (a runner's) or one project's folder (agent-try.sh).
    subs = set(glob.glob(base + "/*/*/subagents/*.jsonl") + glob.glob(base + "/*/subagents/*.jsonl"))
    mains = set(glob.glob(base + "/*.jsonl") + glob.glob(base + "/*/*.jsonl")) - subs
    for f in sorted(mains, key=os.path.getmtime):
        models, tools, _, rereads = summarize(f)
        print(f"main: {dict(models)}; tools {dict(tools)}; reads of the guide or request: {rereads}")
    for f in sorted(subs, key=os.path.getmtime):
        models, tools, first, _ = summarize(f)
        print(f"subagent: {dict(models)}; tools {dict(tools)}; task: {' '.join(first.split())[:110]}")


if __name__ == "__main__":
    main(os.path.expanduser(sys.argv[1] if len(sys.argv) > 1 else "~/.claude/projects"))
