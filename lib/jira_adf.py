#!/usr/bin/env python3
"""A pipeline comment's text as Jira ADF: jira_adf.py < text > adf.json.

The text is a small Markdown subset, so a comment reads well in Jira and in a log:
  ::success|info|note|warning|error   first line only: the comment sits in a panel of that color
  - item                             a bullet
  **bold**, `code`, [text](url)      inline; a bare https:// URL becomes a link
Every other line is its own paragraph; blank lines are dropped.
--mark puts 🤖 in front, for a comment posted under a person's login.
Run with --test for the self-check."""
import json
import re
import sys

PANELS = ("success", "info", "note", "warning", "error")
INLINE = re.compile(r"\*\*(.+?)\*\*|`([^`]+)`|\[([^\]]+)\]\((https?://[^)\s]+)\)|(https?://[^\s)]+[^\s).,;:!?])")


def inline(s):
    out, at = [], 0
    for m in INLINE.finditer(s):
        if m.start() > at:
            out.append({"type": "text", "text": s[at:m.start()]})
        bold, code, label, url, bare = m.groups()
        if bold:
            out.append({"type": "text", "text": bold, "marks": [{"type": "strong"}]})
        elif code:
            out.append({"type": "text", "text": code, "marks": [{"type": "code"}]})
        else:
            href = url or bare
            out.append({"type": "text", "text": label or bare, "marks": [{"type": "link", "attrs": {"href": href}}]})
        at = m.end()
    if at < len(s):
        out.append({"type": "text", "text": s[at:]})
    return out


def adf(text, mark=False):
    lines = [l.rstrip() for l in text.strip("\n").split("\n")]
    panel = lines[0][2:] if lines and lines[0].startswith("::") and lines[0][2:] in PANELS else None
    if mark and len(lines) > (1 if panel else 0):
        lines[1 if panel else 0] = "🤖 " + lines[1 if panel else 0]
    blocks, bullets = [], None
    for line in lines[1 if panel else 0:]:
        if not line.strip():
            bullets = None
            continue
        if line.startswith("- "):
            if bullets is None:
                bullets = {"type": "bulletList", "content": []}
                blocks.append(bullets)
            bullets["content"].append({"type": "listItem", "content": [{"type": "paragraph", "content": inline(line[2:])}]})
        else:
            bullets = None
            blocks.append({"type": "paragraph", "content": inline(line)})
    if panel:
        blocks = [{"type": "panel", "attrs": {"panelType": panel}, "content": blocks}]
    return {"type": "doc", "version": 1, "content": blocks}


def test():
    d = adf("::success\n**Merged** · [PR #7](https://github.com/o/r/pull/7)\n- Cost: `$1.79`\n- see https://x.test/a.\n\nNext line")
    p = d["content"][0]
    assert p["type"] == "panel" and p["attrs"]["panelType"] == "success"
    head, bullets, last = p["content"]
    assert head["content"][0] == {"type": "text", "text": "Merged", "marks": [{"type": "strong"}]}
    assert head["content"][2]["marks"][0]["attrs"]["href"] == "https://github.com/o/r/pull/7" and head["content"][2]["text"] == "PR #7"
    assert [i["content"][0]["content"][-1].get("text") for i in bullets["content"]] == ["$1.79", "."]
    assert bullets["content"][1]["content"][0]["content"][1]["marks"][0]["attrs"]["href"] == "https://x.test/a"
    assert last["content"] == [{"type": "text", "text": "Next line"}]
    plain = adf("::unknown\nhello")
    assert plain["content"][0]["type"] == "paragraph" and plain["content"][0]["content"][0]["text"] == "::unknown"
    assert adf("::info\n**Ready**", mark=True)["content"][0]["content"][0]["content"][0]["text"] == "🤖 "
    print("jira_adf: ok")


if __name__ == "__main__":
    test() if sys.argv[1:] == ["--test"] else json.dump(adf(sys.stdin.read(), "--mark" in sys.argv), sys.stdout, ensure_ascii=False)
