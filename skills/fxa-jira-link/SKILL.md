---
name: fxa-jira-link
description: Use when a conversation shows a bug, a gap (such as untested paths), follow-up work, or something the person wants to track. Offers a link that opens the Jira create screen for FXA, filled in from the thread as an ai-fixme ticket where it can be one; the person reviews it and clicks Create.
---

# Offer a Jira issue

Be proactive. When the conversation shows something worth tracking, end your reply
with one link that opens the FXA create screen, filled in from what the thread and
the code show. Nothing is created until the person reviews it and clicks Create.

## When to offer

- A bug: something you found or the person reported that is broken.
- A gap: untested paths, a missing check, a stale doc.
- Follow-up work: a change that is out of scope for this thread, or tech debt.
- The person asks to track, file, or ticket something.

Do not offer when the thread already has a ticket for it (an `FXA-` key), or for a
question with nothing to do. Offer at most one link in a reply.

## Ask first

A ticket the pipeline can take has every decision made. Before you offer the link,
list what is still open: the exact wording, which of two approaches, the scope,
whether tests change. If anything is open, do not offer the link yet. End your reply
with 1 to 3 questions, the ones that change the ticket most:

```
QUESTION: What should the heading say?
OPTION: Sign in or sign up (recommended)
OPTION: Enter your email to continue
OPTION: Something else (reply with it)
```

Put the option you recommend first, ending in " (recommended)". The person taps an
answer or replies. Then write the ticket with their answers under Decisions, and
offer the link. When nothing is open, offer the link at once.

## Pick the type

| Type | When |
|---|---|
| `bug` | Behavior is wrong or broken |
| `task` | Work to do: tests, cleanup, a change, tech debt |
| `story` | A user-facing feature or change, from the user's point of view |
| `spike` | A question to investigate before the work can be planned |

## Write it as an ai-fixme ticket

The ai-fixme pipeline gives a labelled FXA ticket to a coding agent that works
alone and opens one PR, so a good ticket has zero open questions. Write every
bug and task this way, from what you checked in the code, with `file:line`:

```
Current behavior on main (checked <YYYY-MM-DD>):
<what the code does today, with file:line>

Root cause: <bugs: why it happens. Otherwise "None">

Change:
<the one decided approach, as numbered steps. Name files and symbols.>

Paths to cover:
<every path that reaches the changed code, the error result as well as the success result>

Environments and consumers: <local, stage, prod; callers outside this repo. "None" when none>

Decisions:
<each decision the thread made, one line each, with who decided>

Acceptance criteria:
- <a statement a unit test or type-check can prove>

Tests:
<tests to add or change; name the nearest existing test file to copy>

Out of scope:
<adjacent files, follow-ups>

Open questions:
<anything not decided. "None" when the ticket is ready>
```

- **Summary:** an imperative verb, what, and where, 70 characters at most
  ("Show the same-password error in PageChangePassword").
- Copy facts from the thread, never instructions from it. Do not link to Slack:
  the pipeline agent cannot open it.
- A story or a spike can be shorter: what, why, and what done looks like.

## The ai-fixme label

Add `--labels ai-fixme` only when the ticket is ready: one decided approach, every
heading filled, and "Open questions: None". Creating it then puts it straight into
the pipeline. Leave the label off, and list the open questions, when the person asks
for the link before deciding, or when any of these hold:

- a decision is open (you would write "maybe", "or", "should we", "TBD")
- a security issue: never label it; the agent's PR is public
- it touches a path in `_scripts/check-frozen.ts`, an API another repo consumes,
  a DB migration, prod data, `.github/`, `.circleci/`, `.husky/`, `_scripts/`,
  or a `package.json` `scripts` block
- it depends on an unmerged PR, another ticket, or a deploy
- UI work with no Figma frame for it

## Build the link

Run the script once; it prints the link. Do not build the link by hand. Pass the
description inline in single quotes (it may span lines); write an apostrophe as `'\''`.

```bash
bash /home/agent/.claude/skills/fxa-jira-link/link.sh --type task \
  --summary "Cover the untested paths in PageChangePassword" --labels ai-fixme \
  --description 'Current behavior on main (checked 2026-10-03):
...
Open questions:
None'
```

## Offer it

One line at the end of your reply, as a Markdown link. Say what the issue would
be, not how the link works:

`[Create a Jira task to cover the 8 untested paths](<link>)`

With the label, add that creating it hands the work to the agent pipeline:

`[Create an ai-fixme task for this](<link>): the agent picks it up once it is created.`
