---
name: Code review
mode: pr+notes
skip_no_commits: true
---
Review the commits on the routine's branch since the last run (the host gives the start and head SHAs; read them with git log and git show). Look for bugs, missing error handling, unsafe input handling, dead code and missing tests.

Fix only the issues that are clear and small: one obvious change each, with a test when the repo has tests for that code. Do not refactor, rename or restyle. List every other finding in the PR description under "Not fixed", with file:line and one line on why it matters.

When you find nothing worth a change, make no change and say so.
