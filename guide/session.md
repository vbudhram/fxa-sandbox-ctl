## 2. What the host does with your work

Git is yours, except `push` (there is no `gh` and no push
credential). Commit, amend, fetch, rebase onto `origin/main`, stash,
cherry-pick and make extra branches as you like. At Push branch or Open PR
the host does this:

- It copies the files of `/workspace` as they are on disk, without `.git`. It
  takes the checked-out branch's files plus your uncommitted and untracked
  changes. Other branches and stashes are not shipped.
- It bases the PR on `git merge-base HEAD origin/main`. Rebase onto a newer
  `origin/main` and the PR moves with you; never merge main in.
- It squashes everything into one signed commit on this thread's branch, so
  your commit messages do not reach the PR. `pr_title` becomes the message.
- One thread ships one PR. For a second feature, ask the person to start a
  second thread; each thread gets its own sandbox and branch.

Rules that follow from this:

- Be on the branch you want to ship when you write the handoff. `branch` in
  the handoff must match `git branch --show-current`.
- Make extra worktrees outside `/workspace` (for example `~/wt/<name>`). A
  worktree inside it is copied into the PR.
- When the session pauses, the host saves the commits on `HEAD` and the
  working tree. Other branches, stashes and worktrees are lost. Merge or
  cherry-pick what you need onto the shipping branch first.
- There is no editor, so interactive commands stop. In place of
  `git rebase -i`, use `git commit --fixup <sha>` and then
  `GIT_SEQUENCE_EDITOR=true git rebase -i --autosquash origin/main`.

The host checks the change before it ships it; section 4 lists what it refuses.

To leave a file out of the change, revert it with
`git checkout "$(git merge-base HEAD origin/main)" -- <path>`.

## 3. How you were started: a Slack session (a person in a thread)

There is no `/goal`. A person steers you turn by turn.

- Your first turn investigates, writes a test plan with `/fxa-test-plan`, and
  prints a short plan: the cause, the files you will change and how you will
  verify. Then make the change and verify it. Nobody approves the plan first.
  A question or an investigation needs no plan.
- To ask for a decision, put 2 to 4 answers on lines that start with
  `OPTION: `. For several decisions at once (at most 5), put
  `QUESTION: <the question>` on its own line before each group.
- End every turn with `status: needs-input` or `status: ready`. Use `ready`
  only when the change is done and its tests pass.
- Files you save in `/workspace/.fxa-auto-media/` are posted to the thread
  when your turn ends.
- When the work shows a bug, a gap or follow-up work worth tracking, end the
  reply with a Jira link from the `fxa-jira-link` skill. Ask about open decisions
  first (QUESTION: and OPTION: lines), then offer the link. The person reviews it
  and creates the issue; nothing is filed for them.
- "Push branch" and "Open PR" are buttons in Slack. When the person taps one,
  you get a wrap-up turn that tells you what to do.
