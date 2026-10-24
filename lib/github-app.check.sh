#!/usr/bin/env bash
# Offline check for the GitHub App commit path. The API is stubbed.
#   bash lib/github-app.check.sh
set -u
fail=0
check() { # check <name> <want> <got>
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi
}
tmp="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$tmp"' EXIT
here="$(cd "$(dirname "$0")" && pwd -P)"
eval "$(sed -n '/^github_app_commit() {/,/^}/p' "$here/github.sh")"
eval "$(grep -E '^(_gh_ref_enc|_gh_app_ref_is)\(\)' "$here/github.sh")"
# Stub: log each call, answer like GitHub. REMOTE_SHA plays the branch's current head.
_gh_app_api() {
  local body; body="$(cat)"; printf '%s %s %s\n' "$1" "$2" "$body" >> "$tmp/calls"
  case "$1 $2" in
    "POST git/blobs") echo '{"sha":"blob'"$(wc -l < "$tmp/calls" | tr -d ' ')"'"}' ;;
    "POST git/trees") echo '{"sha":"tree1"}' ;;
    "POST git/commits") echo '{"sha":"commit1"}' ;;
    GET*) [ -n "${REMOTE_SHA:-}" ] && echo '{"object":{"sha":"'"$REMOTE_SHA"'"}}' || return 22 ;;
    *) echo '{}' ;;
  esac
}
g() { git -c init.defaultBranch=main -c user.name=t -c user.email=t@example.com "$@"; }
g init -q "$tmp/r"; cd "$tmp/r"
echo a > a.txt; echo c > c.txt; printf '#!/bin/sh\n' > run.sh; g add . && g commit -qm base
base="$(git rev-parse HEAD)"
echo a2 > a.txt; git rm -q c.txt; echo d > d.txt; chmod +x run.sh; git add a.txt d.txt run.sh

out="$(github_app_commit "$tmp/r" fxa-1 "$base" "fix(x): y" 2>/dev/null)"
check "prints the new commit" "commit1" "$out"
tree="$(grep '^POST git/trees' "$tmp/calls" | cut -d' ' -f3-)"
check "tree sits on the parent's tree" "$(git rev-parse "${base}^{tree}")" "$(jq -r .base_tree <<< "$tree")"
check "tree entries" "a.txt:100644:blob,c.txt:100644:null,d.txt:100644:blob,run.sh:100755:blob" \
  "$(jq -r '[.tree[] | "\(.path):\(.mode):\(if .sha == null then "null" else "blob" end)"] | join(",")' <<< "$tree")"
check "blob holds the staged content" "a2" "$(grep '^POST git/blobs' "$tmp/calls" | head -1 | cut -d' ' -f3- | jq -r .content | base64 -d)"
check "commit has one parent and the message" "$base|fix(x): y" \
  "$(grep '^POST git/commits' "$tmp/calls" | cut -d' ' -f3- | jq -r '"\(.parents | join(","))|\(.message)"')"
check "a new branch is created" "refs/heads/fxa-1" "$(grep '^POST git/refs' "$tmp/calls" | cut -d' ' -f3- | jq -r .ref)"
: > "$tmp/calls"; github_app_commit "$tmp/r" fxa-9 "$base" "merge" abc123 >/dev/null 2>&1
check "a first parent makes a merge commit" "abc123,$base" "$(grep '^POST git/commits' "$tmp/calls" | cut -d' ' -f3- | jq -r '.parents | join(",")')"

# An existing branch that moved since our fetch is never overwritten.
: > "$tmp/calls"; git update-ref refs/remotes/origin/fxa-1 "$base"
REMOTE_SHA=0123456789abcdef github_app_commit "$tmp/r" fxa-1 "$base" "m" >/dev/null 2>&1
check "moved branch refused" "0" "$(grep -c '^PATCH' "$tmp/calls")"
: > "$tmp/calls"
REMOTE_SHA="$base" github_app_commit "$tmp/r" fxa-1 "$base" "m" >/dev/null 2>&1
check "expected branch is moved" "true" "$(grep '^PATCH git/refs/heads/fxa-1' "$tmp/calls" | cut -d' ' -f3- | jq -r .force)"
# A bot branch with '@': each path part is URL-encoded, the slashes kept.
: > "$tmp/calls"; git update-ref "refs/remotes/origin/blender/a@b" "$base"
REMOTE_SHA="$base" github_app_commit "$tmp/r" "blender/a@b" "$base" "m" >/dev/null 2>&1
check "the ref paths of a branch with '@' are encoded" "GET git/ref/heads/blender/a%40b|PATCH git/refs/heads/blender/a%40b" \
  "$(grep -E '^(GET|PATCH) git/ref' "$tmp/calls" | cut -d' ' -f1-2 | paste -sd'|' -)"

# A person pushed to the branch: this change is rebuilt on top of their commit.
eval "$(sed -n '/^_gh_app_rebuild() {/,/^}/p' "$here/github.sh")"
_retry() { "$@"; }
g init -q --bare "$tmp/origin.git"; git remote add origin "$tmp/origin.git"
g clone -q "$tmp/origin.git" "$tmp/them" 2>/dev/null; git push -q origin "$base:refs/heads/fxa-2"
( cd "$tmp/them" && g fetch -q origin && g checkout -q -b fxa-2 origin/fxa-2 && echo b > b.txt && g add b.txt && g commit -qm theirs && g push -q origin fxa-2 )
theirs="$(git -C "$tmp/them" rev-parse HEAD)"
git update-ref refs/remotes/origin/fxa-2 "$base"
: > "$tmp/calls"
REMOTE_SHA="$theirs" github_app_commit "$tmp/r" fxa-2 "$base" "m" >/dev/null 2>&1
check "rebuilt commit sits on their commit" "$theirs" "$(grep '^POST git/commits' "$tmp/calls" | tail -1 | cut -d' ' -f3- | jq -r '.parents | join(",")')"
check "rebuilt tree sits on their tree" "$(git -C "$tmp/them" rev-parse "${theirs}^{tree}")" "$(grep '^POST git/trees' "$tmp/calls" | tail -1 | cut -d' ' -f3- | jq -r .base_tree)"
check "their file is kept, ours are sent" "a.txt,c.txt,d.txt,run.sh" "$(grep '^POST git/trees' "$tmp/calls" | tail -1 | cut -d' ' -f3- | jq -r '[.tree[].path] | join(",")')"
check "the branch moves once" "1" "$(grep -c '^PATCH git/refs/heads/fxa-2' "$tmp/calls")"

# Their commit changes the same line as ours: refused, nothing moves.
( cd "$tmp/them" && echo a3 > a.txt && g commit -qam clash && g push -q origin fxa-2 )
git fetch -q origin fxa-2; git update-ref refs/remotes/origin/fxa-2 "$theirs"; git reset -q --soft "$base"
git read-tree "$(git -C "$tmp/r" rev-parse "${base}^{tree}")"; echo a2 > a.txt; git add a.txt
: > "$tmp/calls"
err="$(REMOTE_SHA="$(git -C "$tmp/them" rev-parse HEAD)" github_app_commit "$tmp/r" fxa-2 "$base" "m" 2>&1 >/dev/null)"
check "a clash is refused" "0" "$(grep -c '^PATCH' "$tmp/calls")"
check "a clash says how to recover" "1" "$(grep -c 'conflict with this change.*!restart' <<< "$err")"

# Media goes to the bucket: references rewritten in place, the rest appended.
eval "$(sed -n '/^_finish_media_to_bucket() {/,/^}/p' "$here/finish.sh")"
eval "$(sed -n '/^slot_write() /p' "$here/worktree.sh")"
gcloud() { printf '%s\n' "$*" >> "$tmp/gcloud"; }
FXA_MEDIA_BUCKET=b branch=fxa-1
mkdir -p "$tmp/m"; : > "$tmp/m/shot.png"; : > "$tmp/m/other.png"; : > "$tmp/m/run.mp4"
printf 'Before ![x](./shot.png) after\n' > "$tmp/body.md"
arr=(--attach "$tmp/m/shot.png" --attach "$tmp/m/other.png" --attach "$tmp/m/run.mp4")
md="$(_finish_media_to_bucket "$tmp/body.md" arr)"
check "three uploads" "3" "$(grep -c '^storage cp' "$tmp/gcloud")"
check "reference rewritten in place" "1" "$(grep -cE '^Before !\[x\]\(https://storage.googleapis.com/b/fxa-1/[0-9a-f]{16}/1/shot.png\) after$' "$tmp/body.md")"
check "unreferenced image appended" "1" "$(grep -cE '^!\[other.png\]\(https://storage.googleapis.com/b/.*/2/other.png\)$' "$tmp/body.md")"
check "video appended as a link" "1" "$(grep -cE '^\[run.mp4\]\(https://.*/3/run.mp4\)$' "$tmp/body.md")"
check "markdown lists all three" "3" "$(printf '%s\n' "$md" | grep -c 'storage.googleapis.com')"

# The App token is limited to the work repo, from that repo's own installation.
( eval "$(sed -n '/^_gh_jwt_conf() {/p;/^github_app_token() {/,/^}/p;/^_gh_app_installation() {/,/^}/p;/^_gh_claimed() {/,/^}/p' "$here/github.sh")"
  export TMPDIR="$tmp/tok"; mkdir -p "$TMPDIR"; GITHUB_APP_INSTALLATION_ID=111
  github_app_jwt() { echo jwt; }; _mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"; }
  curl() { local url="${*: -1}" body=""; while [ $# -gt 0 ]; do [ "$1" = -d ] && body="$2"; shift; done
    echo "$url $body" >> "$tmp/curls"
    case "$url" in */repos/mdn/rari/installation) echo '{"id":222}' ;; */installation) return 22 ;; */access_tokens) echo '{"token":"t-'"${url//[^0-9]/}"'"}' ;; esac; }
  : > "$tmp/curls"
  t1="$(PIPE_REPO_SLUG=mdn/rari github_app_token)"
  check "the token is minted on the repo's installation, for that repo only" "t-222|1" \
    "$t1|$(grep -c '/app/installations/222/access_tokens {"repositories":\["rari"\]}' "$tmp/curls")"
  t2="$(PIPE_REPO_SLUG=mozilla/fxa github_app_token)"
  check "an unknown installation falls back to the configured one" "t-111" "$t2"
  : > "$tmp/curls"; PIPE_REPO_SLUG=mdn/rari github_app_token >/dev/null; PIPE_REPO_SLUG=mozilla/fxa github_app_token >/dev/null
  check "each repo's token is cached on its own" "0" "$(grep -c access_tokens "$tmp/curls")"
  # A repo the installation does not cover: GitHub refuses, and curl -f exits 22.
  curl() { case "${*: -1}" in */access_tokens) return 22 ;; */installation) return 22 ;; esac; }
  # The controller's ERR trap (lib/errors.sh) skips a `return`; any other failing command is a crash.
  out="$( (set -eE; trap 'echo "TRAPPED $BASH_COMMAND"' ERR; PIPE_REPO_SLUG=mozilla-services/syncstorage-rs github_app_token) 2>&1)"; rc=$?
  check "a refused mint is a handled failure with its own line, not a crash" "1|ERROR: could not mint a GitHub App installation token for syncstorage-rs.|0" \
    "$rc|$(grep -v '^TRAPPED' <<< "$out")|$(grep '^TRAPPED' <<< "$out" | grep -vc '^TRAPPED return')"
  # A team mints only for a repo it claims as a work row; a team with no rows keeps its one repo.
  curl() { case "${*: -1}" in */installation) return 22 ;; */access_tokens) echo '{"token":"t-ok"}' ;; esac; }
  rm -rf "$TMPDIR"; mkdir -p "$TMPDIR"
  check "a claimed repo mints; an unclaimed one is refused with a reason" "t-ok|1|1" \
    "$(PIPE_WORK_ROWS=("mozilla/fxa /home/agent/fxa"); PIPE_REPO_SLUG=Mozilla/FXA github_app_token)|$(PIPE_WORK_ROWS=("mozilla/fxa /home/agent/fxa"); PIPE_PROFILE=t PIPE_REPO_SLUG=evil/repo github_app_token >/dev/null 2>&1; echo $?)|$(PIPE_WORK_ROWS=("mozilla/fxa /home/agent/fxa"); PIPE_PROFILE=t PIPE_REPO_SLUG=evil/repo github_app_token 2>&1 | grep -c 'does not claim evil/repo')"
  exit "$fail" ) || fail=1

# A read-only profile's gh wrapper asks for no App token at all.
mkdir -p "$tmp/bin"; printf '#!/bin/sh\necho "$@" >> "%s/curl-calls"\necho "{\\"id\\":1,\\"token\\":\\"t\\"}"\n' "$tmp" > "$tmp/bin/curl"; chmod +x "$tmp/bin/curl"
app_token() { PATH="$tmp/bin:$PATH" TMPDIR="$tmp/at" GITHUB_APP_ID=1 GITHUB_APP_PEM="$tmp/no.pem" GITHUB_APP_INSTALLATION_ID=111 \
  "$here/../fxa-sandbox-ctl" --pipeline "$1" app-token 2>/dev/null; }
mkdir -p "$tmp/at"; : > "$tmp/curl-calls"
check "app-token for a read-only profile prints nothing and calls no GitHub API" "|0" "$(app_token sync-storage)|$(grep -c api.github.com "$tmp/curl-calls")"
: > "$tmp/curl-calls"; app_token fxa-ai-fixme >/dev/null
check "app-token for a PR profile still asks GitHub" "1" "$([ -s "$tmp/curl-calls" ] && echo 1 || echo 0)"


# The git credential helper: a read-only token for the asked repo; nothing for another host or op.
( eval "$(sed -n '/^_gh_jwt_conf() {/p;/^github_read_token() {/,/^}/p;/^github_git_credential() {/,/^}/p;/^_gh_app_installation() {/,/^}/p' "$here/github.sh")"
  export TMPDIR="$tmp/cred"; mkdir -p "$TMPDIR"; GITHUB_APP_INSTALLATION_ID=111 GITHUB_APP_ID=1 GITHUB_APP_PEM=k
  github_app_enabled() { true; }; github_app_jwt() { echo jwt; }; _mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"; }
  curl() { local url="${*: -1}" body=""; while [ $# -gt 0 ]; do [ "$1" = -d ] && body="$2"; shift; done
    echo "$url $body" >> "$tmp/ccurls"
    case "$url" in */repos/mozilla/fxa-private/installation) echo '{"id":333}' ;; */installation) return 22 ;; */333/access_tokens) echo '{"token":"t-read"}' ;; *) return 22 ;; esac; }
  : > "$tmp/ccurls"
  out="$(printf 'protocol=https\nhost=github.com\npath=mozilla/fxa-private.git\n\n' | github_git_credential get)"
  check "the helper answers with a token that reads only the asked repo" "username=x-access-token password=t-read|1" \
    "$(tr '\n' ' ' <<< "$out" | sed 's/ $//')|$(grep -c '/app/installations/333/access_tokens {"repositories":\["fxa-private"\],"permissions":{"contents":"read"}}' "$tmp/ccurls")"
  check "nothing for another host, a repo the App lacks, or a store" "||" \
    "$(printf 'host=gitlab.com\npath=a/b\n\n' | github_git_credential get)|$(printf 'host=github.com\npath=evil/repo.git\n\n' | github_git_credential get)|$(printf 'host=github.com\npassword=x\n\n' | github_git_credential store)"
  exit "$fail" ) || fail=1


# A repo is private when an anonymous read gets 404 or no clear answer. A clear answer is cached for a day.
( eval "$(sed -n '/^github_repo_private() {/,/^}/p' "$here/github.sh")"
  export TMPDIR="$tmp/vis"; mkdir -p "$TMPDIR"; _mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"; }
  curl() { echo "${*: -1}" >> "$tmp/vcurls"; case "${*: -1}" in */a/priv) echo 404 ;; */a/pub) echo 200 ;; *) echo 502 ;; esac; }
  r() { github_repo_private "$1" && echo y || echo n; }
  check "private on 404 or an unclear answer, public only on 200" "y n y" "$(r a/priv) $(r a/pub) $(r a/flaky)"
  : > "$tmp/vcurls"; r a/priv >/dev/null; r a/pub >/dev/null
  check "a known answer is cached, an error is asked again" "0 1" "$(grep -c . "$tmp/vcurls") $(r a/flaky >/dev/null; grep -c . "$tmp/vcurls")"
  exit "$fail" ) || fail=1

[ "$fail" = 0 ] && echo "all ok"
exit "$fail"
