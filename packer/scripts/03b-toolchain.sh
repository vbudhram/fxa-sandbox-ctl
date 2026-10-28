#!/bin/bash
# 03b-toolchain.sh — the runner's Node, Claude Code and Codex, in /usr/local, the one prefix
# that wins on PATH. The Packer build runs it, and infra/firecracker/refresh.sh runs it
# in the snapshot guest. Run as root: 03b-toolchain.sh [node-version], fxa main's
# .nvmrc when it is not given.
# Prints "node <version>", "claude <version>", "codex <version>" and "nightly <version>",
# and fails when one is not what was asked for.
set -euo pipefail

# Firefox Nightly, the v2 pairing authority: FIREFOX_BINARY in /etc/agent-env.sh (06-agent-init.sh).
NIGHTLY=/opt/firefox-nightly
# Nightly changes each day: fetch it once a day, not on each refresh. A failed fetch keeps the earlier copy.
nightly() {
  local day; day="$(date -u +%F)"
  [ "$(cat "$NIGHTLY/.fetched" 2>/dev/null)" != "$day" ] || return 0
  rm -rf "$NIGHTLY.new" && mkdir -p "$NIGHTLY.new"
  if curl -fsSL 'https://download.mozilla.org/?product=firefox-nightly-latest-ssl&os=linux64&lang=en-US' \
    | tar -xJ -C "$NIGHTLY.new" --strip-components=1 && [ -x "$NIGHTLY.new/firefox" ]; then
    rm -rf "$NIGHTLY" && mv "$NIGHTLY.new" "$NIGHTLY" && echo "$day" > "$NIGHTLY/.fetched"
  else
    rm -rf "$NIGHTLY.new"
    [ -x "$NIGHTLY/firefox" ] || { echo "ERROR: Firefox Nightly did not install" >&2; return 1; }
    echo "WARN: the Nightly fetch failed; the earlier copy stays" >&2
  fi
}

# opt_tool <dir> <version> <url>   A tar.gz unpacked into <dir> once for each version. A failed
# fetch keeps the earlier copy and only warns: these are one team's tools, never FxA's.
opt_tool() {
  [ "$(cat "$1/.version" 2>/dev/null)" != "$2" ] || return 0
  rm -rf "$1.new" && mkdir -p "$1.new"
  if curl -fsSL "$3" | tar -xz -C "$1.new" && echo "$2" > "$1.new/.version"; then
    rm -rf "$1" && mv "$1.new" "$1" && chmod -R a+rX "$1"
  else
    rm -rf "$1.new"; echo "WARN: $1 $2 did not install; the earlier copy stays" >&2
  fi
}

# The storage team's Spanner path with no Docker (profiles/sync-storage/boot.sh): CI's Spanner
# and Pub/Sub emulators and fake GCS, idle files for every other team. The emulator pin follows
# SPANNER_EMULATOR_VER in syncstorage-rs. x86_64 only: the emulator has no arm64 build.
SPANNER_EMULATOR_VERSION=1.5.52
FAKE_GCS_VERSION=1.56.1
PUBSUB_EMULATOR_COMPONENT=google-cloud-sdk-pubsub-emulator-20261009074343
sync_tools() {
  [ "$(uname -m)" = x86_64 ] || return 0
  opt_tool /opt/spanner-emulator "$SPANNER_EMULATOR_VERSION" \
    "https://storage.googleapis.com/cloud-spanner-emulator/releases/${SPANNER_EMULATOR_VERSION}/cloud-spanner-emulator_linux_amd64-${SPANNER_EMULATOR_VERSION}.tar.gz"
  opt_tool /opt/fake-gcs "$FAKE_GCS_VERSION" \
    "https://github.com/fsouza/fake-gcs-server/releases/download/v${FAKE_GCS_VERSION}/fake-gcs-server_${FAKE_GCS_VERSION}_Linux_amd64.tar.gz"
  opt_tool /opt/pubsub-emulator "$PUBSUB_EMULATOR_COMPONENT" \
    "https://dl.google.com/dl/cloudsdk/channels/rapid/components/${PUBSUB_EMULATOR_COMPONENT}.tar.gz"
}

# The one pin for each runtime: manager.sh reads them for the manager, and refresh.sh
# for the snapshot (lib/claude-pin.check.sh).
CLAUDE_CODE_VERSION=2.1.304
CODEX_VERSION=0.163.0

want="${1:-$(curl -fsSL https://raw.githubusercontent.com/mozilla/fxa/main/.nvmrc)}"
want="$(printf '%s' "$want" | tr -d 'v \n')"
# FxA's preinstall refuses any Node but the exact one in .nvmrc.
[[ "$want" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "ERROR: .nvmrc is not a plain version: ${want}" >&2; exit 1; }

# The marker, not node -v: a release unpacked over another leaves a mixed npm that
# cannot install, so a release is always unpacked onto a clean npm and corepack.
if [ "$(cat /usr/local/.node-release 2>/dev/null)" != "$want" ]; then
  a="$(uname -m)"; case "$a" in x86_64) a=x64 ;; aarch64) a=arm64 ;; esac
  rm -rf /usr/local/lib/node_modules/npm /usr/local/lib/node_modules/corepack
  curl -fsSL "https://nodejs.org/dist/v${want}/node-v${want}-linux-${a}.tar.xz" \
    | tar -xJ -C /usr/local --strip-components=1 --exclude='*.md' --exclude=LICENSE
  echo "$want" > /usr/local/.node-release
fi
hash -r
corepack enable

# One copy of each: an older image put another under /usr, beside the apt Node.
rm -rf /usr/lib/node_modules/@anthropic-ai/claude-code /usr/bin/claude /usr/lib/node_modules/@openai/codex /usr/bin/codex
cc() { /usr/local/bin/claude --version 2>/dev/null | cut -d' ' -f1; }
cx() { /usr/local/bin/codex --version 2>/dev/null | awk '{ print $NF }'; }
# npm 11 skips install scripts unless they are allowed by name.
[ "$(cc)" = "$CLAUDE_CODE_VERSION" ] || npm install -g --prefix /usr/local --allow-scripts=@anthropic-ai/claude-code \
  "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" >&2
[ "$(cx)" = "$CODEX_VERSION" ] || npm install -g --prefix /usr/local --allow-scripts=@openai/codex "@openai/codex@${CODEX_VERSION}" >&2

echo "node $(node -v | tr -d v)"
echo "claude $(cc)"
echo "codex $(cx)"
[ "$(node -v | tr -d v)" = "$want" ] || { echo "ERROR: node is $(node -v), not ${want}" >&2; exit 1; }
[ "$(cc)" = "$CLAUDE_CODE_VERSION" ] || { echo "ERROR: claude is '$(cc)', not ${CLAUDE_CODE_VERSION}" >&2; exit 1; }
[ "$(cx)" = "$CODEX_VERSION" ] || { echo "ERROR: codex is '$(cx)', not ${CODEX_VERSION}" >&2; exit 1; }
npm -v > /dev/null || { echo "ERROR: npm does not run" >&2; exit 1; }

nightly
echo "nightly $(sed -n 's/^Version=//p' "$NIGHTLY/application.ini" | head -1)"
sync_tools
echo "spanner-emulator $(cat /opt/spanner-emulator/.version 2>/dev/null || echo none)"
