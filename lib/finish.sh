#!/bin/bash
# finish.sh: host-side handoff. The agent writes the handoff file in the slot
# when it finishes its change; the host commits, pushes and opens the PR with
# its own credentials, because the VM cannot commit or reach GitHub.

[ -n "${_FXA_FINISH_LOADED:-}" ] && return 0
_FXA_FINISH_LOADED=1

FINISH_LIB_DIR="$(dirname "${BASH_SOURCE[0]}")"
source "${FINISH_LIB_DIR}/config.sh"
source "${FINISH_LIB_DIR}/worktree.sh"

: "${FXA_DONE_FILENAME:=.fxa-auto-done.json}"

# finish_done_file_path [worktree]
#   With no worktree, use the base slot, for callers that do not track a slot.
finish_done_file_path() {
  local worktree="${1:-}"
  if [ -z "$worktree" ]; then
    worktree="$(worktree_shared_path)" || return 1
  fi
  printf '%s/%s\n' "$worktree" "$FXA_DONE_FILENAME"
}

# finish_attach_and_wait <agent-name>
#   Attach to the agent's screen session in the foreground. A background poller
#   kills the SSH when the handoff appears. Returns 1 on a detach without one.
finish_attach_and_wait() {
  local name="${1:-}"
  if [ -z "$name" ]; then
    echo "ERROR: finish_attach_and_wait requires an agent name" >&2
    return 1
  fi

  local meta="${LOG_DIR}/${name}.meta"
  if [ ! -f "$meta" ]; then
    echo "ERROR: no metadata for agent '${name}'" >&2
    return 1
  fi

  local NAME WORKSPACE CPU MEMORY IP STARTED
  source "$meta"

  local ssh_key="${LOG_DIR}/ssh/${name}/id_ed25519"
  # This agent's slot, not the base one: agents run in parallel slots.
  local done_file
  done_file="$(finish_done_file_path "${WORKSPACE}")" || return 1

  # Without a TTY the TUI cannot render, so poll silently instead.
  if [ ! -t 0 ] || [ ! -t 1 ]; then
    echo "(no TTY — polling silently for handoff. Attach live with: fxa-sandbox-ctl attach ${name})" >&2
    finish_wait_for_done "${WORKSPACE}"
    return $?
  fi

  echo "" >&2
  echo "=== attaching to Claude TUI on ${IP} ===" >&2
  echo "Ctrl-C detaches the watcher (the agent keeps running)." >&2
  echo "Resume later with: fxa-sandbox-ctl finish" >&2
  echo "" >&2

  (
    local elapsed=0
    while [ "$elapsed" -lt 7200 ]; do
      if [ -s "$done_file" ] && jq -e . "$done_file" >/dev/null 2>&1; then
        pkill -f "ssh.*${IP}.*screen -x ${VM_SCREEN_SESSION}" 2>/dev/null || true
        exit 0
      fi
      sleep 3
      elapsed=$(( elapsed + 3 ))
    done
  ) &
  local poller_pid=$!
  trap 'kill "$poller_pid" 2>/dev/null; trap - INT TERM EXIT' INT TERM EXIT

  # `screen -x` is multi-attach, so a separate `fxa-sandbox-ctl attach` still works.
  ssh -t -i "${ssh_key}" ${VM_SSH_OPTS} "${VM_SSH_USER}@${IP}" \
    "screen -x ${VM_SCREEN_SESSION} || screen -S ${VM_SCREEN_SESSION}" || true

  kill "$poller_pid" 2>/dev/null
  trap - INT TERM EXIT

  if [ -s "$done_file" ] && jq -e . "$done_file" >/dev/null 2>&1; then
    echo "" >&2
    echo "=== handoff file detected ===" >&2
    return 0
  fi
  echo "" >&2
  echo "Detached without handoff. Agent still running." >&2
  return 1
}

# _handoff_settled <worktree> <handoff_file>
#   A handoff can appear before the work it names, so ready means parseable JSON
#   plus work to ship. Anything else means "not yet" and the watcher polls on.
_handoff_settled() {
  local wt="$1" f="$2"
  # gce: check for the one file before a full-tree pull, which starves the runner's tests.
  if [ "${FXA_VM_BACKEND:-tart}" = "gce" ] && [ ! -s "$f" ]; then
    local name; name="$(_worktree_agent_for_workspace "$wt")"
    [ -n "$name" ] && vm_exec "$name" test -s "/workspace/$(basename "$f")" 2>/dev/null || return 1
  fi
  _worktree_pull_if_remote "$wt"
  [ -s "$f" ] && jq -e . "$f" >/dev/null 2>&1 || return 1
  # Uncommitted changes are the normal case: the agent cannot commit.
  [ -n "$(worktree_filtered_status "$wt")" ] && return 0
  [ "$(git -C "$wt" rev-list --count "origin/${FXA_WORKTREE_BASE:-main}..HEAD" 2>/dev/null || echo 0)" != "0" ]
}

# _finish_fetch_session_log <worktree>
#   gce only. Copy the agent's session transcript into the slot before the
#   runner goes. Telemetry prices from it: the stream log's output tokens are near zero.
_finish_fetch_session_log() {
  local wt="$1"
  [ "${FXA_VM_BACKEND:-tart}" = "gce" ] || return 0
  local name; name="$(_worktree_agent_for_workspace "$wt")"
  # The meta lookup can miss; the agent name is the slot's branch name by construction.
  [ -n "$name" ] || name="$(git -C "$wt" branch --show-current 2>/dev/null)"
  [ -n "$name" ] && vm_is_running "$name" 2>/dev/null \
    || { echo "WARN: no running agent found for ${wt}; session transcript not fetched, telemetry will undercount output tokens." >&2; return 0; }
  # Claude Code and Codex keep session logs in different trees; take the newest of either.
  vm_exec "$name" bash -c 'f=$(ls -t /home/agent/.claude/projects/*/*.jsonl /home/agent/.codex/sessions/*/*/*/*.jsonl 2>/dev/null | head -1); [ -n "$f" ] && cat "$f"' \
    2>/dev/null | slot_write "${wt}/.fxa-auto-session.jsonl.tmp" \
    && [ -s "${wt}/.fxa-auto-session.jsonl.tmp" ] \
    && mv "${wt}/.fxa-auto-session.jsonl.tmp" "${wt}/.fxa-auto-session.jsonl" \
    || { rm -f "${wt}/.fxa-auto-session.jsonl.tmp"; echo "WARN: could not fetch the session transcript from ${name}; telemetry will undercount output tokens." >&2; }
}

# finish_wait_for_done [worktree] [timeout_seconds]
#   Poll for a settled handoff, default 2 hours. With no worktree, scan every pool slot.
finish_wait_for_done() {
  local worktree="${1:-}"
  local timeout="${2:-7200}"

  local done_file=""
  if [ -n "$worktree" ]; then
    done_file="$(finish_done_file_path "$worktree")" || return 1
  fi

  local started elapsed=0
  started="$(date +%s)"

  if [ -n "$done_file" ]; then
    echo "Watching for ${done_file}" >&2
  else
    echo "Watching every pool slot for a handoff file..." >&2
  fi
  echo "(Ctrl-C stops the watcher; the agent keeps running.)" >&2

  local wt found
  while [ "$elapsed" -lt "$timeout" ]; do
    found=""
    if [ -n "$done_file" ]; then
      if _handoff_settled "$(dirname "$done_file")" "$done_file"; then
        found="$done_file"
      fi
    else
      while IFS= read -r wt; do
        [ -z "$wt" ] && continue
        if _handoff_settled "$wt" "${wt}/${FXA_DONE_FILENAME}"; then
          found="${wt}/${FXA_DONE_FILENAME}"
          break
        fi
      done < <(_worktree_pool_list)
    fi
    if [ -n "$found" ]; then
      echo "" >&2
      echo "=== handoff file detected: ${found} ===" >&2
      _finish_fetch_session_log "$(dirname "$found")"
      return 0
    fi
    sleep 5
    elapsed=$(( $(date +%s) - started ))
    if [ $(( elapsed % 30 )) -eq 0 ]; then
      printf '[%4ds] ' "$elapsed" >&2
    fi
  done

  echo "" >&2
  echo "ERROR: timed out after ${timeout}s waiting for handoff file." >&2
  return 1
}

# A failed re-commit is more often the hook than signing, so name the hook first.
_finish_recommit_failed() {
  echo "ERROR: re-commit failed. The pre-commit hook rejects the diff, or signing failed." >&2
  echo "       Read the hook output above first: 'yarn check:frozen' refuses edits to" >&2
  echo "       frozen paths, and lint-staged fails on lint errors." >&2
  echo "       If the hook output is clean, check 'git config commit.gpgsign' and that" >&2
  echo "       your signing key is unlocked." >&2
}

# _finish_release_runner <worktree>
#   gce only. Nothing reads the runner after the push, and it bills by the hour.
#   A feedback round boots a fresh one. Tart keeps its VM, which costs nothing.
_finish_release_runner() {
  [ "${FXA_VM_BACKEND:-tart}" = "gce" ] || return 0
  local name; name="$(_worktree_agent_for_workspace "$1")"
  [ -n "$name" ] || return 0
  echo "Releasing runner '${name}': the PR is open and the branch is on origin." >&2
  agent_stop "$name" >&2 || echo "WARN: could not delete runner '${name}'; it is still billing. Run: fxa-sandbox-ctl --backend gce stop ${name}" >&2
}

# _finish_claim <worktree> / _finish_release <worktree>
#   Mark the slot so readers skip it: a `git status` mid-commit breaks the index write.
_finish_claim()   { : > "${LOG_DIR}/$(basename "$1").finishing"; }
_finish_release() { rm -f "${LOG_DIR}/$(basename "$1").finishing"; }

# media_mp4 <video>   Write <video>.mp4 next to it: H.264 plays in every browser and in Slack, where
# WebM does not (iOS not at all). The scale keeps both sides even, as x264 needs.
media_mp4() {
  command -v ffmpeg >/dev/null 2>&1 || return 1
  ffmpeg -nostdin -y -loglevel error -i "$1" -map_metadata -1 -c:v libx264 -pix_fmt yuv420p -movflags +faststart \
    -vf 'scale=trunc(iw/2)*2:trunc(ih/2)*2' -an "${1%.*}.mp4"
}

# _finish_bucket_cp <file> <object>   Upload one file; print its public URL.
_finish_bucket_cp() {
  local err; err="$(gcloud storage cp -q "$1" "gs://${FXA_MEDIA_BUCKET}/$2" --cache-control="public, max-age=3600" 2>&1 >/dev/null)" \
    || { echo "  WARN: could not upload $(basename "$1") to the media bucket: $(printf '%s' "$err" | grep -m1 ERROR | cut -c1-200)" >&2; return 1; }
  echo "https://storage.googleapis.com/${FXA_MEDIA_BUCKET}/$2"
}

# _finish_media_to_bucket <body_file> <array-name>
#   The App cannot upload GitHub attachments, so upload to the public bucket at
#   an unguessable path and rewrite the body. Prints the Markdown for all files.
#   GitHub plays no video from outside its own uploads, so a video shows as a still frame that links to its MP4.
# _finish_play_frame <video> <png>   A still frame of the video, 480 px wide, with a white play triangle on a dark disc in
# its center: GitHub strips CSS, so the overlay that tells a reader "this is a video" is drawn into the picture.
_finish_play_frame() {
  local in='lte(hypot(X-W/2,Y-H/2),40)' tri='gte(X,W/2-14)*lte(X,W/2+22)*lte(abs(Y-H/2),(W/2+22-X)*0.62)' c q=""
  for c in r g b; do q="${q}${q:+:}${c}='if(${in},if(${tri},255,${c}(X,Y)*0.35),${c}(X,Y))'"; done
  ffmpeg -nostdin -y -loglevel error -i "$1" -vf "thumbnail,scale=480:-2,format=rgb24,geq=${q}" -frames:v 1 "$2"
}

_finish_media_to_bucket() {
  local body_file="$1" _media_arr="$2" f orig name url furl link dir md="" n=0 files=()
  eval "files=(\${${_media_arr}[@]+\"\${${_media_arr}[@]}\"})"
  dir="${branch:-media}/$(openssl rand -hex 8)"
  for f in ${files[@]+"${files[@]}"}; do
    [ "$f" = --attach ] && continue
    orig="$(basename "$f")"; furl=""
    case "$f" in *.webm|*.mov) media_mp4 "$f" && f="${f%.*}.mp4" ;; esac
    name="$(basename "$f" | tr -c 'A-Za-z0-9._\n-' '-')"; n=$((n + 1))
    url="$(_finish_bucket_cp "$f" "${dir}/${n}/${name}")" || continue
    case "$name" in
      *.mp4|*.webm|*.mov)
        command -v ffmpeg >/dev/null 2>&1 && _finish_play_frame "$f" "${f%.*}.png" \
          && furl="$(_finish_bucket_cp "${f%.*}.png" "${dir}/${n}/${name%.*}.png")"
        if [ -n "$furl" ]; then link="<a href=\"${url}\"><img src=\"${furl}\" width=\"480\" alt=\"${name} (video: click to play)\"></a>"
        else link="[${name}](${url})"; fi ;;
      # 480 px wide in the body: a full-size screenshot pushed the PR text out of view. The link opens the full size.
      *) link="<a href=\"${url}\"><img src=\"${url}\" width=\"480\" alt=\"${name}\"></a>" ;;
    esac
    md="${md}${link}"$'\n'
    # Rewrite local references in place, `(shot.png)` or `(./.fxa-auto-media/shot.png)`
    # (never a URL); append the rest.
    python3 - "$body_file" "$orig" "$url" "$link" <<'PY' | slot_write "${body_file}.new" && mv -f "${body_file}.new" "$body_file"
import re, sys
path, name, url, link = sys.argv[1:]
body = open(path).read()
local = r"\((?![a-z]+://)(?:[^()\s]*/)?" + re.escape(name) + r"\)"
# An image reference to the file becomes the sized, linked picture; any other reference (a plain link) gets the URL.
new = re.sub(r"!\[[^\]]*\]" + local, lambda m: link, body)
new = re.sub(local, lambda m: "(" + url + ")", new)
if new == body:
    new = body.rstrip("\n") + "\n\n" + link + "\n"
sys.stdout.write(new)
PY
  done
  printf '%s' "$md"
}

# _finish_copy_media <src> <dest> <root>
#   On Tart the VM still runs, so a checked file can become a link to ~/.ssh
#   before gh reads it. Copy through one no-follow descriptor inside <root>.
_finish_copy_media() {
  python3 - "$@" <<'PY'
import fcntl, os, stat, sys
src, dest, root = sys.argv[1:]
fd = os.open(src, os.O_RDONLY | os.O_NOFOLLOW)
# F_GETPATH is macOS only; Linux names the descriptor's file under /proc.
real = (fcntl.fcntl(fd, fcntl.F_GETPATH, bytes(1024)).rstrip(b"\0").decode() if hasattr(fcntl, "F_GETPATH")
        else os.readlink("/proc/self/fd/%d" % fd))
st = os.fstat(fd)
if not stat.S_ISREG(st.st_mode) or not real.startswith(root.rstrip("/") + "/") or st.st_size > 100 << 20:
    sys.exit(1)
with os.fdopen(fd, "rb") as f, open(dest, "xb") as o:
    o.write(f.read())
PY
}

# finish_media_args <worktree> <done_file> <out-array-name>
#   Turn the handoff's media_paths into `gh pr create --attach` flags. The agent
#   picks the paths, so refuse any outside the worktree or not media: it would
#   upload a host file to a public PR. Skip a missing file, it must not cost the PR.
#   Always print the `media:` line, so a handoff with no media is visible.
finish_media_args() {
  local worktree="$1" done_file="$2" out="$3"
  local p rel local_media real wt_real listed=0 attached=0 copy_dir copy
  wt_real="$(cd "$worktree" && pwd -P)"
  copy_dir="$(mktemp -d)"
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    listed=$((listed + 1))
    rel="${p#/workspace/}"
    case "$rel" in
      /*|*..*|"") echo "  WARN: media path refused (outside the worktree): ${p}" >&2; continue ;;
    esac
    case "$rel" in
      *.png|*.jpg|*.jpeg|*.webp|*.gif|*.webm|*.mp4|*.mov) ;;
      *) echo "  WARN: media path refused (not a media type): ${p}" >&2; continue ;;
    esac
    local_media="${worktree}/${rel}"
    real="$( [ -f "$local_media" ] && cd "$(dirname "$local_media")" 2>/dev/null && pwd -P )/$(basename "$rel")"
    mkdir -p "${copy_dir}/${listed}"; copy="${copy_dir}/${listed}/$(basename "$rel")"  # gh matches body refs by name
    if [ -f "$local_media" ] && [ ! -L "$local_media" ] && [[ "$real" == "$wt_real"/* ]] &&
       _finish_copy_media "$local_media" "$copy" "$wt_real" 2>/dev/null; then
      eval "$out+=(--attach \"\$copy\")"
      attached=$((attached + 1))
    else
      echo "  WARN: media listed but not found inside the worktree, skipping: ${p}" >&2
    fi
  done < <(jq -r '.media_paths // [] | .[]' "$done_file" 2>/dev/null)
  local why=""
  [ -f "${worktree}/.fxa-auto-media-skipped.txt" ] && [ ! -L "${worktree}/.fxa-auto-media-skipped.txt" ] && why="; skipped: $(head -c 200 "${worktree}/.fxa-auto-media-skipped.txt" | tr -d '\n')"
  echo "media: ${listed} listed, ${attached} attached${why}" >&2
}

# _finish_risk_section <worktree> <pr_body> <risk_notes>   The PR body with a ## Risk section after "This pull request",
# for the human reviewer: merge risk from the paths and size, rollback from what a revert cannot undo, verification from
# the runner's records. The host sets the levels (a self-rated risk reads low); the agent's notes only explain. FxA only.
_finish_risk_section() {
  local wt="$1" body="$2" notes="${3:-}" f a d files=0 adds=0 dels=0 code=0 logic=0 m=1 r=1 v=1 areas="" why="" sec n pass=0 bad=0 ci=0 med=0
  [ -d "${wt}/packages/fxa-settings" ] || { printf '%s' "$body"; return 0; }
  add() { case ", ${areas}, " in *", $1, "*) ;; *) areas="${areas:+${areas}, }$1" ;; esac; }
  because() { case "; ${why}; " in *"; $1; "*) ;; *) why="${why:+${why}; }$1" ;; esac; }
  while IFS=$'\t' read -r a d f; do
    case "$f" in .fxa-*|ai/*|artifacts/*|"") continue ;; esac
    files=$((files + 1))
    # A lock file or a snapshot is generated: its lines say nothing about the size of the change.
    case "$f" in yarn.lock|*/yarn.lock|package-lock.json|*/package-lock.json|*.snap) ;; *) adds=$((adds + ${a//-/0})); dels=$((dels + ${d//-/0})) ;; esac
    case "$f" in *.spec.*|*.test.*|*/test/*|*/tests/*|*/__tests__/*|*/__mocks__/*|*/__snapshots__/*|*.snap|*.stories.*|packages/functional-tests/*|docs/*|*.md) continue ;; esac
    code=1
    # Copy (.ftl, and email templates) and dependencies have rules of their own. A style file is UI, but its proof is a picture.
    case "$f" in
      packages/fxa-auth-server/lib/senders/*.ftl|packages/fxa-auth-server/lib/senders/*.mjml|libs/accounts/email-renderer/*.ftl|libs/accounts/email-renderer/*.mjml)
        [ "$r" -ge 2 ] || r=2; add "email copy"; because "a sent email cannot be recalled"; continue ;;
      *.ftl) add "copy"; continue ;;
      package.json|*/package.json|yarn.lock|*/yarn.lock|package-lock.json|*/package-lock.json) [ "$m" -ge 2 ] || m=2; logic=1; add "dependencies"; continue ;;
      *.css|*.scss|*.less) ;;
      *) logic=1 ;;
    esac
    case "$f" in
      packages/fxa-auth-server/lib/crypto/*|packages/fxa-auth-server/lib/tokens/*|packages/fxa-auth-server/lib/oauth/*|packages/fxa-customs-server/*|\
      packages/fxa-auth-server/lib/routes/account*|packages/fxa-auth-server/lib/routes/password*|packages/fxa-auth-server/lib/routes/session*|\
      packages/fxa-auth-server/lib/routes/totp*|packages/fxa-auth-server/lib/routes/mfa*|packages/fxa-auth-server/lib/routes/recovery*|\
      packages/fxa-auth-server/lib/routes/passkey*|packages/fxa-auth-server/lib/routes/passwordless*|packages/fxa-auth-server/lib/routes/linked-accounts*|\
      packages/fxa-auth-server/lib/routes/devices-and-sessions*|packages/fxa-auth-server/lib/routes/auth-schemes*|packages/fxa-auth-server/lib/routes/oauth*|\
      packages/fxa-auth-server/lib/routes/idp*|packages/fxa-auth-server/lib/db.ts|packages/fxa-auth-server/lib/signer*|packages/fxa-auth-server/lib/serverJWT*|\
      packages/fxa-auth-server/lib/customs*|libs/accounts/passkey/*|libs/accounts/two-factor/*|libs/accounts/recovery-phone/*|libs/accounts/oauth/*|libs/accounts/rate-limit/*)
        m=3; add "auth (sessions, tokens, 2FA, OAuth)" ;;
      packages/fxa-auth-server/lib/account-delete*) m=3; r=3; add "account deletion"; because "account deletion cannot be undone" ;;
      packages/db-migrations/*) m=3; r=3; add "the database schema"; because "a DB migration: production runs it by hand, and its reverse patch is commented out" ;;
      libs/shared/db/*|packages/fxa-shared/db/*) m=3; add "the database schema" ;;
      libs/payments/*|apps/payments/*|packages/fxa-payments-server/*|packages/fxa-auth-server/lib/payments/*|packages/fxa-auth-server/lib/routes/subscriptions*|\
      packages/fxa-shared/payments/*|packages/fxa-shared/subscriptions/*)
        m=3; [ "$r" -ge 2 ] || r=2; add "payments"; because "a charge or a processed webhook stays" ;;
      .circleci/*|.github/workflows/*) m=3; add "CI" ;;
      packages/fxa-content-server/server/lib/csp*|packages/fxa-content-server/server/lib/routes/post-csp*) m=3; add "CSP and security headers" ;;
      */config/*key*.json) m=3; r=3; add "key files"; because "key files change what existing tokens verify against" ;;
      packages/fxa-auth-server/lib/senders/*|packages/fxa-auth-server/lib/email/*|libs/accounts/email-renderer/*|libs/accounts/email-sender/*)
        [ "$m" -ge 2 ] || m=2; [ "$r" -ge 2 ] || r=2; add "email"; because "a sent email cannot be recalled" ;;
      */config/*|configs/*|*.env*) [ "$m" -ge 2 ] || m=2; [ "$r" -ge 2 ] || r=2; add "config"; because "a config change needs a restart" ;;
      packages/fxa-profile-server/*|libs/profile/*) [ "$m" -ge 2 ] || m=2; add "the profile server" ;;
      packages/fxa-settings/*|packages/fxa-react/*) [ "$m" -ge 2 ] || m=2; add "settings and React UI" ;;
      packages/fxa-content-server/*) [ "$m" -ge 2 ] || m=2; add "the content server" ;;
      *) [ "$m" -ge 2 ] || m=2; add "other code" ;;
    esac
  done < <(git -C "$wt" diff --cached --numstat --no-renames 2>/dev/null)
  [ $((adds + dels)) -gt 500 ] || [ "$files" -gt 20 ] && m=3
  [ $((adds + dels)) -gt 100 ] && [ "$m" -lt 2 ] && m=2
  # Verification: the verify verdict's rows, the --revert proof and the media.
  if [ -s "${wt}/.fxa-verify-verdict.txt" ]; then
    pass="$(sed 1d "${wt}/.fxa-verify-verdict.txt" | grep -c '^PASS ' || true)"; bad="$(sed 1d "${wt}/.fxa-verify-verdict.txt" | grep -c '^FAIL ' || true)"
    ci="$(sed 1d "${wt}/.fxa-verify-verdict.txt" | grep -c '^CI ' || true)"
  fi
  local counts; counts="${pass} check$([ "$pass" = 1 ] && echo " passes" || echo "s pass")$([ "$ci" -gt 0 ] && echo ", ${ci} left to CI")"
  local vt
  find "${wt}/.fxa-auto-media" -maxdepth 1 -type f 2>/dev/null | grep -qiE '\.(png|jpe?g|webp|gif|webm|mp4|mov)$' && med=1
  if [ "$code" = 0 ]; then vt="Strong. Only tests and docs change."
  elif [ "$bad" -gt 0 ]; then v=3; vt="Weak. ${bad} check$([ "$bad" = 1 ] || echo s) failed."
  elif [ "$pass" = 0 ]; then v=3; vt="Weak. No verify run is on record."
  # Copy or styles only: no test fails without them, so a picture of the change is the proof.
  elif [ "$logic" = 0 ] && [ "$med" = 1 ]; then vt="Strong. A copy or style change: ${counts}, and a screenshot or video shows it."
  elif [ "$logic" = 0 ]; then v=2; vt="Partial. A copy or style change: ${counts}; no screenshot shows the change."
  elif head -1 "${wt}/.fxa-verify-revert.txt" 2>/dev/null | grep -q ' proof=yes$'; then vt="Strong. A test fails without the fix (verify --revert). ${counts}."
  else v=2; vt="Partial. ${counts}; no test is shown to fail without the fix."; fi
  [ "$logic" = 1 ] && [ "$med" = 1 ] && vt="${vt} A screenshot or video is attached."
  [ -n "$areas" ] || areas="tests and docs"
  local lv=(Low Medium High) rb=(Easy Moderate Hard) vs=(Strong Partial Weak) top=$m
  [ "$r" -gt "$top" ] && top=$r; [ "$v" -gt "$top" ] && top=$v
  local rt="A plain revert; it ships on the next train."
  [ -n "$why" ] && rt="$(printf '%s' "${why:0:1}" | tr '[:lower:]' '[:upper:]')${why:1}."
  sec="## Risk

**Risk: ${lv[$((top - 1))]}** (the worst of the three below)

- Merge risk: ${lv[$((m - 1))]}. ${files} file$([ "$files" = 1 ] || echo s), +${adds} -${dels}: ${areas}.
- Rollback: ${rb[$((r - 1))]}. ${rt}
- Verification: ${vs[$((v - 1))]}. ${vt#*. }"
  # The agent's notes: what the checks would not catch, a rollback step. At most 3 lines.
  n="$(printf '%s\n' "$notes" | grep -v '^[[:space:]]*$' | head -3 | cut -c1-300 | sed -E 's/^[-*][[:space:]]*//; s/^/- /')"
  [ -z "$n" ] || sec="${sec}
${n}"
  if printf '%s\n' "$body" | grep -q '^## This pull request'; then
    S="$sec" awk 'BEGIN { s = ENVIRON["S"] } in_pr && /^## / && !done { print s "\n"; done = 1 } /^## This pull request/ { in_pr = 1 } { print } END { if (!done) print "\n" s }' <<< "$body"
  else printf '%s\n\n%s\n' "$body" "$sec"; fi
}

# _finish_media_note <worktree> <base> <attached>   The host's backstop for the handoff check's media rule: an FxA
# PR that changes what a person sees, with nothing attached and no reason, says so in its body (one line, or nothing).
_finish_media_note() {
  local wt="$1" vis
  [ -d "${wt}/packages/fxa-settings" ] && [ "${3:-0}" = 0 ] || return 0
  [ -s "${wt}/.fxa-auto-media-skipped.txt" ] && return 0
  vis="$(git -C "$wt" diff --name-only --diff-filter=d "$2" HEAD 2>/dev/null \
    | grep -E '^(packages|apps|libs)/.*\.(tsx|jsx|css|scss|html|mustache|hbs|ftl|svg)$' \
    | grep -vE '(\.test\.|\.spec\.|\.stories\.|__tests__/|/tests?/|functional-tests/)' | head -1 || true)"
  [ -z "$vis" ] || printf '\n\n_No screenshot or video is attached, though this PR changes what a person sees (`%s`)._\n' "$vis"
}

# finish_diff_only <key> <worktree>   A pipeline run on a read-only profile (PIPE_PR_OPEN=0)
# pushes nothing. Keep the change as <state dir>/diffs/<key>.patch, which `state push`
# mirrors, and post the agent's summary and the diffstat to the ticket. The caller labels it.
finish_diff_only() {
  local key="$1" wt="$2" done_file title body cb mb dir patch stat
  done_file="$(finish_done_file_path "$wt")"
  [ -s "$done_file" ] || { echo "ERROR: handoff file not found at ${done_file}." >&2; return 1; }
  title="$(jq -r '.pr_title // empty' "$done_file")"; body="$(jq -r '.pr_body // empty' "$done_file")"
  cb="$(jq -r '.commit_body // empty' "$done_file")"
  mb="$(git -C "$wt" merge-base HEAD "origin/${FXA_WORKTREE_BASE:-main}" 2>/dev/null)" \
    || { echo "ERROR: no merge-base with origin/${FXA_WORKTREE_BASE:-main} in ${wt}" >&2; return 1; }
  dir="${PIPE_STATE_DIR}/diffs"; patch="${dir}/${key}.patch"; mkdir -p "$dir" || return 1
  # Commits from a rebase round, the edits, and new files; never the .fxa-* scratch files.
  ( cd "$wt" && git diff --binary --no-ext-diff --no-textconv "$mb" -- . ':(exclude).fxa-*' \
      && git ls-files -o --exclude-standard -z -- . ':(exclude).fxa-*' \
        | while IFS= read -r -d '' f; do git diff --binary --no-ext-diff --no-textconv --no-index -- /dev/null "$f" || true; done ) > "${patch}.diff" \
    || { rm -f "${patch}.diff"; echo "ERROR: could not write ${patch}" >&2; return 1; }
  [ -s "${patch}.diff" ] || { rm -f "$patch" "${patch}.diff"; echo "ERROR: nothing to ship: the run changed no file." >&2; return 1; }
  # A mail header over the diff, so `git am` makes the commit with the run's subject and body.
  { printf 'From 0000000000000000000000000000000000000000 Mon Sep 17 00:00:00 2001\nFrom: %s agent <noreply@example.invalid>\nSubject: [PATCH] %s\n\n%s\n---\n\n' \
      "${PIPE_PROFILE:-FxA}" "${title:-Change from the agent}" "${cb:-$key}"; cat "${patch}.diff"; } > "$patch" && rm -f "${patch}.diff" \
    || { echo "ERROR: could not write ${patch}" >&2; return 1; }
  stat="$(cd "$wt" && git apply --stat "$patch" 2>/dev/null | tail -15)"
  # The runner wrote the title, body and patch: the PR path's guard runs before any of it is posted.
  if ! _finish_pii_guard "$wt" "$done_file" "$title" "$body" "$cb" "$patch"; then
    jira_comment "$key" "🤖 Diff-only run: the patch is kept in the pipeline's state dir (diffs/${key}.patch). Its summary is not posted, because the personal-data check refused it. A person must review the patch." \
      || echo "WARN: could not post the diff comment on ${key}" >&2
    printf '%s\n' "$patch"; return 0
  fi
  local where="diffs/${key}.patch in the pipeline's state dir"
  jira_attach "$key" "$patch" && where="attached as ${key}.patch; apply it with: git am ${key}.patch"
  jira_comment "$key" "🤖 Diff-only run: the ${PIPE_PROFILE:-} pipeline opens no PR yet, so the change is a patch for a person to review (${where}).

${title:-No title.}

${body}

${stat}" || echo "WARN: could not post the diff comment on ${key}" >&2
  printf '%s\n' "$patch"
}

# finish_push_and_pr [worktree] [create_pr]
#   Commit the agent's change, push the branch and open or update the PR.
#   Prints the PR URL on stdout (an empty line without create_pr). Progress on stderr.
finish_push_and_pr() {
  _finish_claim "${1:-$(worktree_shared_path 2>/dev/null)}"
  trap '_finish_release "${1:-$(worktree_shared_path 2>/dev/null)}"' RETURN
  _finish_push_and_pr "$@"
}

_finish_push_and_pr() {
  if ! command -v gh >/dev/null 2>&1; then
    echo "ERROR: gh CLI not installed on the host. Install with: brew install gh" >&2
    return 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq not installed on the host." >&2
    return 1
  fi

  # Without create_pr="true", push and print the gh command to paste instead.
  local worktree="${1:-}"
  local create_pr="${2:-false}"
  if [ -z "$worktree" ]; then
    local wt
    while IFS= read -r wt; do
      [ -z "$wt" ] && continue
      if [ -s "${wt}/${FXA_DONE_FILENAME}" ] && jq -e . "${wt}/${FXA_DONE_FILENAME}" >/dev/null 2>&1; then
        worktree="$wt"
        break
      fi
    done < <(_worktree_pool_list)
    if [ -z "$worktree" ]; then
      echo "ERROR: no handoff file found in any pool worktree." >&2
      echo "       Either no agent has finished, or specify the worktree explicitly." >&2
      return 1
    fi
    echo "Auto-detected ready handoff in ${worktree}" >&2
  fi

  local done_file
  done_file="$(finish_done_file_path "$worktree")"

  if [ ! -s "$done_file" ]; then
    echo "ERROR: handoff file not found at ${done_file}." >&2
    echo "       The agent hasn't finished yet, or it failed before writing it." >&2
    return 1
  fi
  # A pipeline finish (cmd_jira, cmd_finish) checks that the ticket is still this team's to ship; a session does not.
  # FXA_SHIP_CHECK is 1, or the launch's key. The runner wrote the handoff, so its key must be the slot's branch.
  if [ -n "${FXA_SHIP_CHECK:-}" ]; then
    local sk; sk="$(jq -r '.issue // empty' "$done_file" 2>/dev/null)"
    if ! [[ "$sk" =~ ^[A-Z][A-Z0-9]*-[0-9]+$ ]] \
       || [ "$(git -C "$worktree" rev-parse --abbrev-ref HEAD 2>/dev/null)" != "$(printf '%s' "$sk" | tr 'A-Z' 'a-z')" ] \
       || { [ "$FXA_SHIP_CHECK" != 1 ] && [ "$FXA_SHIP_CHECK" != "$sk" ]; }; then
      echo "ERROR: the handoff's ticket key (${sk:-none}) is not the slot's branch$([ "$FXA_SHIP_CHECK" = 1 ] || printf ' or the launched %s' "$FXA_SHIP_CHECK"); no push." >&2
      return 1
    fi
    pipeline_ship_ok "$sk" "$worktree" || return 1
  fi

  # A read-only profile (PIPE_PR_OPEN=0) never writes to its repo: `finish` keeps the patch, as
  # the watch does. The runner wrote the handoff, so its key must be the slot's own branch.
  if [ "${PIPE_PR_OPEN:-1}" = 0 ]; then
    local key; key="$(jq -r '.issue // empty' "$done_file")"
    if ! [[ "$key" =~ ^[A-Z][A-Z0-9]*-[0-9]+$ ]] \
       || [ "$(git -C "$worktree" rev-parse --abbrev-ref HEAD 2>/dev/null)" != "$(printf '%s' "$key" | tr 'A-Z' 'a-z')" ]; then
      echo "ERROR: the ${PIPE_PROFILE:-} profile is read-only, and the handoff's ticket key does not match the slot's branch." >&2
      return 1
    fi
    finish_diff_only "$key" "$worktree" >&2 || return 1
    echo "Read-only profile: no push and no PR. Label it with: fxa-sandbox-ctl label ${key} diff" >&2
    printf '\n'; return 0
  fi

  local issue branch commit_sha pr_title pr_body
  issue="$(jq -r '.issue // empty' "$done_file")"
  branch="$(jq -r '.branch // empty' "$done_file")"
  commit_sha="$(jq -r '.commit_sha // empty' "$done_file")"
  pr_title="$(jq -r '.pr_title // empty' "$done_file")"
  pr_body="$(jq -r '.pr_body // empty' "$done_file")"
  # Strip the harness's Claude Code footer and session link here, whatever the VM's CLAUDE.md says.
  pr_body="$(printf '%s\n' "$pr_body" | grep -vE 'Generated with \[?Claude Code|^https://claude\.ai/code/session_|^Claude-Session:' | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}')"

  if [ -z "$branch" ] || [ -z "$pr_title" ] || [ -z "$pr_body" ]; then
    # Only the names: the file is runner-written text, and a PR URL in it read as this run's PR.
    echo "ERROR: handoff file is missing required keys: $([ -n "$branch" ] || printf 'branch ')$([ -n "$pr_title" ] || printf 'pr_title ')$([ -n "$pr_body" ] || printf 'pr_body')" >&2
    return 1
  fi
  # The title becomes a commit subject and a gh argument. One line, printable.
  if [ "${#pr_title}" -gt 200 ] || [[ "$pr_title" == *[[:cntrl:]]* ]]; then
    echo "ERROR: pr_title is over 200 chars or contains control characters. Refusing." >&2
    return 1
  fi
  local conv='^(feat|fix|chore|refactor|test|docs|perf|ci|build|style|revert|task|bug)\([^()]+\)!?: [^[:space:]]'
  if ! [[ "$pr_title" =~ $conv ]]; then
    # Only its start, and plain characters: this line reaches the manager pass through the launch log.
    echo "ERROR: pr_title is not a scoped conventional subject, e.g. 'fix(auth): reject an expired token': $(printf '%s' "${pr_title:0:60}" | tr -cd 'A-Za-z0-9 ._/:(),!-')" >&2
    return 1
  fi

  worktree_git_ok "$worktree" >/dev/null || return 1
  local current_branch
  current_branch="$(git -C "$worktree" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  if [ "$current_branch" != "$branch" ]; then
    echo "ERROR: worktree is on '${current_branch}' but handoff says '$(printf '%s' "${branch:0:60}" | tr -cd 'A-Za-z0-9._/-')'." >&2
    return 1
  fi

  if [ -n "$commit_sha" ]; then
    local head_sha
    head_sha="$(git -C "$worktree" rev-parse HEAD 2>/dev/null)"
    if [ "$head_sha" != "$commit_sha" ]; then
      echo "WARN: HEAD is ${head_sha} but handoff names ${commit_sha}. Continuing with HEAD." >&2
    fi
  fi

  # The agent cannot commit: the shared .git is read-only in the VM, because a
  # linked worktree's commit writes objects and refs that every slot shares.
  #
  # A rebase round arrives mid-merge with the agent's resolved files still
  # unmerged in the index. Check that no markers remain, then stage them here.
  local merging=""
  if git -C "$worktree" rev-parse --verify -q MERGE_HEAD >/dev/null 2>&1; then
    merging=1
    local f still=""
    local -a unmerged=()
    while IFS= read -r -d '' f; do unmerged+=("$f"); done \
      < <(git -C "$worktree" diff -z --name-only --diff-filter=U 2>/dev/null)
    for f in "${unmerged[@]}"; do
      grep -qE '^(<{7}|={7}|>{7})( |$)' "${worktree}/${f}" 2>/dev/null && still="${still}${f}"$'\n'
    done
    if [ -n "$still" ]; then
      echo "ERROR: conflict markers remain in:" >&2
      printf '  %s\n' "$still" >&2
      echo "       Refusing to commit: this would push markers into the PR." >&2
      return 1
    fi
    if [ "${#unmerged[@]}" -gt 0 ]; then
      echo "Completing the merge: staging ${#unmerged[@]} resolved file(s)..." >&2
      git -C "$worktree" add -- "${unmerged[@]}" >&2 || {
        echo "ERROR: could not stage the resolved files." >&2
        return 1
      }
    fi
    # Close the merge: the squash's `git reset --soft` refuses mid-merge. The
    # squash discards this commit at once, so skip the hooks.
    git -C "$worktree" commit --no-edit --no-verify >&2 || {
      echo "ERROR: could not close the merge commit." >&2
      return 1
    }
  fi

  # Stage what worktree_filtered_status reports, not `git add -A`, which would
  # sweep in newKey.json and the .fxa-* scratch files.
  local dirty
  dirty="$(worktree_filtered_status "$worktree")"
  if [ -n "$dirty" ]; then
    echo "Staging agent changes on the host (the VM cannot commit)..." >&2
    local -a paths=()
    local line p
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      [ "${line:1:1}" = " " ] && continue  # already staged; re-adding a staged delete fails
      p="${line:3}"          # porcelain is "XY <path>"
      p="${p##* -> }"        # renames read "R  old -> new"
      p="${p%\"}"; p="${p#\"}"
      paths+=("$p")
    done <<<"$dirty"
    if [ "${#paths[@]}" -gt 0 ]; then
      git -C "$worktree" add -- "${paths[@]}" >&2 || {
        echo "ERROR: could not stage agent changes." >&2
        return 1
      }
    fi
  fi
  if git -C "$worktree" diff --cached --quiet 2>/dev/null &&
     [ "$(git -C "$worktree" rev-list --count "origin/${FXA_WORKTREE_BASE:-main}..HEAD" 2>/dev/null || echo 0)" = "0" ]; then
    echo "ERROR: nothing to ship: no staged changes and no commits ahead of the base." >&2
    return 1
  fi

  # Squash to one commit on the host, where the signing key is. Squash against
  # the base branch, not main: on a release branch the merge-base with main is
  # an old ancestor, and the PR would absorb every base-branch commit.
  local base_ref merge_base
  base_ref="origin/${FXA_WORKTREE_BASE:-main}"
  if [ -n "$merging" ]; then
    # After a rebase round's merge, the old merge-base would leave the PR conflicting.
    merge_base="$(git -C "$worktree" rev-parse "$base_ref" 2>/dev/null)"
  else
    merge_base="$(git -C "$worktree" merge-base HEAD "$base_ref" 2>/dev/null)"
  fi
  if [ -z "$merge_base" ]; then
    echo "ERROR: could not find merge-base with ${base_ref}." >&2
    return 1
  fi
  local cut_base="$merge_base"
  merge_base="$(_finish_squash_base "$worktree" "$branch" "$merge_base" "$merging")"
  local commit_count
  commit_count="$(git -C "$worktree" rev-list --count "${merge_base}..HEAD")"
  echo "Squashing ${commit_count} commit(s) and re-signing on host..." >&2
  git -C "$worktree" reset --soft "$merge_base" >&2 || {
    echo "ERROR: soft reset to merge-base failed." >&2
    return 1
  }
  # Fix-pr mode (a dependency fix run): the change goes on the head the run booted at, or nowhere.
  local fix="${FXA_APP_COMMIT_FF:-}"
  if [ -n "$fix" ]; then
    if ! [[ "$fix" =~ ^[1-9][0-9]*$ ]] || ! [[ "${FXA_FIX_HEAD_SHA:-}" =~ ^[0-9a-f]{40}$ ]] || [ -z "${FXA_FINISH_PR:-}" ] || ! github_app_enabled; then
      echo "ERROR: a fix run needs its run, its PR, its head and the GitHub App; nothing was pushed." >&2; return 1
    fi
    [ "$merge_base" = "$FXA_FIX_HEAD_SHA" ] || { echo "ERROR: the branch of the PR moved; nothing was pushed." >&2; _finish_prfix_why moved; return 3; }
  fi
  # After the reset the index holds the whole change, a rebase round's merge included.
  # A fix run's refusal is its end (why guard:<class>), not an operator error.
  # A fix run has no approver's tooling label: .yarn/* and .yarnrc* stay refused.
  if [ -n "$fix" ]; then
    FXA_ALLOW_TOOLING_EDITS="" FXA_ALLOW_TOOLING_SCOPE="" _finish_tooling_guard "$worktree" || { _finish_prfix_why guard:tooling; return 1; }
    _finish_prfix_lock_guard "$worktree" || { _finish_prfix_why guard:lock; return 1; }
  fi
  _finish_tooling_guard "$worktree" || { _finish_prfix_why guard:tooling; return 1; }
  _finish_check_frozen "$worktree" || { _finish_prfix_why guard:frozen; return 1; }
  local commit_body
  commit_body="$(_finish_commit_body "$(jq -r '.commit_body // empty' "$done_file")" "$pr_body")"
  # The Risk section for the reviewer, before the PII guard, so the agent's notes in it are checked too. A fix run sets no body.
  # A failure keeps the agent's body as it is: the section must never cost the PR its body.
  local with_risk=""
  [ -n "$fix" ] || with_risk="$(_finish_risk_section "$worktree" "$pr_body" "$(jq -r '.risk_notes // empty' "$done_file" 2>/dev/null)")" || with_risk=""
  [ -z "$with_risk" ] || pr_body="$with_risk"
  _finish_pii_guard "$worktree" "$done_file" "$pr_title" "$pr_body" "$commit_body" || { _finish_prfix_why guard:pii; return 1; }

  local as_is=""
  if [ -n "$fix" ]; then
    git -C "$worktree" diff --cached --quiet && { echo "ERROR: the fix adds nothing to the PR head; nothing was pushed." >&2; return 1; }
    # The PR head again, just before the push: a rebase during the agent's turn ends the run, it is not rebuilt.
    local now_head; now_head="$(_retry gh pr view "$FXA_FINISH_PR" --json headRefOid -q .headRefOid 2>/dev/null || true)"
    [ "$now_head" = "$FXA_FIX_HEAD_SHA" ] || { echo "ERROR: the branch of the PR moved to ${now_head:0:10}; nothing was pushed." >&2; _finish_prfix_why moved; return 3; }
  elif _finish_as_is "$worktree" "$merge_base" "$cut_base"; then
    as_is=1
    echo "  The run added nothing on top of them; the PR is their commits as they are." >&2
  fi

  # As the GitHub App: GitHub authors and signs the commit, and the operator's
  # key and login stay out of the push. gh below also acts as the App.
  if [ -n "$as_is" ]; then
    if github_app_enabled; then
      local GH_TOKEN; GH_TOKEN="$(github_app_token)" || return 1
      export GH_TOKEN
    fi
  elif github_app_enabled; then
    local new_sha GH_TOKEN arc=0 msg
    echo "Committing and pushing ${branch} as the GitHub App..." >&2
    msg="$(printf '%s' "$pr_title"; [ -n "${commit_body//[[:space:]]/}" ] && printf '\n\n%s' "$commit_body")"
    # A fix run's commit lands on a public PR: a fixed host text, never the agent's title or body.
    [ -z "$fix" ] || msg="$(_finish_prfix_message "$fix" "$FXA_FINISH_PR")"
    new_sha="$(github_app_commit "$worktree" "$branch" "$merge_base" "$msg")" || arc=$?
    if [ "$arc" != 0 ]; then
      [ "$arc" = 3 ] && _finish_prfix_why moved
      [ -n "$fix" ] && return "$arc"; return 1
    fi
    echo "  App commit: ${new_sha}" >&2
    # First, before any step that can fail: the ref moved, so the run's end is 'ok'.
    if [ -n "$fix" ]; then
      _prfix_set "$fix" '.new_sha = $s' --arg s "$new_sha" || echo "WARN: run ${fix} pushed ${new_sha:0:10}, but its record did not take new_sha" >&2
    fi
    GH_TOKEN="$(github_app_token)" || return 1
    export GH_TOKEN
  else
    # Hooks off: the slot's hooks are agent-written code that would run on the
    # host. _finish_check_frozen runs origin's copy instead, and CI runs lint.
    if [ -n "${commit_body//[[:space:]]/}" ]; then
      git -C "$worktree" -c core.hooksPath=/dev/null commit -m "$pr_title" -m "$commit_body" >&2 || {
        _finish_recommit_failed
        return 1
      }
    else
      git -C "$worktree" -c core.hooksPath=/dev/null commit -m "$pr_title" >&2 || {
        _finish_recommit_failed
        return 1
      }
    fi
    local new_sha
    new_sha="$(git -C "$worktree" rev-parse HEAD)"
    echo "  signed HEAD: ${new_sha}" >&2

    # A re-run re-squashes an already-pushed branch, so a plain push can be
    # rejected. The lease still refuses if someone else pushed to the branch.
    echo "Pushing ${branch} to origin..." >&2
    if ! git -C "$worktree" push -u origin "$branch" >&2; then
      echo "Normal push rejected (likely a re-squash of an already-pushed branch); retrying with --force-with-lease..." >&2
      git -C "$worktree" push -u --force-with-lease origin "$branch" >&2 || {
        echo "ERROR: git push failed even with --force-with-lease." >&2
        echo "       The remote branch may have moved unexpectedly; inspect:" >&2
        echo "       git -C '${worktree}' log --oneline origin/${branch}" >&2
        return 1
      }
    fi
  fi

  local media_args=()
  finish_media_args "$worktree" "$done_file" media_args
  # A fix run adds no body, so it gets no note.
  if [ -z "$fix" ]; then
    local media_note; media_note="$(_finish_media_note "$worktree" "$merge_base" "${#media_args[@]}")"
    [ -z "$media_note" ] || { pr_body="${pr_body}${media_note}"; echo "media: none for a visible change; the PR body says so" >&2; }
  fi

  # Always save the body, so the user can run `gh pr create --body-file` later.
  local body_file="${worktree}/.fxa-auto-pr-body.md"
  printf '%s\n' "$pr_body" | slot_write "$body_file"
  local media_md=""
  # A fix run writes nothing to GitHub but the push: no media, gate, reviewers, Copilot or feedback.
  [ -z "$fix" ] || media_args=()
  if github_app_enabled && [ -n "${FXA_MEDIA_BUCKET:-}" ] && [ "${#media_args[@]}" -gt 0 ]; then
    media_md="$(_finish_media_to_bucket "$body_file" media_args)"
    media_args=()  # the helper ran in a subshell; gh must not retry these as the App
  fi

  if [ "$create_pr" != "true" ]; then
    echo "" >&2
    echo "=== Branch pushed; PR not auto-created ===" >&2
    echo "Review the commit, body, and any media URLs, then run:" >&2
    echo "" >&2
    printf '  cd %q\n' "$worktree" >&2
    printf '  gh pr create --base %s --head %s --title %q --label %s --body-file %s\n' \
      "${FXA_WORKTREE_BASE:-main}" "$branch" "$pr_title" "${FXA_PR_LABEL:-auto}" \
      ".fxa-auto-pr-body.md" >&2
    echo "" >&2
    echo "Or pass --create-pr to your next 'jira' / 'finish' invocation to do it automatically." >&2
    # Archive the handoff so the next ticket can write a fresh one.
    mv "$done_file" "${done_file}.$(date +%s)" 2>/dev/null || rm -f "$done_file"
    # An empty line tells callers not to expect a URL.
    printf '\n'
    return 0
  fi

  # A fix round's branch already has a PR, and `gh pr create` would fail and
  # skip the reviewer request and the functional gate. Update that PR instead.
  # A checked-out PR is the session's own (FXA_FINISH_PR): a search by branch can find a fork's PR of that name.
  local pr_url existing="${FXA_FINISH_PR:-}"
  [ -n "$existing" ] || existing="$(cd "$worktree" && gh pr list --head "$branch" --state open \
                --json url,isCrossRepository -q 'map(select(.isCrossRepository | not))[0].url // empty' 2>/dev/null)" || existing=""
  if [ -n "$existing" ]; then
    echo "PR already open for ${branch}; updating it instead of creating..." >&2
    pr_url="$existing"
    echo "PR updated: ${pr_url}" >&2
    if [ -n "$fix" ]; then
      _finish_release_runner "$worktree"
      printf '%s\n' "$pr_url"
      mv "$done_file" "${done_file}.$(date +%s)" 2>/dev/null || rm -f "$done_file"
      return 0
    fi
    # First, before the steps that can fail on their own: the push reset the gate.
    finish_approve_functional_gate "$pr_url"
    # Never change an existing PR's title or body: a round's handoff describes
    # only that round, and the squash-merge would put its subject in main.
    local pr_num="${existing##*/}"
    echo "  Keeping the PR title and body; the round is recorded on Jira." >&2
    # Post a round's media as a comment, so the original body's screenshots stay.
    if [ "${#media_args[@]}" -gt 0 ]; then
      (cd "$worktree" && command gh pr comment "$pr_num" \
         --body "Updated evidence from the latest automated round." \
         ${media_args[@]+"${media_args[@]}"} >/dev/null 2>&1) \
        || echo "  WARN: could not attach round media to PR #${pr_num}." >&2
    elif [ -n "$media_md" ]; then
      (cd "$worktree" && command gh pr comment "$pr_num" --body "Updated evidence from the latest automated round.

${media_md}" >/dev/null 2>&1) || echo "  WARN: could not post round media to PR #${pr_num}." >&2
    fi
    finish_add_reviewers "$pr_url"
    finish_request_copilot_review "$pr_url"
    _finish_feedback_comment "$issue" "$done_file" "$pr_url"
    _finish_feedback_pr "$pr_url" "$done_file"
    _finish_release_runner "$worktree"
    printf '%s\n' "$pr_url"
    mv "$done_file" "${done_file}.$(date +%s)" 2>/dev/null || rm -f "$done_file"
    return 0
  fi

  echo "Creating pull request via gh..." >&2
  # Reviewers are added after create: a bad handle as a create flag would lose the PR.
  # ${arr[@]+"${arr[@]}"}: bash 3.2 under `set -u` fails on an empty "${arr[@]}".
  pr_url="$(cd "$worktree" && gh pr create ${FXA_PR_DRAFT:+--draft} \
    --base "${FXA_WORKTREE_BASE:-main}" \
    --head "$branch" \
    --title "$pr_title" \
    --label "${FXA_PR_LABEL:-auto}" \
    ${media_args[@]+"${media_args[@]}"} \
    --body-file "$body_file" 2>&1)" || {
    # A missing label or a rejected attachment must not cost the PR: retry once without either.
    echo "WARN: gh pr create failed with --label ${FXA_PR_LABEL:-auto}; retrying without it or media." >&2
    echo "$pr_url" >&2
    # gh creates the PR and still exits non-zero when an attachment fails (an App
    # token cannot upload user assets), so a PR may already exist.
    pr_url="$(cd "$worktree" && gh pr list --head "$branch" --state open --json url,isCrossRepository -q 'map(select(.isCrossRepository | not))[0].url // empty' 2>/dev/null)"
    [ -n "$pr_url" ] && echo "NOTE: the PR was created; some media did not upload." >&2
    [ -n "$pr_url" ] || pr_url="$(cd "$worktree" && gh pr create ${FXA_PR_DRAFT:+--draft} \
      --base "${FXA_WORKTREE_BASE:-main}" \
      --head "$branch" \
      --title "$pr_title" \
      --body-file "$body_file" 2>&1)" || {
      echo "ERROR: gh pr create failed:" >&2
      echo "$pr_url" >&2
      return 1
    }
    echo "NOTE: PR created without the '${FXA_PR_LABEL:-auto}' label. Add it by hand." >&2
  }

  # gh prints the URL on the last line.
  pr_url="$(printf '%s\n' "$pr_url" | tail -1)"
  # In the log before the runner is released: progress reads the PR from it, and
  # agent_stop spares this launcher only once the log has the PR. Without it the
  # launcher killed itself at the release and left the runner up.
  echo "PR opened: ${pr_url}" >&2
  # First, before reviewers, Copilot and the release, each of which can fail.
  finish_approve_functional_gate "$pr_url"

  finish_add_reviewers "$pr_url"
  # The repo's automatic Copilot review skips drafts, so ask for it on every new PR.
  finish_request_copilot_review "$pr_url"

  _finish_release_runner "$worktree"
  printf '%s\n' "$pr_url"

  # Archive the handoff file so the next ticket can write a fresh one.
  mv "$done_file" "${done_file}.$(date +%s)" 2>/dev/null || rm -f "$done_file"
}

# _finish_prfix_message <run> <PR url>   The fix commit's message: the PR number, the run id and the package names of
# heads.fix that pass the name check.
_finish_prfix_message() {
  local pk; pk="$(db_value "SELECT coalesce(heads->'fix'->'packages', '[]') FROM routine_runs WHERE id = $1;" 2>/dev/null \
    | jq -r '[.[]? | strings | select(test("^[@a-z0-9._/-]{1,80}$"))][:10] | join(", ")' 2>/dev/null || true)"
  printf 'fix(deps): fix the failing checks of #%s\n\nRoutine run %s. Packages: %s.' "${2##*/}" "$1" "${pk:-not named}"
}

# _finish_prfix_why <why>   In fix-pr mode, the run's end code (heads.fix.why). 'moved' also drops the push claim:
# nothing was pushed, so a stop may end the row again.
_finish_prfix_why() {
  [ -n "${FXA_APP_COMMIT_FF:-}" ] || return 0
  if [ "$1" = moved ]; then _prfix_set "$FXA_APP_COMMIT_FF" '.why = $w | del(.pushing, .pending_sha)' --arg w "$1"
  else _prfix_set "$FXA_APP_COMMIT_FF" '.why = $w' --arg w "$1"; fi || echo "WARN: run ${FXA_APP_COMMIT_FF} did not take why ${1}" >&2
  return 0
}

# _finish_feedback_comment <KEY> <done_file> <pr_url>
#   A review-feedback round's handoff carries `feedback_summary`: one line per
#   comment, fixed or not, with a reason. Post it on the ticket. Best effort, no
#   retry: a repeated post would comment twice.
_finish_feedback_comment() {
  local key="$1" done_file="$2" pr_url="$3" summary
  [[ "$key" =~ ^[A-Z][A-Z0-9]*-[0-9]+$ ]] || return 0
  summary="$(jq -r '.feedback_summary // empty | if type == "array" then join("\n") else . end' "$done_file" 2>/dev/null)" || summary=""
  [ -n "$summary" ] || return 0
  jira_comment "$key" "🤖 Review feedback on ${pr_url}:
${summary}" || echo "  WARN: could not post the feedback summary on ${key}." >&2
}

# _finish_feedback_pr <pr_url> <done_file>
#   On the PR too: the round's `feedback_summary` as one comment, and, when the
#   handoff has `open_questions`, that list in place of the body's "Questions for
#   the reviewer" section. Only that section: the rest of the body stays.
#   Best effort, no retry: a repeated post would comment twice.
_finish_feedback_pr() {
  local pr_url="$1" done_file="$2" summary repo num body new
  repo="$(printf '%s' "$pr_url" | sed -nE 's#.*github\.com/([^/]+/[^/]+)/pull/.*#\1#p')"
  num="$(printf '%s' "$pr_url" | sed -nE 's#.*/pull/([0-9]+).*#\1#p')"
  [ -n "$repo" ] && [ -n "$num" ] || return 0
  summary="$(jq -r '.feedback_summary // empty | if type == "array" then map("- " + .) | join("\n") else . end' "$done_file" 2>/dev/null)" || summary=""
  if [ -n "$summary" ]; then
    gh api -X POST "repos/${repo}/issues/${num}/comments" -f body="This review round pushed a new commit:
${summary}" >/dev/null 2>&1 || echo "  WARN: could not post the round summary on the PR." >&2
  fi
  jq -e '.open_questions | type == "array"' "$done_file" >/dev/null 2>&1 || return 0
  body="$(gh api "repos/${repo}/pulls/${num}" --jq '.body // ""' 2>/dev/null)" || return 0
  new="$(jq -c '.open_questions | map(tostring)' "$done_file" | BODY="$body" python3 -c '
import json, os, re, sys
qs, body = json.load(sys.stdin), os.environ["BODY"].replace("\r\n", "\n")
m = re.search(r"^\*\*Questions for the reviewer:?\*\*[ \t]*\n", body, re.M)
if not m: sys.exit(1)
end = re.search(r"^(\*\*[^*\n]+\*\*|#{1,6}[ \t])", body[m.end():], re.M)
stop = m.end() + end.start() if end else len(body)
section = "\n".join(f"{i}. {q}" for i, q in enumerate(qs, 1)) if qs else "None left open."
print(body[:m.end()] + "\n" + section + "\n" + ("\n" + body[stop:] if end else ""), end="")
')" || { echo "  NOTE: no questions section in the PR body to update." >&2; return 0; }
  [ "$new" = "$body" ] && return 0
  printf '%s' "$new" | gh api -X PATCH "repos/${repo}/pulls/${num}" -F body=@- >/dev/null 2>&1 \
    || echo "  WARN: could not update the PR body's questions." >&2
}

# finish_add_reviewers <pr_url>
#   Request review from the team and assign the ticket's reporter. Best effort:
#   the PR already exists, so log each failure and go on.
#   FXA_PR_TEAM     team slug to request, default fxa-devs. Empty disables.
#   FXA_PR_ASSIGNEE reporter's GitHub login, resolved by the caller. Empty disables.
finish_add_reviewers() {
  local pr_url="${1:-}"
  [ -n "$pr_url" ] || return 0

  local owner_repo num
  owner_repo="$(printf '%s' "$pr_url" | sed -E 's#.*github\.com/([^/]+/[^/]+)/pull/.*#\1#')"
  num="$(printf '%s' "$pr_url" | sed -E 's#.*/pull/([0-9]+).*#\1#')"

  local team="${FXA_PR_TEAM-fxa-devs}"
  if [ -n "$team" ]; then
    # REST, not `gh pr edit`, which fails on this repo's deprecated Projects-classic field.
    if [ -n "$owner_repo" ] && [ -n "$num" ]; then
      if gh api -X POST "repos/${owner_repo}/pulls/${num}/requested_reviewers" \
           -f "team_reviewers[]=${team}" >/dev/null 2>&1; then
        echo "  Requested review from ${team}." >&2
      elif gh api "repos/${owner_repo}/pulls/${num}/requested_reviewers" --jq '.teams[].slug' 2>/dev/null | grep -qx "$team"; then
        # The common case: CODEOWNERS requested the team when the PR opened.
        echo "  ${team} is already requested (CODEOWNERS)." >&2
      else
        echo "  WARN: could not request review from ${team}." >&2
      fi
    fi
  fi

  local assignee="${FXA_PR_ASSIGNEE:-}"
  if [ -n "$assignee" ]; then
    if gh pr edit "$pr_url" --add-assignee "$assignee" >/dev/null 2>&1; then
      echo "  Assigned ${assignee}." >&2
    else
      if gh api -X POST "repos/${owner_repo}/issues/${num}/assignees" \
           -f "assignees[]=${assignee}" >/dev/null 2>&1; then
        echo "  Assigned ${assignee}." >&2
      else
        echo "  NOTE: could not assign ${assignee}. They may lack repo access." >&2
      fi
    fi
  else
    echo "  NOTE: no reporter assigned (FXA_PR_ASSIGNEE unset or unresolved)." >&2
  fi
}

# _finish_as_is <worktree> <squash_base> <cut_base>   True when the squash moved onto a
#   person's commits and the index adds nothing to them: open the PR on them as they are.
#   An App commit of an empty change is refused (422), and a local one would add nothing.
_finish_as_is() {
  [ "$2" != "$3" ] && git -C "$1" diff --cached --quiet "$2" 2>/dev/null
}

# _finish_squash_base <worktree> <branch> <merge_base> <merging>
#   Where the squash starts. A person's commits on the PR stay theirs: the change
#   goes on top of the PR's head. A rebase round (merging) rewrites anyway.
_finish_squash_base() {
  local wt="$1" branch="$2" base="$3" merging="${4:-}" head people
  head="$(git -C "$wt" rev-parse -q --verify "refs/remotes/origin/${branch}" 2>/dev/null || true)"
  if [ -z "$merging" ] && [ -n "$head" ] && git -C "$wt" merge-base --is-ancestor "$base" "$head" 2>/dev/null; then
    people="$(git -C "$wt" log --format=%an "${base}..${head}" 2>/dev/null | grep -v '\[bot\]$' || true)"
    if [ -n "$people" ]; then
      echo "  The PR has commits from a person, so this change goes on top of them." >&2
      echo "$head"; return 0
    fi
    # A checked-out PR (FXA_FINISH_PR) is another author's, a bot's too: its commits stay as they are.
    if [ -n "${FXA_FINISH_PR:-}" ]; then
      echo "  This session checked out the PR, so this change goes on top of its head." >&2
      echo "$head"; return 0
    fi
  fi
  echo "$base"
}

# finish_request_copilot_review <pr_url>
#   Ask Copilot to re-review a round's push to an existing PR, so its old review
#   is not the last word. The endpoint returns an empty requested_reviewers list
#   because the bot starts at once; the timeline event is the proof.
#   FXA_PR_COPILOT  reviewer login, default copilot-pull-request-reviewer[bot]. Empty disables.
finish_request_copilot_review() {
  local pr_url="${1:-}" bot="${FXA_PR_COPILOT-copilot-pull-request-reviewer[bot]}"
  [ -n "$pr_url" ] && [ -n "$bot" ] || return 0
  local owner_repo num
  owner_repo="$(printf '%s' "$pr_url" | sed -E 's#.*github\.com/([^/]+/[^/]+)/pull/.*#\1#')"
  num="$(printf '%s' "$pr_url" | sed -E 's#.*/pull/([0-9]+).*#\1#')"
  [ -n "$owner_repo" ] && [ -n "$num" ] || return 0
  if gh api -X POST "repos/${owner_repo}/pulls/${num}/requested_reviewers" \
       -f "reviewers[]=${bot}" >/dev/null 2>&1; then
    echo "  Requested a fresh Copilot review." >&2
  else
    echo "  NOTE: Copilot re-review request failed; its last review may be stale." >&2
  fi
}

# finish_approve_functional_gate <pr_url>
#   Approve the on-hold functional-tests gate on the PR's latest CircleCI
#   pipeline. Non-fatal: on any failure the gate waits for manual approval.
finish_approve_functional_gate() {
  local pr_url="${1:-}"
  [ -n "$pr_url" ] || return 0

  local token; token="$(circleci_token)"
  if [ -z "$token" ]; then
    echo "No CircleCI token (CIRCLECI_TOKEN / CIRCLECI_CLI_TOKEN / ~/.circleci/cli.yml); skipping gate auto-approval." >&2
    echo "Approve it manually in the CircleCI UI for ${pr_url} if functional tests are needed." >&2
    return 0
  fi
  if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    echo "WARN: curl or jq missing; skipping gate auto-approval." >&2
    return 0
  fi

  local owner_repo slug branch
  owner_repo="$(printf '%s' "$pr_url" | sed -E 's#.*github\.com/([^/]+/[^/]+)/pull/.*#\1#')"
  if [ -z "$owner_repo" ] || [ "$owner_repo" = "$pr_url" ]; then
    echo "WARN: couldn't parse owner/repo from ${pr_url}; skipping gate approval." >&2
    return 0
  fi
  # Only the repos whose CI the operator trusts with agent code: the gate runs CI with its secrets.
  case " ${FXA_GATE_REPOS:-mozilla/fxa} " in *" ${owner_repo} "*) ;; *)
    echo "No gate auto-approval for ${owner_repo} (FXA_GATE_REPOS)." >&2; return 0 ;; esac
  slug="gh/${owner_repo}"
  branch="$(gh pr view "$pr_url" --json headRefName -q .headRefName 2>/dev/null)" || branch=""
  if [ -z "$branch" ]; then
    echo "WARN: couldn't resolve PR branch; skipping gate approval." >&2
    return 0
  fi

  local api="https://circleci.com/api/v2"
  local hdr="Circle-Token: ${token}"

  echo "Looking for the functional-tests approval gate on ${slug}@${branch}..." >&2
  # The pipeline for the PR's head: right after a push the newest one on the
  # branch can still be the previous push's, whose gate is already approved.
  local head; head="$(gh pr view "$pr_url" --json headRefOid -q .headRefOid 2>/dev/null || true)"
  local elapsed=0
  while [ "$elapsed" -lt 180 ]; do
    local pipeline_id
    # `|| =""` keeps a failed curl (HTTP error, DNS) from aborting under set -e.
    pipeline_id="$(curl -fsS -H "$hdr" "${api}/project/${slug}/pipeline?branch=${branch}" 2>/dev/null \
      | jq -r --arg h "$head" '[.items[] | select($h == "" or .vcs.revision == $h)][0].id // empty')" || pipeline_id=""
    if [ -n "$pipeline_id" ]; then
      local wf arid
      # Reads the first page of workflows/jobs; the PR gate sits early in the list.
      for wf in $(curl -fsS -H "$hdr" "${api}/pipeline/${pipeline_id}/workflow" 2>/dev/null \
                    | jq -r '.items[].id'); do
        local gate; gate="$(curl -fsS -H "$hdr" "${api}/workflow/${wf}/job" 2>/dev/null \
          | jq -r '.items[]
              | select(.type=="approval" and (.name | test("Functional";"i")))
              | "\(.status) \(.approval_request_id // .id)"' \
          | head -1)" || gate=""
        # Approved already (this call runs after the PR opens and again in the CI watch).
        [ "${gate%% *}" = success ] && { echo "Functional-tests gate already approved (workflow ${wf})." >&2; return 0; }
        arid=""; [ "${gate%% *}" = on_hold ] && arid="${gate#* }"
        if [ -n "$arid" ]; then
          if curl -fsS -X POST -H "$hdr" "${api}/workflow/${wf}/approve/${arid}" >/dev/null 2>&1; then
            echo "Approved functional-tests gate (workflow ${wf})." >&2
            return 0
          fi
          echo "WARN: approve call failed for workflow ${wf}." >&2
        fi
      done
    fi
    sleep 10
    elapsed=$(( elapsed + 10 ))
  done
  echo "WARN: no on-hold functional-tests gate found within 3 minutes." >&2
  echo "      It may already be approved/running, or the gate never appeared." >&2
  echo "      If functional tests are required and not running, approve manually: ${pr_url}" >&2
  return 0
}

# finish_watch_ci <pr_url>
#   Blocks until CI checks settle (or user Ctrl-C). Fires a macOS notification
#   on terminal state. Returns 0 if all required checks passed, 1 otherwise.
finish_watch_ci() {
  local pr_url="${1:-}"
  if [ -z "$pr_url" ]; then
    echo "ERROR: finish_watch_ci requires a PR URL" >&2
    return 1
  fi
  if ! command -v gh >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    echo "WARN: gh or jq missing; skipping CI watch." >&2
    return 0
  fi

  finish_approve_functional_gate "$pr_url"

  echo "Waiting for CI to register checks on ${pr_url}..." >&2
  # `gh pr checks --watch` exits at once with zero checks, so wait for the first one.
  local appeared=0 elapsed=0
  while [ "$elapsed" -lt 180 ]; do
    if gh pr checks "$pr_url" --json bucket 2>/dev/null | jq -e 'length > 0' >/dev/null 2>&1; then
      appeared=1
      break
    fi
    sleep 10
    elapsed=$(( elapsed + 10 ))
  done

  if [ "$appeared" -eq 0 ]; then
    echo "No CI checks registered within 3 minutes — leaving the PR for async CI." >&2
    finish_notify "PR opened (CI not yet attached)" "$pr_url"
    return 0
  fi

  echo "Watching CI checks on ${pr_url}" >&2
  echo "(Ctrl-C stops the watcher; CI keeps running on GitHub.)" >&2

  # Each check once, when it finishes, not the whole table every 30 s: in a
  # log file each redraw was new lines, most of a launch log. 3 h at most.
  local seen="" cur t0; t0="$(date +%s)"
  while [ $(( $(date +%s) - t0 )) -lt 10800 ]; do
    cur="$(gh pr checks "$pr_url" --json name,bucket 2>/dev/null | jq -r '.[] | "\(.bucket)\t\(.name)"' 2>/dev/null | sort)" || cur=""
    if [ -n "$cur" ]; then
      comm -13 <(printf '%s\n' "$seen") <(printf '%s\n' "$cur") | while IFS=$'\t' read -r b n; do
        [ "$b" = pending ] || printf '  [%3dm] %-8s %s\n' $(( ($(date +%s) - t0) / 60 )) "$b" "$n" >&2
      done
      seen="$cur"
      printf '%s\n' "$cur" | cut -f1 | grep -qx pending || break
    fi
    sleep 30
  done

  local json
  json="$(gh pr checks "$pr_url" --json bucket,name,state 2>/dev/null)" || {
    echo "WARN: couldn't read final CI state via gh." >&2
    return 1
  }

  printf '%s' "$json" | jq -r 'group_by(.bucket) | map("\(length) \(.[0].bucket)") | "CI: " + join(", ")' >&2 2>/dev/null || true
  local failed_names pending_names
  failed_names="$(printf '%s' "$json" | jq -r '
    [.[] | select(.bucket == "fail" or .bucket == "cancel") | .name] | join(", ")
  ')"
  pending_names="$(printf '%s' "$json" | jq -r '
    [.[] | select(.bucket == "pending") | .name] | join(", ")
  ')"

  if [ -n "$failed_names" ]; then
    finish_notify "CI failed: ${failed_names}" "$pr_url"
    echo "" >&2
    echo "CI failed checks: ${failed_names}" >&2
    return 1
  fi
  if [ -n "$pending_names" ]; then
    echo "CI still pending: ${pending_names}" >&2
    return 1
  fi
  finish_notify "CI passed on PR" "$pr_url"
  echo "" >&2
  echo "All CI checks passed." >&2
  return 0
}

# _finish_tooling_guard <worktree>
#   Refuse CI or host tooling edits: CI runs with secrets before review, and
#   hooks run on the operator's Mac. FXA_ALLOW_TOOLING_EDITS=1 allows them all.
#   FXA_ALLOW_TOOLING_SCOPE=scripts (the launch sets it from an approved Jira label)
#   allows package.json task scripts and _scripts/ only: not npm's install, prepare or publish
#   hooks, and not a _scripts/ file that such a hook runs.
_finish_tooling_guard() {
  local wt="$1" f hit="" scope="${FXA_ALLOW_TOOLING_SCOPE:-}" keys
  [ "${FXA_ALLOW_TOOLING_EDITS:-}" = "1" ] && return 0
  # A recovery finish has no launch env: use the scope the launch recorded for this key.
  [ -n "$scope" ] || scope="$(_finish_tooling_scope_of "$wt")"
  # The scripts scope allows named task scripts, not npm's lifecycle hooks: CI runs those in the install.
  keys='{scripts, "lint-staged", husky}'
  [ "$scope" = scripts ] && keys='{hooks: ((.scripts // {}) | with_entries(select(.key | test("^(pre|post)?(install|prepare|publish|pack|version|uninstall|shrinkwrap|dependencies)$|^prepublishOnly$")))), "lint-staged", husky}'
  while IFS= read -r -d '' f; do
    case "$f" in
      _scripts/*)
        if [ "$scope" != scripts ]; then hit="${hit}${f}"$'\n'
        # A hook at HEAD that names the file runs it in CI's install (FxA's preinstall runs _scripts/check-package-manager.sh).
        elif git -C "$wt" grep -qE "\"(pre|post)?(install|prepare|publish|pack|version|uninstall|shrinkwrap|dependencies|publishOnly)\" *:.*${f//./\\.}" HEAD -- '*package.json' 2>/dev/null; then
          hit="${hit}${f} (an npm install, prepare or publish hook runs it: the tooling label does not cover it)"$'\n'
        fi ;;
      .github/*|.circleci/*|.husky/*|*/.husky/*|.lintstagedrc*|*/.lintstagedrc*|lint-staged.config.*|*/lint-staged.config.*|\
      .yarnrc*|*/.yarnrc*|.yarn/*|.npmrc|*/.npmrc)
        hit="${hit}${f}"$'\n' ;;
      package.json|*/package.json)
        # Only the parts a hook or CI executes. A dependency bump is fine. A missing side (a new
        # or deleted file) counts as {}, so a new lib's package.json passes unless it adds scripts.
        if [ "$({ git -C "$wt" show ":$f" 2>/dev/null || echo '{}'; } | jq -cS "$keys")" != \
             "$({ git -C "$wt" show "HEAD:$f" 2>/dev/null || echo '{}'; } | jq -cS "$keys")" ]; then
          if [ "$scope" = scripts ]; then hit="${hit}${f} (an npm install, prepare or publish hook, lint-staged or husky: the tooling label does not cover these)"$'\n'
          else hit="${hit}${f} (scripts/lint-staged/husky)"$'\n'; fi
        fi ;;
    esac
  done < <(git -C "$wt" diff --cached -z --name-only 2>/dev/null)
  [ -z "$hit" ] && return 0
  # The paths on the ERROR line itself: progress and the pass keep only that line.
  echo "ERROR: refusing to ship: the change touches CI or host tooling: $(printf '%s' "$hit" | tr '\n' ' ' | sed 's/ *$//')" >&2
  echo "       For package.json scripts or _scripts/ only, an approver adds the label ${PIPE_TOOLING_LABEL:-ai-fixme-allow-tooling} and relaunches." >&2
  echo "       For anything else, relaunch with FXA_ALLOW_TOOLING_EDITS=1 if the ticket asks for this." >&2
  return 1
}

# _finish_prfix_lock_guard <worktree>   A fix run's yarn.lock entries: each one the staged change adds or changes
# must resolve from the npm registry (berry's npm:, a registry.yarnpkg.com or registry.npmjs.org URL), a workspace:,
# or a patch: of an npm: package. A checksum that changes with no version change is refused too.
_finish_prfix_lock_guard() {
  local wt="$1" f hit=""
  # One line per entry: key, version, resolution, checksum (berry and v1 lockfiles).
  local tsv='function out() { if (k != "" && k != "__metadata:") print k "\t" v "\t" r "\t" c; k = v = r = c = "" }
    /^[^ #\t].*:$/ { out(); k = $0; next }
    /^  version:? / { v = $2 } /^  (resolution:|resolved) / { r = $2 } /^  (checksum:|integrity) / { c = $2 }
    END { out() }'
  while IFS= read -r -d '' f; do
    case "$f" in yarn.lock|*/yarn.lock) ;; *) continue ;; esac
    hit="${hit}$(awk -F'\t' 'FILENAME == ARGV[1] { o[$1] = $2 FS $3 FS $4; ov[$1] = $2; oc[$1] = $4; next }
      o[$1] != $2 FS $3 FS $4 {
        if ($3 !~ /^(@[a-z0-9._~-]+\/)?[a-z0-9._~-]+@(npm:[0-9A-Za-z.+-]+|workspace:.*|patch:.*@npm%3A.*)$/ \
            && $3 !~ /^https:\/\/registry\.(yarnpkg\.com|npmjs\.org)\//) print "x"
        else if (($1 in ov) && ov[$1] == $2 && oc[$1] != $4) print "x"
      }' <(git -C "$wt" show "HEAD:$f" 2>/dev/null | tr -d '"' | awk "$tsv") <(git -C "$wt" show ":$f" 2>/dev/null | tr -d '"' | awk "$tsv"))"
  done < <(git -C "$wt" diff --cached -z --name-only 2>/dev/null)
  [ -z "$hit" ] && return 0
  echo "ERROR: refusing to ship: The fix changes yarn.lock entries, which I do not push. Fix it by hand." >&2
  return 1
}

# _finish_tooling_scope_of <worktree>   The tooling scope that cmd_launch recorded for the
#   worktree's ticket (PIPE_STATE_DIR/tooling/<KEY>), or nothing. It counts only while an approver's
#   label is still on the ticket: a label removed since the launch, or no answer from Jira, gives nothing.
_finish_tooling_scope_of() {
  local key s; key="$(worktree_key_for "$(git -C "$1" rev-parse --abbrev-ref HEAD 2>/dev/null)")"
  [ -n "${PIPE_STATE_DIR:-}" ] && [ -n "$key" ] || return 0
  s="$(awk 'NR == 1 { print $1 }' "${PIPE_STATE_DIR}/tooling/${key}" 2>/dev/null || true)"
  [ -n "$s" ] && jira_tooling_approver "$key" >/dev/null 2>&1 && printf '%s\n' "$s"
  return 0
}

# _finish_pii_guard <worktree> <done_file> <pr_title> <pr_body> <commit_body> [patch]   GitHub is public, so
# refuse to ship personal or internal data in the PR's text or the staged diff (or <patch>) (lib/pii_guard.py).
_finish_pii_guard() {
  local wt="$1" d hits rc=0
  d="$(mktemp "${TMPDIR:-/tmp}/fxa-pii.XXXXXX")"
  jq -n --arg t "$3" --arg b "$4" --arg c "$5" --slurpfile f "$2" \
    '{pr_title: $t, pr_body: $b, commit_body: $c} + ($f[0] | {feedback_summary, open_questions} | map_values(
       if type == "array" then map(tostring) | join("\n") else (. // "" | tostring) end))' > "$d.json" \
    && { if [ -n "${6:-}" ]; then cat "$6"; else git -C "$wt" diff --cached -U0 --text --no-textconv --no-color --no-ext-diff; fi; } > "$d" \
    && hits="$(python3 "${FINISH_LIB_DIR}/pii_guard.py" "$d.json" "$d" "$wt")" || rc=$?
  rm -f "$d" "$d.json"
  [ "$rc" = 0 ] && return 0
  # The places on the ERROR line itself: progress and the pass keep only that line.
  echo "ERROR: refusing to ship: personal or internal data in the PR: $(printf '%s' "${hits:-the check could not run}" | paste -sd ';' - | sed 's/;/; /g')" >&2
  echo "       GitHub is public. Remove it from the PR text and the change, then finish again." >&2
  return 1
}

# _finish_commit_body <commit_body> <pr_body>   The squash commit's body: the agent's short
# Because / This commit / Closes body, without the harness footer, at most 30 lines. With
# none (an older handoff), only the PR body's closing line: the PR keeps the detail.
_finish_commit_body() {
  if [ -n "${1//[[:space:]]/}" ]; then
    printf '%s\n' "$1" | grep -vE 'Generated with \[?Claude Code|^https://claude\.ai/code/session_|^Claude-Session:' \
      | sed -e 's/[[:space:]]*$//' | cat -s | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}' | head -30 || true
  else
    printf '%s\n' "$2" | grep -E '^(Closes|Fixes):? +[^[:space:]]' | head -3 || true
  fi
}

# _finish_check_frozen <worktree>
#   The pre-commit hook's frozen-path gate, with the script from origin, not
#   the agent's slot. GIT_DIR and GIT_WORK_TREE point it at the slot's index.
_finish_check_frozen() {
  local wt="$1" root tmp adm
  root="$(worktree_repo_root)" || return 1
  adm="$(worktree_git_ok "$wt")" || return 1
  tmp="$(mktemp -d)/check-frozen.ts"
  git -C "$root" show "origin/${FXA_WORKTREE_BASE:-main}:_scripts/check-frozen.ts" > "$tmp" 2>/dev/null || {
    echo "  WARN: no _scripts/check-frozen.ts on origin; skipping the frozen-path check." >&2
    rm -f "$tmp"; return 0
  }
  # Run from the operator's checkout with no project config: a tsconfig.json in
  # the slot can make ts-node load any file the agent wrote. A clone with no install (a private fork's
  # host clone) borrows the FxA host clone's ts-node: the check needs only Node, ts-node and TypeScript.
  local run="$root" fxa; fxa="$(pipeline_host_clone mozilla/fxa 2>/dev/null || true)"
  [ -x "$root/node_modules/.bin/ts-node" ] || { [ -n "$fxa" ] && [ -x "$fxa/node_modules/.bin/ts-node" ] && run="$fxa"; } || {
    echo "ERROR: the frozen-path check could not run: no ts-node in ${root} or in the FxA host clone. Run yarn install in ${root}, then finish again." >&2
    rm -rf "$(dirname "$tmp")"; return 1; }
  if ! (cd "$run" && GIT_DIR="$adm" GIT_WORK_TREE="$wt" TS_NODE_SKIP_PROJECT=true TS_NODE_TRANSPILE_ONLY=true \
        TS_NODE_COMPILER_OPTIONS='{"module":"commonjs","moduleResolution":"node"}' \
        npx --no-install ts-node "$tmp" >&2); then
    rm -rf "$(dirname "$tmp")"
    echo "ERROR: check:frozen (origin/main's copy) rejects this change." >&2
    return 1
  fi
  rm -rf "$(dirname "$tmp")"
}

# finish_notify <message> [pr_url]
#   macOS notification only; the caller logs the message.
finish_notify() {
  local message="$1"
  local pr_url="${2:-}"

  if command -v osascript >/dev/null 2>&1; then
    # Pass text as arguments: CI check names come from the agent's branch.
    osascript -e 'on run {m, s}' -e 'display notification m with title "fxa-sandbox-ctl" subtitle s' -e 'end run' -- "$message" "$pr_url" 2>/dev/null || true
  fi
  # A notification only: every caller logs the same message itself.
}
