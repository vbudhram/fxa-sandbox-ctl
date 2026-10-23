"""The entries of a team memory folder as JSON, for the dashboard's Memory tab.

stdin: each topic file as a line "\\x1e<scope>\\t<file>" followed by the file's text (memory_list in lib/memory.sh).
The scope is "team" or the repo (owner/repo) the folder is for; a repo fact's cite gets the repo in front.
stdout: {"on": true, "entries": [...]}, newest confirmed first.
"""
import hashlib
import json
import re
import sys


def blocks(scope, name, text):
    for part in re.split(r"(?m)^(?=## mem-)", text):
        lines = part.split("\n")
        if not re.fullmatch(r"## mem-[0-9a-f]{8}", lines[0]) or len(lines) < 3:
            continue
        meta = lines[1]
        if not (meta.startswith("<!-- ") and meta.endswith(" -->")):
            continue
        kv = {}
        for pair in meta[5:-4].split(" | "):
            k, _, v = pair.partition(": ")
            kv[k] = v
        why = next((x[5:] for x in lines[3:] if x.startswith("Why: ")), "")
        pre = "" if scope == "team" else scope + ":"
        cites = [{"cite": pre + kv[f"cite{n}"], "anchor": kv.get(f"anchor{n}", "")} for n in ("", "2", "3") if kv.get(f"cite{n}")]
        # The version leaves out the confirmed date: a run that confirms the entry does not make an open edit stale.
        v = hashlib.sha1(re.sub(r"\| confirmed: [^|]* ", "", part.rstrip("\n")).encode()).hexdigest()[:12]
        yield {"id": lines[0][3:], "scope": scope, "kind": kv.get("kind", ""), "file": name, "text": lines[2], "why": why,
               "path": kv.get("path", ""), "terms": kv.get("terms", ""), "cites": cites,
               "confirmed": kv.get("confirmed", ""), "source": kv.get("source", ""), "taint": kv.get("taint") == "1",
               "person": kv.get("person") == "1", "v": v}


def main():
    entries = []
    for chunk in sys.stdin.read().split("\x1e")[1:]:
        head, _, text = chunk.partition("\n")
        scope, _, name = head.rpartition("\t")
        entries.extend(blocks(scope or "team", name, text))
    entries.sort(key=lambda e: e["confirmed"], reverse=True)
    json.dump({"on": True, "entries": entries}, sys.stdout)


if __name__ == "__main__":
    main()
