#!/usr/bin/env bash
# eval-install.sh: an installed FxA checkout at one base commit, for local evals, so the
# agent can run tests. Prints its folder. Made once per base, in ~/.cache/fxa-eval/<base>.
#
#   eval-install.sh <base sha>
#
# It starts as a clean checkout of the base with node_modules copied copy-on-write (APFS
# cp -c: no extra disk) from the nearest install: an earlier base, else FXA_CLONE. Then it
# installs with the Node version in .nvmrc (only what changed), builds the workspace
# packages as the runner image does, and hides every
# ref past the base: only origin/main, at the base, and no remote. The objects of newer
# commits stay in .git, as on a pinned runner.
# Each run copies this folder again (agent-try.sh --base), so runs never share files.
set -euo pipefail
base="${1:?usage: eval-install.sh <base sha>}"
[[ "$base" =~ ^[0-9a-f]{40}$ ]] || { echo "eval-install.sh: give a full commit sha" >&2; exit 2; }
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FXA="${FXA_CLONE:-$ROOT/../fxa}" CACHE="${FXA_EVAL_CACHE:-$HOME/.cache/fxa-eval}"
dir="$CACHE/$base"
# build: every workspace package built, as the runner image does (packer/scripts/11-gce-clone.sh),
# so a test that imports fxa-shared or a lib loads. Like the image, a failed package is not fatal.
build() {
  [ -f "$dir.built" ] && return 0
  echo "== building the workspace packages for ${base:0:10} (once per base)" >&2
  # shellcheck source=/dev/null
  export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"; . "$NVM_DIR/nvm.sh"
  # The l10n-prime targets need the translations cloned first, as the image does.
  ( cd "$dir" && { [ -d external/l10n ] || nvm exec "$(cat .nvmrc)" yarn l10n:clone; } \
      && nvm exec "$(cat .nvmrc)" npx nx run-many -t build --all --exclude=fxa-dev-launcher ) > "$dir.build.log" 2>&1 \
    || echo "eval-install.sh: some packages did not build; see $dir.build.log" >&2
  touch "$dir.built"
}
[ -f "$dir.ready" ] && { build; echo "$dir"; exit 0; }
mkdir -p "$CACHE"

# The seed: the newest ready base, else the operator's clone (with its install).
seed="$(ls -t "$CACHE"/*.ready 2>/dev/null | head -1 | sed 's/\.ready$//' || true)"
seed="${seed:-$FXA}"
[ -d "$seed/node_modules" ] || echo "eval-install.sh: $seed has no node_modules; the first install downloads everything" >&2
git -C "$FXA" cat-file -e "${base}^{commit}" 2>/dev/null || git -C "$FXA" fetch -q origin "$base"
rm -rf "$dir.tmp"
# A clean checkout, then only the seed's node_modules folders (the root's and each
# package's), copy-on-write. A whole working tree carries caches (.nx) not worth copying.
git clone -q --shared --no-checkout --single-branch --no-tags "$FXA" "$dir.tmp"
cd "$dir.tmp"
git checkout -q --detach "$base"
echo "== copying node_modules from $seed (copy-on-write)" >&2
( cd "$seed" && find . \( -path ./.git -o -path ./.nx -o -path '*/node_modules/*' \) -prune -o -type d -name node_modules -print ) \
  | while IFS= read -r nm; do mkdir -p "$(dirname "$nm")" && cp -c -R "$seed/$nm" "$nm"; done

echo "== installing for ${base:0:10} with Node $(cat .nvmrc)" >&2
# shellcheck source=/dev/null
export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"; . "$NVM_DIR/nvm.sh"
nvm install "$(cat .nvmrc)" >/dev/null
nvm exec "$(cat .nvmrc)" corepack enable >/dev/null 2>&1 || true
nvm exec "$(cat .nvmrc)" yarn install --immutable > "$dir.install.log" 2>&1 \
  || { echo "eval-install.sh: yarn install failed; see $dir.install.log" >&2; exit 1; }

# One ref, origin/main at the base, and no remote. Whole ref folders go at once:
# a batch delete fails on macOS when two refs differ only in case.
gd="$(git rev-parse --git-dir)"
rm -rf "$gd/refs/remotes" "$gd/refs/tags" "$gd/packed-refs" "$gd/FETCH_HEAD" "$gd/ORIG_HEAD"
find "$gd/refs/heads" -type f -delete 2>/dev/null || true
git update-ref refs/remotes/origin/main "$base"
git remote set-url origin "no-fetch://eval"
git reflog expire --expire=now --all
cd /; mv "$dir.tmp" "$dir"; touch "$dir.ready"
build
echo "$dir"
