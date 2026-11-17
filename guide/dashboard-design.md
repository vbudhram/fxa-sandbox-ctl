# Dashboard design

Read this before you change the dashboard in `dashboard-v2/`, a Vite, React and TypeScript app. The tokens are CSS custom properties in `src/styles/theme.css`, and the shared parts are in `src/ui` and `src/charts`.

## Rules

1. Write every colour, size, space and radius as a token (`var(--ink)`, `var(--t-sub)`, `var(--s3)`, `var(--r-md)`). Do not write a hex value. The per-team fox palettes are the one exception.
2. Use the status tones as pairs: `ok` on `okbg`, `warn` on `warnbg`, `bad` on `badbg`, `info` on `infobg`, `purpletxt` on `purplebg` for merged work. `info` means live, not neutral.
3. Put a word or a count next to each status colour.
4. Use `amber` only as a fill or a border, not for text. Use the `tty-*` tokens in the terminal.
5. Use only the type sizes `--t-tiny` (11px) to `--t-huge` (32px). Use `--t-kpi` for every KPI and spend number. Give each number that changes `tabular-nums`.
6. Space with `s1`, `s2`, `s3`, `s4` and `s6`. Space blocks with a sibling rule on a class (`* + .charts`), not an inline margin.
7. Style a reusable part by class, never by an element id.
8. Use motion only to show a data change or a running item. A data change moves once, in 300 ms or less: a belt moves to its new stop, a number counts to its new value, a bar grows. A running item can loop (`live` dot, the terminal cursor). Do not move anything on the first paint, on hover, or on an update that changed nothing. Under `prefers-reduced-motion`, stop all motion: set `MotionConfig reducedMotion="user"` and keep the CSS rule that stops every animation and transition.
9. Give each link, button and summary the 2px `link` focus outline.
10. Write the words in short, plain sentences in sentence case. Use no emoji. Show a Jira key or a PR number in the `key` class.
11. Format with the helpers in `src/format`. Do not write a new one in a view.
    - `usd()` gives "$1,284.50", and from $10,000 it drops the cents, for example "$1,530,863".
    - `ago()` gives "5m ago", or the date after a week. `age()` gives the bare length, for example "Data is 2h old".
    - `short()` gives a duration, and from 48 hours it gives days.
    - `plural(n, 'run')` gives "1 run" or "2 runs". Use it for each count that can be 1.
12. Put each `:hover` rule in `@media (hover: hover)`, so that a tap on a phone does not leave it on. Give a button the same look on `:active`.
13. Cap a list of things that need a person, so that the rest of the view stays above the fold. The alerts strip shows 5, with the `bad` alerts first, and a "Show all N alerts" button.

## Build a view

Use the parts in `src/ui/parts.tsx`:

```tsx
<Tag tone="bad" label="3 failing" />          // a pill: ok, warn, bad, info, merged, dim; also run, live, sq, href
<Dot tone="info" label="running" live />       // a status dot; live pulses it
<Meter pct={72} tone="warn" label="72% of budget" />
<Card>...</Card>                               // also sm (a tile), flat (a card in a card), tone, href
<Kv label="Cost" value="none" na />
<StatTile label="Opened" value={6} sub="6 pipeline" />
<EmptyBox>No merged ticket yet.</EmptyBox>
```

- React escapes each value. Do not use `dangerouslySetInnerHTML` on text from a snapshot, Jira, GitHub or a runner.
- Use `Card` in the main column, `Card sm` for a tile in a grid, and `Card flat` for a card inside a card or a pane.
- Use `Kv` for facts about one item. Use a table for many items with the same columns.
- Use the shared heading and spacing rules: an `h2` is a section head (16/700), an `h3` is a card head (13/600), a card has `--card-pad` padding, and stacked cards are `--stack-gap` apart. The e2e test in `e2e/smoke.spec.ts` fails when a view drifts from them.

## Verify a change

1. Run the checks, in `dashboard-v2/`:

   ```bash
   npm run typecheck && npm run lint && npm test && npm run build && npx playwright test
   ```

2. Serve the build with a page fixture, and open it in a browser, in the light and the dark theme:

   ```bash
   python3 e2e/serve.py --fixture ../skills/fxa-ctl-dev/page-fixture-overview.json --port 4180
   ```

3. Make sure that the text is legible and that nothing overlaps, at 1440, 1024, 768 and 375 px.
4. Run `bash skills/fxa-ctl-dev/test.sh changed` before you push, and commit `dashboard-v2/dist`.

The files in `dashboard-v2/test/golden` are frozen results of the retired v1 dashboard. When a model change in `src/model` changes a result on purpose, update the file by hand.
