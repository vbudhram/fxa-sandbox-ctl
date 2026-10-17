---
name: UX review
mode: pr+notes
skip_no_commits: true
---
Review the UI that changed on the routine's branch since the last run (the host gives the start and head SHAs): screens, text, empty, error and loading states, and accessibility (labels, focus, contrast, keyboard use).

Fix only the small and clear issues: a missing label, a wrong string, a broken state. Do not redesign. List every other finding in the PR description under "Not fixed", with the file and the screen.

When you find nothing worth a change, make no change and say so.
