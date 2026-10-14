This session works on Mozilla Monitor (`mozilla/blurts-server`), a Next.js app in `/workspace`.
FxA runs beside it only for sign-in. The full manual is the Monitor section of
`/etc/vm-agent-guide.md`.

- Before you run anything, check that `/run/fxa-profile/ready` exists. If not, wait and read
  `/var/log/profile-boot.log`. If `/run/fxa-profile/failed` exists, tell the person what failed.
  Do not install things yourself.
- Run every Monitor command with Node 20 and without FxA's `NODE_ENV`:
  `export PATH=/opt/node20/bin:$PATH; unset NODE_ENV`.
- Verify with `npm run test`, `npm run test-integrations`, `npm run lint`, or
  `npx vitest run <path>` for one file. The FxA verify skills do not apply to Monitor code.
- Do not run `fxa-start`, FxA tests or FxA checks unless the task is about sign-in.
- The dev server is on http://localhost:6060. Never print `.env.local`.
- This profile is read-only: the host ships the change as a patch, not a PR.
