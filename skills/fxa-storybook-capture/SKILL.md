---
name: fxa-storybook-capture
description: Use inside the FxA sandbox VM to screenshot the component states a ticket changed, using Storybook, and hand the files to the host for PR attachment. Trigger when the diff touches a component that has a sibling *.stories.tsx. Not for user flows across pages, which need the full stack.
---

# Capture component screenshots with Storybook

Storybook renders one component at a time from static args. It needs no database,
no Redis, no FxA services, and no credentials. That is why this skill exists: it
gives a reviewer visual evidence at a fraction of the cost of a functional-test run.

The host attaches whatever you list in `media_paths`. You never call `gh`.

## When to run, and when to stop

Run only when **both** are true:

1. The diff changes a component's rendered output: markup, style, copy, layout, or
   which element renders.
2. That component has a sibling `*.stories.tsx`.

Check it directly:

    git status --porcelain | awk '{print $2}' | grep '^packages/fxa-settings/src' 
    ls "$(dirname <changed-file>)"/*.stories.tsx

**Stop and produce nothing** when the change is logic without a visual result: a
hook, a lib module, a webchannel, a type, a test, or anything under
`packages/fxa-auth-server` or `libs/`. A screenshot of an unrelated component is
worse than no screenshot, because a reviewer reads it as evidence.

Say in one line that you skipped capture and why, and write that line to
`/workspace/.fxa-auto-media-skipped.txt` so the host can show it. Leave
`media_paths` empty.

## Budget

- **One** Storybook start. The `fxa-settings` webpack build takes 3 to 6 minutes.
- **At most 4 screenshots.** Capture the states the ticket changed, nothing else.
- If the build fails twice, stop, leave `media_paths` empty, and write the
  reason to `/workspace/.fxa-auto-media-skipped.txt`. Do not debug Storybook.
  It is not the ticket.
- This runs **before** you write the handoff file. After the handoff, stop.

## Step 0 — Confirm the browser exists

    ls ~/.cache/ms-playwright/ | grep -q '^firefox-' && echo "firefox ok"

If it prints nothing, stop here: write "storybook capture skipped: no Playwright
firefox in this runner" to `/workspace/.fxa-auto-media-skipped.txt`, say so, and
leave `media_paths` empty. Do not run `playwright install`; it needs network the
runner may not have and would spend the budget on infrastructure.

## Step 1 — Start Storybook

    cd /workspace
    yarn workspace fxa-settings storybook --no-open

The script chains `build-css` itself, so run it as-is. Tailwind output is
gitignored and `preview.tsx` imports it, so a separate `build-css` is not needed
and skipping the chain breaks the preview. Port 6008. Run it in the background.
**Keep `--no-open`.** Without it Storybook spawns `xdg-open` after the build,
which does not exist on a headless runner, and the uncaught error kills the
server a few seconds after the 200 (seen 2026-09-20).

For `fxa-react` components use `yarn workspace fxa-react storybook --no-open`
(port 6007).

## Step 2 — Wait, and do not trust the 200

    curl -sf http://localhost:6008/iframe.html > /dev/null

**Send no timeout flag.** The webpack builder serves that file through
`webpack-dev-middleware` with `waitUntilValid`, so the request blocks until the
first compile finishes. A 200 means "compiled".

**A 200 does not mean "compiled clean".** A bundle with errors also returns 200,
and the story then renders an error box. A screenshot of an error box looks like a
real capture. Step 4 asserts against this; do not skip it.

Storybook moves to a free port when 6008 is busy. Read the real port from its log
rather than assuming.

## Step 3 — Map changed files to story ids

    curl -s http://localhost:6008/index.json

Match each entry's `importPath` to your changed `*.stories.tsx` files, and collect
the `id` values. Story ids follow the story file, so never reuse an id you read
before an edit.

## Step 4 — Shoot

Write `/workspace/.fxa-auto-shoot.mjs`. The `.fxa-auto-*` prefix is ignored by the
dirty-worktree guard, so it will not pollute the diff.

```js
import { firefox } from 'playwright';
import fs from 'fs';

const OUT = '/workspace/.fxa-auto-media';
const PORT = process.env.SB_PORT ?? '6008';
// [storyId, fileSlug] — keep the numeric prefix so files sort.
const SHOTS = [['components-thirdpartyauth--default', '01-third-party-auth']];

fs.mkdirSync(OUT, { recursive: true });
const browser = await firefox.launch();
const page = await browser.newPage({ viewport: { width: 900, height: 700 } });

for (const [id, slug] of SHOTS) {
  // Not 'networkidle': the dev server keeps HMR traffic open and the first
  // preview compile can hold the request past 30 s. Wait for load, then for
  // the story to put something in the root.
  await page.goto(`http://localhost:${PORT}/iframe.html?id=${id}&viewMode=story`,
                  { waitUntil: 'load', timeout: 180000 });
  const root = page.locator('#storybook-root');
  if ((await root.count()) === 0) throw new Error(`story ${id} has no #storybook-root`);
  await root.locator(':scope > *').first().waitFor({ timeout: 60000 });

  // A failed bundle still returns 200 and paints an error box. Refuse to
  // screenshot that: it would reach the reviewer looking like evidence.
  // Storybook 8 always renders the box and hides it, so test visibility,
  // never presence.
  if (await page.locator('#error-message').isVisible())
    throw new Error(`story ${id} rendered a Storybook error box`);
  if ((await root.innerHTML()).trim() === '') throw new Error(`story ${id} rendered empty`);

  // Shoot the root, not the viewport: the card is a small island in an empty page.
  await root.screenshot({ path: `${OUT}/${slug}.png` });
  console.log(`captured ${slug}.png`);
}

await browser.close();
```

Run it with `node /workspace/.fxa-auto-shoot.mjs`. Step 0 confirmed the firefox
binary; `playwright` resolves from the repo root, so install nothing.

## Step 5 — Hand off

List every file you captured in `media_paths` in `.fxa-auto-done.json`, as paths
relative to `/workspace`:

    "media_paths": [".fxa-auto-media/01-third-party-auth.png"]

Reference them in `pr_body` if you want them placed inline:

    ![Rectangular buttons on Signin](./.fxa-auto-media/01-third-party-auth.png)

The host rewrites that reference to the uploaded asset URL. An unreferenced file
is appended to the body instead. Either is fine.

Delete nothing from `.fxa-auto-media/`. The host reads it after you exit.

## Do not

- Do not start the FxA stack, run `fxa-start`, or run `yarn test-sandbox`. This
  skill exists to avoid all of that.
- Do not screenshot a component the ticket did not change.
- Do not commit anything under `.fxa-auto-media/`. It is scratch for the host.
- Do not retry a failed Storybook build more than once.
