# FxA Android

This session works on FxA in `/workspace`, with Firefox for Android (Fenix) in an emulator beside the
stack and desktop Firefox. Everything in the FxA sections above applies. This section adds Android.

## Setup

The host starts the emulator when the session starts and installs Fenix. Wait for
`/run/fxa-profile/ready`. Progress: `/var/log/profile-boot.log`. The emulator's log:
`~/.emulator.log`. A failure: `/run/fxa-profile/failed`.

## How the parts connect

| Part | Where | Notes |
|---|---|---|
| FxA | content :3030, auth :9000, profile :1111 | the usual stack (`/fxa-stack`); the content server serves pairing v2 |
| Desktop Firefox | `$FIREFOX_BINARY` (Nightly, `/opt/firefox-nightly`) | the pairing authority, driven over Marionette by the specs |
| Emulator | `emulator-5554`, Android x86_64 with KVM | `adb` is on PATH; the AVD is `fxa` |
| Fenix | `org.mozilla.fenix.debug` | built from `/home/agent/firefox` (`obj-android`); the APK is `~/fenix-debug.apk` |
| The device's localhost | the runner's ports | `adb reverse` from `_scripts/ports.txt`, done at boot |
| Channel server | `wss://channelserver.services.mozilla.com` | production, also for the local stack; both devices need to reach it |

Fenix talks to the local stack through two settings: the FxA server override (the
`pref_key_override_fxa_server` shared preference, set to `http://localhost:3030`), and the localhost
web channel match, which the image adds to the Firefox tree (hidden with skip-worktree).

The stack starts with `PAIRING_VERSION=2`, and no `PAIRING_V2_MIN_VERSION_*` is set, so the page
sends `"v2MinVersion": {}`. A phone then takes the v2 flow only when Fenix reports
`pairingVersion: 2` in `fxa_status` (`isPairingV2Enabled` in `lib/pairing/v2-gate.ts`).

## Commands

```
adb shell am start -n org.mozilla.fenix.debug/org.mozilla.fenix.HomeActivity    # start Fenix
adb exec-out screencap -p > /workspace/.fxa-auto-media/android-<step>.png        # evidence
adb logcat -d -v time | grep -E 'FirefoxAccountStateMachine|mozac-fxawebchannel|fxa_client'
adb shell am force-stop org.mozilla.fenix.debug; adb shell pm clear org.mozilla.fenix.debug
```

A Fenix change: edit under `/home/agent/firefox/mobile/android`, then rebuild and install. The first
build is in the image, so a rebuild takes seconds to a few minutes.

```
cd /home/agent/firefox && ./mach gradle :fenix:assembleDebug && adb install -r ~/fenix-debug.apk
./mach gradle --stop      # after the last build: the daemons keep about 14 GB
```

## Proof

`/android-verify` runs the Android pairing spec against the stack, desktop Nightly and the emulator,
saves screenshots and the FxA logcat lines, and prints a verdict. A skipped spec is a FAIL.

For a change to a pairing or sign-in flow, run `/android-verify --record`. It saves a side-by-side
video of the phone and the desktop for each try, with that try's logcat and spec log. Review the
video before you share it (the skill says how), and attach it to the PR.

## Traps

- `monkey` opens LeakCanary, not Fenix: start `HomeActivity` by name.
- The phone shows "Finish pairing in the app" and the desktop stays on the QR code. On a phone,
  `useFxAStatus` gives Fenix 500 ms to answer `fxa_status` (`PAIRING_FXA_STATUS_TIMEOUT_MS`). Main
  starts that clock at mount, but `firefox.fxaStatus` sends on the first frame, which the emulator
  reaches 2 to 4 s later. The page gives up before it asks, and routes a v2-capable Fenix to the hint.
  Logcat shows the page's `fxa_status sent msg` seconds after the pairing tab opened, and no
  `pair_oauth_start`. Not your change: `/android-verify` runs the spec again.
- The phone stays on "One last step to sync" while the desktop shows "Your device is connected",
  and logcat shows `Unexpected state change: complete`: the supplicant finished before the
  approve_signin page subscribed (FXA-14793). Not your change; the device is paired.
- The pairing passes, then "Connected Services lists the Android device" fails or hangs until
  `Test timeout of 300000ms exceeded`, often on every other try. The desktop's device name holds
  the runner's hostname, which contains "android". Two bugs in the specs then act on that name:
  1. `isMobileDevice` in the pairing specs matches the name, so the spec picks the desktop when the
     API lists it first.
  2. `sendCommand` in `functional-tests/lib/marionette.ts` sends `msg.length` (UTF-16 units) as the
     length prefix, not bytes. The `’` in the name makes the prefix wrong, and Marionette waits forever.

  Not your change, unless your tree fixes both: the spec should check `d.type === 'mobile'`, and
  the prefix should use `Buffer.byteLength`.
- These are not the cause of a failed pairing, so do not spend time on them: the channel server
  (when a try reaches it, a round trip takes under a second), the minimum versions (none are set),
  and the emulator's CPU (`-cores 4` did not help).
- Never run `pkill -f` with text from this guide; stop the emulator with `adb emu kill`.
