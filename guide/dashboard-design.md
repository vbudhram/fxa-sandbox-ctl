# Dashboard design

Read this before you change `dashboard/index.html`. The page is one file: the CSS, then JS that builds HTML. Each component is one class, and each value is a CSS custom property (a token).

## Rules

1. Write every colour, size, space and radius as a token (`var(--ink)`, `var(--t-sub)`, `var(--s3)`, `var(--r-md)`). Do not write a hex value. The per-team fox palettes are the one exception.
2. Use the status tones as pairs: `ok` on `okbg`, `warn` on `warnbg`, `bad` on `badbg`, `info` on `infobg`, `purpletxt` on `purplebg` for merged work. `info` means live, not neutral.
3. Put a word or a count next to each status colour.
4. Use `amber` only as a fill or a border, not for text. Use the `tty-*` tokens in the terminal.
5. Use only the type sizes `--t-tiny` (11px) to `--t-huge` (32px). Use `--t-kpi` for every KPI and spend number. Give each number that changes `tabular-nums`.
6. Space with `s1`, `s2`, `s3`, `s4` and `s6`. Space blocks with a sibling rule on a class (`* + .charts`), not an inline margin.
7. Style a reusable part by class, never by an element id.
8. Only a running item moves (`.dot.live`, `.tag.run.live`). Keep the `prefers-reduced-motion` rule that stops all motion.
9. Give each link, button and summary the 2px `link` focus outline.
10. Write the words in short, plain sentences in sentence case. Use no emoji. Show a Jira key or a PR number in the `key` class.

## Build a view

Use the helpers in the `// Components:` block, next to `const esc =`:

```js
tag("3 failing", "bad")                     // a pill: ok, warn, bad, info, merged, dim; { run, live, sq, href }
dot("info", true)                           // a status dot; true pulses it
meter(72, "warn", "72% of budget")          // a bar, 0 to 100
card(html`<h2>Spend</h2>${body}`, { sm: true }) // also { flat: true }
kvRow("Cost", "none", true)                 // label, value, missing
table(["Team", ["Runs", "num"]], rows, { figures: true }) // also { dense: true }
emptybox("No merged ticket yet.")
cls("tag", tone, { run: true })             // a class list
```

- Put every value through `` html`...` ``. It escapes each `${value}`.
- Use `raw()` only on HTML that a helper or `html` made. Never use `raw()` on text from a snapshot, Jira, GitHub or a runner.
- Give `put()` a string, for example `` String(html`...`) ``. `put()` compares with `===`, so an `html` object repaints on every poll.
- Use `card` in the main column, `card sm` for a small tile in a grid, and `card flat` for a card inside a card or a pane.
- Use `kvRow` for facts about one item. Use `table` for many items with the same columns.
- Use `table figures` when every column after the first is a number. Use `dense` in a narrow place.

## Verify a change

1. Run the offline checks of the helpers:

   ```bash
   bash lib/dashboard-html.check.sh
   bash lib/dashboard.check.sh
   bash skills/fxa-ctl-dev/page.check.sh
   ```

2. Take a screenshot of each view that you changed, in the light theme:

   ```bash
   bash skills/fxa-ctl-dev/page.sh '#overview' --shot /tmp/light.png
   ```

3. Take the same screenshot in the dark theme:

   ```bash
   bash skills/fxa-ctl-dev/page.sh '#overview' --probe 'document.documentElement.dataset.theme = "dark"' --shot /tmp/dark.png
   ```

4. Look at both screenshots. Make sure that the text is legible and that nothing overlaps.
5. Run `bash skills/fxa-ctl-dev/test.sh changed` before you push.
