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

Fenix talks to the local stack through two settings: the FxA server override (the
`pref_key_override_fxa_server` shared preference, set to `http://localhost:3030`), and the localhost
web channel match, which the image adds to the Firefox tree (hidden with skip-worktree).

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

## Traps

- `monkey` opens LeakCanary, not Fenix: start `HomeActivity` by name.
- The pairing page gives a phone 500 ms to answer `fxa_status` (`useFxAStatus`). On a cold Fenix
  start the first answer can come later, and the page shows "Finish pairing in the app". That is a
  known FxA bug, not your change: run `/android-verify` again.
- Never run `pkill -f` with text from this guide; stop the emulator with `adb emu kill`.
