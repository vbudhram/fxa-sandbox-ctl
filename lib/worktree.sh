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
#   worktree_key_for BRANCH        Invert worktree_branch_for.
#   worktree_pool_slot_names       The pool, as slot names.
#   worktree_slots                 Per slot: "<slot> busy <agent>" or "<slot> free -".
#   worktree_free_slots OWNED      Slots a ticket can actually claim.
#   worktree_prepare_for_issue KEY Ensure the shared worktree exists and is checked
#                                  out on the branch for KEY (created from origin/main
#                                  if new). Prints the worktree path on stdout.

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

worktree_shared_path() {
  local root parent
  root="$(worktree_repo_root)" || return 1
  parent="$(dirname "$root")"
  printf '%s/%s\n' "$parent" "$FXA_SHARED_WORKTREE_NAME"
}

# Branch name for an issue: the lowercased Jira key, and nothing else.
# FXA-13494 -> fxa-13494, PAY-1234 -> pay-1234.
#
# This is the ONLY branch-name generator in the system. The skill used to carry
# a second one that prefixed `fxa-` onto every key. The two agreed on FXA keys
# and disagreed on every other project: the skill looked for `fxa-pay-1234`
# while this function had created `pay-1234`. Eight readers (reap, drain,
# feedback, prstate, alive, progress, usage, record) would have missed the run.
worktree_branch_for() {
  local key="${1:-}"
  if [ -z "$key" ]; then
    echo "ERROR: worktree_branch_for requires ISSUE-KEY" >&2
    return 1
  fi
  printf '%s\n' "$key" | tr '[:upper:]' '[:lower:]'
}

# Invert worktree_branch_for. The branch is the key lowercased, so the inverse
# is uppercase. Stray-VM collection and free-slot detection both depend on this
# round trip: when it breaks, a live run gets stopped and the pool hands out a
# slot that a ticket still owns.
worktree_key_for() {
  printf '%s\n' "${1:-}" | tr '[:lower:]' '[:upper:]'
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
  # No early exit: it closes the pipe under the producer's printf, which then
  # reports "Broken pipe" on stderr for every caller.
  _worktree_each_active_agent | awk -v t="$target" '!found {
    name=$1; $1=""; sub(/^ /,"");
    if ($0 == t) { print name; found=1 }
  }'
}

# _worktree_pull_if_remote <path>
#   On the gce backend the agent edits a copy on the runner, so every reader of
#   the slot (stall detection, snapshot, the handoff poll, staging) first pulls
#   the tree back. Tart reads the mount and this is a no-op.
# ponytail: one gcloud describe plus one rsync per status read; cache the
# running check if snapshot gets slow.
_PULL_MEMO=""
_worktree_pull_if_remote() {
  [ "${FXA_VM_BACKEND:-tart}" = "gce" ] || return 0
  # finish owns the slot while it stages and commits; a pull now would race it.
  [ -f "${LOG_DIR}/$(basename "$1").finishing" ] && return 0
  # So does a launch until the run files are on the runner: a pull with
  # --delete from a runner that has no token yet removed the token from the
  # slot before the tar was built, and the agent died at turn 1 (FXA-10441).
  # A marker over 20 min old is a launch that died; ignore it.
  local mk="${LOG_DIR}/$(basename "$1").launching"
  [ -f "$mk" ] && [ $(( $(date +%s) - $(stat -f %m "$mk") )) -lt 1200 ] && return 0
  # Once per 20 s per slot: a snapshot reads the same slot several times.
  # A string cache, not an associative array: macOS ships bash 3.2.
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
#   Run `git status --porcelain` and drop lines that are known not to matter:
#     - any .fxa-* file at the root: our orchestration files, and agent scratch
#       files (an agent once wrote .fxa-pr-body.md and finish committed it)
#     - the ai/ agent-context symlink convention
#     - per-worktree .claude/ state (claude-code creates this; not part of the fix)
#     - the FxA auth-server test key artifact (newKey.json)
#     - whatever extended-regex pattern the user puts in $FXA_DIRTY_IGNORE
#   Empty output means "clean enough for our purposes."
worktree_filtered_status() {
  local path="$1"
  _worktree_pull_if_remote "$path"
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

# worktree_pool_slot_names
#   The pool as slot names (fxa-auto, fxa-auto-2, ...) rather than paths.
worktree_pool_slot_names() {
  local wt
  while IFS= read -r wt; do
    [ -z "$wt" ] && continue
    basename "$wt"
  done <<< "$(_worktree_pool_list)"
}

# worktree_slots
#   One line per slot: "<slot> busy <agent>" or "<slot> free -".
#
#   This answers "is a VM running there", which is NOT the same question as
#   "can a ticket claim it". Use worktree_free_slots to claim.
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
#   Print each pool slot that is genuinely claimable, one per line. OWNED-KEYS
#   is the newline-separated list of uppercase keys that still own a slot
#   (in practice, the inflight tickets). Pass the empty string when none do.
#
#   A slot is claimable only when BOTH hold:
#     1. the branch checked out in it belongs to no owning ticket, and
#     2. no agent VM is currently running on it.
#
#   Condition 1 is the one `worktree_slots` misses. The VM is stopped as soon
#   as the PR opens, so a slot reads `free` for the whole CI run while its
#   ticket still owns the worktree. Launching there switches the branch out
#   from under a ticket that may still need a fix relaunch.
#
#   Condition 2 is not redundant. A ticket that stops owning its slot can still
#   have a VM up, and worktree_prepare_for_issue refuses to mount a workspace
#   another agent's VM holds. Reporting such a slot as claimable makes a pass
#   burn a launch on a guaranteed abort: on 2026-08-24 FXA-14371 was labelled
#   inflight, aborted with "Stop 'fxa-14285' first", and had to be returned to
#   the queue by hand. A leftover branch does not block a claim, but a leftover
#   VM does.
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
    # On tart the slot is the only copy of an unpushed run, so a ticket owns it
    # until its label leaves inflight. On gce the runner holds the work while it
    # runs (the VM check below withholds the slot), and once the PR is pushed the
    # branch is on origin, where any slot can resume it. Ownership adds nothing.
    if [ "${FXA_VM_BACKEND:-tart}" != "gce" ] && [ -n "$owned" ] && printf '%s\n' "$owned" | grep -qx "$key"; then
      continue                      # owned by a ticket that may still relaunch
    fi
    if [ -n "$(_worktree_agent_for_workspace "$path")" ]; then
      continue                      # a VM still runs here; a launch would abort
    fi
    printf '%s\n' "$slot"
  done <<< "$(worktree_pool_slot_names)"
}

# worktree_acquire_pool_slot [BASE] [OWNED-KEYS]
#   Returns the absolute path to a claimable worktree from the pool, or creates
#   the next-numbered slot if none is claimable. Progress goes to stderr.
#
#   OWNED-KEYS is the newline-separated list of keys that still own a slot; it
#   comes from the caller because this file does not talk to Jira. Pass the
#   literal string UNKNOWN when that list could not be fetched, and this refuses
#   to guess rather than hand out a slot a ticket is still using.
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

  # First, try to reuse a claimable existing slot.
  local slot
  while IFS= read -r slot; do
    [ -z "$slot" ] && continue
    echo "Reusing free pool slot: ${parent}/${slot}" >&2
    printf '%s\n' "${parent}/${slot}"
    return 0
  done <<< "$(worktree_free_slots "$owned")"

  local pool busy
  pool="$(_worktree_pool_list)"
  busy="$(_worktree_busy_workspaces)"

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
  # The host's pre-commit hook (lint-staged, check:frozen) runs in the slot and
  # needs node_modules there. Slots 3 to 5 had none, and 4 of 9 gce runs died
  # at the commit with "prettier ENOENT" after a finished run.
  [ -d "${root}/node_modules" ] && [ ! -e "${path}/node_modules" ] && ln -s "${root}/node_modules" "${path}/node_modules"
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

# worktree_copy_secrets <path>
#   Copy per-developer secrets/configs from the main FxA repo into <path>.
#   FxA gitignores these files, so a fresh worktree starts empty and the agent
#   can't run `fxa-start` until they're in place. Mirrors the file list in the
#   `fxa-worktree` helper. Safe to re-run; missing source files are skipped.
# worktree_secret_files
#   The files, relative to the FxA repo root, that a run needs and git ignores.
#   One list: worktree_copy_secrets copies them into the slot, and the gce
#   backend ships the same set into the runner.
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

worktree_copy_secrets() {
  local path="${1:-}"
  if [ -z "$path" ] || [ ! -d "$path" ]; then
    echo "ERROR: worktree_copy_secrets needs an existing worktree path" >&2
    return 1
  fi
  # Secrets/ai source: FXA_SECRETS_SOURCE if set (lets a worktree read secrets
  # from another checkout), otherwise the worktree's own repo root (unchanged).
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

  local secret_files=( $(worktree_secret_files) )

  local rel src dest copied=0 skipped=0
  for rel in "${secret_files[@]}"; do
    src="${root}/${rel}"
    dest="${path}/${rel}"
    if [ -f "$src" ]; then
      mkdir -p "$(dirname "$dest")"
      cp "$src" "$dest"
      copied=$((copied + 1))
    else
      skipped=$((skipped + 1))
    fi
  done

  # Firebase emulator config (entire directory).
  if [ -d "${root}/_dev/firebase/.config" ]; then
    mkdir -p "${path}/_dev/firebase"
    cp -R "${root}/_dev/firebase/.config" "${path}/_dev/firebase/.config"
    copied=$((copied + 1))
  fi

  # NX cache left enabled (previously forced off via NX_SKIP_NX_CACHE); nx keys
  # its cache on input hashes, so reuse across pooled worktrees is safe.

  echo "  Synced ${copied} secret/config file(s) into ${path} (${skipped} not present in source)." >&2
}

# worktree_copy_ai_docs <path>
#   Mirror the repo's ai/ directory into <path> as a real directory, not a
#   symlink: only the worktree itself is virtiofs-mounted, so a symlink to a host
#   path does not resolve inside the VM. Kept separate from the secret sync
#   because ai/ holds local notes, not credentials, and every run wants it.
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

# worktree_prepare_for_issue <ISSUE-KEY> [BASE]
#   1. Ensures the shared worktree exists.
#   2. Refuses to proceed if the worktree has uncommitted changes (safety).
#   3. Fetches origin/<base>.
#   4. If branch exists locally, checks it out (resume mode).
#      Otherwise, creates it off origin/<base>.
#   5. Mirrors per-developer secrets/configs from the main repo so the agent
#      can run `fxa-start` without hand-staging credentials.
#   Prints the worktree path on stdout. Progress on stderr.
# _worktree_sync_to_origin <path> <branch>
#   Bring a resumed local branch up to its remote. The remote is the source of
#   truth for a branch that already has a PR: it is what the reviewer reads.
#
#   On 2026-09-08 FXA-11871 resumed a local branch last touched three weeks
#   earlier, because the slot had the ref and nothing fetched it. The agent never
#   saw the PR's head, rewrote a guard that was already merged, and the round's
#   push would have weakened it. Only --force-with-lease stopped that reaching
#   the PR, and it stopped it by accident: the lease refused because the same
#   staleness made the remote-tracking ref wrong too.
_worktree_sync_to_origin() {
  local path="$1" branch="$2"
  # Same reason as the branch swap below: FxA's post-checkout hook clones
  # external/l10n and is not idempotent. Do not inherit this from the caller.
  local nohooks="-c core.hooksPath=/dev/null"

  git -C "$path" ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1 || {
    echo "Branch '${branch}' is not on origin yet; nothing to sync." >&2
    return 0
  }
  git -C "$path" fetch origin "$branch" >&2 || {
    echo "ERROR: 'git fetch origin ${branch}' failed; refusing to resume a branch we cannot verify." >&2
    return 1
  }

  local local_sha remote_sha
  local_sha="$(git -C "$path" rev-parse HEAD)"
  remote_sha="$(git -C "$path" rev-parse "origin/${branch}")"
  [ "$local_sha" = "$remote_sha" ] && return 0

  # The safe path first: a plain fast-forward keeps any uncommitted work.
  if git -C "$path" $nohooks merge --ff-only "origin/${branch}" >&2 2>/dev/null; then
    echo "Fast-forwarded ${branch} to origin/${branch} ($(git -C "$path" rev-parse --short "origin/${branch}"))." >&2
    return 0
  fi

  # Not fast-forwardable, so the local branch carries commits the remote does
  # not. They are unpushed and unreviewed, and they were built on the stale base
  # we are here to correct. Reset, but name the sha: the reflog keeps it
  # reachable, so nothing is destroyed without a way back.
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
    path="$(worktree_acquire_pool_slot "$base" "$owned_keys")" || return 1
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
    # A slot keeps local branch refs across tickets, so "already exists locally"
    # can mean a copy from weeks ago. Resuming it as-is hands the agent a stale
    # branch, which is worse than the elif below guards against: the work looks
    # current and is not.
    echo "Branch '${branch}' already exists locally; resuming." >&2
    git -C "$path" $nohooks checkout "$branch" >&2 || return 1
    _worktree_sync_to_origin "$path" "$branch" || return 1
  elif git -C "$path" ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then
    # The branch exists on ORIGIN but not locally. That is the normal shape of a
    # fix round: a previous run pushed it from a different pool slot, and slots
    # do not share local branch refs. Cutting from origin/<base> here would
    # silently discard every commit already on the PR and then force the agent
    # to rebuild from scratch.
    echo "Branch '${branch}' exists on origin; resuming from there, not from ${base}." >&2
    git -C "$path" fetch origin "$branch" >&2 || return 1
    git -C "$path" $nohooks checkout -b "$branch" "origin/${branch}" >&2 || return 1
  else
    echo "Creating branch '${branch}' off origin/${base}." >&2
    git -C "$path" $nohooks checkout -b "$branch" "origin/${base}" >&2 || return 1
  fi

  # Secrets are copied only when the run actually needs the service stack.
  # They are real credentials (signing keys, vapid keys, firebase config), and
  # the worktree is virtiofs-mounted into a VM running an agent with
  # bypassPermissions whose prompt is built from Jira text. Only `fxa-start`
  # needs them, and functional tests are off by default, so most runs are a
  # lint-and-unit-test change that never reads a key. Don't stage a credential
  # the run will not use.
  worktree_copy_ai_docs "$path" >&2 || true
  if [ "${FXA_COPY_SECRETS:-false}" = "true" ]; then
    echo "Syncing per-developer secrets and config files..." >&2
    worktree_copy_secrets "$path" >&2 || return 1
  else
    echo "Skipping secret sync. Pass --functional-tests, or set FXA_COPY_SECRETS=true, if the run needs fxa-start." >&2
  fi

  printf '%s\n' "$path"
}
