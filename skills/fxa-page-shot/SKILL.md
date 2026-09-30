---
name: fxa-page-shot
description: Use inside the FxA sandbox to screenshot a live page on the local stack (a route, a signed-in or 2FA state, a viewport, a locale, dark mode), or to check a recorded video frame by frame. Trigger when someone asks to see, show or screenshot a page, or asks you to check a video. Not for a component with a sibling *.stories.tsx (use /fxa-storybook-capture), and not to prove a whole flow (use /fxa-functional-local).
---

# Screenshot a live page, or check a video

The script lives outside /workspace, so it never leaves a spec file in the repo.
Do not write a `zz*.spec.ts` or a `/tmp` Playwright script for a screenshot.

## Screenshot a page

    node ~/.claude/skills/fxa-page-shot/page-shot.mjs shot /settings --account verified --viewport 390x844 --viewport 1280x800

Options:

- `--account none|verified|unverified|2fa`: create a `pageshot-<hex>@restmail.net`
  account and sign in first. `unverified` stops on `/confirm_signup_code`.
  The default is `none`.
- `--viewport WxH`: repeat it for more sizes. The default is 1280x720.
- `--locale de`, `--dark`: set the browser language and the color scheme.
- `--selector css`: shoot only that element. The default is the full page.
- `--wait-for css`: wait for that element before the shot.

What it does:

1. It runs `bash ~/.claude/skills/fxa-stack/stack.sh ensure`.
2. It loads the helpers from `packages/functional-tests`: `create('local')`,
   `getFirefoxUserPrefs`, `getReactFeatureFlagUrl` and `getTotpCode`.
3. It opens the route in Firefox with the same base URL, prefs and React flags
   as the functional tests.
4. It writes `<route>-<account>-<WxH>[-<locale>][-dark].png` to
   `/workspace/.fxa-auto-media/` and prints each path. That folder posts to the thread.

On a failure it saves `<name>-FAILED.png` and prints the current URL. Read
that screenshot before you change a selector. Open every PNG with Read
before you describe it.

## Check a video

    node ~/.claude/skills/fxa-page-shot/page-shot.mjs frames /workspace/.fxa-auto-media/<video>.webm --every 1

It writes one frame every N seconds, with a time label, to
`/tmp/fxa-page-shot/<video>/`. It also writes contact sheets of 16 frames each
and prints their paths. Gray tiles are empty slots, not video.

Read every sheet before you describe a video. Do not judge a video from one
frame. Open a single `frame-NNN.png` to look closer.

## When a shot is not possible

The CMS and payments pages do not run on the VM. Write the reason to
`/workspace/.fxa-auto-media-skipped.txt`.

Run `node page-shot.mjs --self-test` to check the argument parser offline.
