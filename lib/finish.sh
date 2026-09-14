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
# A handoff file is not ready the instant it appears. The agent may still be
# committing, and it often amends afterwards (/code-simplifier, /fxa-review-quick).
# On 2026-08-17 FXA-14344 wrote its handoff while HEAD was still origin/main: the
# watcher returned immediately, the dirty-worktree guard in finish_push_and_pr
# refused, and the run stranded with a perfectly good commit landing seconds
# later. Detecting the file is not the same as the work being settled.
#
# Readiness is all three: parseable JSON, a clean worktree, and HEAD matching the
# sha the handoff names. Any of those failing just means "not yet", so the
# watcher keeps polling until its existing timeout.
_handoff_settled() {
  local wt="$1" f="$2"
  # gce: the handoff and the tree are on the runner until pulled. Ask for the
  # one file first; a full-tree pull every poll cost the runner CPU it needed
  # for the tests, and the 5 s loop was running at 150 s per turn.
  if [ "${FXA_VM_BACKEND:-tart}" = "gce" ] && [ ! -s "$f" ]; then
    local name; name="$(_worktree_agent_for_workspace "$wt")"
    [ -n "$name" ] && vm_exec "$name" test -s "/workspace/$(basename "$f")" 2>/dev/null || return 1
  fi
  _worktree_pull_if_remote "$wt"
  [ -s "$f" ] && jq -e . "$f" >/dev/null 2>&1 || return 1
  # There must be work to ship: uncommitted changes (the normal case, since the
  # agent cannot commit) or commits it somehow made. An empty worktree with a
  # handoff file means the agent wrote the handoff before doing the work.
  [ -n "$(worktree_filtered_status "$wt")" ] && return 0
  [ "$(git -C "$wt" rev-list --count "origin/${FXA_WORKTREE_BASE:-main}..HEAD" 2>/dev/null || echo 0)" != "0" ]
}

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
      if _handoff_settled "$(dirname "$done_file")" "$done_file"; then
        echo "" >&2
        echo "=== handoff file detected: ${done_file} ===" >&2
        return 0
      fi
    else
      local wt found=""
      while IFS= read -r wt; do
        [ -z "$wt" ] && continue
        local candidate="${wt}/${FXA_DONE_FILENAME}"
        if _handoff_settled "$wt" "$candidate"; then
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

# A failed re-commit is far more often the pre-commit hook rejecting the diff
# (lint-staged, or check:frozen on a frozen path) than a signing problem. Name
# the hook first and point at its output, which git already printed above.
_finish_recommit_failed() {
  echo "ERROR: re-commit failed. The pre-commit hook rejects the diff, or signing failed." >&2
  echo "       Read the hook output above first: 'yarn check:frozen' refuses edits to" >&2
  echo "       frozen paths, and lint-staged fails on lint errors." >&2
  echo "       If the hook output is clean, check 'git config commit.gpgsign' and that" >&2
  echo "       your signing key is unlocked." >&2
}

# finish_push_and_pr
#   Reads the handoff file and:
#     1. Verifies the branch + commit_sha match the worktree's current state.
#     2. Pushes the branch to origin.
#     3. Runs `gh pr create` with the title/body from the handoff file.
#   Prints the PR URL on stdout. Progress on stderr.
# _finish_release_runner <worktree>
#   gce only. The PR is open and the branch is on origin, so nothing after this
#   point reads the runner; a feedback round boots a fresh one. Tart keeps its
#   VM until the ticket is labeled done, which costs nothing there and about
#   $0.13 an hour here.
_finish_release_runner() {
  [ "${FXA_VM_BACKEND:-tart}" = "gce" ] || return 0
  local name; name="$(_worktree_agent_for_workspace "$1")"
  [ -n "$name" ] || return 0
  echo "Releasing runner '${name}': the PR is open and the branch is on origin." >&2
  agent_stop "$name" >&2 || echo "WARN: could not delete runner '${name}'; it is still billing. Run: fxa-sandbox-ctl --backend gce stop ${name}" >&2
}

# _finish_claim <worktree> / _finish_release <worktree>
#   While finish stages and commits, nothing else may touch the slot's git
#   state. On 2026-09-14 the dashboard feed ran `git status` on FXA-2598's slot
#   mid-commit and lint-staged failed with "could not write index". The marker
#   tells every reader (the pull-through, the snapshot rows) to skip the slot.
_finish_claim()   { : > "${LOG_DIR}/$(basename "$1").finishing"; }
_finish_release() { rm -f "${LOG_DIR}/$(basename "$1").finishing"; }
finish_is_claimed() { [ -f "${LOG_DIR}/$(basename "$1").finishing" ]; }

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
  # The agent's harness asks it to sign the body with a Claude Code footer and a
  # session link. A reviewer reads the PR, not the tooling; strip both here so
  # the rule does not depend on the VM's CLAUDE.md being current.
  pr_body="$(printf '%s\n' "$pr_body" | grep -vE 'Generated with \[?Claude Code|^https://claude\.ai/code/session_|^Claude-Session:' | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}')"

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

  # The agent CANNOT commit, by design. The parent .git is mounted read-only so a
  # sandboxed agent cannot rewrite a sibling worktree's admin files, and a linked
  # worktree's commit writes to the COMMON .git/objects and .git/refs, which are
  # shared with every other worktree. There is no narrower mount that permits one
  # worktree to commit while protecting the rest, so committing moved to the host.
  #
  # This used to refuse on a dirty worktree, which is now the expected state. On
  # 2026-08-17 FXA-14359 finished its work and stalled for 30 minutes reporting
  # "the read-only gitdir mount prevents any commit".
  #
  # Stage exactly what worktree_filtered_status reports, so the same ignore list
  # that decides "dirty" also decides what gets committed. A blanket `git add -A`
  # would sweep in newKey.json and the .fxa-* scratch files.
  # A rebase round arrives here mid-merge: the host merged the base branch in,
  # the agent resolved the files by editing them, and the index still lists them
  # as unmerged because editing a file does not clear its unmerged entry and the
  # VM cannot `git add` (the parent .git is mounted read-only). So finish the
  # merge here: check the markers are gone, then stage the paths.
  local merging=""
  if git -C "$worktree" rev-parse --verify -q MERGE_HEAD >/dev/null 2>&1; then
    merging=1
    local unmerged f still=""
    unmerged="$(git -C "$worktree" diff --name-only --diff-filter=U 2>/dev/null)"
    for f in $unmerged; do
      grep -qE '^(<{7}|={7}|>{7})( |$)' "${worktree}/${f}" 2>/dev/null && still="${still}${f} "
    done
    if [ -n "$still" ]; then
      echo "ERROR: conflict markers remain in:" >&2
      printf '  %s\n' $still >&2
      echo "       Refusing to commit: this would push markers into the PR." >&2
      return 1
    fi
    if [ -n "$unmerged" ]; then
      echo "Completing the merge: staging $(printf '%s\n' "$unmerged" | grep -c .) resolved file(s)..." >&2
      git -C "$worktree" add -- $unmerged >&2 || {
        echo "ERROR: could not stage the resolved files." >&2
        return 1
      }
    fi
    # Close the merge so MERGE_HEAD clears. `git reset --soft` refuses outright
    # while a merge is in progress ("Cannot do a soft reset in the middle of a
    # merge"), and the squash below depends on that reset. The squash discards
    # this commit immediately, so skip the hooks; the final commit still runs
    # them.
    git -C "$worktree" commit --no-edit --no-verify >&2 || {
      echo "ERROR: could not close the merge commit." >&2
      return 1
    }
  fi

  local dirty
  dirty="$(worktree_filtered_status "$worktree")"
  if [ -n "$dirty" ]; then
    echo "Staging agent changes on the host (the VM cannot commit)..." >&2
    local -a paths=()
    local line p
    while IFS= read -r line; do
      [ -z "$line" ] && continue
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

  # Something must exist to ship: either staged work, or commits the agent
  # somehow managed to make.
  if git -C "$worktree" diff --cached --quiet 2>/dev/null &&
     [ "$(git -C "$worktree" rev-list --count "origin/${FXA_WORKTREE_BASE:-main}..HEAD" 2>/dev/null || echo 0)" = "0" ]; then
    echo "ERROR: nothing to ship: no staged changes and no commits ahead of the base." >&2
    return 1
  fi

  # Squash and re-commit on the host so the commit picks up the user's GPG
  # (or SSH) signing config. The VM has no access to that key, so any commit
  # made in-VM lands unsigned. We collapse against the merge-base with the base
  # branch so the squash is correct regardless of how many commits the agent
  # made. Use the base branch, not main: on a release branch such as train-342
  # the merge-base with main is an old ancestor, and resetting to it would
  # squash every base-branch commit into the PR.
  local base_ref merge_base
  base_ref="origin/${FXA_WORKTREE_BASE:-main}"
  if [ -n "$merging" ]; then
    # A rebase round just merged the base in, so the squash target is the base
    # itself. Using the merge-base here would rewind to the OLD common ancestor
    # and re-commit there, leaving the PR still conflicting, which is the exact
    # thing the round set out to fix.
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
  # Carry the PR narrative into the commit body. `git log` is what a developer
  # reads months later, and a bare conventional subject loses the why. Keep the
  # prose sections and drop the PR-template scaffolding: the checklist and the
  # "(Optional)" sections are review furniture, not history.
  local commit_body
  commit_body="$(printf '%s\n' "$pr_body" | awk '
    /^## Checklist/            { skip = 1 }
    /^## .*\(Optional\)/       { skip = 1 }
    /^## /                     { if ($0 !~ /Checklist|\(Optional\)/) skip = 0 }
    !skip                      { print }
  ' | sed -e 's/[[:space:]]*$//' | cat -s)"

  if [ -n "${commit_body//[[:space:]]/}" ]; then
    git -C "$worktree" commit -m "$pr_title" -m "$commit_body" >&2 || {
      _finish_recommit_failed
      return 1
    }
  else
    git -C "$worktree" commit -m "$pr_title" >&2 || {
      _finish_recommit_failed
      return 1
    }
  fi
  local new_sha
  new_sha="$(git -C "$worktree" rev-parse HEAD)"
  echo "  signed HEAD: ${new_sha}" >&2

  # The host re-squashes and re-signs, so resuming/re-running an already-pushed
  # ticket leaves the local branch diverged from its remote and a plain push is
  # non-fast-forward. Try a normal push first; on rejection retry with
  # --force-with-lease, which still refuses to clobber if the remote moved for a
  # reason we didn't expect (someone else pushed to the branch).
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

  # Read media_paths from the handoff and turn them into `gh pr create --attach`
  # flags. gh 2.99.0+ uploads each file to GitHub's own asset store and rewrites
  # any matching body reference (e.g. `![alt](./shot.png)`), appending the rest.
  # This replaced secret gists, which are a text store: binary PNG/WebM through
  # `gh gist create` was never verified to survive intact.
  #
  # Skip a path the agent listed but never wrote. A stale entry must not cost us
  # the PR, for the same reason a missing label does not.
  local media_args=()
  local p local_media
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    local_media="${worktree}/${p#/workspace/}"
    if [ -f "$local_media" ]; then
      media_args+=(--attach "$local_media")
    else
      echo "  WARN: media listed but not found, skipping: ${p}" >&2
    fi
  done < <(jq -r '.media_paths // [] | .[]' "$done_file" 2>/dev/null)

  if [ "${#media_args[@]}" -gt 0 ]; then
    echo "Attaching $(( ${#media_args[@]} / 2 )) media file(s) to the PR..." >&2
  fi

  # Always save the rendered PR body to a file so the user can
  # `gh pr create --body-file` later without re-constructing it. Media is no
  # longer inlined here; it rides along as --attach.
  local body_file="${worktree}/.fxa-auto-pr-body.md"
  printf '%s\n' "$pr_body" > "$body_file"

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
    # Print empty pr_url so callers know not to expect a URL.
    printf '\n'
    return 0
  fi

  # Reviewer and assignee are added as separate best-effort steps after the PR
  # exists, not as `gh pr create` flags: an unknown handle or a permissions error
  # would otherwise fail the whole create and lose the PR. CODEOWNERS already
  # requests fxa-devs on most PRs, but not reliably (PR #21019 opened without it),
  # so ask explicitly and treat "already requested" as success.
  # A fix round pushes to a branch that already has a PR. `gh pr create` then
  # fails with "already exists" and this function returns early, so every step
  # after it is skipped — including the reviewer request and, worse, the
  # functional gate, which the push just reset to on_hold. On 2026-08-14 the
  # FXA-14325 feedback round pushed correctly and then sat with a PENDING gate
  # for exactly this reason. Detect the existing PR and update it instead.
  local pr_url existing
  existing="$(cd "$worktree" && gh pr list --head "$branch" --state open \
                --json url -q '.[0].url' 2>/dev/null)" || existing=""
  if [ -n "$existing" ]; then
    echo "PR already open for ${branch}; updating it instead of creating..." >&2
    pr_url="$existing"
    # Refresh the body only. NEVER touch the title of an existing PR.
    #
    # A fix or feedback round writes a handoff describing only that round, so
    # PATCHing the title replaces the PR's subject with the subject of its last
    # small change. The PR still holds the original diff, so the title then lies,
    # and because this repo squash-merges, the wrong subject lands in main's
    # history. On 2026-08-18 #21029 merged as "test(jest-transforms): cover the
    # SVG component name helper" when the PR was the camelcase removal; #21053
    # read as "preload chai so mocha does not race the ESM loader" for a 46 file
    # chai 5 upgrade, and #21054 as "drop the redundant initTracing call" for a
    # 16 file module removal.
    #
    # The title is set once, by `gh pr create`. Rounds may extend the body,
    # which is additive and safe. Do not "improve" this by re-adding the title.
    #
    # `gh pr edit` exits 1 on this repo (deprecated Projects-classic GraphQL
    # field), so go through REST.
    local pr_num="${existing##*/}"
    (cd "$worktree" && gh api -X PATCH "repos/{owner}/{repo}/pulls/${pr_num}" \
       -F "body=@${body_file}" >/dev/null 2>&1) \
      || echo "  WARN: could not refresh PR body. The pushed diff is still correct." >&2
    # The REST body PATCH cannot carry an upload, so a fix round's media goes on
    # as a comment. That also keeps each round's evidence next to the round,
    # instead of overwriting the original body's screenshots.
    if [ "${#media_args[@]}" -gt 0 ]; then
      (cd "$worktree" && gh pr comment "$pr_num" \
         --body "Updated evidence from the latest automated round." \
         ${media_args[@]+"${media_args[@]}"} >/dev/null 2>&1) \
        || echo "  WARN: could not attach round media to PR #${pr_num}." >&2
    fi
    finish_add_reviewers "$pr_url"
    _finish_release_runner "$worktree"
    printf '%s\n' "$pr_url"
    mv "$done_file" "${done_file}.$(date +%s)" 2>/dev/null || rm -f "$done_file"
    return 0
  fi

  echo "Creating pull request via gh..." >&2
  # ${arr[@]+"${arr[@]}"} — bash 3.2 under `set -u` treats a bare "${arr[@]}"
  # on an empty array as an unbound variable, which would break every PR that
  # has no media.
  pr_url="$(cd "$worktree" && gh pr create \
    --base "${FXA_WORKTREE_BASE:-main}" \
    --head "$branch" \
    --title "$pr_title" \
    --label "${FXA_PR_LABEL:-auto}" \
    ${media_args[@]+"${media_args[@]}"} \
    --body-file "$body_file" 2>&1)" || {
    # A missing label, or an attachment gh rejects, must not cost us the PR: the
    # branch is already pushed and the body is built, so retry once without
    # either. The PR is worth more than its label or its screenshots.
    echo "WARN: gh pr create failed with --label ${FXA_PR_LABEL:-auto}; retrying without it or media." >&2
    echo "$pr_url" >&2
    pr_url="$(cd "$worktree" && gh pr create \
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

  # gh prints the URL on the last line; pull it out cleanly.
  pr_url="$(printf '%s\n' "$pr_url" | tail -1)"

  finish_add_reviewers "$pr_url"

  _finish_release_runner "$worktree"
  printf '%s\n' "$pr_url"

  # Archive the handoff file so the next ticket can write a fresh one.
  mv "$done_file" "${done_file}.$(date +%s)" 2>/dev/null || rm -f "$done_file"
}

# finish_add_reviewers <pr_url>
#   Request review from the team and assign the ticket's reporter. Best effort:
#   every failure here is logged and ignored, because the PR already exists and
#   losing it over a reviewer request would be far worse.
#
#   FXA_PR_TEAM     team slug to request, default fxa-devs. Empty disables.
#   FXA_PR_ASSIGNEE GitHub login of the reporter. The caller resolves this; see
#                   ~/.claude/state/fxa-ai-fixme/reporters.tsv. Empty disables.
finish_add_reviewers() {
  local pr_url="${1:-}"
  [ -n "$pr_url" ] || return 0

  local team="${FXA_PR_TEAM-fxa-devs}"
  if [ -n "$team" ]; then
    # `gh pr edit` fails on this repo: it queries the deprecated Projects-classic
    # GraphQL field and exits 1. Use the REST review-requests endpoint instead.
    local owner_repo num
    owner_repo="$(printf '%s' "$pr_url" | sed -E 's#.*github\.com/([^/]+/[^/]+)/pull/.*#\1#')"
    num="$(printf '%s' "$pr_url" | sed -E 's#.*/pull/([0-9]+).*#\1#')"
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
      local owner_repo num
      owner_repo="$(printf '%s' "$pr_url" | sed -E 's#.*github\.com/([^/]+/[^/]+)/pull/.*#\1#')"
      num="$(printf '%s' "$pr_url" | sed -E 's#.*/pull/([0-9]+).*#\1#')"
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

# finish_approve_functional_gate <pr_url>
#   If CIRCLECI_TOKEN is set, find the PR's latest CircleCI pipeline and approve
#   the on-hold "Approve Functional Tests" gate so functional tests start. Called
#   before the CI watch. Non-fatal: any failure leaves the gate for manual
#   approval and the watch reports it pending, exactly as before.
finish_approve_functional_gate() {
  local pr_url="${1:-}"
  [ -n "$pr_url" ] || return 0

  # Token resolution, in order: CIRCLECI_TOKEN, the circleci CLI's env var, then
  # the CLI's stored config (~/.circleci/cli.yml) so a configured `circleci` CLI
  # works as a fallback without adding the token to this tool's .env.
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

  # Clear the manual functional-tests gate so its checks actually run before we watch.
  finish_approve_functional_gate "$pr_url"

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
