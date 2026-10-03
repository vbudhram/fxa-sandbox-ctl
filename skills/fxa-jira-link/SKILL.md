---
name: fxa-jira-link
description: Use when a conversation shows a bug, a gap (such as untested paths), follow-up work, or something the person wants to track. Offers a link that opens the Jira create screen for FXA with a bug, task, story or spike filled in; the person reviews it and clicks Create.
---

# Offer a Jira issue

Be proactive. When the conversation shows something worth tracking, end your reply
with one link that opens the FXA create screen, filled in. Nothing is created until
the person reviews it and clicks Create, so offering costs them nothing.

## When to offer

- A bug: something you found or the person reported that is broken.
- A gap: untested paths, a missing check, a stale doc.
- Follow-up work: a change that is out of scope for this thread, or tech debt.
- The person asks to track, file, or ticket something.

Do not offer when the thread already has a ticket for it (an `FXA-` key), or for a
question with nothing to do. Offer at most one link in a reply.

## Pick the type

| Type | When |
|---|---|
| `bug` | Behavior is wrong or broken |
| `task` | Work to do: tests, cleanup, a change, tech debt |
| `story` | A user-facing feature or change, from the user's point of view |
| `spike` | A question to investigate before the work can be planned |

## Build the link

```bash
bash /home/agent/.claude/skills/fxa-jira-link/link.sh --type bug \
  --summary "Change password shows the wrong error for a same password" \
  --description "<what, where, how to reproduce, what done looks like>"
```

- **Summary:** one line, under 100 characters, the problem or the outcome.
- **Description:** plain text, short lines:
  1. What is wrong or what to do, in one or two sentences.
  2. Where: file paths with line numbers.
  3. For a bug, the steps to reproduce and the expected result.
  4. What done looks like.
- Run the script once; it prints the link. Do not build the link by hand.

## Offer it

One line at the end of your reply, as a Markdown link, for example:

`[Create a Jira bug for this](<link>)`

Say what the issue would be ("a task to cover the 8 untested paths"), not how the
link works.
