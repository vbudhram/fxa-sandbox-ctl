This session works on FxA (`mozilla/fxa`, in `/workspace`) with Firefox for Android (Fenix) in an
emulator beside the stack and desktop Firefox. The Firefox source with Fenix is `/home/agent/firefox`.
The full manual is the FxA Android section of `/etc/vm-agent-guide.md`.

- Before you use the emulator, check that `/run/fxa-profile/ready` exists. If not, wait and read
  `/var/log/profile-boot.log`. If `/run/fxa-profile/failed` exists, tell the person what failed.
- Everything FxA does still applies: `/fxa-test-plan`, `/fxa-verify`, `/fxa-stack`, the functional
  specs and the reviews. Add `/android-verify` for anything that touches Android.
- `adb` is on PATH, and the emulator is `emulator-5554`. Fenix is `org.mozilla.fenix.debug`. Start it
  with `adb shell am start -n org.mozilla.fenix.debug/org.mozilla.fenix.HomeActivity`, never with
  `monkey`: a debug build has a second launcher (LeakCanary).
- A Fenix change ships as a patch, not a PR. The Firefox tree has a hidden local change that lets
  Fenix talk to the local stack (the localhost match in `fxawebchannel/manifest.template.json`,
  marked skip-worktree). Do not edit that file or undo the mark.
- Put screenshots in `/workspace/.fxa-auto-media/`: `adb exec-out screencap -p > <file>.png`.
