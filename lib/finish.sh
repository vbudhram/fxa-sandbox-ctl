#!/bin/bash
# finish.sh — Host-side post-agent handoff: push the branch and create the PR.
#
# The agent writes /workspace/.fxa-auto-done.json when it finishes implementing
# and committing. Because /workspace is a virtiofs mount of the host's shared
# worktree, the file appears on the host with no SSH needed. The host then
# pushes the branch and runs `gh pr create` using its own credentials.
#
# Public API:
#   finish_done_file_path           Print the absolute path to the handoff file.
#   finish_wait_for_done [timeout]  Block until the handoff file exists. Returns
#                                   0 on detection, 1 on timeout.
#   finish_push_and_pr              Read the handoff file, push the branch,
#                                   create the PR. Prints the PR URL on stdout.

[ -n "${_FXA_FINISH_LOADED:-}" ] && return 0
_FXA_FINISH_LOADED=1

FINISH_LIB_DIR="$(dirname "${BASH_SOURCE[0]}")"
source "${FINISH_LIB_DIR}/config.sh"
source "${FINISH_LIB_DIR}/worktree.sh"

# Filename the agent writes as its handoff signal. Lives at the root of the
# shared worktree.
: "${FXA_DONE_FILENAME:=.fxa-auto-done.json}"

# finish_done_file_path [worktree]
#   Print the absolute path of the handoff JSON for the given worktree (or for
#   the canonical fxa-auto base if no worktree is supplied — kept for legacy
#   callers that don't track a specific slot).
finish_done_file_path() {
  local worktree="${1:-}"
  if [ -z "$worktree" ]; then
    worktree="$(worktree_shared_path)" || return 1
  fi
  printf '%s/%s\n' "$worktree" "$FXA_DONE_FILENAME"
}

# finish_wait_for_done [timeout_seconds]
#   Polls the shared worktree for the handoff file. Default timeout is 2 hours.
#   Prints a progress dot every 30s so the user knows it's alive.
# finish_upload_media <worktree> <relative_path1> [<relative_path2> ...]
#   Uploads each media file as a secret gist (default for `gh gist create`)
#   and emits a markdown "## Media" section to stdout that embeds each file
#   inline (images) or links it (videos/other). Paths are relative to the
#   worktree root.
finish_upload_media() {
  local worktree="$1"
  shift
  local rels=("$@")
  [ "${#rels[@]}" -eq 0 ] && return 0
  if ! command -v gh >/dev/null 2>&1; then
    echo "(media upload skipped: gh not installed)" >&2
    return 0
  fi

  local out=""
  out+=$'\n## Media\n\n'

  local rel local_file filename gist_url gist_id user raw_url
  for rel in "${rels[@]}"; do
    [ -z "$rel" ] && continue
    # Allow callers to pass either absolute /workspace/... or relative paths.
    local_file="${worktree}/${rel#/workspace/}"
    if [ ! -f "$local_file" ]; then
      out+="(missing: ${rel})"$'\n\n'
      continue
    fi
    filename="$(basename "$local_file")"

    echo "Uploading ${filename} as secret gist..." >&2
    gist_url="$(gh gist create -d "fxa-sandbox-ctl: ${filename}" "$local_file" 2>/dev/null | tail -1)"
    if [ -z "$gist_url" ] || [[ "$gist_url" != https://gist.github.com/* ]]; then
      out+="(upload failed: ${rel})"$'\n\n'
      continue
    fi

    gist_id="$(basename "$gist_url")"
    user="$(printf '%s\n' "$gist_url" | awk -F/ '{print $(NF-1)}')"
    raw_url="https://gist.githubusercontent.com/${user}/${gist_id}/raw/${filename}"

    # macOS /bin/bash is 3.2 which lacks ${var,,} — lowercase via tr.
    local lower_name
    lower_name="$(printf '%s' "$filename" | tr '[:upper:]' '[:lower:]')"
    case "$lower_name" in
      *.png|*.jpg|*.jpeg|*.gif|*.webp)
        out+="![${filename}](${raw_url})"$'\n\n'
        ;;
      *.webm|*.mp4|*.mov)
        out+="<video src=\"${raw_url}\" controls></video>"$'\n\n'
        out+="[Download ${filename}](${gist_url})"$'\n\n'
        ;;
      *)
        out+="[${filename}](${gist_url})"$'\n\n'
        ;;
    esac
  done

  printf '%s' "$out"
}

# finish_attach_and_wait <agent-name>
#   SSH into the agent's screen session in the foreground (user sees the live
#   Claude TUI) while a background poller watches for the handoff file. When
#   the handoff appears, the poller kills the SSH so control returns here for
#   push + PR. If the user Ctrl-C's before the handoff, returns 1 so the
#   caller can print a resume hint.
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
  # Use THIS agent's workspace, not the singleton — multiple agents can run
  # concurrently in different pool slots.
  local done_file
  done_file="$(finish_done_file_path "${WORKSPACE}")" || return 1

  # Without a TTY (e.g. invoked from a script or background process), the TUI
  # can't render. Fall back to silent polling so the orchestration still works;
  # the user can `attach` in their own terminal to see Claude live.
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

  # Background poller: when the handoff JSON appears, kill the SSH attached
  # to this VM's screen so control returns to the foreground.
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

  # Foreground SSH+attach. `screen -x` is multi-attach (won't conflict with
  # a separate `fxa-sandbox-ctl attach`).
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

# finish_wait_for_done [worktree] [timeout_seconds]
#   Silent poll for the handoff file. Used by `fxa-sandbox-ctl finish --wait`
#   when there's no TUI to attach to. Prints a heartbeat every 30s. If no
#   worktree is supplied, scans every pool slot for a valid handoff so an
#   agent running in fxa-auto-2+ is still detected.
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

  while [ "$elapsed" -lt "$timeout" ]; do
    if [ -n "$done_file" ]; then
      if [ -s "$done_file" ] && jq -e . "$done_file" >/dev/null 2>&1; then
        echo "" >&2
        echo "=== handoff file detected: ${done_file} ===" >&2
        return 0
      fi
    else
      local wt found=""
      while IFS= read -r wt; do
        [ -z "$wt" ] && continue
        local candidate="${wt}/${FXA_DONE_FILENAME}"
        if [ -s "$candidate" ] && jq -e . "$candidate" >/dev/null 2>&1; then
          found="$candidate"
          break
        fi
      done < <(_worktree_pool_list)
      if [ -n "$found" ]; then
        echo "" >&2
        echo "=== handoff file detected: ${found} ===" >&2
        return 0
      fi
    fi
    sleep 5
    elapsed=$(( $(date +%s) - started ))
    # Heartbeat every 30s.
    if [ $(( elapsed % 30 )) -eq 0 ]; then
      printf '[%4ds] ' "$elapsed" >&2
    fi
  done

  echo "" >&2
  echo "ERROR: timed out after ${timeout}s waiting for handoff file." >&2
  return 1
}

# finish_push_and_pr
#   Reads the handoff file and:
#     1. Verifies the branch + commit_sha match the worktree's current state.
#     2. Pushes the branch to origin.
#     3. Runs `gh pr create` with the title/body from the handoff file.
#   Prints the PR URL on stdout. Progress on stderr.
finish_push_and_pr() {
  if ! command -v gh >/dev/null 2>&1; then
    echo "ERROR: gh CLI not installed on the host. Install with: brew install gh" >&2
    return 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq not installed on the host." >&2
    return 1
  fi

  # $1 = worktree path (optional, auto-detected if empty)
  # $2 = "true" to actually run `gh pr create`; otherwise just push and print
  #      the gh command the user can paste to open the PR themselves.
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

  if [ -z "$branch" ] || [ -z "$pr_title" ] || [ -z "$pr_body" ]; then
    echo "ERROR: handoff file is missing required keys (branch, pr_title, pr_body):" >&2
    cat "$done_file" >&2
    return 1
  fi

  # Verify the worktree is on the expected branch.
  local current_branch
  current_branch="$(git -C "$worktree" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  if [ "$current_branch" != "$branch" ]; then
    echo "ERROR: worktree is on '${current_branch}' but handoff says '${branch}'." >&2
    return 1
  fi

  # Verify the commit_sha (if present) matches HEAD.
  if [ -n "$commit_sha" ]; then
    local head_sha
    head_sha="$(git -C "$worktree" rev-parse HEAD 2>/dev/null)"
    if [ "$head_sha" != "$commit_sha" ]; then
      echo "WARN: HEAD is ${head_sha} but handoff names ${commit_sha}. Continuing with HEAD." >&2
    fi
  fi

  # Refuse to push if the agent left uncommitted code. worktree_filtered_status
  # uses the same ignore list as the prepare-time check, so behavior is
  # consistent end to end.
  local dirty
  dirty="$(worktree_filtered_status "$worktree")"
  if [ -n "$dirty" ]; then
    echo "ERROR: worktree has uncommitted changes:" >&2
    printf '%s\n' "$dirty" | head -10 >&2
    echo "       Inspect and clean up first: git -C '${worktree}' status" >&2
    return 1
  fi

  echo "Pushing ${branch} to origin..." >&2
  git -C "$worktree" push -u origin "$branch" >&2 || {
    echo "ERROR: git push failed." >&2
    return 1
  }

  # Read media_paths from the handoff and upload them as secret gists. The
  # markdown block is appended to pr_body before gh pr create.
  local media_paths=()
  while IFS= read -r p; do
    [ -n "$p" ] && media_paths+=("$p")
  done < <(jq -r '.media_paths // [] | .[]' "$done_file" 2>/dev/null)

  if [ "${#media_paths[@]}" -gt 0 ]; then
    echo "Uploading ${#media_paths[@]} media file(s) as secret gists..." >&2
    local media_md
    media_md="$(finish_upload_media "$worktree" "${media_paths[@]}")"
    if [ -n "$media_md" ]; then
      pr_body="${pr_body}${media_md}"
    fi
  fi

  # Always save the rendered PR body (with media URLs) to a file so the user
  # can `gh pr create --body-file` later without re-constructing it.
  local body_file="${worktree}/.fxa-auto-pr-body.md"
  printf '%s\n' "$pr_body" > "$body_file"

  if [ "$create_pr" != "true" ]; then
    echo "" >&2
    echo "=== Branch pushed; PR not auto-created ===" >&2
    echo "Review the commit, body, and any media URLs, then run:" >&2
    echo "" >&2
    printf '  cd %q\n' "$worktree" >&2
    printf '  gh pr create --base %s --head %s --title %q --body-file %s\n' \
      "${FXA_WORKTREE_BASE:-main}" "$branch" "$pr_title" ".fxa-auto-pr-body.md" >&2
    echo "" >&2
    echo "Or pass --create-pr to your next 'jira' / 'finish' invocation to do it automatically." >&2
    # Archive the handoff so the next ticket can write a fresh one.
    mv "$done_file" "${done_file}.$(date +%s)" 2>/dev/null || rm -f "$done_file"
    # Print empty pr_url so callers know not to expect a URL.
    printf '\n'
    return 0
  fi

  echo "Creating pull request via gh..." >&2
  local pr_url
  pr_url="$(cd "$worktree" && gh pr create \
    --base "${FXA_WORKTREE_BASE:-main}" \
    --head "$branch" \
    --title "$pr_title" \
    --body-file "$body_file" 2>&1)" || {
    echo "ERROR: gh pr create failed:" >&2
    echo "$pr_url" >&2
    return 1
  }

  # gh prints the URL on the last line; pull it out cleanly.
  pr_url="$(printf '%s\n' "$pr_url" | tail -1)"
  printf '%s\n' "$pr_url"

  # Archive the handoff file so the next ticket can write a fresh one.
  mv "$done_file" "${done_file}.$(date +%s)" 2>/dev/null || rm -f "$done_file"
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

  echo "Waiting for CI to register checks on ${pr_url}..." >&2
  # CI can take a minute or two to attach checks to a freshly-opened PR.
  # `gh pr checks --watch` exits immediately with "no checks reported" if zero
  # exist, so poll until at least one shows up, then switch to --watch.
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

  # gh pr checks --watch streams progress and exits when checks settle.
  # --interval 30 cuts API churn. We tolerate non-zero exits (exit code 8 means
  # "checks pending" if the watcher is interrupted; the json query below is the
  # authoritative source.)
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
    # Watcher was interrupted before all checks finished.
    echo "CI still pending: ${pending_names}" >&2
    return 1
  fi
  finish_notify "CI passed on PR" "$pr_url"
  echo "" >&2
  echo "All CI checks passed." >&2
  return 0
}

# finish_notify <message> [pr_url]
#   macOS notification via osascript. Cheap, no extra deps.
finish_notify() {
  local message="$1"
  local pr_url="${2:-}"
  local subtitle=""
  [ -n "$pr_url" ] && subtitle="$pr_url"

  if command -v osascript >/dev/null 2>&1; then
    osascript -e "display notification \"${message}\" with title \"fxa-sandbox-ctl\" subtitle \"${subtitle}\"" 2>/dev/null || true
  fi
  echo "${message}${pr_url:+ — $pr_url}" >&2
}
