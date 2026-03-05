# Sandbox VM — Agent Guide

> Full operations manual for AI agents running inside the FXA sandbox VM.
> For deep FXA domain knowledge, see `/workspace/ai/AGENTS.md`.

---

## Part 1 — VM Environment (Generic)

### Where You Are

- **OS:** Ubuntu 24.04 LTS (ARM64) running in a Tart VM on Apple Silicon
- **User:** `agent` (restricted sudo — systemctl, apt, mysql, redis-cli, chmod, chown)
- **Workspace:** `/workspace` (host directory mounted read-write via virtiofs)
- **Network:** Public internet only. Private/link-local ranges are firewalled (no host access).
- **SSH:** Key-only authentication (password auth disabled)

### Infrastructure (Auto-Started at Boot)

These services are started by `agent-init.service` before the agent process launches:

| Service | Port | Check |
|---------|------|-------|
| MySQL | 3306 | `mysql -u root -e "SELECT 1"` |
| Redis | 6379 | `redis-cli ping` |
| Firestore emulator | 9090 | `curl -sf http://localhost:9090/` |
| goaws (SNS/SQS stub) | 4100 | `curl -sf http://localhost:4100/` |

### Environment Variables

Loaded from `/etc/agent-env.sh` (sourced automatically by agent-init):

```bash
source /etc/agent-env.sh    # PATH, NODE_ENV, DB creds, etc.
```

### Debugging VM Issues

```bash
# Check infrastructure boot status
systemctl status agent-init
journalctl -u agent-init --no-pager

# Check running processes
pm2 status
pm2 logs --lines 50

# Check disk/memory
df -h /workspace
free -m
```

---

## Part 2 — FXA Project

### Service Management

```bash
fxa-start              # Start all FXA application services
fxa-start --status     # Show PM2 process list
fxa-start --stop       # Stop all FXA services + nginx
```

**Important:** `fxa-start` is NOT run automatically. You must run it before using any FXA services.

### Port Map & Health Checks

| Service | Port | Health Check |
|---------|------|-------------|
| Auth server | 9000 | `curl -sf http://localhost:9000/__heartbeat__` |
| Content server (nginx proxy) | 3030 | `curl -sf http://localhost:3030/` |
| Content server (direct) | 3031 | `curl -sf http://localhost:3031/` |
| Settings (React dev) | 3000 | `curl -sf http://localhost:3000/` |
| Profile server | 1111 | `curl -sf http://localhost:1111/__heartbeat__` |
| 123done (test RP) | 8080 | `curl -sf http://localhost:8080/` |
| mail_helper (email) | 9001 | `curl -sf http://localhost:9001/mail` |
| Cloud Tasks emulator | 8123 | `pm2 describe cloud-tasks-emulator` |

### Running Tests

**Before running tests**, verify services are healthy:

```bash
curl -sf http://localhost:9000/__heartbeat__ && echo "auth OK"
curl -sf http://localhost:3030/ >/dev/null && echo "content OK"
curl -sf http://localhost:8080/ >/dev/null && echo "123done OK"
curl -sf http://localhost:9001/mail && echo "mail OK"
```

**Functional tests** (Playwright, sandbox target):

```bash
cd /workspace

# Run all functional tests
yarn test-sandbox

# Run a specific test file
npx playwright test --project=sandbox tests/signin/signIn.spec.ts

# Run tests matching a grep pattern
npx playwright test --project=sandbox -g "sign in"

# Run with headed browser (visible)
npx playwright test --project=sandbox --headed tests/signin/signIn.spec.ts
```

> **WARNING:** Do NOT set `FXA_SANDBOX_IP` inside the VM. That variable is only for running tests from the host Mac. Inside the VM, tests use `localhost` automatically.

**Unit tests** for a specific package:

```bash
npx nx test-unit fxa-auth-server
npx nx test-unit fxa-settings
```

---

### Accessing from the Host Mac

To interact with FXA services from a real Firefox browser on the host, use:

```bash
fxa-sandbox-ctl browser <agent-name>
```

This launches Firefox with a dedicated profile pre-configured with all `identity.fxaccounts.*` preferences pointing at the VM. Two tabs open:
- **Tab 1:** `http://<VM_IP>:3030/` — FXA content server
- **Tab 2:** `http://<VM_IP>:3030/__inbox` — Inbox viewer for captured emails

The browser uses `oauth_webchannel_v1` context (not `fx_desktop_v3`), matching the modern OAuth-based Sync flow.

### Inbox Viewer

The inbox viewer is a self-contained HTML page served at `/__inbox` via nginx. It polls `/__mail/{username}` (proxied to mail_helper on :9001) every 3 seconds.

Features:
- Enter an email address (or just the username part) to watch for emails
- Verification codes are displayed prominently with copy-to-clipboard
- Clickable verification links (`x-link` header)
- Expandable HTML body preview
- Supports `?email=` query param for pre-populating the username
- Clear All button to flush emails

Inside the VM, the inbox viewer is available at `http://localhost:3030/__inbox`.

### Running Functional Tests from the Host

You can run Playwright functional tests from your Mac targeting the sandbox VM:

```bash
cd packages/functional-tests
FXA_SANDBOX_IP=<VM_IP> yarn test-sandbox

# Or run specific tests:
FXA_SANDBOX_IP=<VM_IP> npx playwright test --project=sandbox tests/signin/signIn.spec.ts
```

The sandbox Playwright project uses `oauth_webchannel_v1` context and includes HSTS-disabling Firefox prefs (the sandbox auth server sends `strict-transport-security` headers over plain HTTP).

### Architecture: nginx Reverse Proxy

```
Browser ──► nginx (:3030)
              ├── /__inbox             ──► /tmp/inbox-viewer.html (static file)
              ├── /__mail/*            ──► mail_helper (:9001) [API proxy]
              ├── /static/*            ──► settings dev server (:3000)
              ├── /settings/static/*   ──► settings dev server (:3000)
              ├── /sockjs-node, /ws    ──► settings dev server (:3000)  [HMR WebSocket]
              └── /* (everything else) ──► content server (:3031)
```

- `sub_filter` rewrites `$VM_IP` URLs to `$host` in HTML/JSON/JS responses
- This makes URLs work both from the host Mac (via VM IP) and inside the VM (via localhost)
- Content server's `PUBLIC_URL` stays as `http://$VM_IP:3030` for correct server-side logic

### PM2 Processes

After `fxa-start`, these PM2 processes run:

| Process | What It Does |
|---------|-------------|
| `auth` | fxa-auth-server on :9000 |
| `content` | fxa-content-server on :3031 (watched, auto-restarts on changes) |
| `settings-react` | Webpack 5 dev server for fxa-settings on :3000 |
| `settings-css` | Tailwind CSS watcher |
| `settings-ftl` | Fluent l10n file watcher |
| `profile` | fxa-profile-server on :1111 |
| `inbox` | mail_helper on :9001 |
| `123done` | Test relying party on :8080 |
| `cloud-tasks-emulator` | gRPC emulator on :8123 |
| `goaws-stub` | SNS/SQS stub on :4100 (if goaws binary missing) |

---

### fxa-settings (React UI on :3000)

- Ejected CRA with Webpack 5 dev server
- **HMR enabled:** edit `.tsx`, `.css`, or `.ftl` files and changes appear instantly in the browser — no restart needed
- Three PM2 processes: `settings-react` (Webpack), `settings-css` (Tailwind watcher), `settings-ftl` (Fluent l10n watcher)
- Source: `packages/fxa-settings/src/`
- nginx routes `/static/*`, `/settings/static/*`, `/ws` (HMR WebSocket) to :3000

### fxa-content-server (Node.js on :3031)

- Legacy Backbone server, proxied behind nginx at :3030
- PM2 watch enabled on `server/**/*.js` — auto-restarts on code changes (manual browser refresh needed)
- `PROXY_SETTINGS=true` makes it proxy React settings routes to fxa-settings
- `local.json` overrides: CSP disabled, `public_url=localhost:3030`, `showReactApp` flags
- Source: `packages/fxa-content-server/server/`

### fxa-auth-server (Hapi on :9000)

- Core authentication API (SRP, OAuth, sessions, keys)
- `PUBLIC_URL` and `OAUTH_URL` set to `localhost:9000` (JWT issuer must match)
- Stripe/subscriptions **disabled** (`SUBHUB_STRIPE_APIKEY=""`, `SUBSCRIPTIONS_ENABLED=false`)
- Rate limiting **disabled** (`CUSTOMS_SERVER_URL="none"`)

---

### Common Gotchas

1. **Services are NOT auto-started.** You must run `fxa-start` after the VM boots.

2. **Cloud Tasks emulator must start before auth server.** `fxa-start` handles this, but if restarting auth manually, ensure the emulator is running first or `accountDestroy` returns 500.

3. **nginx handles :3030, not content server.** The content server listens on :3031. Port 3030 is nginx, which proxies to both content (:3031) and settings (:3000).

4. **Do NOT set `FXA_SANDBOX_IP` inside the VM.** This variable is for the host Mac. Inside the VM, use `localhost` for all service URLs.

5. **Native modules need platform fix.** The workspace `node_modules` are from macOS (darwin-arm64). `fxa-start` installs Linux equivalents automatically. If you reinstall packages, you may need to run `fxa-start` again.

6. **Auth server PUBLIC_URL must be localhost.** The JWT issuer derives from `PUBLIC_URL`. If set to the VM IP, OAuth token verification fails with issuer mismatch.

7. **Stripe/subscriptions are disabled.** No Stripe, Play Store, or App Store backends. Subscription-related features will return empty results.

8. **Rate limiting is disabled.** `CUSTOMS_SERVER_URL="none"` — no request throttling in the sandbox.

9. **mail_helper is the email service.** Emails are captured locally on :9001. Check `curl http://localhost:9001/mail` for verification codes. Or use the inbox viewer at `http://localhost:3030/__inbox`.

10. **Settings HMR works live; content-server needs restart.** Edit settings `.tsx` → instant update. Edit content-server `.js` → PM2 auto-restarts (watch mode) but you need to refresh the browser.

11. **nginx must be manually restarted if proxy config changes.** If you modify `/tmp/fxa-proxy.conf`, run `nginx -c /tmp/fxa-proxy.conf -s reload`.

---

### Deep Domain Knowledge

For FXA architecture, domain-specific guides, and coding conventions, see:
- `/workspace/ai/AGENTS.md` — Entry point for all AI documentation
- `/workspace/ai/ARCHITECTURE.md` — Full system map
- Domain guides in `/workspace/ai/docs/domain-guides/`

> These paths reference the FXA monorepo mounted at /workspace.
