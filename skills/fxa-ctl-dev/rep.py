#!/usr/bin/env python3
"""Replace exact text: rep.py <file> < pairs.json, where pairs.json is [["old", "new"], ...],
or rep.py < triples.json, where triples.json is [["file", "old", "new"], ...] for several files,
or rep.py --blocks < edits.txt, for code with quotes and backslashes, with no JSON to escape:

    <<<< path/to/file
    old lines
    ====
    new lines
    >>>>

Each old text must occur exactly once. On any miss, nothing is written to any file."""
import json
import sys


def blocks(text):
    edits, cur = [], None
    for line in text.split('\n'):
        if cur is None and line.startswith('<<<< '):
            cur = [line[5:].strip(), [], [], 1]
        elif cur is not None and line == '====' and cur[3] == 1:
            cur[3] = 2
        elif cur is not None and line == '>>>>' and cur[3] == 2:
            edits.append([cur[0], '\n'.join(cur[1]), '\n'.join(cur[2])])
            cur = None
        elif cur is not None:
            cur[cur[3]].append(line)
    if cur is not None:
        sys.exit(f"rep.py: {cur[0]}: a block has no closing '>>>>'; nothing written")
    return edits


if sys.argv[1:] == ['--blocks']:
    edits = blocks(sys.stdin.read())
else:
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
