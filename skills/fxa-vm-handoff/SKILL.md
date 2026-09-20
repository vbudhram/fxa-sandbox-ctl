---
name: fxa-vm-handoff
description: Use inside the FxA sandbox VM to write /workspace/.fxa-auto-done.json, the handoff file the host reads to open the pull request. Run it last, after the PR body is drafted.
allowed-tools: Bash, Read, Write, Edit
---

# FxA sandbox handoff

The host opens the pull request. You never run `gh`. The host reads
`/workspace/.fxa-auto-done.json` and nothing else, so this file is the only
route your work takes to a human.

When the file is absent or invalid, the host still opens a pull request. It
derives a title from the branch and sends an empty body. Three runs shipped that
way, and one branch produced two identical pull requests.

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

The title must equal the commit subject exactly. Use a scoped conventional
subject, for example `fix(auth): reject an expired session token`.

```bash
git --no-pager log -1 --format='%s'
```

Rules for the title:
- Give the scope. `fix:` is not enough. Write `fix(settings):`.
- Use one of `fix`, `feat`, `chore`, `refactor`, `test`, `docs`, `perf`.
- Do not put the Jira key in the title. Put it in the body.
- Keep it under 72 characters.

Fix the commit subject when it does not match, then read it again:

```bash
git commit --amend -m "<corrected subject>"
git --no-pager log -1 --format='%s'
```

## Step 4: Write the file

```bash
cd /workspace
jq -n \
  --arg issue "FXA-12345" \
  --arg branch "$(git branch --show-current)" \
  --arg sha "$(git rev-parse HEAD)" \
  --arg title "$(git --no-pager log -1 --format='%s')" \
  --rawfile body /tmp/pr-body.md \
  --argjson media "$(ls .fxa-auto-media/*.{png,jpg,jpeg,webp,gif,webm,mp4,mov} 2>/dev/null | jq -R . | jq -s .)" \
  '{issue:$issue, branch:$branch, commit_sha:$sha, pr_title:$title,
    pr_body:$body, media_paths:$media}' \
  > /workspace/.fxa-auto-done.json
```

Write the body to `/tmp/pr-body.md` first. A here-doc inside `jq -n` loses the
newlines, and the pull request body then arrives as one paragraph.

`media_paths` is read from `.fxa-auto-media/`, so every file a capture skill
wrote is listed and nothing is typed by hand. Do not replace it with `[]`.

## Step 5: Verify the file before you stop

```bash
jq -e '.branch and .pr_title and .pr_body' /workspace/.fxa-auto-done.json \
  && echo "handoff OK" || echo "handoff INVALID"
echo "media: $(jq -r '.media_paths | length' /workspace/.fxa-auto-done.json) file(s) listed"
jq -r '.pr_title' /workspace/.fxa-auto-done.json
test "$(jq -r '.pr_title' /workspace/.fxa-auto-done.json)" \
     = "$(git --no-pager log -1 --format='%s')" \
  && echo "title matches commit" || echo "TITLE MISMATCH"
```

The host rejects the file when `branch`, `pr_title`, or `pr_body` is empty. Do
not finish the run until `handoff OK` and `title matches commit` both print.

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
