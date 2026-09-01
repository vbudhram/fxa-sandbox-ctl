#!/usr/bin/env python3
"""Transform AI_FIXME_PIPELINE.md into Slack Canvas flavored markdown.

    python3 build-canvas-md.py

Canvas markdown is close to GitHub markdown, with three differences that matter
here:

1. Headings stop at `###`. The source uses `####` for the ten stages, so every
   heading shifts up one level and the H1 is dropped (the canvas title field
   carries it).
2. Mermaid does not render. Both diagrams are replaced with the ASCII versions
   below, in the order they appear in the source.
3. Code blocks may not sit inside a list item. The script checks for that rather
   than trusting it.

Tables, code blocks, bold, and inline code all survive unchanged.
"""

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent
SRC = ROOT / "AI_FIXME_PIPELINE.md"
OUT = ROOT / "AI_FIXME_PIPELINE.canvas.md"

# Replacements for the fenced mermaid blocks, in source order.
LIFECYCLE_ASCII = r"""  [Stage 0]  reporter adds the label  ai-fixme
      |
      v
  [Stage 1]  QUEUED  <-------------------------------------+
      |                                                    |
      v                                                    |
  [Stage 2]  admission + grounding                         |
      |                                                    |
      +-- underspecified / blocked --> record fingerprint --+
      |                                comment once, then silent
      |
      +-- code already satisfies it --> EXIT: recommend closing
      |
      v  admit
  [ a claimable slot?  ctl freeslots ]
      |
      +-- none free ----------------------------------> back to QUEUED
      |
      v  claim one
  [Stage 3]  label inflight, launch on slot  <-------------+
      |                                                    |
      v                                                    |
  [Stage 4]  worktree prep, branch, context, render goal   |
      |                                                    |
      +-- goal over 4100 chars --> EXIT: blocked           |
      |                                                    |
      v                                                    |
  [Stage 5]  VM boot + hardening                           |
      |                                                    |
      v                                                    |
  [Stage 6]  agent run, 30 turns, writes handoff JSON      |
      |                                                    |
      +-- VM dead --> relaunched once? -- no --------------+
      |                     |                              |
      |                     +-- yes --> EXIT: blocked      |
      v  handoff file, valid JSON + real work              |
  [Stage 7]  host: stage, squash, sign, push               |
             gh pr create, reviewers, approve gate         |
      |                                                    |
      v                                                    |
  [ check-in reclaims the VM: usage -> record -> stop ]    |
      |                                                    |
      v                                                    |
  [Stage 8]  CI settled?                                   |
      |                                                    |
      +-- flake, under 2 reruns per SHA --> rerun, loop    |
      |                                                    |
      +-- real failure, under 2 attempts -----------------+
      |                                                    |
      +-- cap reached --> EXIT: blocked                    |
      |                                                    |
      v  all green                                         |
  [Stage 9]  ai-fixme-done: PR open + green, slot free     |
      |                                                    |
      +-- verified review feedback, under 2 rounds -------+
      |                                                    |
      +-- 2 rounds spent --> EXIT: blocked                 |
      |
      v  no unhandled comments
  [Stage 10]  drain
      |
      +-- still open and green --> back to Stage 9
      +-- MERGED ---------------> EXIT: ai-fixme-merged    (terminal)
      +-- CLOSED unmerged ------> EXIT: ai-fixme-rejected  (terminal)"""

STATE_ASCII = r"""  ai-fixme                        queued, owns no slot
     |
     |  \__ admission skip: stays ai-fixme, label untouched
     |
     |  pass claims a slot and launches
     v
  ai-fixme-inflight               *** OWNS A POOL SLOT ***
     |
     |  \__ relaunch after a real CI failure: stays inflight
     |  \__ orphaned label, progress reports nolog: back to ai-fixme
     |  \__ attempt or relaunch cap reached: -> ai-fixme-blocked
     |
     |  PR open and green
     v
  ai-fixme-done                   review queue, slot released
     |
     |  \__ verified review feedback, max 2 rounds: -> ai-fixme-inflight
     |  \__ feedback cap reached: -> ai-fixme-blocked
     |
     |  drain
     +--> ai-fixme-merged         terminal archive
     +--> ai-fixme-rejected       terminal archive

  ai-fixme-blocked --> ai-fixme   only a human relabels"""

DIAGRAMS = [LIFECYCLE_ASCII, STATE_ASCII]

# Prose that only makes sense next to the Mermaid render: the colour legend, and
# the loop bullets that name Mermaid node IDs. Each pair must match exactly once,
# or the build fails rather than shipping stale text.
REWRITES = [
    (
        """Colour by actor: blue is the **pass**, green is the **orchestrator**
(`fxa-sandbox-ctl`), brown is the **agent VM**, purple is a **human**, grey is
**waiting**, red is a **terminal state**.

Three loops matter more than the straight line through the middle:

- `SKIP → S1` is the queue's parking loop. A skipped ticket stays visible and re-enters only
  when its text changes.
- `S8 → S3` and `FB → S3` both re-enter the launch stage on the **same slot**. That is why a
  ticket owns its worktree until its label leaves `inflight`.
- `S10 → S9` is the drain finding nothing to do, which is the common case.""",
        """Three loops matter more than the straight line through the middle:

- The skip loop parks a ticket back in the queue. A skipped ticket stays visible, and it
  re-enters only when its text changes.
- Stage 8 and stage 9 both re-enter stage 3 on the **same slot**. That is why a ticket owns
  its worktree until its label leaves `inflight`.
- Stage 10 finding the PR still open and green is a no-op, which is the common case.""",
    ),
]

MERMAID = re.compile(r"^```mermaid[ \t]*\r?\n.*?^```[ \t]*$", re.M | re.S)


def apply_rewrites(md: str) -> str:
    for old, new in REWRITES:
        if md.count(old) != 1:
            raise SystemExit(
                f"ERROR: rewrite matched {md.count(old)} times, expected 1. "
                "The source changed; update REWRITES."
            )
        md = md.replace(old, new)
    return md


def swap_diagrams(md: str) -> str:
    calls = {"n": 0}

    def sub(_match: "re.Match[str]") -> str:
        i = calls["n"]
        calls["n"] += 1
        if i >= len(DIAGRAMS):
            raise SystemExit(f"ERROR: found mermaid block {i + 1}, only {len(DIAGRAMS)} ASCII replacements exist.")
        return "```\n" + DIAGRAMS[i] + "\n```"

    out = MERMAID.sub(sub, md)
    if calls["n"] != len(DIAGRAMS):
        raise SystemExit(f"ERROR: replaced {calls['n']} diagrams but hold {len(DIAGRAMS)}. The source changed.")
    return out


def shift_headings(md: str) -> str:
    """Drop the H1 and move ## -> #, ### -> ##, #### -> ###."""
    lines = []
    in_fence = False
    for line in md.split("\n"):
        if line.startswith("```"):
            in_fence = not in_fence
            lines.append(line)
            continue
        if in_fence:
            lines.append(line)
            continue
        m = re.match(r"^(#{1,6}) (.*)$", line)
        if m:
            level, text = len(m.group(1)), m.group(2)
            if level == 1:
                continue  # the canvas title field carries this
            lines.append("#" * (level - 1) + " " + text)
            continue
        lines.append(line)
    return "\n".join(lines)


def check(md: str) -> list:
    """Report canvas rules the output would break."""
    problems = []
    in_fence = False
    for n, line in enumerate(md.split("\n"), 1):
        if line.lstrip().startswith("```"):
            # An indented fence means the block sits inside a list item.
            if not in_fence and line.startswith((" ", "\t")):
                problems.append(f"line {n}: indented code fence, canvas forbids code blocks in list items")
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        if re.match(r"^#{4,6} ", line):
            problems.append(f"line {n}: heading deeper than ###")
    if in_fence:
        problems.append("unclosed code fence")
    return problems


def main() -> int:
    if not SRC.exists():
        print(f"ERROR: {SRC} not found.", file=sys.stderr)
        return 1

    raw = SRC.read_text(encoding="utf-8")
    md = shift_headings(swap_diagrams(apply_rewrites(raw))).strip() + "\n"

    problems = check(md)
    if problems:
        print("Canvas rule violations:", file=sys.stderr)
        for p in problems:
            print(f"  {p}", file=sys.stderr)
        return 1

    OUT.write_text(md, encoding="utf-8")
    print(f"Wrote {OUT.name} ({len(md) / 1024:.1f} KB, {md.count(chr(10)) + 1} lines). No canvas rule violations.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
