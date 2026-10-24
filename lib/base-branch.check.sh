#!/usr/bin/env bash
# Offline check for a repo whose default branch is not main (syncstorage-rs uses master): the
# session fetches the profile's base, and the runner gets origin/main as an alias of it.
#   bash lib/base-branch.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
here="$(cd "$(dirname "$0")" && pwd)"
# Out of the repo: a mounted checkout reads as dubious ownership to git in the Linux test run.
cd "$tmp"
eval "$(sed -n '/^_gce_pin_runner_tree() {/,/^}/p' "$here/agent.sh")"
# The runner: the pin's one command goes to a file, and the runner answers with the pinned sha.
vm_exec() { shift; case "$1" in test) return 0 ;; esac; printf '%s\n' "$*" > "$tmp/pin.cmd"; echo "$FXA_PIN_SHA"; }
LOG_DIR="$tmp"; S=1111111111111111111111111111111111111111 B=2222222222222222222222222222222222222222
pin() { FXA_WORKTREE_BASE="$1" FXA_PIN_SHA="$S" FXA_PIN_BASE_SHA="$B" FXA_PIN_BRANCH=agent-x _gce_pin_runner_tree r1 "$tmp" >/dev/null; }
pin master
check "a master base moves origin/master, and makes origin/main its alias when the repo has none" "1|1" \
  "$(grep -c "update-ref refs/remotes/origin/master $B" "$tmp/pin.cmd")|$(grep -c "\[ 'master' = main \] || git rev-parse -q --verify refs/remotes/origin/main >/dev/null || git update-ref refs/remotes/origin/main $B" "$tmp/pin.cmd")"
# The alias line, run in a real clone: it adds origin/main only where it is missing.
g() { git -c user.name=t -c user.email=t@example.com "$@"; }
r="$tmp/repo"; git init -q "$r"; g -C "$r" commit -q --allow-empty -m one; b1="$(git -C "$r" rev-parse HEAD)"
git -C "$r" update-ref refs/remotes/origin/master "$b1"
alias_line="$(grep -o "\[ 'master' = main \] ||.*" <<< "$(pin master; cat "$tmp/pin.cmd")" | head -1 | sed "s/$B/$b1/")"
( cd "$r" && eval "$alias_line" )
check "in a clone with no origin/main, the alias points at the base" "$b1" "$(git -C "$r" rev-parse -q --verify refs/remotes/origin/main)"
g -C "$r" commit -q --allow-empty -m two; b2="$(git -C "$r" rev-parse HEAD)"; git -C "$r" update-ref refs/remotes/origin/main "$b2"
( cd "$r" && eval "$alias_line" )
check "a real origin/main is left alone" "$b2" "$(git -C "$r" rev-parse refs/remotes/origin/main)"
r2="$tmp/repo2"; git init -q "$r2"; g -C "$r2" commit -q --allow-empty -m one
main_line="$(grep -o "\[ 'main' = main \] ||.*" <<< "$(pin main; cat "$tmp/pin.cmd")" | head -1 | sed "s/$B/$(git -C "$r2" rev-parse HEAD)/")"
( cd "$r2" && eval "$main_line" )
check "a main base makes no alias" "none" "$(git -C "$r2" rev-parse -q --verify refs/remotes/origin/main || echo none)"
check "the session fetches the profile's base, not main" "1|0" \
  "$(grep -c 'fetch --quiet origin "\$base"' "$here/../fxa-sandbox-ctl")|$(grep -c 'fetch --quiet origin main &&' "$here/../fxa-sandbox-ctl")"
# A private fork at the image's FxA path: the fetch goes to the fork, not the image clone's public origin.
PIPE_REPO_SLUG=mozilla/fxa-private pin main
check "the pin points origin at the tree's repo before it fetches" "1" "$(grep -c 'cd /workspace && old=\$(git rev-parse HEAD) && git remote set-url origin https://github.com/mozilla/fxa-private.git && { git cat-file' "$tmp/pin.cmd")"
FXA_WORKTREE_BASE=main FXA_PIN_SHA="$S" FXA_PIN_BRANCH='a;id' _gce_pin_runner_tree r1 "$tmp" >/dev/null 2>&1
check "the branch reaches the remote shell quoted" "1" "$(grep -cF "git checkout --quiet -B a\;id $S" "$tmp/pin.cmd")"
check "a slug that is not plain refuses the pin" "1" "$(PIPE_REPO_SLUG='a/b;x' FXA_WORKTREE_BASE=main FXA_PIN_SHA="$S" FXA_PIN_BRANCH=agent-x _gce_pin_runner_tree r1 "$tmp" 2>&1 | grep -c 'not a plain slug')"
# The libs build at the pin runs only when the pin changes libs/ or yarn.lock against the snapshot's commit.
guard="$(grep -o '! git diff --quiet "\$old" HEAD -- libs/ yarn.lock 2>/dev/null' "$tmp/pin.cmd" | head -1)"
lr="$tmp/libs"; git init -q "$lr"; mkdir -p "$lr/libs" && echo a > "$lr/libs/a" && g -C "$lr" add -A && g -C "$lr" commit -q -m one
o1="$(git -C "$lr" rev-parse HEAD)"; echo r > "$lr/README" && g -C "$lr" add -A && g -C "$lr" commit -q -m docs
same="$(cd "$lr" && old="$o1" && eval "$guard" && echo build || echo skip)"
echo b > "$lr/libs/a" && g -C "$lr" commit -qam lib
moved="$(cd "$lr" && old="$o1" && eval "$guard" && echo build || echo skip)"
gone="$(cd "$lr" && old=0000000000000000000000000000000000000000 && eval "$guard" && echo build || echo skip)"
check "the pin skips the libs build when no lib moved, builds when one did or the old commit is unknown" "skip|build|build" "$same|$moved|$gone"
# The pinned order on a real clone: a set-url then a fetch from that remote reaches a commit the old origin lacks.
pub="$tmp/pub"; priv="$tmp/priv"; git init -q "$pub"; g -C "$pub" commit -q --allow-empty -m pub
git clone -q "$pub" "$priv"; g -C "$priv" commit -q --allow-empty -m secret; ps="$(git -C "$priv" rev-parse HEAD)"
git clone -q "$pub" "$tmp/runner"
( cd "$tmp/runner" && git remote set-url origin "$priv" && { git cat-file -e "${ps}^{commit}" 2>/dev/null || git fetch --quiet origin "$ps"; } ) 2>/dev/null
check "on a clone of the public repo, the fork's commit arrives after the set-url" "commit" "$(git -C "$tmp/runner" cat-file -t "$ps" 2>/dev/null)"

# The libs content imports, from the Nx graph: transitive, with no npm packages and no content itself.
pin main; mkdir -p "$tmp/w/packages/fxa-content-server" "$tmp/bin"
echo '{"graph":{"nodes":{"fxa-content-server":{"data":{"root":"packages/fxa-content-server"}},"fxa-settings":{"data":{"root":"packages/fxa-settings"}},"shared-email":{"data":{"root":"libs/shared/email"}},"shared-log":{"data":{"root":"libs/shared/log"}},"shared-l10n":{"data":{"root":"libs/shared/l10n"}}},"dependencies":{"fxa-content-server":[{"target":"shared-email"},{"target":"npm:express"},{"target":"fxa-settings"}],"fxa-settings":[{"target":"shared-l10n"}],"shared-email":[{"target":"shared-log"}],"shared-log":[{"target":"shared-email"}]}}}' > "$tmp/graph.json"
cat > "$tmp/bin/npx" <<EOF2
#!/bin/sh
case "\$*" in *--file=*) cp "$tmp/graph.json" "\${3#--file=}" ;; *) echo "\$*" > "$tmp/npx.args" ;; esac
EOF2
chmod +x "$tmp/bin/npx"
libs_block="$(sed -n '/if \[ -d packages\/fxa-content-server \]/,/^    fi$/p' "$tmp/pin.cmd" | sed "s#/tmp/fxa-#$tmp/fxa-#g; s#source /etc/agent-env.sh#true#")"
( cd "$tmp/w" && PATH="$tmp/bin:$PATH" bash -c "$libs_block" )
check "the pin builds the libs content imports, transitively, once each, and no package" "nx run-many -t build -p shared-email,shared-log" "$(cat "$tmp/npx.args" 2>/dev/null)"
# A fix run (FXA_PIN_UNTRUSTED): no install, Nx or build of the PR head before the egress firewall.
FXA_PIN_UNTRUSTED=1 pin main
check "a fix run's pin runs no yarn install, npx or nx" "0|1" "$(grep -cE 'yarn install|npx|nx ' "$tmp/pin.cmd")|$(grep -c "git checkout --quiet -B agent-x $S" "$tmp/pin.cmd")"
pin main
check "another run's pin still installs and builds the libs" "1|1" "$(grep -c 'yarn install --immutable' "$tmp/pin.cmd")|$(grep -c 'nx run-many -t build' "$tmp/pin.cmd")"
check "the session boot marks a fix run's pin untrusted" "1" "$(grep -c 'FXA_PIN_UNTRUSTED="${fixh:+1}"' "$here/../fxa-sandbox-ctl")"
exit "$fail"
