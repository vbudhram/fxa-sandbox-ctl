---
name: pyfxa-verify
description: Verify a PyFxA change in the sandbox. Runs flake8 and the PyFxA unit tests (or the named test files) in a venv. Use it after each PyFxA change, before you say the work is done.
---

# Verify a PyFxA change

```bash
bash ~/.claude/skills/pyfxa-verify/verify.sh                 # flake8, then all unit tests
bash ~/.claude/skills/pyfxa-verify/verify.sh fxa/tests/test_oauth.py   # flake8, then these files
```

- The first run makes the venv `/home/agent/.pyfxa-venv` and installs PyFxA with its
  test and lint packages, about 30 s. Later runs reuse it.
- The live tests skip unless `FXA_RUN_LIVE_TESTS=1`. To run them, use `/pyfxa-live`.
- Exit 0 means both passed. Report the last lines of each step, not the whole log.
