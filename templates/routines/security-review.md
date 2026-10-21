---
about: Looks for untrusted input, missing access checks, secrets and weak crypto in the changed code. It changes no code, because a public fix would disclose the issue before a release.
name: Security review
mode: report
locked_mode: report
skip_no_commits: true
---
Review the code that changed on the routine's branch since the last run (the host gives the start and head SHAs) for security defects: untrusted input that reaches a shell, a query, a file path or HTML; missing access checks; secrets in code or logs; weak crypto; unsafe dependencies.

Report only. Change no code and open no PR: a fix in public would disclose the issue before a release. For each finding give the file:line, how a caller reaches it, the impact, and the fix you suggest. Say how sure you are.

When you find nothing, say so in one line.
