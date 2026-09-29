#!/bin/bash
# worktree.sh: Manage the pool of "fxa-auto" git worktrees for the agent.
#
# Slots are reused because a fresh worktree needs a full yarn install (slow).
# Each ticket swaps its own branch into a slot.
#
# Public API:
#   worktree_repo_root             Resolve the FxA repo root.
#   worktree_shared_path           Print the first slot's path.
#   worktree_branch_for KEY        Print the branch name for an issue (lowercased key).
#   worktree_key_for BRANCH        Invert worktree_branch_for.
#   worktree_pool_slot_names       The pool, as slot names.
#   worktree_slots                 Per slot: "<slot> busy <agent>" or "<slot> free -".
#   worktree_free_slots OWNED      Slots a ticket can actually claim.
#   worktree_release_branch BRANCH Detach the idle pool slot that holds BRANCH.
#   worktree_prepare_for_issue KEY Claim a slot and check out the branch for KEY.
#                                  Prints the worktree path on stdout.

[ -n "${_FXA_WORKTREE_LOADED:-}" ] && return 0
_FXA_WORKTREE_LOADED=1

: "${FXA_REPO_DEFAULT:=${HOME}/Desktop/working2/fxa}"
: "${FXA_PRIVATE_REPO:=}"
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

# worktree_git_ok <path>
#   On Tart the agent can rewrite <path>/.git to point host git at a config it
#   wrote (credential helper, remote). Pass only when it names this repo's admin
#   dir and that dir points back. Prints the admin dir.
worktree_git_ok() {
  local wt root adm
  wt="$(cd "$1" 2>/dev/null && pwd -P)" && root="$(worktree_repo_root)" && root="$(cd "$root" && pwd -P)" || return 1
  [ "$wt" = "$root" ] && { printf '%s\n' "$root/.git"; return 0; }
  if [ -f "$wt/.git" ] && [ ! -L "$wt/.git" ]; then
    adm="$(head -c 4096 "$wt/.git")"; adm="${adm#gitdir: }"
    if [[ "$adm" =~ ^"$root"/\.git/worktrees/[A-Za-z0-9._-]+$ ]] && [[ "$adm" != */.. ]] && [ ! -L "$adm" ] &&
       [ "$(cat "$adm/gitdir" 2>/dev/null)" = "$wt/.git" ]; then
      printf '%s\n' "$adm"; return 0
    fi
  fi
  echo "ERROR: ${wt}/.git is not the worktree pointer the host wrote; refusing to run git there." >&2
  return 1
}

# slot_write <file>
#   Write stdin to a file in a slot the agent can write, never through a link it
#   planted: remove, then create with O_EXCL (noclobber).
slot_write() { rm -f -- "$1" && (set -C; cat > "$1"); }

worktree_shared_path() {
  local root parent
  root="$(worktree_repo_root)" || return 1
  parent="$(dirname "$root")"
  printf '%s/%s\n' "$parent" "$FXA_SHARED_WORKTREE_NAME"
}

# Branch name for an issue: the lowercased key (PAY-1234 -> pay-1234).
# Keep this the ONLY branch-name generator: a second one that prefixed `fxa-`
# broke every non-FXA key for all readers (reap, drain, feedback, progress...).
worktree_branch_for() {
  local key="${1:-}"
  if [ -z "$key" ]; then
    echo "ERROR: worktree_branch_for requires ISSUE-KEY" >&2
    return 1
  fi
  printf '%s\n' "$key" | tr '[:upper:]' '[:lower:]'
}

# Invert worktree_branch_for. If this round trip breaks, stray-VM collection
# stops a live run and the pool hands out a slot that a ticket still owns.
worktree_key_for() {
  printf '%s\n' "${1:-}" | tr '[:lower:]' '[:upper:]'
}

# Print "NAME WORKSPACE" for every .meta whose VM is running; skip stale metas.
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

# Print the agent NAME whose VM is running on a given workspace path, if any.
_worktree_agent_for_workspace() {
  local target="$1"
  # No early exit: it closes the pipe under the producer's printf, which then
  # reports "Broken pipe" on stderr for every caller.
  _worktree_each_active_agent | awk -v t="$target" '!found {
    name=$1; $1=""; sub(/^ /,"");
    if ($0 == t) { print name; found=1 }
  }'
}

# _worktree_pull_if_remote <path>
#   On gce the agent edits a copy on the runner, so every reader of the slot
#   pulls the tree back first. On Tart the slot is the mount; this is a no-op.
# ponytail: one gcloud describe plus one rsync per status read; cache the
# running check if snapshot gets slow.
_PULL_MEMO=""
_worktree_pull_if_remote() {
  [ "${FXA_VM_BACKEND:-tart}" = "gce" ] || return 0
  # finish owns the slot while it stages and commits; a pull now would race it.
  [ -f "${LOG_DIR}/$(basename "$1").finishing" ] && return 0
  # So does a launch: a --delete pull before the runner had the token removed
  # it from the slot, and the agent died at turn 1. Ignore markers over 20 min.
  local mk="${LOG_DIR}/$(basename "$1").launching"
  [ -f "$mk" ] && [ $(( $(date +%s) - $(_mtime "$mk") )) -lt 1200 ] && return 0
  # Once per 20 s per slot; a string cache because macOS ships bash 3.2.
  local now hit; now="$(date +%s)"
  hit="$(printf '%s\n' "$_PULL_MEMO" | grep -m1 "^$1 " || true)"
  [ -n "$hit" ] && [ $(( now - $(printf '%s' "$hit" | cut -d' ' -f2) )) -lt 20 ] && return 0
  local name; name="$(_worktree_agent_for_workspace "$1")"
  [ -n "$name" ] || return 0
  vm_pull_tree "$name" /workspace "$1" 2>/dev/null || true
  _PULL_MEMO="$(printf '%s\n' "$_PULL_MEMO" | grep -v "^$1 " || true)
$1 ${now}"
}

# worktree_filtered_status <path>
#   `git status --porcelain` without our own files: .fxa-* (orchestration and
#   agent scratch, once committed by finish), ai/, .claude/, newKey.json, and
#   $FXA_DIRTY_IGNORE. Empty output means clean enough.
worktree_filtered_status() {
  local path="$1"
  _worktree_pull_if_remote "$path"
  worktree_git_ok "$path" >/dev/null || { echo "?? .git (pointer changed)"; return 0; }
  local extra_pattern="${FXA_DIRTY_IGNORE:-}"
  git -C "$path" status --porcelain 2>/dev/null \
    | grep -vE '^\?\? \.fxa-' \
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

worktree_pool_slot_names() {
  local wt
  while IFS= read -r wt; do
    [ -z "$wt" ] && continue
    basename "$wt"
  done <<< "$(_worktree_pool_list)"
}

# "Is a VM running there", which is NOT "can a ticket claim it"; see worktree_free_slots.
worktree_slots() {
  local root parent slot path agent
  root="$(worktree_repo_root)" || return 1
  parent="$(dirname "$root")"
  while IFS= read -r slot; do
    [ -z "$slot" ] && continue
    path="${parent}/${slot}"
    agent="$(_worktree_agent_for_workspace "$path")"
    if [ -n "$agent" ]; then echo "${slot} busy ${agent}"; else echo "${slot} free -"; fi
  done <<< "$(worktree_pool_slot_names)"
}

# worktree_free_slots <OWNED-KEYS>
#   Print each claimable slot. OWNED-KEYS is the newline-separated list of
#   uppercase keys that still own a slot (the inflight tickets), or empty.
#   A slot is claimable only when its branch has no owner AND no VM runs on it.
#   The VM stops when the PR opens, so the ticket still owns the slot during CI.
#   A leftover VM makes worktree_prepare_for_issue abort, which burns a launch.
worktree_free_slots() {
  local owned="${1:-}"
  local root parent slot path branch key
  root="$(worktree_repo_root)" || return 1
  parent="$(dirname "$root")"
  while IFS= read -r slot; do
    [ -z "$slot" ] && continue
    path="${parent}/${slot}"
    branch="$(git -C "$path" rev-parse --abbrev-ref HEAD 2>/dev/null)" || continue
    key="$(worktree_key_for "$branch")"
    # On tart the slot is the only copy of an unpushed run. On gce the runner
    # holds the work, then origin does, so any slot can resume it.
    if [ "${FXA_VM_BACKEND:-tart}" != "gce" ] && [ -n "$owned" ] && printf '%s\n' "$owned" | grep -qx "$key"; then
      continue                      # owned by a ticket that may still relaunch
    fi
    if [ -n "$(_worktree_agent_for_workspace "$path")" ]; then
      continue                      # a VM still runs here; a launch would abort
    fi
    printf '%s\n' "$slot"
  done <<< "$(worktree_pool_slot_names)"
}

# worktree_release_branch <BRANCH>
#   Detach the idle slot that holds <BRANCH>, at the same commit. Git lets only
#   one worktree hold a branch, so a kept branch blocks a fix round elsewhere.
worktree_release_branch() {
  local branch="${1:-}" wt
  [ -z "$branch" ] && return 1
  while IFS= read -r wt; do
    [ -z "$wt" ] && continue
    [ "$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null)" = "$branch" ] || continue
    [ -n "$(_worktree_agent_for_workspace "$wt")" ] && continue
    git -C "$wt" -c core.hooksPath=/dev/null checkout --quiet --detach >&2 || return 1
  done <<< "$(_worktree_pool_list)"
}

# _worktree_add <root> <path> <name> <base>
#   Fetch origin/<base> and add a worktree at <path> on its <name>-holding branch.
_worktree_add() {
  local root="$1" path="$2" name="$3" base="$4"
  if ! _retry git -C "$root" fetch origin "$base" >&2; then
    echo "ERROR: 'git fetch origin ${base}' failed." >&2
    return 1
  fi
  local holding="${name}-holding"
  if git -C "$root" show-ref --verify --quiet "refs/heads/${holding}"; then
    git -C "$root" -c core.hooksPath=/dev/null worktree add "$path" "$holding" >&2 || return 1
  else
    git -C "$root" -c core.hooksPath=/dev/null worktree add -b "$holding" "$path" "origin/${base}" >&2 || return 1
  fi
}

# worktree_acquire_pool_slot [BASE] [OWNED-KEYS]
#   Print a claimable slot path, or create the next-numbered slot.
#   OWNED-KEYS=UNKNOWN means the Jira query failed: refuse rather than guess.
worktree_acquire_pool_slot() {
  local base="${1:-$FXA_WORKTREE_BASE}"
  local owned="${2:-}"
  local root parent
  root="$(worktree_repo_root)" || return 1
  parent="$(dirname "$root")"

  if [ "$owned" = "UNKNOWN" ]; then
    echo "ERROR: cannot tell which pool slots are still owned (the ticket query failed)." >&2
    echo "       Re-run with an explicit --worktree <slot> rather than risk switching" >&2
    echo "       the branch out from under a ticket that still needs it." >&2
    return 1
  fi

  local slot
  while IFS= read -r slot; do
    [ -z "$slot" ] && continue
    echo "Reusing free pool slot: ${parent}/${slot}" >&2
    printf '%s\n' "${parent}/${slot}"
    return 0
  done <<< "$(worktree_free_slots "$owned")"

  local pool
  pool="$(_worktree_pool_list)"

  # The base name counts as slot 1, so [fxa-auto] gives fxa-auto-2 next.
  local max_suffix=1 has_base=0 suffix name wt
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

  _worktree_add "$root" "$new_path" "$new_name" "$base" || return 1
  printf '%s\n' "$new_path"
}

# worktree_create_named <name> [base]
#   Create or reuse the worktree <parent>/<name>. Refuse to clobber a path that
#   exists but is not a registered worktree.
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
  _worktree_add "$root" "$path" "$name" "$base" || return 1
  # The host's pre-commit hook (lint-staged) runs in the slot and needs
  # node_modules there; without it gce runs died at commit with "prettier ENOENT".
  [ -d "${root}/node_modules" ] && [ ! -e "${path}/node_modules" ] && ln -s "${root}/node_modules" "${path}/node_modules"
  printf '%s\n' "$path"
}

# Gitignored files, relative to the repo root, that `fxa-start` needs. The gce
# backend ships the same list into the runner.
worktree_secret_files() {
  cat <<'LIST'
.env
secrets.env
secrets.json
packages/fxa-auth-server/config/key.json
packages/fxa-auth-server/config/public-key.json
packages/fxa-auth-server/config/secret-key.json
packages/fxa-auth-server/config/secrets.json
packages/fxa-auth-server/config/secrets2.json
packages/fxa-auth-server/config/vapid-keys.json
packages/fxa-auth-server/test/config/mock-vapid-keys.json
packages/fxa-admin-server/.env
packages/fxa-admin-server/src/config/public-key.json
packages/fxa-admin-server/src/config/secret-key.json
packages/fxa-admin-server/src/config/secrets.json
packages/fxa-content-server/server/config/secrets.json
packages/fxa-payments-server/server/config/secrets.json
packages/123done/secrets.json
libs/shared/db/mysql/account/src/.env
LIST
}

# worktree_copy_secrets <path>
#   Copy worktree_secret_files into <path>. Safe to re-run; skips missing sources.
worktree_copy_secrets() {
  local path="${1:-}"
  if [ -z "$path" ] || [ ! -d "$path" ]; then
    echo "ERROR: worktree_copy_secrets needs an existing worktree path" >&2
    return 1
  fi
  local root
  if [ -n "${FXA_SECRETS_SOURCE:-}" ]; then
    if [ ! -d "$FXA_SECRETS_SOURCE" ]; then
      echo "ERROR: FXA_SECRETS_SOURCE='${FXA_SECRETS_SOURCE}' is not a directory." >&2
      return 1
    fi
    root="$FXA_SECRETS_SOURCE"
  else
    root="$(worktree_repo_root)" || return 1
  fi

  local rel src dest copied=0 skipped=0
  for rel in $(worktree_secret_files); do
    src="${root}/${rel}"
    dest="${path}/${rel}"
    if [ -f "$src" ]; then
      mkdir -p "$(dirname "$dest")"
      # The agent can plant a link in the slot (Tart); never copy a secret through one.
      case "$(cd "$(dirname "$dest")" && pwd -P)/" in "$(cd "$path" && pwd -P)/"*) ;; *)
        echo "ERROR: ${rel%/*} in the slot leads outside it; refusing to copy secrets." >&2; return 1 ;; esac
      rm -f -- "$dest"
      cp "$src" "$dest"
      copied=$((copied + 1))
    else
      skipped=$((skipped + 1))
    fi
  done

  if [ -d "${root}/_dev/firebase/.config" ]; then
    mkdir -p "${path}/_dev/firebase"
    [ -L "${path}/_dev" ] || [ -L "${path}/_dev/firebase" ] && { echo "ERROR: _dev in the slot is a link; refusing to copy secrets." >&2; return 1; }
    rm -rf -- "${path}/_dev/firebase/.config"
    cp -R "${root}/_dev/firebase/.config" "${path}/_dev/firebase/.config"
    copied=$((copied + 1))
  fi

  echo "  Synced ${copied} secret/config file(s) into ${path} (${skipped} not present in source)." >&2
}

# worktree_copy_ai_docs <path>
#   Copy ai/ into <path> as a real directory: a symlink to a host path does not
#   resolve inside the VM. Not credentials, so every run gets it.
worktree_copy_ai_docs() {
  local path="${1:-}"
  [ -n "$path" ] && [ -d "$path" ] || return 0

  local root
  if [ -n "${FXA_SECRETS_SOURCE:-}" ] && [ -d "${FXA_SECRETS_SOURCE}" ]; then
    root="$FXA_SECRETS_SOURCE"
  else
    root="$(worktree_repo_root)" || return 0
  fi
  [ -d "${root}/ai" ] || return 0

  rm -rf "${path}/ai"
  if command -v rsync >/dev/null 2>&1; then
    rsync -a --delete "${root}/ai/" "${path}/ai/"
  else
    cp -R "${root}/ai" "${path}/ai"
  fi
  echo "  Mirrored ai/ into ${path}." >&2
}

# _worktree_sync_to_origin <path> <branch>
#   Bring a resumed local branch up to origin, which is what the reviewer reads.
#   A slot once resumed a three-week-old local ref and the agent rewrote a guard
#   that was already merged on the PR.
# _origin_has_branch <path> <branch>   0 on origin, 1 not there, 2 origin did
# not answer. ls-remote exits 2 for "no such ref" and 128 for a network error.
_origin_has_branch() {
  local rc d
  for d in 3 9 0; do
    rc=0; git -C "$1" ls-remote --exit-code --heads origin "$2" >/dev/null 2>&1 || rc=$?
    [ "$rc" = 0 ] && return 0
    [ "$rc" = 2 ] && return 1
    [ "$d" = 0 ] || sleep "$d"
  done
  return 2
}

_worktree_sync_to_origin() {
  local path="$1" branch="$2"
  # FxA's post-checkout hook clones external/l10n and is not idempotent.
  local nohooks="-c core.hooksPath=/dev/null"

  local has=0; _origin_has_branch "$path" "$branch" || has=$?
  if [ "$has" = 1 ]; then echo "Branch '${branch}' is not on origin yet; nothing to sync." >&2; return 0; fi
  [ "$has" = 0 ] || { echo "ERROR: origin did not answer; refusing to resume a branch we cannot verify." >&2; return 1; }
  _retry git -C "$path" fetch origin "$branch" >&2 || {
    echo "ERROR: 'git fetch origin ${branch}' failed; refusing to resume a branch we cannot verify." >&2
    return 1
  }

  local local_sha remote_sha
  local_sha="$(git -C "$path" rev-parse HEAD)"
  remote_sha="$(git -C "$path" rev-parse "origin/${branch}")"
  [ "$local_sha" = "$remote_sha" ] && return 0

  # A fast-forward keeps any uncommitted work.
  if git -C "$path" $nohooks merge --ff-only "origin/${branch}" >&2 2>/dev/null; then
    echo "Fast-forwarded ${branch} to origin/${branch} ($(git -C "$path" rev-parse --short "origin/${branch}"))." >&2
    return 0
  fi

  # Diverged: the local commits are unpushed and built on the stale base, so
  # reset and name the old sha. The reflog cannot bring back uncommitted edits.
  if [ -n "$(worktree_filtered_status "$path")" ]; then
    echo "ERROR: ${branch} in ${path} diverged from origin and has uncommitted changes." >&2
    echo "       Refusing to reset. Commit, stash, or discard them, then relaunch." >&2
    return 1
  fi
  local ahead
  ahead="$(git -C "$path" rev-list --count "origin/${branch}..HEAD" 2>/dev/null || echo '?')"
  echo "WARN: ${branch} has ${ahead} local commit(s) that origin does not, and cannot fast-forward." >&2
  echo "      Resetting to origin/${branch}. Recover the old tip from ${local_sha} if it mattered:" >&2
  echo "      git -C '${path}' cherry-pick ${local_sha}" >&2
  git -C "$path" reset --hard "origin/${branch}" >&2 || {
    echo "ERROR: could not reset ${branch} to origin/${branch}." >&2
    return 1
  }
}

# worktree_prepare_for_issue <KEY> [BASE] [SLOT] [OWNED-KEYS]
#   Claim SLOT (or a free pool slot), then check out the branch for KEY: the
#   local ref synced to origin, else origin's, else new off origin/<base>.
#   Prints the worktree path on stdout. Progress on stderr.
worktree_prepare_for_issue() {
  local key="${1:-}"
  local base="${2:-$FXA_WORKTREE_BASE}"
  local named_slot="${3:-}"
  local owned_keys="${4:-}"

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
    # This ticket's own earlier runner is a relaunch (a stalled or cut-off run):
    # keep its tree in the slot, then stop it, so the new run resumes that work.
    if [ -n "$busy_agent" ] && [ "$busy_agent" = "$branch" ]; then
      echo "Relaunch: stopping this ticket's earlier runner '${busy_agent}' after saving its tree..." >&2
      _worktree_pull_if_remote "$path" >&2 || true
      agent_stop "$busy_agent" >&2 || { echo "ERROR: could not stop '${busy_agent}'." >&2; return 1; }
      busy_agent=""
    fi
    if [ -n "$busy_agent" ]; then
      # Two agents on one worktree corrupt each other. Use /dev/tty because
      # callers capture stdout with $( ), which defeats `[ -t 1 ]`.
      # The device file passes -r and -w even with no terminal; opening it tells.
      if { : </dev/tty; } 2>/dev/null; then
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
    path="$(worktree_acquire_pool_slot "$base" "$owned_keys")" || return 1
  fi

  # Warn only: git checkout itself fails if the swap would clobber real work.
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
  _retry git -C "$path" fetch origin "$base" >&2 || {
    echo "ERROR: 'git fetch origin ${base}' failed." >&2
    return 1
  }

  # FxA's post-checkout hook clones external/l10n and fatals on a second run.
  local nohooks="-c core.hooksPath=/dev/null" has
  if git -C "$path" show-ref --verify --quiet "refs/heads/${branch}"; then
    # A local ref can be weeks old, so sync it to origin before the agent sees it.
    echo "Branch '${branch}' already exists locally; resuming." >&2
    git -C "$path" $nohooks checkout "$branch" >&2 || return 1
    _worktree_sync_to_origin "$path" "$branch" || return 1
  elif { has=0; _origin_has_branch "$path" "$branch" || has=$?; [ "$has" != 1 ]; }; then
    # A fix round on another slot: cutting from <base> would drop the PR's
    # commits, so "origin did not answer" must not read as "not there".
    [ "$has" = 0 ] || { echo "ERROR: origin did not answer; cannot tell whether '${branch}' exists there." >&2; return 1; }
    echo "Branch '${branch}' exists on origin; resuming from there, not from ${base}." >&2
    _retry git -C "$path" fetch origin "$branch" >&2 || return 1
    git -C "$path" $nohooks checkout -b "$branch" "origin/${branch}" >&2 || return 1
  else
    echo "Creating branch '${branch}' off origin/${base}." >&2
    git -C "$path" $nohooks checkout -b "$branch" "origin/${base}" >&2 || return 1
  fi

  # Real credentials go only to runs that start the stack: the agent runs with
  # bypassPermissions on a prompt built from Jira text.
  worktree_copy_ai_docs "$path" >&2 || true
  if [ "${FXA_COPY_SECRETS:-false}" = "true" ]; then
    echo "Syncing per-developer secrets and config files..." >&2
    worktree_copy_secrets "$path" >&2 || return 1
  else
    echo "Skipping secret sync. Pass --functional-tests, or set FXA_COPY_SECRETS=true, if the run needs fxa-start." >&2
    # An earlier functional run left them in this slot; this run must not see them.
    local rel real; real="$(cd "$path" && pwd -P)"
    for rel in $(worktree_secret_files) _dev/firebase/.config; do
      git -C "$path" ls-files --error-unmatch -- "$rel" >/dev/null 2>&1 && continue
      # Through a planted dir link this rm would reach a host file.
      case "$(cd "$(dirname "${path}/${rel}")" 2>/dev/null && pwd -P)/" in "$real"/*) rm -rf -- "${path:?}/${rel}" ;; esac
    done
  fi

  printf '%s\n' "$path"
}
