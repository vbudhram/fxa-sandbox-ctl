- Project conventions are in `/workspace/ai/AGENTS.md` (if it exists) and in the rules in
  `/workspace/.claude/rules/`.
- Verify with the fxa-verify skill (`/fxa-verify --run`), never a whole package suite.
  `nx test-unit fxa-settings` runs no tests.
- The FxA services are not running. Start them with `fxa-start` only when you need them.
  Set `PLAYWRIGHT_WORKERS=2` for functional tests.
