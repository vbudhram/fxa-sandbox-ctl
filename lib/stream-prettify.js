#!/usr/bin/env node
// Pretty-print Claude Code's --output-format=stream-json --include-partial-messages.
// Reads JSONL events from stdin, writes formatted human-readable output to stdout.
//
// Output format:
//   - assistant text deltas: streamed inline as the model produces them
//   - tool calls: "→ ToolName({input})" with input streamed inside the parens
//   - tool results: "  ← <truncated single-line snippet>" on a new line
//   - errors: "  ✗ <error>" on a new line
//   - final summary: "=== done: <subtype> ($<cost>, <ms>ms) ===" on a new line

const readline = require('readline');

const rl = readline.createInterface({
  input: process.stdin,
  crlfDelay: Infinity,
});

// Track current content_block context to format correctly across deltas.
let inToolUse = false;

const out = (s) => process.stdout.write(s);

const truncateOneLine = (s, max = 200) => {
  return String(s).replace(/\s+/g, ' ').trim().slice(0, max);
};

const renderToolResult = (content) => {
  if (typeof content === 'string') return content;
  if (Array.isArray(content)) {
    return content.map((c) => c?.text ?? '').join(' ');
  }
  return JSON.stringify(content);
};

rl.on('line', (line) => {
  if (!line.trim()) return;

  let e;
  try {
    e = JSON.parse(line);
  } catch {
    return;
  }

  // Partial streaming events: text deltas, tool input JSON deltas, block boundaries.
  if (e.type === 'stream_event') {
    const ev = e.event;
    if (!ev) return;

    if (ev.type === 'content_block_start') {
      const cb = ev.content_block;
      if (cb?.type === 'tool_use') {
        inToolUse = true;
        out(`\n→ ${cb.name}(`);
      } else if (cb?.type === 'text') {
        inToolUse = false;
        out('\n');
      } else {
        inToolUse = false;
      }
    } else if (ev.type === 'content_block_delta') {
      const d = ev.delta;
      if (!d) return;
      if (d.type === 'text_delta' && d.text) {
        out(d.text);
      } else if (d.type === 'input_json_delta' && d.partial_json) {
        out(d.partial_json);
      }
    } else if (ev.type === 'content_block_stop') {
      if (inToolUse) out(')');
      inToolUse = false;
    }
    return;
  }

  // User messages carry tool_result content back to the model.
  if (e.type === 'user') {
    const content = e.message?.content ?? [];
    for (const c of content) {
      if (c.type === 'tool_result') {
        const txt = truncateOneLine(renderToolResult(c.content));
        if (c.is_error) {
          out(`\n  ✗ ${txt}\n`);
        } else {
          out(`\n  ← ${txt}\n`);
        }
      }
    }
    return;
  }

  // Final summary event from /goal completion or print mode end.
  if (e.type === 'result') {
    const cost = (e.total_cost_usd ?? 0).toFixed(4);
    const ms = e.duration_ms ?? 0;
    const status = e.subtype ?? 'unknown';
    out(`\n\n=== claude done: ${status} ($${cost}, ${ms}ms) ===\n`);
    return;
  }

  // System init: brief one-liner so user knows the session is alive.
  if (e.type === 'system' && e.subtype === 'init') {
    const session = (e.session_id || '').slice(0, 8);
    const model = e.model || '?';
    out(`[claude session ${session} • model: ${model}]\n`);
    return;
  }
});

rl.on('close', () => {
  // Ensure trailing newline so the next prompt isn't mid-line.
  out('\n');
});
