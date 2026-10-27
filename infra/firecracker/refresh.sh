#!/bin/bash
# refresh.sh [--force]: when main moved, bring the build guest's clone to main,
# install only when yarn.lock moved, and take a new snapshot with the stack
# running. Run as root on the host; fc-refresh.timer runs it. New slots restore
# the newest snapshot; running slots keep theirs. The two newest are kept.
set -euo pipefail
exec 9> /fc/run/refresh.lock
flock -n 9 || { echo "a refresh is already running"; exit 0; }
# Each run's outcome, for fxa-sandbox-ctl fc status: systemd's Result reads success again after
# every boot, and the host boots on demand. refresh.ok marks the last good run.
outcome() { printf 'result=%s\nat=%s\n' "$([ "$1" = 0 ] && echo success || echo failed)" "$(date +%s)" > /fc/run/refresh.status; [ "$1" != 0 ] || touch /fc/run/refresh.ok; }
trap 'outcome $?' EXIT
# A stop (systemctl stop, the host shutting down) is a failed run: without these, the EXIT trap saw 0.
trap 'exit 143' TERM; trap 'exit 130' INT
fc=/usr/local/sbin/fc
# The guest's Node and Claude Code come from the image's own toolchain script, which
# fxa-sandbox-ctl fc install puts beside this one; it holds the Claude Code pin.
toolchain=/usr/local/share/fxa/03b-toolchain.sh
CLAUDE_CODE_VERSION="$(sed -n 's/^CLAUDE_CODE_VERSION=//p' "$toolchain")"
CODEX_VERSION="$(sed -n 's/^CODEX_VERSION=//p' "$toolchain")"
[ -n "$CLAUDE_CODE_VERSION" ] && [ -n "$CODEX_VERSION" ] || { echo "ERROR: no Claude Code or Codex pin in ${toolchain}" >&2; exit 1; }
cur="$(cat /fc/snap/latest/commit 2>/dev/null || echo none)"
cur_cc="$(cat /fc/snap/latest/claude-code 2>/dev/null || echo none)"
cur_cx="$(cat /fc/snap/latest/codex 2>/dev/null || echo none)"
new="$(git ls-remote https://github.com/mozilla/fxa.git refs/heads/main | cut -f1)"
[[ "$new" =~ ^[0-9a-f]{40}$ ]] || { echo "ERROR: could not read main" >&2; exit 1; }
[ "$new" = "$cur" ] && [ "$cur_cc" = "$CLAUDE_CODE_VERSION" ] && [ "$cur_cx" = "$CODEX_VERSION" ] && [ "${1:-}" != --force ] && { echo "snapshot is at main (${new:0:10})"; exit 0; }
echo "main moved: ${cur:0:10} -> ${new:0:10}"

# Start from the newest snapshot's disk: it was synced just before the snapshot,
# so it is known good. A build disk kept between runs was left damaged by a kill.
cp --reflink=always "$(readlink -f /fc/snap/latest)/rootfs.ext4" /fc/build/rootfs.ext4
# On any failure, shut the guest down cleanly; systemd would kill it mid-write.
trap 'rc=$?; "$fc" ssh 0 "sudo sync; sudo systemctl poweroff" >/dev/null 2>&1 || true; sleep 8; outcome $rc' EXIT
"$fc" boot
# agent-init appends to /etc/agent-env.sh at boot: wait until it has finished.
# A failed unit stays failed and never turns active: give up after 300 s, so the run records a failure.
w0="$(date +%s)"; until [ "$("$fc" ssh 0 'systemctl is-active agent-init fxa-gce-checkout' 2>/dev/null | grep -cx active)" = 2 ]; do [ $(( $(date +%s) - w0 )) -lt 300 ] || { echo "ERROR: agent-init not done after 300s: $("$fc" ssh 0 'systemctl is-active agent-init fxa-gce-checkout' 2>&1 | tr '\n' ' ')" >&2; exit 1; }; sleep 2; done
# The image build wrote the lock hash as root; the agent keeps it current from here.
"$fc" ssh 0 'sudo chown agent:agent /home/agent/.image-lock-hash'
want="$(curl -fsSL "https://raw.githubusercontent.com/mozilla/fxa/${new}/.nvmrc")"
tc="$("$fc" ssh 0 "sudo bash -s -- ${want//[^0-9.v]/}" < "$toolchain")"
echo "$tc"
# The guest's stdout is not trusted: keep only plain versions, which the controller's alerts read.
cc="$(sed -n 's/^claude \([0-9][0-9.]*\)$/\1/p' <<< "$tc" | head -1)"; cx="$(sed -n 's/^codex \([0-9][0-9.]*\)$/\1/p' <<< "$tc" | head -1)"
"$fc" ssh 0 "sudo -u agent bash -s -- $new" <<'GUEST'
set -euo pipefail
cd /home/agent/fxa && source /etc/agent-env.sh
git fetch -q origin main && git checkout -q -B main "$1"
# The clone carries over from the last snapshot: build output that main no longer ignores would show as a change in every session.
git ls-files -o --exclude-standard | sed 's/^/removed untracked: /'; git ls-files -o --exclude-standard -z | xargs -0 -r rm -f --
if [ "$(sha256sum yarn.lock | cut -d' ' -f1)" != "$(cat /home/agent/.image-lock-hash 2>/dev/null)" ]; then
  echo "yarn.lock moved: installing"
  # A rebuild over the old tree runs esbuild's install.js on its already-swapped native bin/esbuild, which fails: relink from the cache.
  rm -f node_modules/.yarn-state.yml
  yarn install --immutable > /tmp/refresh-yarn.log 2>&1 || { tail -30 /tmp/refresh-yarn.log; tail -n 15 /tmp/xfs-*/build.log 2>/dev/null; exit 1; }
  (cd packages/functional-tests && npx playwright install chromium firefox > /dev/null 2>&1) || true
  sha256sum yarn.lock | cut -d' ' -f1 > /home/agent/.image-lock-hash
fi
# As the image build does: a new lib on main has no dist otherwise, and the Nx cache makes a runner's pin build a hit.
# NODE_ENV as CI's build job: agent-env's development fails payments-next's prerender (useContext of null).
NODE_ENV=test npx nx run-many -t build --all --exclude=fxa-dev-launcher > /tmp/refresh-nx.log 2>&1 || { echo "WARN: nx build failed; runners build what they need at the pin"; tail -15 /tmp/refresh-nx.log; }
echo "clone at $(git rev-parse --short HEAD)"
GUEST
# The snapshot's stack uses CI's location override and Nightly's env; images before them lack the lines.
"$fc" ssh 0 'sudo bash -s' <<'GUEST'
grep -q GEODB_LOCATION_OVERRIDE /etc/agent-env.sh || cat >> /etc/agent-env.sh <<'ENV'
# As CI sets it (.circleci/config.yml), so a spec that passes here passes there.
export GEODB_LOCATION_OVERRIDE='{"location": {"countryCode": "US", "postalCode": "85001"}}'
ENV
grep -q '^export FIREFOX_BINARY=' /etc/agent-env.sh || cat >> /etc/agent-env.sh <<'ENV'
# Firefox Nightly (03b-toolchain.sh), the authority for the v2 pairing and Marionette specs.
export FIREFOX_BINARY=/opt/firefox-nightly/firefox
# Current Nightly refuses Marionette's chrome commands without this.
export MOZ_REMOTE_ALLOW_SYSTEM_ACCESS=1
ENV
GUEST
# The image has no apt lists: without the update, the install finds no package, and each boot
# then installs dnsmasq itself (about 30 s).
"$fc" ssh 0 'sudo bash -c "apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq make perl unzip watchman dnsmasq-base" > /dev/null 2>&1' \
  || echo "WARN: the snapshot's packages did not install; each boot installs dnsmasq itself"
# Firefox, so a session can change it and hand back a diff: an artifact build
# (prebuilt C++, local front end), rebuilt when Firefox main moved. A failure
# keeps the snapshot's earlier build and never blocks the FxA refresh.
"$fc" ssh 0 'sudo -u agent bash -s' <<'GUEST' || echo "WARN: the Firefox build failed; the snapshot keeps the earlier one"
set -euo pipefail
cd /home/agent
# Depth 200: CI builds artifacts an hour or more after a push, so mach looks back
# for the nearest commit that has them; a depth-1 clone has none to look at.
[ -d firefox ] || git clone -q --depth 200 https://github.com/mozilla-firefox/firefox firefox
cd firefox
printf '%s\n' 'ac_add_options --enable-artifact-builds' 'mk_add_options MOZ_OBJDIR=@TOPSRCDIR@/obj-artifact' 'mk_add_options AUTOCLOBBER=1' > mozconfig
old="$(git rev-parse HEAD)"
git fetch -q --depth 200 origin main && git checkout -q FETCH_HEAD
if [ ! -x obj-artifact/dist/bin/firefox ] || [ "$old" != "$(git rev-parse HEAD)" ]; then
  [ -d ~/.mozbuild ] || ./mach --no-interactive bootstrap --no-system-changes \
    --application-choice "Firefox for Desktop Artifact Mode" > /tmp/refresh-firefox.log 2>&1
  ./mach build >> /tmp/refresh-firefox.log 2>&1 || { git checkout -q "$old"; tail -30 /tmp/refresh-firefox.log; exit 1; }
fi
# fxa-dev-launcher sets the Nightly prefs only when FIREFOX_BIN has "Nightly" in it.
ln -sfn /home/agent/firefox/obj-artifact/dist/bin /home/agent/Nightly
echo "firefox at $(git rev-parse --short HEAD)"
GUEST
"$fc" ssh 0 'sudo sync; sudo systemctl poweroff' || true
sleep 8

name="$(date -u +%Y%m%d-%H%M)"
/usr/local/sbin/fc-make-snapshot "$name"
echo "$new" > "/fc/snap/${name}/commit"
echo "$cc" > "/fc/snap/${name}/claude-code"
echo "$cx" > "/fc/snap/${name}/codex"
# Keep the two newest; a slot already restored keeps its memory and disk copy.
ls -1dt /fc/snap/2*/ 2>/dev/null | tail -n +3 | xargs -r rm -rf
[ -d /fc/snap/v1 ] && [ "$(readlink /fc/snap/latest)" != /fc/snap/v1 ] && rm -rf /fc/snap/v1
echo "snapshot ${name} at ${new:0:10}"
