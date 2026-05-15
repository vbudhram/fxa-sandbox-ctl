#!/bin/bash
# worktree.sh — Manage a single shared "fxa-auto" git worktree for the agent.
#
# Why shared: a fresh worktree triggers full npm/yarn installs (slow). Reusing
# one worktree keeps node_modules warm. Each ticket gets its own branch swapped
# into the shared checkout.
#
# Public API:
#   worktree_repo_root             Resolve the FxA repo root.
#   worktree_shared_path           Print the shared worktree path.
#   worktree_branch_for KEY        Print the branch name for an issue (lowercased key).
#   worktree_prepare_for_issue KEY Ensure the shared worktree exists and is checked
#                                  out on the branch for KEY (created from origin/main
#                                  if new). Prints the worktree path on stdout.

[ -n "${_FXA_WORKTREE_LOADED:-}" ] && return 0
_FXA_WORKTREE_LOADED=1

: "${FXA_REPO_DEFAULT:=${HOME}/Desktop/working2/fxa}"
: "${FXA_WORKTREE_BASE:=main}"
: "${FXA_SHARED_WORKTREE_NAME:=fxa-auto}"

worktree_repo_root() {
  local candidate="${FXA_REPO:-$FXA_REPO_DEFAULT}"
  if [ ! -d "$candidate" ]; then
    echo "ERROR: FxA repo not found at '${candidate}'. Set FXA_REPO to override." >&2
    return 1
  fi
  if ! git -C "$candidate" rev-parse --show-toplevel >/dev/null 2>&1; then
    echo "ERROR: '${candidate}' is not a git repository." >&2
    return 1
  fi
  git -C "$candidate" rev-parse --show-toplevel
}

worktree_shared_path() {
  local root parent
  root="$(worktree_repo_root)" || return 1
  parent="$(dirname "$root")"
  printf '%s/%s\n' "$parent" "$FXA_SHARED_WORKTREE_NAME"
}

# Branch name for an issue: just the lowercased Jira key (e.g., FXA-13494 → fxa-13494).
worktree_branch_for() {
  local key="${1:-}"
  if [ -z "$key" ]; then
    echo "ERROR: worktree_branch_for requires ISSUE-KEY" >&2
    return 1
  fi
  printf '%s\n' "$key" | tr '[:upper:]' '[:lower:]'
}

# _worktree_each_active_agent
#   Yield "NAME WORKSPACE" lines for every .meta whose VM is actually running.
#   Stale metas (crashed orchestrators, TaskStop without cleanup) are skipped.
_worktree_each_active_agent() {
  local meta NAME WORKSPACE CPU MEMORY IP STARTED
  for meta in "${LOG_DIR}"/*.meta; do
    [ -f "$meta" ] || continue
    NAME=""; WORKSPACE=""
    source "$meta" 2>/dev/null
    [ -z "$NAME" ] || [ -z "$WORKSPACE" ] && continue
    if vm_is_running "$NAME" 2>/dev/null; then
      printf '%s %s\n' "$NAME" "$WORKSPACE"
    fi
  done
}

# List workspaces currently claimed by actively-running agents.
_worktree_busy_workspaces() {
  _worktree_each_active_agent | awk '{ $1=""; sub(/^ /,""); print }'
}

# Print the agent NAME whose VM is running on a given workspace path, if any.
_worktree_agent_for_workspace() {
  local target="$1"
  _worktree_each_active_agent | awk -v t="$target" '{
    name=$1; $1=""; sub(/^ /,"");
    if ($0 == t) { print name; exit }
  }'
}

# worktree_filtered_status <path>
#   Run `git status --porcelain` and drop lines that are known not to matter:
#     - our own orchestration files (.fxa-auto-*, .fxa-jira-*, .fxa-auto-token)
#     - the ai/ agent-context symlink convention
#     - per-worktree .claude/ state (claude-code creates this; not part of the fix)
#     - the FxA auth-server test key artifact (newKey.json)
#     - whatever extended-regex pattern the user puts in $FXA_DIRTY_IGNORE
#   Empty output means "clean enough for our purposes."
worktree_filtered_status() {
  local path="$1"
  local extra_pattern="${FXA_DIRTY_IGNORE:-}"
  git -C "$path" status --porcelain 2>/dev/null \
    | grep -vE '^\?\? \.fxa-(auto|jira)-' \
    | grep -vE '^\?\? ai/?$' \
    | grep -vE '^\?\? \.claude(/|$)' \
    | grep -vE '^\?\? packages/fxa-auth-server/config/newKey\.json$' \
    | { [ -n "$extra_pattern" ] && grep -vE "$extra_pattern" || cat; } \
    || true
}

# List all existing pool worktrees: <parent>/fxa-auto, fxa-auto-2, fxa-auto-3, ...
_worktree_pool_list() {
  local root
  root="$(worktree_repo_root)" || return 1
  local base="$FXA_SHARED_WORKTREE_NAME"
  git -C "$root" worktree list --porcelain 2>/dev/null \
    | awk '/^worktree /{print $2}' \
    | grep -E "/(${base}|${base}-[0-9]+)\$" \
    || true
}

# worktree_acquire_pool_slot [BASE]
#   Returns the absolute path to a free worktree from the pool, or creates the
#   next-numbered slot if all are busy. "Free" means no running agent .meta
#   file lists this workspace. Progress goes to stderr.
worktree_acquire_pool_slot() {
  local base="${1:-$FXA_WORKTREE_BASE}"
  local root parent
  root="$(worktree_repo_root)" || return 1
  parent="$(dirname "$root")"

  local pool busy
  pool="$(_worktree_pool_list)"
  busy="$(_worktree_busy_workspaces)"

  # First, try to reuse a free existing slot.
  local wt
  while IFS= read -r wt; do
    [ -z "$wt" ] && continue
    if ! printf '%s\n' "$busy" | grep -qFx "$wt"; then
      echo "Reusing free pool slot: ${wt}" >&2
      printf '%s\n' "$wt"
      return 0
    fi
  done <<< "$pool"

  # No free slot — figure out the next-numbered name. Init to 1 so the base
  # name (treated as slot 1) plus any existing numbered slots yields a sane
  # next number (e.g. pool=[fxa-auto] → next is fxa-auto-2, not fxa-auto-1).
  local max_suffix=1 has_base=0 suffix name
  while IFS= read -r wt; do
    [ -z "$wt" ] && continue
    name="$(basename "$wt")"
    if [ "$name" = "$FXA_SHARED_WORKTREE_NAME" ]; then
      has_base=1
    else
      suffix="$(printf '%s' "$name" | sed -n "s/^${FXA_SHARED_WORKTREE_NAME}-\([0-9]\+\)\$/\1/p")"
      [ -n "$suffix" ] && [ "$suffix" -gt "$max_suffix" ] && max_suffix="$suffix"
    fi
  done <<< "$pool"

  local new_name new_path
  if [ "$has_base" -eq 0 ]; then
    new_name="$FXA_SHARED_WORKTREE_NAME"
  else
    new_name="${FXA_SHARED_WORKTREE_NAME}-$((max_suffix + 1))"
  fi
  new_path="${parent}/${new_name}"

  echo "All pool slots busy; creating new slot ${new_path} off origin/${base}." >&2
  echo "(Note: a brand-new slot needs 'yarn install' on first agent run — ~5-10 min.)" >&2

  if ! git -C "$root" fetch origin "$base" >&2; then
    echo "ERROR: 'git fetch origin ${base}' failed." >&2
    return 1
  fi

  local holding="${new_name}-holding"
  if git -C "$root" show-ref --verify --quiet "refs/heads/${holding}"; then
    git -C "$root" -c core.hooksPath=/dev/null worktree add "$new_path" "$holding" >&2 || return 1
  else
    git -C "$root" -c core.hooksPath=/dev/null worktree add -b "$holding" "$new_path" "origin/${base}" >&2 || return 1
  fi
  printf '%s\n' "$new_path"
}

# worktree_create_named <name> [base]
#   Create (or reuse) a worktree at <parent>/<name> off origin/<base>. If the
#   path already exists and is a registered worktree, returns its path. If the
#   path exists but isn't a worktree, errors out rather than clobber.
worktree_create_named() {
  local name="${1:-}"
  local base="${2:-$FXA_WORKTREE_BASE}"

  if [ -z "$name" ]; then
    echo "ERROR: worktree_create_named requires a name" >&2
    return 1
  fi

  local root parent path
  root="$(worktree_repo_root)" || return 1
  parent="$(dirname "$root")"
  path="${parent}/${name}"

  if git -C "$root" worktree list --porcelain | awk '/^worktree /{print $2}' | grep -qFx "$path"; then
    printf '%s\n' "$path"
    return 0
  fi

  if [ -e "$path" ]; then
    echo "ERROR: ${path} exists but is not a registered git worktree." >&2
    return 1
  fi

  echo "Creating worktree ${path} off origin/${base}." >&2
  if ! git -C "$root" fetch origin "$base" >&2; then
    echo "ERROR: 'git fetch origin ${base}' failed." >&2
    return 1
  fi

  local holding="${name}-holding"
  if git -C "$root" show-ref --verify --quiet "refs/heads/${holding}"; then
    git -C "$root" -c core.hooksPath=/dev/null worktree add "$path" "$holding" >&2 || return 1
  else
    git -C "$root" -c core.hooksPath=/dev/null worktree add -b "$holding" "$path" "origin/${base}" >&2 || return 1
  fi
  printf '%s\n' "$path"
}

# Ensure the shared worktree exists. Creates it off origin/<base> if missing.
# Kept for backward compatibility (cmd_tail, finish_done_file_path default).
_worktree_ensure_shared() {
  local base="${1:-$FXA_WORKTREE_BASE}"
  local root path
  root="$(worktree_repo_root)" || return 1
  path="$(worktree_shared_path)" || return 1

  if git -C "$root" worktree list --porcelain | awk '/^worktree /{print $2}' | grep -qx "$path"; then
    printf '%s\n' "$path"
    return 0
  fi

  if [ -e "$path" ]; then
    echo "ERROR: ${path} exists but is not a registered git worktree." >&2
    echo "       Remove it or unregister and retry." >&2
    return 1
  fi

  echo "Shared worktree not found; creating ${path} off origin/${base}." >&2
  echo "Fetching origin/${base}..." >&2
  if ! git -C "$root" fetch origin "$base" >&2; then
    echo "ERROR: 'git fetch origin ${base}' failed." >&2
    return 1
  fi
  if ! git -C "$root" rev-parse --verify --quiet "refs/remotes/origin/${base}" >/dev/null; then
    echo "ERROR: origin/${base} not found after fetch." >&2
    return 1
  fi

  # Use a long-lived holding branch so the worktree always has a checked-out
  # branch even between tickets. Tickets branch off origin/<base> directly.
  local holding="${FXA_SHARED_WORKTREE_NAME}-holding"
  if git -C "$root" show-ref --verify --quiet "refs/heads/${holding}"; then
    git -C "$root" worktree add "$path" "$holding" >&2 || return 1
  else
    git -C "$root" worktree add -b "$holding" "$path" "origin/${base}" >&2 || return 1
  fi
  printf '%s\n' "$path"
}

# worktree_prepare_for_issue <ISSUE-KEY> [BASE]
#   1. Ensures the shared worktree exists.
#   2. Refuses to proceed if the worktree has uncommitted changes (safety).
#   3. Fetches origin/<base>.
#   4. If branch exists locally, checks it out (resume mode).
#      Otherwise, creates it off origin/<base>.
#   Prints the worktree path on stdout. Progress on stderr.
worktree_prepare_for_issue() {
  local key="${1:-}"
  local base="${2:-$FXA_WORKTREE_BASE}"
  local named_slot="${3:-}"

  if [ -z "$key" ]; then
    echo "ERROR: worktree_prepare_for_issue requires ISSUE-KEY" >&2
    return 1
  fi

  local branch path
  branch="$(worktree_branch_for "$key")" || return 1
  if [ -n "$named_slot" ]; then
    # Explicit slot: create if missing, reuse if already there.
    path="$(worktree_create_named "$named_slot" "$base")" || return 1
    local busy_agent
    busy_agent="$(_worktree_agent_for_workspace "$path")"
    if [ -n "$busy_agent" ]; then
      # Another agent's VM is actively running on this worktree. Prompt to
      # confirm — concurrent agents on the same worktree corrupt each other.

      # Use /dev/tty directly so the check works even when this function is
      # called inside $( ... ) command substitution (which captures stdout
      # and would defeat `[ -t 1 ]`).
      if [ -r /dev/tty ] && [ -w /dev/tty ]; then
        {
          echo ""
          echo "WARNING: agent '${busy_agent}' is actively running on ${path}."
          echo "         Reusing the worktree will mount it into a second VM and likely corrupt both agents' work."
          printf "Continue anyway? [y/N] "
        } >/dev/tty
        local reply
        read -r reply </dev/tty
        case "$reply" in
          [yY]|[yY][eE][sS]) echo "Proceeding." >&2 ;;
          *) echo "Aborted. Stop '${busy_agent}' first or use a different --worktree name." >&2; return 1 ;;
        esac
      else
        echo "ERROR: agent '${busy_agent}' is running on ${path}." >&2
        echo "       No controlling TTY available to prompt — stop the agent or pick a different worktree." >&2
        return 1
      fi
    fi
  else
    # No --worktree: acquire a free pool slot, or create the next-numbered one.
    path="$(worktree_acquire_pool_slot "$base")" || return 1
  fi

  # Warn (but don't refuse) on uncommitted/untracked changes. The agent will
  # inherit whatever state the worktree is in — git checkout itself will fail
  # if a swap would clobber real work, which is the proper safety net.
  local dirty
  dirty="$(worktree_filtered_status "$path")"
  if [ -n "$dirty" ]; then
    local current
    current="$(git -C "$path" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")"
    echo "Note: worktree ${path} has uncommitted/untracked changes on '${current}':" >&2
    printf '%s\n' "$dirty" | head -10 >&2
    echo "      Proceeding — the agent will inherit this state." >&2
  fi

  echo "Fetching origin/${base}..." >&2
  git -C "$path" fetch origin "$base" >&2 || {
    echo "ERROR: 'git fetch origin ${base}' failed." >&2
    return 1
  }

  # Skip git hooks on the branch swap. FxA's post-checkout hook clones
  # external/l10n, which is not idempotent — running it after the initial
  # worktree-add (which already cloned l10n) fatals on "directory not empty".
  local nohooks="-c core.hooksPath=/dev/null"
  if git -C "$path" show-ref --verify --quiet "refs/heads/${branch}"; then
    echo "Branch '${branch}' already exists locally; resuming." >&2
    git -C "$path" $nohooks checkout "$branch" >&2 || return 1
  else
    echo "Creating branch '${branch}' off origin/${base}." >&2
    git -C "$path" $nohooks checkout -b "$branch" "origin/${base}" >&2 || return 1
  fi

  printf '%s\n' "$path"
}
