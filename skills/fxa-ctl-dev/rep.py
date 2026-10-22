#!/usr/bin/env python3
"""Replace exact text: rep.py <file> < pairs.json, where pairs.json is [["old", "new"], ...],
or rep.py < triples.json, where triples.json is [["file", "old", "new"], ...] for several files.
Each old text must occur exactly once. On any miss, nothing is written to any file."""
import json
import sys

edits = json.load(sys.stdin)
if len(sys.argv) > 1:
    edits = [[sys.argv[1], old, new] for old, new in edits]
texts = {}
for p, old, new in edits:
    s = texts[p] if p in texts else open(p).read()
    n = s.count(old)
    if n != 1:
        sys.exit(f"rep.py: {p}: {n} matches for {old[:70]!r}; nothing written")
    texts[p] = s.replace(old, new)
for p, s in texts.items():
    open(p, "w").write(s)
    print(f"rep.py: {p}: ok")
