#!/bin/bash
# 03b-toolchain.sh — the runner's Node, Claude Code and Codex, in /usr/local, the one prefix
# that wins on PATH. The Packer build runs it, and infra/firecracker/refresh.sh runs it
# in the snapshot guest. Run as root: 03b-toolchain.sh [node-version], fxa main's
# .nvmrc when it is not given.
# Prints "node <version>", "claude <version>" and "codex <version>", and fails when one
# is not what was asked for.
set -euo pipefail

# The one pin for each runtime: manager.sh reads them for the manager, and refresh.sh
# for the snapshot (lib/claude-pin.check.sh).
CLAUDE_CODE_VERSION=2.1.296
CODEX_VERSION=0.162.1

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
