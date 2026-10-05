---
name: fxa-functional-local
description: Run the one Playwright functional test that covers a user flow against the VM's local FxA stack, with video, and hand the video to the engineer. Use to prove a UI or flow change end to end, or when asked for a video of a flow.
---

# One functional test, locally, with video

Pick the existing spec that covers the flow; do not write a throwaway spec.
Then run it with the helper, which starts the stack if needed, records video,
and copies it to /workspace/.fxa-auto-media/ (posted to the engineer):

    bash ~/.claude/skills/fxa-functional-local/run.sh tests/settings/changePassword.spec.ts "change password with a correct password"

The second argument is a `-g` filter on the test title; omit it to run the file.
While you change one test, always give the filter: a whole file reruns every
test in it.
It runs one worker and no retries, so a failure is a real failure, and prints
PASS or FAIL with the video paths. A trace is kept on failure under
/workspace/artifacts/functional/.

## A run longer than 10 minutes

A Bash call waits 10 minutes at most. A whole spec file, or a first run that
starts the stack, can take longer. Start it in the background, then wait:

    bash ~/.claude/skills/fxa-functional-local/run.sh --bg tests/settings/changePassword.spec.ts
    bash ~/.claude/skills/fxa-functional-local/run.sh wait

`wait` returns within 4.5 minutes, before the prompt cache expires:

- exit 0 or 1: the run ended. It prints PASS or FAIL and the video lines.
- exit 75: still running. Call `wait` again.
- exit 4: the run died without a result. It prints the last log lines.

Keep calling `wait` in the same turn. Do not end the turn while the run goes on,
and do not write your own `sleep` loop.

## Read a trace

Use `trace.sh` after a local spec fails, or when a red CI run put traces in
/workspace/.fxa-ci/. Give it one trace.zip or a directory:

    bash ~/.claude/skills/fxa-functional-local/trace.sh /workspace/artifacts/functional
    bash ~/.claude/skills/fxa-functional-local/trace.sh /workspace/.fxa-ci

For each trace.zip, it prints:

- The test actions in order, with the duration of each. `!!` marks the failed
  action, and the line below it shows the error.
- The console errors and warnings.
- The failed requests (4xx, 5xx, or no response), with the method and the URL.
- The last page URL.

It removes the route handler steps and caps each list, and it says how many
lines it cut. Read the failed action first, then the failed requests near it.
Do not call CircleCI hosts. If /workspace/.fxa-ci has no trace, ask the
engineer to paste the job link.

## Which spec covers which flow

Paths are under /workspace/packages/functional-tests/.

| Flow | Spec | Test title to filter on |
|---|---|---|
| Sign in with password | tests/signin/signIn.spec.ts | login as an existing user |
| Sign in with a code | tests/key-stretching-v2/signInTokenCode.spec.ts | sign in within token code |
| Unblock | tests/signin/signinBlocked.spec.ts | valid code entered |
| Cached sign in | tests/signin/signinCached.spec.ts | sign in twice |
| Sign up with a code | tests/react-conversion/signup.spec.ts | signup web |
| Password reset | tests/resetPassword/resetPassword.spec.ts | can reset password |
| Account recovery key | tests/settings/recoveryKey.spec.ts | revoke recovery key |
| Reset with recovery key | tests/resetPassword/resetPasswordRecoveryKey.spec.ts | can reset password with recovery key |
| 2FA setup and sign in | tests/settings/setup2faWithBackupCodes.spec.ts | enable with QR code |
| 2FA backup codes | tests/settings/totpRecoveryCode.spec.ts | totp valid recovery code |
| Recovery phone | tests/settings/recoveryPhone.spec.ts | can setup, confirm and remove recovery phone |
| Change or secondary email | tests/settings/changeEmail.spec.ts | change primary email and login |
| Change password | tests/settings/changePassword.spec.ts | change password with a correct password |
| Delete account | tests/settings/deleteAccount.spec.ts | delete account |
| Display name | tests/settings/displayName.spec.ts | add the display name |
| Avatar | tests/settings/avatar.spec.ts | upload and remove avatar |
| Connect another device | tests/signin/connectAnotherDevice.spec.ts | verify /connect_another_device page |
| Passwordless | tests/passwordless/signinPasswordless.spec.ts | passwordless signup |
| Mock Google or Apple sign in | tests/thirdPartyAuth/mockIdp.spec.ts | Google links an existing account |

If no row fits, `git grep -n "test(" packages/functional-tests/tests` and pick
the closest existing test.

## Not on the VM

- OAuth through 123done (`tests/oauth/*`, loginHint, relay, smart window): the
  token exchange needs Stripe and Strapi. Say CI covers it.
- Payments (`tests-payments-next`): no payments stack. Say CI covers it.
- Sync specs launch their own Firefox. The helper records it too, as
  `<test>-own-<n>.webm`. Pairing's authority is a headless Firefox driven by
  Marionette, which nothing can record, and pairing needs Firefox Nightly. Run
  them only when asked; the video shows the supplicant side only.
- The helper drops a video that shows only a blank page, and says so. Do not
  post a blank video in its place.
- `#chromium` tests run in the `local-chromium` project, not `local`. `run.sh` passes both projects, so it runs each test once in the correct browser.

## Notes

- Codes in emails and SMS work offline: the inbox on :9001 and Redis serve them.
- A test that passes but leaves "Failed to cleanup account" needs admin-server
  on :8095 (`bash ~/.claude/skills/fxa-stack/stack.sh status`).
- Content-server edits restart it under pm2; wait for
  `curl -sf localhost:3030/` before running.
- If the stack itself fails, use `/fxa-stack` to diagnose it; do not debug the
  app from a timed-out test.
