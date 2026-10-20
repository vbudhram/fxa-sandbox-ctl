---
name: android-verify
description: Use to prove an FxA or Fenix change on Android - runs the Android pairing spec across the FxA stack, desktop Nightly and Fenix in the emulator, saves screenshots and FxA logcat lines, and prints a PASS or FAIL verdict. With --record, a side-by-side video of the phone and the desktop.
---

# Android verify

One command proves that FxA, desktop Firefox and Fenix still work together, and leaves evidence:

    bash ~/.claude/skills/android-verify/verify.sh            # the v2 pairing spec
    bash ~/.claude/skills/android-verify/verify.sh --fenix    # rebuild and install Fenix first
    bash ~/.claude/skills/android-verify/verify.sh --spec pairingFlowAndroid   # another Android spec

It checks that the emulator and Fenix are up and the stack serves pairing v2. It runs the spec
with `ANDROID_PAIRING_V2_ENABLED=1` on `--project=local`. It passes only when Playwright exits 0 and its summary has a passed count and no failed or
flaky one: a skipped spec is a FAIL. On a fail it runs the spec once more, because the pairing page can give up on
`fxa_status` before it sends it (a trap in the FxA Android guide), and it says so.

Evidence goes to `/workspace/.fxa-auto-media/`: `android-<spec>.png` (the phone's screen at the
end) and `android-<spec>-try<N>-logcat.txt` (the FxA and pairing-page lines of each try). Print the verdict table it ends with.

## Record the flow

    bash ~/.claude/skills/android-verify/verify.sh --record

`--record` records each try as one video, `android-<spec>-try<N>.mp4` in the same folder: the phone
on the left (`adb screenrecord`), desktop Nightly on the right (an ffmpeg grab of its X display),
lined up by the wall-clock start of each recorder. The video starts at sign-in, so the first
20 s or so is the desktop signing in.

Review it before you share it. Take a frame every 4 s
(`node ~/.claude/skills/fxa-page-shot/page-shot.mjs frames <video> --every 4`), then read every
contact sheet it prints. Look closely at the frames where the phone shows "Connect", where the
desktop shows the approval, and the last one. Check:

| Check | Failure looks like |
|---|---|
| In sync | The phone on "Connect" while the desktop is still on the QR |
| Ends on success on both sides | The desktop on "Your device is connected", the phone still on "One last step to sync" |

The second row was a real FxA bug once: the supplicant emitted `complete` before the
approve_signin page subscribed, and logcat showed `Unexpected state change: complete`. The logcat
file keeps those page lines.

Your own reproduction checks still come first: a spec proves the flow works, not that your bug
is gone. Add an `adb` or API check for the bug itself, with its output.
