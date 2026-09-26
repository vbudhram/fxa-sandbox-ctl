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
It runs one worker and no retries, so a failure is a real failure, and prints
PASS or FAIL with the video paths. A trace is kept on failure under
/workspace/artifacts/functional/.

## Which spec covers which flow

Paths are under /workspace/packages/functional-tests/.

| Flow | Spec | Test title to filter on |
|---|---|---|
| Sign in with password | tests/signin/signIn.spec.ts | login as an existing user |
| Sign in with a code | tests/key-stretching-v2/signInTokenCode.spec.ts | accepts valid sign in code |
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
- Pairing and Sync specs open a second Firefox that is not recorded, and pairing
  needs Firefox Nightly. Run them only when asked; the video shows one side.
- `#chromium` tests run in the `local-chromium` project, not `local`.

## Notes

- Codes in emails and SMS work offline: the inbox on :9001 and Redis serve them.
- A test that passes but leaves "Failed to cleanup account" needs admin-server
  on :8095 (`bash ~/.claude/skills/fxa-stack/stack.sh status`).
- Content-server edits restart it under pm2; wait for
  `curl -sf localhost:3030/` before running.
- If the stack itself fails, use `/fxa-stack` to diagnose it; do not debug the
  app from a timed-out test.
