#!/usr/bin/env python3
"""Replace exact text in one file: rep.py <file> < pairs.json, where pairs.json is [["old", "new"], ...].
Each old text must occur exactly once. On any miss, nothing is written."""
import json
import sys

p = sys.argv[1]
s = open(p).read()
for old, new in json.load(sys.stdin):
    n = s.count(old)
    if n != 1:
        sys.exit(f"rep.py: {p}: {n} matches for {old[:70]!r}; nothing written")
    s = s.replace(old, new)
open(p, "w").write(s)
print(f"rep.py: {p}: ok")
