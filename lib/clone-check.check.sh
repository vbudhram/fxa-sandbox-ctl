#!/usr/bin/env bash
# Offline check that the runner's clone steps fail and name a repo that did not clone, in place of a WARN
# (the profile workspace) or a 600 s pin timeout (a team stack).
#   bash lib/clone-check.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
tmp="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$tmp"' EXIT; here="$(cd "$(dirname "$0")" && pwd)"
eval "$(sed -n '/^_gce_profile_workspace() {/,/^}/p' "$here/agent.sh")"
eval "$(sed -n '/^_trees_line_ok() {/,/^}/p;/^_trees_workspace() {/,/^}/p' "$here/trees.sh")"
_clone_filter() { :; }
# The remote command runs here: /home/agent is the temp dir; sudo runs the command; a clone of a repo
# named bad-* fails, any other makes its .git.
mkdir -p "$tmp/bin" "$tmp/home"
printf '#!/bin/sh\nwhile [ $# -gt 0 ]; do case "$1" in -u) shift 2 ;; env) shift; while [ $# -gt 0 ] && [ "$1" != git ]; do shift; done ;; *) break ;; esac; done\nexec "$@"\n' > "$tmp/bin/sudo"
printf '#!/bin/sh\n[ "$1" = clone ] || exit 0\nfor a; do d="$a"; done\ncase "$*" in *bad-*) echo "fatal: repository not found" >&2; exit 128 ;; esac\nmkdir -p "$d/.git"\n' > "$tmp/bin/git"
printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/ln"; printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/chown"; chmod +x "$tmp/bin/"*
vm_exec() { shift; [ "$1" = sudo ] && shift; [ "$1" = bash ] && [ "$2" = -c ] || return 9; PATH="$tmp/bin:$PATH" bash -c "${3//\/home\/agent/$tmp/home}"; }
PIPE_WORKSPACE=/home/agent/work PIPE_REPO_SLUG=org/work
PIPE_REPOS=("org/work /home/agent/work work" "org/bad-dep /home/agent/dep dep" "org/data /home/agent/data data")
out="$(_gce_profile_workspace r1 2>&1)"; rc=$?
check "a dep that did not clone fails the step and names it" "1|1" "$rc|$(grep -c 'did not clone: .*/home/dep' <<< "$out")"
rm -rf "$tmp/home"/*; PIPE_REPOS=("org/work /home/agent/work work" "org/dep /home/agent/dep dep")
_gce_profile_workspace r1 >/dev/null 2>&1; check "every repo cloned: the step passes" "0" "$?"
TREES_ROOT="$tmp/home/stack"; mkdir -p "$TREES_ROOT"; z=0000000000000000000000000000000000000000
printf 'a\torg/a\t/home/agent/a\t%s\tmain\t%s\tb1\nb\torg/bad-b\t/home/agent/b\t%s\tmain\t%s\tb2\n' $z $z $z $z > "$tmp/trees.tsv"
out="$(_trees_workspace r1 "$tmp/trees.tsv" 2>&1)"; rc=$?
check "a stack tree that did not clone fails at once and names it" "1|1" "$rc|$(grep -c 'did not clone: .*/home/b' <<< "$out")"
[ "$fail" = 0 ] && echo "all checks pass"
exit "$fail"
