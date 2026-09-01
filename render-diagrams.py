#!/usr/bin/env python3
"""Render the Mermaid diagrams in AI_FIXME_PIPELINE.md to PNG.

    python3 render-diagrams.py [--theme dark|default] [--scale 2]

Writes diagrams/<n>-<name>.png. Uses headless Chrome, so it needs no npm
install, but it does need network access for the mermaid CDN.

Chrome screenshots the viewport, not the content, so this runs two passes:
the first renders the diagram and reports its natural size through the page
title, the second sets the window to exactly that size and captures it.
"""

import argparse
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent
SRC = ROOT / "AI_FIXME_PIPELINE.md"
OUTDIR = ROOT / "diagrams"

CHROME_CANDIDATES = [
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/Applications/Chromium.app/Contents/MacOS/Chromium",
    "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
]

# Name each diagram by the order it appears in the source.
NAMES = ["lifecycle", "state-machine"]

# Render direction override, by diagram index. The lifecycle is a ten stage
# chain, so top-down gives a 1:2.6 image that scrolls forever in a Slack canvas
# or a chat message. Left to right is wider and shorter for the same graph. The
# markdown and HTML keep the top-down version, which reads better on a page.
DIRECTIONS = {0: "LR"}

FLOW_HEADER = re.compile(r"^(\s*flowchart\s+)(TD|TB|LR|RL|BT)\b", re.M)

MERMAID = re.compile(r"^```mermaid[ \t]*\r?\n(.*?)^```[ \t]*$", re.M | re.S)

PAGE = """<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>pending</title>
<style>
  html, body { margin: 0; padding: 0; background: __BG__; }
  #wrap { display: inline-block; padding: 28px; background: __BG__; }
  #wrap svg { display: block; }
</style>
</head><body>
<div id="wrap"><pre class="mermaid">__DIAGRAM__</pre></div>
<script type="module">
import mermaid from "https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.esm.min.mjs";
mermaid.initialize({
  startOnLoad: false,
  theme: "__THEME__",
  securityLevel: "loose",
  // useMaxWidth false makes the SVG render at its natural size instead of
  // stretching to 100% of the container, which is what makes the measurement
  // below meaningful.
  flowchart: { curve: "basis", nodeSpacing: 45, rankSpacing: 55, useMaxWidth: false },
  state: { useMaxWidth: false },
  themeVariables: { fontSize: "15px" },
});
try {
  await mermaid.run({ querySelector: ".mermaid" });
  const r = document.getElementById("wrap").getBoundingClientRect();
  document.title = Math.ceil(r.width) + "x" + Math.ceil(r.height);
} catch (e) {
  document.title = "ERROR " + e.message;
}
</script>
</body></html>
"""


def find_chrome() -> str:
    for path in CHROME_CANDIDATES:
        if pathlib.Path(path).exists():
            return path
    found = shutil.which("chromium") or shutil.which("google-chrome")
    if found:
        return found
    raise SystemExit("ERROR: no Chrome, Chromium, or Edge found. Install one, or use mmdc.")


def run_chrome(chrome: str, extra: list, url: str) -> str:
    cmd = [
        chrome, "--headless", "--disable-gpu", "--no-sandbox",
        "--hide-scrollbars", "--virtual-time-budget=20000", *extra, url,
    ]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    return proc.stdout


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--theme", default="default", choices=["default", "dark", "neutral", "forest"])
    ap.add_argument("--scale", type=float, default=2.0, help="device pixel ratio, 2 for retina")
    ap.add_argument("--direction", default="auto", choices=["auto", "source", "TD", "LR"],
                    help="auto applies the DIRECTIONS table, source renders as written")
    args = ap.parse_args()

    if not SRC.exists():
        print(f"ERROR: {SRC} not found.", file=sys.stderr)
        return 1

    diagrams = MERMAID.findall(SRC.read_text(encoding="utf-8"))
    if not diagrams:
        print("ERROR: no mermaid blocks in the source.", file=sys.stderr)
        return 1

    chrome = find_chrome()
    OUTDIR.mkdir(exist_ok=True)
    bg = "#0f1419" if args.theme == "dark" else "#ffffff"

    with tempfile.TemporaryDirectory() as tmp:
        for i, body in enumerate(diagrams):
            name = NAMES[i] if i < len(NAMES) else f"diagram-{i + 1}"
            body = body.rstrip()

            if args.direction == "source":
                want = None
            elif args.direction == "auto":
                want = DIRECTIONS.get(i)
            else:
                want = args.direction
            if want:
                body, n = FLOW_HEADER.subn(lambda m: m.group(1) + want, body, count=1)
                if n:
                    # Suffix the filename so an overridden render never silently
                    # overwrites the one that matches the markdown.
                    name = f"{name}-{want.lower()}"
                    print(f"  {name}: rendering {want} instead of the source direction")
            page = (PAGE.replace("__DIAGRAM__", body)
                        .replace("__THEME__", args.theme)
                        .replace("__BG__", bg))
            html = pathlib.Path(tmp) / f"{i}.html"
            html.write_text(page, encoding="utf-8")
            url = html.as_uri()

            # Pass 1: measure.
            dom = run_chrome(chrome, ["--dump-dom"], url)
            m = re.search(r"<title>(\d+)x(\d+)</title>", dom)
            if not m:
                err = re.search(r"<title>(ERROR[^<]*)</title>", dom)
                print(f"ERROR: {name} did not render. {err.group(1) if err else 'no size reported'}",
                      file=sys.stderr)
                return 1
            w, h = int(m.group(1)), int(m.group(2))

            # Pass 2: capture at exactly that size.
            out = OUTDIR / f"{i + 1}-{name}.png"
            run_chrome(chrome, [
                f"--screenshot={out}",
                f"--window-size={w},{h}",
                f"--force-device-scale-factor={args.scale}",
            ], url)

            if not out.exists() or out.stat().st_size == 0:
                print(f"ERROR: {out.name} was not written.", file=sys.stderr)
                return 1
            print(f"  {out.relative_to(ROOT)}  {w}x{h} logical, "
                  f"{int(w * args.scale)}x{int(h * args.scale)} actual, "
                  f"{out.stat().st_size / 1024:.0f} KB")

    print(f"Rendered {len(diagrams)} diagram(s) with the {args.theme} theme.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
