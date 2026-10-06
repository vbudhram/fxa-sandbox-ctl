---
name: fxa-vm-handoff
description: Use inside the FxA sandbox VM to write /workspace/.fxa-auto-done.json, the handoff file the host reads to open the pull request. Run it last, after the PR body is drafted.
allowed-tools: Bash, Read, Write, Edit
---

# FxA sandbox handoff

The host opens the pull request. You never run `gh`. The host reads
`/workspace/.fxa-auto-done.json` and nothing else, so this file is the only
route your work takes to a human.

When the file is absent or invalid, the host refuses to ship. It pushes nothing
and opens no pull request.

## Step 1: Confirm you have something to hand off

```bash
cd /workspace
BASE="$(git merge-base HEAD "origin/${FXA_WORKTREE_BASE:-main}")"
git --no-pager diff --stat "$BASE"
git --no-pager status --short
git --no-pager log --oneline "$BASE"..HEAD
```

Do not diff against `main`. The pool worktree never fast-forwards local `main`,
so `git diff main...HEAD` reports the whole monorepo. One measurement showed
2562 files against a real change of 2 files.

Stop when the diff and the status are both empty. Report that you have no work
to hand off. Do not write the file.

## Step 2: Check the scope

```bash
git --no-pager diff --stat "$BASE" | tail -1
```

Read the file list. Revert a file the ticket does not need:

```bash
git checkout "$BASE" -- <path>
```

Scope creep blocks the goal. A reviewer who finds an unrelated file asks why it
is there, and that question delays every other file in the change.

## Step 3: Build the title

The host squashes the change to one commit and uses `pr_title` as its subject.
Use a scoped conventional subject, for example
`fix(auth): reject an expired session token`.

Rules for the title:
- Give the scope. `fix:` is not enough. Write `fix(settings):`.
- Use one of `fix`, `feat`, `chore`, `refactor`, `test`, `docs`, `perf`, `ci`, `build`.
- Do not put the Jira key in the title. Put it in the body.
- Keep it under 72 characters.

Do not commit to set the title. In a pipeline run the shared `.git` is
read-only, so `git commit` fails. The host makes the commit.

## Step 4: Write the file

```bash
cd /workspace
jq -n \
  --arg issue "FXA-12345" \
  --arg branch "$(git branch --show-current)" \
  --arg title "fix(auth): reject an expired session token" \
  --rawfile body /tmp/pr-body.md \
  --argjson media "$(ls .fxa-auto-media/*.{png,jpg,jpeg,webp,gif,webm,mp4,mov} 2>/dev/null | jq -R . | jq -s .)" \
  '{issue:$issue, branch:$branch, pr_title:$title,
    pr_body:$body, media_paths:$media}' \
  > /workspace/.fxa-auto-done.json.tmp \
  && mv /workspace/.fxa-auto-done.json.tmp /workspace/.fxa-auto-done.json
```

Write to the `.tmp` file, then `mv` it into place, so the host never reads a
half-written file. Omit `commit_sha`: the host creates the commit.

Write the body to `/tmp/pr-body.md` first. A here-doc inside `jq -n` loses the
newlines, and the pull request body then arrives as one paragraph.

In a review-feedback round, also add `feedback_summary`: a list with one short
line per comment, `Fixed:` or `Not fixed:`, the point, one reason, and the
comment's link from the context file. Add
`--argjson fs "$(jq -R . /tmp/feedback-summary.txt | jq -s .)"` and
`feedback_summary:$fs`. The host posts it on the Jira ticket and on the PR.

In that round, also add `open_questions`: the PR body's "Questions for the reviewer"
that are still open after your change, in their wording, as a list. Leave out the ones
your change answers; use `[]` when none are left. The host puts this list in place of
that section of the PR body, and changes nothing else in the body. Add
`--argjson oq "$(jq -R . /tmp/open-questions.txt | jq -s 'map(select(length > 0))')"`
and `open_questions:$oq`.

`media_paths` is read from `.fxa-auto-media/`, so every file a capture skill
wrote is listed and nothing is typed by hand. Do not replace it with `[]`.

## Step 5: Run the check before you stop

```bash
bash ~/.claude/skills/fxa-vm-handoff/check.sh --fix
```

It formats the changed files with Prettier, deletes untracked scratch files
(`zz*.spec.ts`, `*.tmp.mjs`), and checks the handoff file: the keys, a scoped
conventional `pr_title`, the branch, and that each `media_paths` file exists.
It also checks the PR title and body against the STE rules a script can check:
unapproved words, em dashes, sentences over 25 words and paragraphs over 6
sentences (`ste.sh`, beside it). Rewrite what it names; a style line alone
exits 3 and does not stop the ship.
Fix each `handoff check:` line it prints, and run it again until it prints
`handoff check: ok`. The host runs the same check at Open PR and refuses a
title that is not a scoped conventional subject.

## Body rules

Follow `.github/PULL_REQUEST_TEMPLATE.md` exactly. Keep every checklist row.
Put `x` only in a row that applies. Leave the other rows unchecked. Do not
delete a row.

Leave `I have manually reviewed all AI generated code` unchecked. A human did
not review it.

Keep the body under 300 words. Measured bodies ran to 654 words, and the
operator has already cut one by hand.

- Give the reason for the change first, then the change.
- Use bullet points. Do not write paragraphs.
- Do not paste a test log. CI runs the tests and reports them.
- Give a local test result in two lines maximum: the command and the counts.
- Do not describe what you verified and found correct.
- Do not add a section that the template does not have.
- Name the remaining work only when it changes how a reviewer reads the fix.
  Say plainly that the deferred part leaves the defect reachable, when it does.
