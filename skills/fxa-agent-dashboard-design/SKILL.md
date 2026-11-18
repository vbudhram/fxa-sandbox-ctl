---
name: fxa-agent-dashboard-design
description: Use when you audit, critique, redesign or polish a view of the FxA Agent dashboard v2 (dashboard-v2/, served at /v2), for example the Overview, Sandboxes, Pipeline or Stats pages, or when the owner asks for a UX audit, a design review, a gauntlet loop on a page, or "make this page better to use".
---

# Dashboard design for FxA Agent users

The users are operators of FxA Agent. They open a view to answer one question in 5 seconds, then act. A view is good when that answer is first, true and legible at every width. Make the page better to navigate and use.

Read these first:
- `guide/dashboard-design.md`: the design rules, the shared parts and the checks.
- `dashboard-v2/src/styles/theme.css`: the v2 tokens. The components are in `dashboard-v2/src/ui` and `src/charts`.
- `skills/fxa-agent-product-owner/SKILL.md`: the owner's taste and delivery habits.
- `bar.md` (here): the 7-rule bar. Copy it to the scratchpad, and write the view's 5-second question at the top. Draft the question yourself, and ask the owner to confirm it in the first report.

Keep `deferred.md` in the scratchpad: one line for each owner decision and each finding you chose not to fix, with the reason. It is for one page. Start a new one for the next page.

The routes of a view and its fixtures are in its spec, `dashboard-v2/e2e/<view>.spec.ts`. The fixtures are `skills/fxa-ctl-dev/page-fixture-*.json`. A view can have several (Sandboxes has `sandboxes`, `sb-cards`, `sb-done` and `sb-panel`), so run one server for each, on its own port.

The fixtures hold demo data, which fits the layout by design. Make the worst realistic case of each one too: `python3 e2e/worst.py ../skills/fxa-ctl-dev/page-fixture-<name>.json > <scratchpad>/worst-<name>.json`. It sets long names and titles, long Jira keys, 7-figure money, 6-digit PR numbers, 54-day ages, 400-day-old times and 40 rows in each list. Serve it like any other fixture.

## The loop

1. **Render.** The server serves `dashboard-v2/dist`, so run `npm run build` first and after each fix. Then start the fixture server on a free port from 4180. Do not use 4174 or 4175: Playwright reuses a server on those ports, and the e2e tests then fail.
   ```bash
   cd dashboard-v2 && npm run build && python3 e2e/serve.py --fixture ../skills/fxa-ctl-dev/page-fixture-<name>.json --port 4180
   ```
   The fixture's feeds go stale after about 3 min, and the page then shows a stale notice. Restart the server before you judge the fresh state. Judge the stale state on purpose too.
2. **Probe.** At 1440x900, 1024x768, 768x1024 and 375x812 (`resize_window`), in light and dark (`colorScheme`), run `probe.js` in the browser's javascript tool. Open each pane or drawer of the view and probe it too. It lists `CUT` and `ellipsis` text, overlaps, sideways scroll, and each heading's top in reading order. Each `CUT` and overlap is a defect. An `ellipsis` passes only when the full text is in a `title` or the next view. Probe the worst-case fixture too: a fault that only long or large data shows is still a defect.
3. **Critique.** Start 2 independent critics in parallel, a UX critic and a visual design critic. Give each its own browser tab (`tabs_create`, then the `tabId` on every call), or they move each other's page. Give each critic only:
   - the URL and the routes,
   - `bar.md` with the 5-second question,
   - `deferred.md`, so that it does not raise those items again,
   - the request for a verdict, READY or NOT READY, with findings ranked by the bar rule, each with the width, the theme and the selector.

   Do not give a critic your own findings or your fixes.
4. **Fix.** Fix the findings that you can check. Give each fix a test or a probe that fails without it. Look for the same fault in the other views. Put each owner decision (a word, a metric's meaning, jargon) in `deferred.md`, and do not guess.
5. **Check.** Run `npm run typecheck && npm run lint && npx vitest run && npm run build`. Then run `npx playwright test`, and `bash skills/fxa-ctl-dev/test.sh changed`. Keep the e2e to the critical path: a new e2e test only for a new action that changes state. Commit `dashboard-v2/dist`.
6. **Repeat** from step 2 with new critics. Stop when both critics say READY, or when the owner says stop. If 2 rounds in a row raise only the same items, stop and report them. Then give the owner `deferred.md` as numbered options, with the recommended one first.
7. **Learn.** Before you stop, read back the owner's corrections in this session: a direct "no, do X", an edit the owner made to your code, a variant the owner chose, a value nudged more than once. Write each one as a rule for a class of parts, not for one card, with its reason. For example, "every number that can be 1 uses `plural()`", not "the runs tile says 1 run". Add the rule to `guide/dashboard-design.md`, or to the bar when it is a pass or fail test. Skip a correction that a fresh agent would follow anyway, and ask the owner when the reason is not clear.

## Design in Claude, then port

The owner can try token values or a layout in Claude before any code changes:
- The design system is a Design System artifact: https://claude.ai/artifact/2MUvrz1RqSsJH1KW5cmChn. Read it with the Artifact tool.
- A new layout is a Design artifact made from that design system. For a new view, make 2 or 3 mockups before you write code.

An artifact does not change the dashboard. The code is the source of truth, and only the code has the checks. When the owner says "port it":
1. Read the artifact, and list each token or layout change it makes against `dashboard-v2/src/styles/theme.css` and the view's CSS and TSX.
2. Make those changes in the code. Keep the light and dark values as pairs.
3. Run the checks of step 5 of the loop.
   - `src/styles/theme.test.ts` requires a dark value for each token. Keep the light and dark values as pairs.
4. Run the loop on the changed views.
5. Publish the design system artifact again from the code, so that the artifact and the code agree.

Do not use `/design-sync` for this. It is for the standalone claude.ai/design, which closes on December 14, 2026.

## Traps that cost a round

| Symptom | Cause | Fix |
|---|---|---|
| A media rule has no effect | A later rule with the same specificity wins | Add a parent class to the selector |
| The cards change order on a narrow screen | `display: contents` lifts the children into the grid | Set `order` on the lifted children |
| axe fails `label-content-name-mismatch` | An `aria-label` that does not contain the visible text (WCAG 2.5.3) | Remove the `aria-label`, or start it with the visible text |
| A `@container` rule does not style the box | A container query cannot style the container itself | Put the rule on a child |
| A row shows twice | Two lists join on the same item | Dedupe by key at the join, with a test |
| A KPI shows 0 or "$0" | A missing value with a default | Show "?" or "unknown", and say "loading" before the data arrives |
| A 7-figure value spills out of a KPI tile on a phone | The tile value is 28px in a two-column grid | `--t-kpi` drops to 22px under 640px in `theme.css`: use the token, not a fixed size |
| A hover background stays on after a tap on a phone | A `:hover` rule with no guard | Put each `:hover` rule in `@media (hover: hover)`. `theme.test.ts` fails on a bare one |
| A chart stays 640px wide and the page scrolls sideways, but only in the Browser pane | The pane is hidden, so the page runs in the background and `ResizeObserver` never fires | Ask the owner to show the pane, or measure in headless Playwright. Do not fix `useWidth` |


## Ship

Commit with a scoped message. Push only when the owner says "ship"; before that, ask which result the owner wants (local only, an ai-fixme ticket, or a PR). On "ship", follow `fxa-ctl-dev`: `ship.sh`. Ask "Promote now?", and on a yes run the promote in the background. After the promote, render the live views as `fxa-ctl-dev` shows.
