#!/usr/bin/env bash
# How many of the agent's FxA PRs that change what a person sees carry a screenshot or a video.
#   bash skills/fxa-ctl-dev/pr-media.sh [since YYYY-MM-DD] [repo]   (default: 30 days ago, mozilla/fxa)
# Prints the counts by source (pipeline: a Jira branch; slack: agent-*), then each visible PR with none.
set -euo pipefail
since="${1:-$(python3 -c 'import datetime; print((datetime.date.today() - datetime.timedelta(days=30)).isoformat())')}"
repo="${2:-mozilla/fxa}"
gh pr list -R "$repo" --author app/fxa-agent --state all --limit 1000 --search "created:>=${since}" \
  --json number,title,createdAt,headRefName,body,files,comments | python3 -c '
import json, re, sys
from collections import Counter
ATT = re.compile(r"(user-attachments/assets/|!\[[^\]]*\]\([^)]+\)|<img\b|<video\b|https?://\S+\.(png|gif|jpe?g|webp|mp4|webm|mov)\b)", re.I)
VIS = re.compile(r"^(packages|apps|libs)/.*\.(tsx|jsx|css|scss|html|mustache|hbs|ftl|svg)$")
NOT = re.compile(r"(\.test\.|\.spec\.|\.stories\.|__tests__/|/tests?/|functional-tests/)")
c, gap = Counter(), []
for p in json.load(sys.stdin):
    vis = [f["path"] for f in p.get("files") or [] if VIS.search(f["path"]) and not NOT.search(f["path"])]
    if not vis: continue
    src = "slack" if p["headRefName"].startswith("agent-") else "pipeline"
    text = (p.get("body") or "") + "\n".join(x.get("body") or "" for x in p.get("comments") or [])
    has = bool(ATT.search(text)); c[src, has] += 1
    noted = "  [noted]" if "No screenshot or video is attached" in text else ""
    if not has: gap.append("  #%s %s %-8s %s  %s%s" % (p["number"], p["createdAt"][:10], src, vis[0], p["title"][:70], noted))
for s in ("pipeline", "slack"):
    t = c[s, True] + c[s, False]
    print(f"{s}: {c[s, True]} of {t} visible PRs have a screenshot or a video")
print("visible PRs with none:" if gap else "visible PRs with none: 0"); print("\n".join(gap))
'
