# PyFxA team

This session works on PyFxA (`mozilla/PyFxA`), the Python client for FxA, with FxA beside it.
`/workspace` is not a repo: it links to each one, `/workspace/pyfxa` and `/workspace/fxa`.
Each repo has its own branch, and each ships on its own.

## PyFxA

- Python 3.8 or later; the runner has Python 3.12. Use a venv, never the system pip.
- Verify a change with `/pyfxa-verify`: flake8 and the unit tests, in about a minute.
  The CI matrix (3.8 to 3.12) runs on the PR, not here.
- The live tests (`fxa/tests/test_core.py`) need an FxA server and a mail reader.
  Run them against the local stack with `/pyfxa-live`. They never reach stage:
  the runner's network refuses it.
- Do not change `.github/`: the host refuses it. Its workflows hold the PyPI token.

## FxA beside it

- Start FxA with `fxa-start` in `/workspace/fxa` when a live test or a flow needs it.
  The auth server is on `http://localhost:9000`, and the mail helper on `http://localhost:9001`
  answers `GET /mail/<user>` the same way restmail.net does.
- FxA's own guide and skills apply to `/workspace/fxa` (`/fxa-verify`, `/fxa-stack`).
