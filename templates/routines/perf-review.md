---
about: Looks for slow paths in the changed code, such as work or queries in loops, missing indexes and blocking calls, and fixes only what it can measure.
name: Performance review
mode: pr+notes
skip_no_commits: true
---
Review the code that changed on the routine's branch since the last run (the host gives the start and head SHAs) for slow paths: repeated work in loops, queries in loops, missing indexes, large payloads, blocking calls, and memory that grows.

Fix an issue only when the fix is clear and you can measure it (a test, a benchmark or a count before and after). List every other finding in the PR description under "Not fixed", with file:line and the cost you expect.

When you find nothing worth a change, make no change and say so.
