---
name: fxa-perf
description: Use inside the FxA sandbox when a request asks for a page to load or show faster, or for proof of a speed change, with numbers or a side-by-side video. Builds fxa-settings for production at each version, times cold loads in Firefox on a throttled network, keeps the results across pauses, and puts videos side by side.
---

# Measure page speed

A ready harness, so you do not write one. One thread built its own four times
and lost 45 minutes to a proxy that cut files short.

```bash
P=~/.claude/skills/fxa-perf/perf.sh
$P build base origin/main          # prod build of fxa-settings, about 2 min
$P build new                       # the working tree, your change
$P measure base,new 3              # while you iterate; 7 for the final numbers
$P report base,new
$P video base,new                  # once, at the end
$P stop                            # puts the settings dev server back on :3000
```

- **What it times:** ms from navigation to the shell (`#fxa-shell`), the first
  paint, and the email form. With the `email` flow (`measure base,new 7 email`)
  it also types an email, submits, and times the step to the next field.
- **Network:** `PERF_PROFILE=mobile` (slow 4G: 150 ms, 1.6 Mbit/s, the default),
  `desktop` (40 ms, 10 Mbit/s) or `none`. The page's own server throttles,
  so there is no proxy. Calls to the auth server are not throttled: say so when
  a number depends on them.
- **The stack must run:** the server reads the live config from :3030. It
  stops `settings-react` while it holds :3000. Run `perf.sh stop` when you are done.

## Rules that save the most time

1. **Measure a build once.** Results are kept by the build's asset manifest in
   `/workspace/.fxa-keep/perf`, which a pause keeps. `measure` skips a build
   that already has the rounds you ask for, so the baseline is measured once a thread.
   Builds are in `/tmp/fxa-perf` and do not survive a pause: build again (2 min), and the
   same source gives the same manifest, so its kept results still count.
2. **Iterate with 3 rounds; give 7 only for the numbers you report.**
3. **Record video once, at the end, for the final builds.** Each video run
   takes minutes. A video does not prove a number: the medians do.
4. **A run over 4 minutes goes in the background** (`run_in_background`), and
   you wait with `timeout 270 tail --pid=<pid> -f /dev/null`, again until it ends.
5. **Commit before `build <label> <rev>`.** It checks out `<rev>` in
   fxa-settings and fxa-react, then puts HEAD back, and it refuses when those
   paths have uncommitted changes.

## Report

Give the medians table, the profile, the number of loads, and the change in ms
and %. Attach the video from `/workspace/.fxa-auto-media/perf-<flow>.mp4`.
Say what you did not measure (other profiles, the auth server, Chromium).
