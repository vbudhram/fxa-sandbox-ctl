#!/usr/bin/env python3
"""Wrap AI_FIXME_PIPELINE.md into a standalone HTML doc.

The markdown stays the single source of truth. Re-run this after any edit:

    python3 build-pipeline-html.py

The output renders markdown with marked and diagrams with mermaid, both from a
CDN, so the page needs network access on first load.
"""

import html
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent
SRC = ROOT / "AI_FIXME_PIPELINE.md"
OUT = ROOT / "AI_FIXME_PIPELINE.html"

TEMPLATE = r"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>ai-fixme, the autonomous ticket-to-PR pipeline</title>
<style>
  :root {
    --bg: #0f1419;
    --bg-alt: #161b22;
    --bg-code: #1c2128;
    --fg: #d7dde5;
    --fg-dim: #8b949e;
    --fg-bright: #f0f6fc;
    --accent: #58a6ff;
    --border: #2a3038;
    --warn: #d29922;
    --sidebar: 300px;
  }
  @media (prefers-color-scheme: light) {
    :root {
      --bg: #ffffff; --bg-alt: #f6f8fa; --bg-code: #f6f8fa;
      --fg: #1f2328; --fg-dim: #59636e; --fg-bright: #000;
      --accent: #0969da; --border: #d1d9e0; --warn: #9a6700;
    }
  }
  * { box-sizing: border-box; }
  html { scroll-behavior: smooth; scroll-padding-top: 1.5rem; }
  body {
    margin: 0; background: var(--bg); color: var(--fg);
    font: 16px/1.65 -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif;
    -webkit-font-smoothing: antialiased;
  }
  #layout { display: flex; align-items: flex-start; }

  /* ---- sidebar ---- */
  #toc {
    position: sticky; top: 0; flex: 0 0 var(--sidebar); width: var(--sidebar);
    height: 100vh; overflow-y: auto; padding: 1.75rem 1rem 3rem 1.5rem;
    border-right: 1px solid var(--border); background: var(--bg-alt);
  }
  #toc h2 {
    font-size: .7rem; text-transform: uppercase; letter-spacing: .09em;
    color: var(--fg-dim); margin: 0 0 .85rem; font-weight: 600;
  }
  #toc a {
    display: block; padding: .2rem 0 .2rem .6rem; color: var(--fg-dim);
    text-decoration: none; font-size: .82rem; line-height: 1.4;
    border-left: 2px solid transparent;
  }
  #toc a:hover { color: var(--accent); }
  #toc a.lvl3 { padding-left: 1.5rem; font-size: .78rem; }
  #toc a.lvl4 { padding-left: 2.3rem; font-size: .75rem; color: #6e7681; }
  #toc a.active { color: var(--accent); border-left-color: var(--accent); background: rgba(88,166,255,.07); }

  /* ---- content ---- */
  main { flex: 1 1 auto; min-width: 0; padding: 2.5rem 3rem 6rem; max-width: 62rem; }
  h1, h2, h3, h4 { color: var(--fg-bright); line-height: 1.25; font-weight: 600; }
  h1 { font-size: 2rem; margin: 0 0 1rem; }
  h2 { font-size: 1.45rem; margin: 3rem 0 1rem; padding-bottom: .4rem; border-bottom: 1px solid var(--border); }
  h3 { font-size: 1.15rem; margin: 2.2rem 0 .8rem; }
  h4 { font-size: 1rem; margin: 1.8rem 0 .6rem; color: var(--accent); }
  h2 .anchor, h3 .anchor, h4 .anchor {
    opacity: 0; margin-left: .4rem; color: var(--fg-dim);
    text-decoration: none; font-weight: 400;
  }
  h2:hover .anchor, h3:hover .anchor, h4:hover .anchor { opacity: 1; }
  p, li { max-width: 46rem; }
  a { color: var(--accent); }
  hr { border: 0; border-top: 1px solid var(--border); margin: 2.5rem 0; }
  strong { color: var(--fg-bright); font-weight: 600; }
  blockquote {
    margin: 1rem 0; padding: .1rem 1rem; border-left: 3px solid var(--warn);
    color: var(--fg-dim);
  }

  code {
    font-family: ui-monospace, SFMono-Regular, "SF Mono", Menlo, monospace;
    font-size: .855em; background: var(--bg-code); padding: .14em .38em;
    border-radius: 4px; border: 1px solid var(--border);
  }
  pre {
    background: var(--bg-code); border: 1px solid var(--border); border-radius: 8px;
    padding: 1rem 1.1rem; overflow-x: auto; line-height: 1.5; font-size: .84rem;
  }
  pre code { background: none; border: 0; padding: 0; font-size: inherit; }

  table {
    border-collapse: collapse; margin: 1.2rem 0; font-size: .875rem;
    display: block; overflow-x: auto; max-width: 100%;
  }
  th, td { border: 1px solid var(--border); padding: .5rem .75rem; text-align: left; vertical-align: top; }
  th { background: var(--bg-alt); color: var(--fg-bright); font-weight: 600; white-space: nowrap; }
  tbody tr:nth-child(even) { background: rgba(127,127,127,.045); }

  .mermaid {
    background: var(--bg-alt); border: 1px solid var(--border); border-radius: 8px;
    padding: 1.25rem; margin: 1.5rem 0; text-align: center; overflow-x: auto;
  }
  .mermaid svg { max-width: 100%; height: auto; }

  #meta {
    color: var(--fg-dim); font-size: .82rem; margin: -.4rem 0 2rem;
    padding-bottom: 1.2rem; border-bottom: 1px solid var(--border);
  }

  @media (max-width: 950px) {
    #toc { display: none; }
    main { padding: 1.5rem 1.25rem 4rem; }
  }
  @media print {
    #toc { display: none; }
    body { background: #fff; color: #000; }
    main { max-width: none; padding: 0; }
    pre, table, .mermaid { break-inside: avoid; }
    h2 { break-before: page; }
  }
</style>
</head>
<body>
<div id="layout">
  <nav id="toc"><h2>Contents</h2><div id="toc-links"></div></nav>
  <main>
    <article id="content"></article>
  </main>
</div>

<script id="source" type="text/markdown">__MARKDOWN__</script>

<script type="module">
import { marked } from "https://cdn.jsdelivr.net/npm/marked@12/lib/marked.esm.js";
import mermaid from "https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.esm.min.mjs";

const src = document.getElementById("source").textContent;
const esc = (s) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

// Lift fenced mermaid blocks out BEFORE markdown parsing, then put them back as
// <pre class="mermaid">. Doing this with a custom renderer would tie the file to
// one marked major version, because the renderer.code signature changed in v15.
const diagrams = [];
const stripped = src.replace(/^```mermaid[ \t]*\r?\n([\s\S]*?)^```[ \t]*$/gm, (_m, body) => {
  diagrams.push(body);
  return "\n@@MERMAID" + (diagrams.length - 1) + "@@\n";
});

marked.setOptions({ gfm: true, breaks: false });
document.getElementById("content").innerHTML = marked
  .parse(stripped)
  .replace(/<p>@@MERMAID(\d+)@@<\/p>/g,
           (_m, i) => '<pre class="mermaid">' + esc(diagrams[+i]) + "</pre>");

// Heading anchors + table of contents.
const slug = (t) => t.toLowerCase().replace(/[^\w\s-]/g, "").trim().replace(/\s+/g, "-");
const links = document.getElementById("toc-links");
const seen = new Set();
document.querySelectorAll("#content h2, #content h3, #content h4").forEach((h) => {
  let id = slug(h.textContent);
  while (seen.has(id)) id += "-x";
  seen.add(id);
  h.id = id;
  h.insertAdjacentHTML("beforeend", ' <a class="anchor" href="#' + id + '">#</a>');
  const a = document.createElement("a");
  a.href = "#" + id;
  a.textContent = h.textContent.replace(/\s*#$/, "");
  a.className = "lvl" + h.tagName[1];
  links.appendChild(a);
});

// Highlight the heading nearest the top of the viewport.
const anchors = [...links.querySelectorAll("a")];
const heads = anchors.map((a) => document.getElementById(a.hash.slice(1)));
const sync = () => {
  let i = 0;
  heads.forEach((h, n) => { if (h.getBoundingClientRect().top < 120) i = n; });
  anchors.forEach((a, n) => a.classList.toggle("active", n === i));
};
document.addEventListener("scroll", sync, { passive: true });
sync();

const dark = matchMedia("(prefers-color-scheme: dark)").matches;
mermaid.initialize({
  startOnLoad: false,
  theme: dark ? "dark" : "default",
  securityLevel: "loose",
  flowchart: { curve: "basis", nodeSpacing: 45, rankSpacing: 55, useMaxWidth: true },
  themeVariables: { fontSize: "13px" },
});
await mermaid.run({ querySelector: ".mermaid" });
</script>
</body>
</html>
"""


def main() -> int:
    if not SRC.exists():
        print(f"ERROR: {SRC} not found.", file=sys.stderr)
        return 1

    md = SRC.read_text(encoding="utf-8")
    # Only `</script` can terminate the host script element. Nothing else needs
    # escaping, and escaping more would corrupt the markdown.
    md = md.replace("</script", "<\\/script")

    OUT.write_text(TEMPLATE.replace("__MARKDOWN__", md), encoding="utf-8")
    kb = OUT.stat().st_size / 1024
    print(f"Wrote {OUT.name} ({kb:.1f} KB) from {SRC.name}.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
