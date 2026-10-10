---
name: pyfxa-live
description: Run PyFxA's live tests against the FxA stack in this sandbox (the auth server on localhost:9000, the mail helper on localhost:9001), not against stage. Use it when a PyFxA change touches the client's calls to the auth server.
---

# Run PyFxA's live tests against the local FxA

```bash
bash ~/.claude/skills/pyfxa-live/live.sh                         # fxa/tests/test_core.py
bash ~/.claude/skills/pyfxa-live/live.sh fxa/tests/test_core.py -k password
```

1. It starts FxA when the auth server does not answer (`fxa-start` in `/workspace/fxa`, a few minutes).
2. It runs the tests with `FXA_RUN_LIVE_TESTS=1`, and sets `FXA_TEST_SERVER_URL` and
   `FXA_TEST_MAIL_URL` to the local servers.
3. PyFxA's tests read those two variables only after a change that makes them do so.
   Until then they call stage and restmail.net, which the runner's network refuses:
   the script says so when every test fails to connect.
