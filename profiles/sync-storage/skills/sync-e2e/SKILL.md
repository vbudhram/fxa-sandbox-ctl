---
name: sync-e2e
description: Use in the Sync Storage sandbox to prove local Sync works end to end, the way Firefox uses it. Checks the protocol (FxA token, token server, Hawk-signed storage), then a real headless Firefox that signs in to the local FxA and syncs to the server on :8000. Run it after a change to tokenserver or syncstorage code, once the server is rebuilt and restarted.
---

# Sync end to end

1. Check that `/run/fxa-profile/ready` exists. If not, wait: the server is still building.
2. After a code change, rebuild and restart the server (the commands are in the Sync Storage
   section of `/etc/vm-agent-guide.md`).
3. Run both checks:
   ```
   cd ~/.claude/skills/sync-e2e
   ~/.syncstorage-venv/bin/python e2e.py
   ~/.syncstorage-venv/bin/python firefox.py
   ```
   Each prints its steps, then `sync e2e: ok` or `firefox sync: ok`. On a failure it prints the
   HTTP status or Firefox's Sync status. Read `~/.syncstorage.log` for the server's side.
4. Report the output of both as the proof of the change.
