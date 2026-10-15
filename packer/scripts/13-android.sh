#!/bin/bash
# 13-android.sh — the fxa-dev-android image only (FXA_ANDROID=true): Firefox for Android (Fenix)
# built from source, an x86_64 emulator, and Firefox Nightly as the pairing authority.
# Measured on n2-standard-8 (2026-10-15): clone 2.5 min, bootstrap 1 min, build 8 min,
# Fenix 9 min; about 35 GB more disk. The build needs about 15 GB of RAM.
set -euo pipefail
[ "${FXA_ANDROID:-false}" = true ] || { echo "==> not the android image; skipped"; exit 0; }
export DEBIAN_FRONTEND=noninteractive
A=/home/agent

echo "==> Emulator libraries"
# The emulator loads X11 and GL libraries even with -no-window.
# 07-cleanup.sh already removed the apt lists, so fetch them again and remove them after.
apt-get update -qq
apt-get install -y -qq libx11-xcb1 libxcb1 libxcb-cursor0 libgl1 libegl1 libpulse0 libnss3 libxcomposite1 \
  libxcursor1 libxdamage1 libxi6 libxtst6 libxkbfile1 libasound2t64 libxkbcommon-x11-0 xvfb > /dev/null
apt-get clean
rm -rf /var/lib/apt/lists/*
# /dev/kvm is root:kvm on a runner with nested virtualization.
getent group kvm >/dev/null || groupadd -r kvm
usermod -aG kvm agent

echo "==> Firefox source and Fenix (debug, x86_64, artifact mode)"
sudo -u agent -H bash <<'AGENT'
set -euo pipefail
cd ~
# Depth 200: mach looks back for the nearest commit with CI artifacts.
[ -d firefox ] || git clone -q --depth 200 https://github.com/mozilla-firefox/firefox firefox
cd firefox
cat > mozconfig <<'EOF'
ac_add_options --enable-project=mobile/android
ac_add_options --target=x86_64-linux-android
ac_add_options --enable-artifact-builds
mk_add_options MOZ_OBJDIR=@TOPSRCDIR@/obj-android
mk_add_options AUTOCLOBBER=1
EOF
./mach --no-interactive bootstrap --no-system-changes --application-choice mobile_android_artifact_mode > /tmp/android-bootstrap.log 2>&1 \
  || { tail -30 /tmp/android-bootstrap.log; exit 1; }
# Fenix accepts web channel messages only from listed hosts; the local stack is http://localhost.
# Not in the tree yet (FxA docs/pairing/README.md). skip-worktree hides it from git diff and status,
# so a Fenix patch never carries it (a local commit would: the patch is diffed from the merge-base).
python3 - <<'PY'
import json, subprocess
p = subprocess.check_output(['git', 'ls-files', '*/feature/accounts/src/main/assets/extensions/fxawebchannel/manifest.template.json'], text=True).split()[0]
d = json.load(open(p))
for cs in d.get('content_scripts', []):
    for u in ('http://localhost/*', 'http://127.0.0.1/*'):
        if u not in cs['matches']:
            cs['matches'].append(u)
json.dump(d, open(p, 'w'), indent=2); open(p, 'a').write('\n')
PY
git update-index --skip-worktree "$(git ls-files '*/feature/accounts/src/main/assets/extensions/fxawebchannel/manifest.template.json')"
[ -z "$(git status --porcelain --untracked-files=no)" ] || { echo "==> ERROR: the localhost patch shows in git status"; exit 1; }
./mach build > /tmp/android-build.log 2>&1 || { tail -40 /tmp/android-build.log; exit 1; }
./mach gradle :fenix:assembleDebug > /tmp/android-gradle.log 2>&1 || { tail -40 /tmp/android-gradle.log; exit 1; }
apk=obj-android/gradle/build/mobile/android/fenix/app/outputs/apk/debug/fenix-x86_64-debug.apk
unzip -p "$apk" assets/extensions/fxawebchannel/manifest.json | grep -q localhost \
  || { echo "==> ERROR: the Fenix build has no localhost web channel match"; exit 1; }
ln -sfn "$PWD/$apk" ~/fenix-debug.apk
# The gradle and Kotlin daemons keep about 14 GB; a runner needs that RAM for the stack.
./mach gradle --stop > /dev/null 2>&1 || true

# The bootstrapped AVD is a CI leftover (a /builds/worker path, android-24): write one for the installed image.
img="$(cd ~/.mozbuild/android-sdk-linux && ls -d system-images/android-*/*/x86_64 | sort -V | tail -1)"
mkdir -p ~/.android/avd/fxa.avd
printf 'avd.ini.encoding=UTF-8\npath=%s/.android/avd/fxa.avd\ntarget=%s\n' "$HOME" "$(cut -d/ -f2 <<< "$img")" > ~/.android/avd/fxa.ini
cat > ~/.android/avd/fxa.avd/config.ini <<EOF
abi.type=x86_64
hw.cpu.arch=x86_64
hw.cpu.ncore=2
hw.ramSize=4096
hw.lcd.width=1080
hw.lcd.height=2400
hw.lcd.density=420
hw.keyboard=yes
hw.gpu.enabled=yes
hw.gpu.mode=swiftshader_indirect
disk.dataPartition.size=8G
image.sysdir.1=${img}/
tag.id=$(cut -d/ -f3 <<< "$img")
PlayStore.enabled=false
EOF
echo "==> AVD fxa on ${img}; Fenix $(du -h "$apk" | cut -f1)"
AGENT

echo "==> Firefox Nightly, the v2 pairing authority"
mkdir -p /opt/firefox-nightly
curl -fsSL 'https://download.mozilla.org/?product=firefox-nightly-latest-ssl&os=linux64&lang=en-US' \
  | tar -xJ -C /opt/firefox-nightly --strip-components=1
/opt/firefox-nightly/firefox --version 2>/dev/null || true

# On PATH for the agent: adb and the emulator from the bootstrapped SDK.
ln -sfn "$A/.mozbuild/android-sdk-linux/platform-tools/adb" /usr/local/bin/adb
ln -sfn "$A/.mozbuild/android-sdk-linux/emulator/emulator" /usr/local/bin/emulator
cat >> /etc/agent-env.sh <<'ENV'
# fxa-dev-android: the Android SDK, the AVD and Nightly (13-android.sh).
export ANDROID_SDK_ROOT=/home/agent/.mozbuild/android-sdk-linux ANDROID_HOME=/home/agent/.mozbuild/android-sdk-linux
export ANDROID_AVD_HOME=/home/agent/.android/avd FIREFOX_BINARY=/opt/firefox-nightly/firefox
# Current Nightly refuses Marionette's chrome commands without this.
export MOZ_REMOTE_ALLOW_SYSTEM_ACCESS=1
# The content server serves pairing v2, which the Android pairing specs need (fxa-start inherits it).
export PAIRING_VERSION=2
ENV
echo "==> android image ready"
