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
