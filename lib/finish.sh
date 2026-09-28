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

# _finish_media_to_bucket <body_file> <array-name>
#   The App cannot upload GitHub attachments, so upload to the public bucket at
#   an unguessable path and rewrite the body. Prints the Markdown for all files.
_finish_media_to_bucket() {
  local body_file="$1" _media_arr="$2" f name url dir md="" n=0 files=()
  eval "files=(\${${_media_arr}[@]+\"\${${_media_arr}[@]}\"})"
  dir="${branch:-media}/$(openssl rand -hex 8)"
  for f in ${files[@]+"${files[@]}"}; do
    [ "$f" = --attach ] && continue
    name="$(basename "$f" | tr -c 'A-Za-z0-9._\n-' '-')"; n=$((n + 1))
    local err; err="$(gcloud storage cp -q "$f" "gs://${FXA_MEDIA_BUCKET}/${dir}/${n}/${name}" --cache-control="public, max-age=3600" 2>&1 >/dev/null)" \
      || { echo "  WARN: could not upload ${name} to the media bucket: $(printf '%s' "$err" | grep -m1 ERROR | cut -c1-200)" >&2; continue; }
    url="https://storage.googleapis.com/${FXA_MEDIA_BUCKET}/${dir}/${n}/${name}"
    case "$name" in *.mp4|*.webm|*.mov) md="${md}[${name}](${url})"$'\n' ;; *) md="${md}![${name}](${url})"$'\n' ;; esac
    # Rewrite `(./shot.png)` and `(shot.png)` references in place; append the rest.
    python3 - "$body_file" "$(basename "$f")" "$url" <<'PY' | slot_write "${body_file}.new" && mv -f "${body_file}.new" "$body_file"
import sys
path, name, url = sys.argv[1:]
body = open(path).read()
new = body.replace("(./" + name + ")", "(" + url + ")").replace("(" + name + ")", "(" + url + ")")
if new == body:
    link = ("[%s](%s)" if name.rsplit(".", 1)[-1] in ("mp4", "webm", "mov") else "![%s](%s)") % (name, url)
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
real = fcntl.fcntl(fd, fcntl.F_GETPATH, bytes(1024)).rstrip(b"\0").decode()
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

  local issue branch commit_sha pr_title pr_body
  issue="$(jq -r '.issue // empty' "$done_file")"
  branch="$(jq -r '.branch // empty' "$done_file")"
  commit_sha="$(jq -r '.commit_sha // empty' "$done_file")"
  pr_title="$(jq -r '.pr_title // empty' "$done_file")"
  pr_body="$(jq -r '.pr_body // empty' "$done_file")"
  # Strip the harness's Claude Code footer and session link here, whatever the VM's CLAUDE.md says.
  pr_body="$(printf '%s\n' "$pr_body" | grep -vE 'Generated with \[?Claude Code|^https://claude\.ai/code/session_|^Claude-Session:' | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}')"

  if [ -z "$branch" ] || [ -z "$pr_title" ] || [ -z "$pr_body" ]; then
    echo "ERROR: handoff file is missing required keys (branch, pr_title, pr_body):" >&2
    cat "$done_file" >&2
    return 1
  fi
  # The title becomes a commit subject and a gh argument. One line, printable.
  if [ "${#pr_title}" -gt 200 ] || [[ "$pr_title" == *[[:cntrl:]]* ]]; then
    echo "ERROR: pr_title is over 200 chars or contains control characters. Refusing." >&2
    return 1
  fi

  worktree_git_ok "$worktree" >/dev/null || return 1
  local current_branch
  current_branch="$(git -C "$worktree" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  if [ "$current_branch" != "$branch" ]; then
    echo "ERROR: worktree is on '${current_branch}' but handoff says '${branch}'." >&2
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
  local commit_count
  commit_count="$(git -C "$worktree" rev-list --count "${merge_base}..HEAD")"
  echo "Squashing ${commit_count} commit(s) and re-signing on host..." >&2
  git -C "$worktree" reset --soft "$merge_base" >&2 || {
    echo "ERROR: soft reset to merge-base failed." >&2
    return 1
  }
  # After the reset the index holds the whole change, a rebase round's merge included.
  _finish_tooling_guard "$worktree" || return 1
  _finish_check_frozen "$worktree" || return 1
  # The PR body becomes the commit body so `git log` keeps the why. Drop the
  # checklist and "(Optional)" template sections.
  local commit_body
  commit_body="$(printf '%s\n' "$pr_body" | awk '
    /^## Checklist/            { skip = 1 }
    /^## .*\(Optional\)/       { skip = 1 }
    /^## /                     { if ($0 !~ /Checklist|\(Optional\)/) skip = 0 }
    !skip                      { print }
  ' | sed -e 's/[[:space:]]*$//' | cat -s)"

  # As the GitHub App: GitHub authors and signs the commit, and the operator's
  # key and login stay out of the push. gh below also acts as the App.
  if github_app_enabled; then
    local new_sha GH_TOKEN
    echo "Committing and pushing ${branch} as the GitHub App..." >&2
    new_sha="$(github_app_commit "$worktree" "$branch" "$merge_base" \
      "$(printf '%s' "$pr_title"; [ -n "${commit_body//[[:space:]]/}" ] && printf '\n\n%s' "$commit_body")")" || return 1
    echo "  App commit: ${new_sha}" >&2
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

  # Always save the body, so the user can run `gh pr create --body-file` later.
  local body_file="${worktree}/.fxa-auto-pr-body.md"
  printf '%s\n' "$pr_body" | slot_write "$body_file"
  local media_md=""
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
  local pr_url existing
  existing="$(cd "$worktree" && gh pr list --head "$branch" --state open \
                --json url -q '.[0].url' 2>/dev/null)" || existing=""
  if [ -n "$existing" ]; then
    echo "PR already open for ${branch}; updating it instead of creating..." >&2
    pr_url="$existing"
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
    pr_url="$(cd "$worktree" && gh pr list --head "$branch" --state open --json url -q '.[0].url' 2>/dev/null)"
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

  finish_add_reviewers "$pr_url"

  _finish_release_runner "$worktree"
  printf '%s\n' "$pr_url"

  # Archive the handoff file so the next ticket can write a fresh one.
  mv "$done_file" "${done_file}.$(date +%s)" 2>/dev/null || rm -f "$done_file"
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
      else
        # Already-requested is the common case: CODEOWNERS covers most PRs.
        echo "  NOTE: review request for ${team} not added (already requested, or no permission)." >&2
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

  # Fall back to the circleci CLI's config, so the token need not be in .env.
  local token="${CIRCLECI_TOKEN:-${CIRCLECI_CLI_TOKEN:-}}"
  if [ -z "$token" ] && [ -f "${HOME}/.circleci/cli.yml" ]; then
    token="$(sed -n 's/^token:[[:space:]]*//p' "${HOME}/.circleci/cli.yml" | head -1 | tr -d '\42\47')" || token=""
  fi
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
  slug="gh/${owner_repo}"
  branch="$(gh pr view "$pr_url" --json headRefName -q .headRefName 2>/dev/null)" || branch=""
  if [ -z "$branch" ]; then
    echo "WARN: couldn't resolve PR branch; skipping gate approval." >&2
    return 0
  fi

  local api="https://circleci.com/api/v2"
  local hdr="Circle-Token: ${token}"

  echo "Looking for the functional-tests approval gate on ${slug}@${branch}..." >&2
  local elapsed=0
  while [ "$elapsed" -lt 180 ]; do
    local pipeline_id
    # `|| =""` keeps a failed curl (HTTP error, DNS) from aborting under set -e.
    pipeline_id="$(curl -fsS -H "$hdr" "${api}/project/${slug}/pipeline?branch=${branch}" 2>/dev/null \
      | jq -r '.items[0].id // empty')" || pipeline_id=""
    if [ -n "$pipeline_id" ]; then
      local wf arid
      # Reads the first page of workflows/jobs; the PR gate sits early in the list.
      for wf in $(curl -fsS -H "$hdr" "${api}/pipeline/${pipeline_id}/workflow" 2>/dev/null \
                    | jq -r '.items[].id'); do
        arid="$(curl -fsS -H "$hdr" "${api}/workflow/${wf}/job" 2>/dev/null \
          | jq -r '.items[]
              | select(.type=="approval" and .status=="on_hold" and (.name | test("Functional";"i")))
              | (.approval_request_id // .id)' \
          | head -1)" || arid=""
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

  # Ignore the watch's exit code: the JSON query below is the real result.
  gh pr checks "$pr_url" --watch --interval 30 >&2 || true

  local json
  json="$(gh pr checks "$pr_url" --json bucket,name,state 2>/dev/null)" || {
    echo "WARN: couldn't read final CI state via gh." >&2
    return 1
  }

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
#   hooks run on the operator's Mac. FXA_ALLOW_TOOLING_EDITS=1 allows them.
_finish_tooling_guard() {
  local wt="$1" f hit=""
  [ "${FXA_ALLOW_TOOLING_EDITS:-}" = "1" ] && return 0
  while IFS= read -r -d '' f; do
    case "$f" in
      .github/*|.circleci/*|.husky/*|_scripts/*|*/.husky/*|.lintstagedrc*|*/.lintstagedrc*|lint-staged.config.*|*/lint-staged.config.*|\
      .yarnrc*|*/.yarnrc*|.yarn/*|.npmrc|*/.npmrc)
        hit="${hit}${f}"$'\n' ;;
      package.json|*/package.json)
        # Only the parts a hook or CI executes. A dependency bump is fine.
        if [ "$(git -C "$wt" show ":$f" 2>/dev/null | jq -cS '{scripts, "lint-staged", husky}')" != \
             "$(git -C "$wt" show "HEAD:$f" 2>/dev/null | jq -cS '{scripts, "lint-staged", husky}')" ]; then
          hit="${hit}${f} (scripts/lint-staged/husky)"$'\n'
        fi ;;
    esac
  done < <(git -C "$wt" diff --cached -z --name-only 2>/dev/null)
  [ -z "$hit" ] && return 0
  echo "ERROR: refusing to ship: the change touches CI or host tooling:" >&2
  printf '  %s\n' "$hit" >&2
  echo "       Relaunch with FXA_ALLOW_TOOLING_EDITS=1 if the ticket asks for this." >&2
  return 1
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
  # the slot can make ts-node load any file the agent wrote.
  if ! (cd "$root" && GIT_DIR="$adm" GIT_WORK_TREE="$wt" TS_NODE_SKIP_PROJECT=true TS_NODE_TRANSPILE_ONLY=true \
        TS_NODE_COMPILER_OPTIONS='{"module":"commonjs","moduleResolution":"node"}' \
        npx --no-install ts-node "$tmp" >&2); then
    rm -rf "$(dirname "$tmp")"
    echo "ERROR: check:frozen (origin/main's copy) rejects this change." >&2
    return 1
  fi
  rm -rf "$(dirname "$tmp")"
}

# finish_notify <message> [pr_url]
#   macOS notification, plus the same line on stderr.
finish_notify() {
  local message="$1"
  local pr_url="${2:-}"

  if command -v osascript >/dev/null 2>&1; then
    # Pass text as arguments: CI check names come from the agent's branch.
    osascript -e 'on run {m, s}' -e 'display notification m with title "fxa-sandbox-ctl" subtitle s' -e 'end run' -- "$message" "$pr_url" 2>/dev/null || true
  fi
  echo "${message}${pr_url:+ — $pr_url}" >&2
}
