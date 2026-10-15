---
name: android-verify
description: Use to prove an FxA or Fenix change on Android - runs the Android pairing spec across the FxA stack, desktop Nightly and Fenix in the emulator, saves screenshots and FxA logcat lines, and prints a PASS or FAIL verdict.
---

# Android verify

One command proves that FxA, desktop Firefox and Fenix still work together, and leaves evidence:

    bash ~/.claude/skills/android-verify/verify.sh            # the v2 pairing spec
    bash ~/.claude/skills/android-verify/verify.sh --fenix    # rebuild and install Fenix first
    bash ~/.claude/skills/android-verify/verify.sh --spec pairingFlowAndroid   # another Android spec

It checks that the emulator and Fenix are up and the stack serves pairing v2. It runs the spec
with `ANDROID_PAIRING_V2_ENABLED=1` on `--project=local`. It counts only `1 passed`: a skipped spec
is a FAIL. On a fail it runs the spec once more, because of the known 500 ms `fxa_status`
deadline on a cold Fenix start, and it says so.

Evidence goes to `/workspace/.fxa-auto-media/`: `android-<spec>.png` (the phone's screen at the
end) and `android-<spec>-logcat.txt` (the FxA lines). Print the verdict table it ends with.

Your own reproduction checks still come first: a spec proves the flow works, not that your bug
is gone. Add an `adb` or API check for the bug itself, with its output.
