This session works on PyFxA (`mozilla/PyFxA`), the Python client for FxA, with FxA beside it.
`/workspace` is not a repo: it links to `/workspace/pyfxa` and `/workspace/fxa`. Each repo has
its own branch and ships on its own. The full manual is the PyFxA section of
`/etc/vm-agent-guide.md`.

- For PyFxA, use a venv, never the system pip. Verify with `/pyfxa-verify` (flake8 and the
  unit tests). The CI matrix runs on the PR, not here.
- The live tests need a running FxA: start it with `fxa-start` in `/workspace/fxa`, then run
  `/pyfxa-live`. They never reach stage.
- For a change in `/workspace/fxa`, the FxA repo notes above and the FxA skills apply.
