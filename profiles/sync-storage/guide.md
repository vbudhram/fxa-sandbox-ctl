# Sync Storage

This session works on syncstorage-rs (`mozilla-services/syncstorage-rs`) in `/workspace`: the
Sync storage server and the token server, one Rust binary. FxA runs beside it. No Docker.

## Setup

The host builds and starts the server in the background when the session starts: the Rust
toolchain, a Python venv for the token verifier, two MySQL databases, a first `cargo build`,
and the server on :8000. A first boot takes a few minutes; later steps are skipped when done.

- Wait for `/run/fxa-profile/ready`. Progress: `/var/log/profile-boot.log`. Build output:
  `/var/log/syncstorage-build.log`. A failure: `/run/fxa-profile/failed`.

## How the parts connect

| Part | Where | Notes |
|---|---|---|
| Storage and token server | http://localhost:8000 | `target/debug/syncserver --config ~/.syncstorage.toml` |
| Databases | MySQL on 127.0.0.1:3306, user `sync`, password `test` | `syncstorage` and `tokenserver`; the server runs the migrations |
| Token verifier | PyFxA in `~/.syncstorage-venv`, inside the server | The `py_verifier` feature, as production builds; it needs `PYTHONPATH` set to the venv |
| FxA | auth server http://localhost:9000, content server http://localhost:3030 | `tokenserver.fxa_oauth_server_url` points at :9000 |
| Firefox | `/home/agent/Nightly/firefox`, and the desktop's Firefox | Both use FxA's local dev prefs: Sync's token server is http://localhost:8000/1.0/sync/1.5 |

The token server assigns every user to the node `http://localhost:8000` (the `tokenserver.nodes` row).

## Commands

```
export RUSTUP_HOME=/opt/rust/rustup PATH=/opt/rust/cargo/bin:$PATH
F="--no-default-features --features=syncstorage-db/mysql --features=py_verifier"
cargo build --bin syncserver $F                   # after a change; incremental, seconds
```

Tests run under nextest, on their own databases, as the repo's CI runs them (`make test`). A
plain `cargo test -p <crate>` fails some tests that pass in CI: always use `--workspace` with a filter.

```
export SYNC_SYNCSTORAGE__DATABASE_URL=mysql://sync:test@127.0.0.1:3306/syncstorage_test
export SYNC_TOKENSERVER__DATABASE_URL=mysql://sync:test@127.0.0.1:3306/tokenserver_test
export RUST_TEST_THREADS=1 PYTHONPATH=$(~/.syncstorage-venv/bin/python -c 'import site; print(site.getsitepackages()[0])')
cargo nextest run --workspace -E 'package(tokenserver-auth)'   # one crate, the CI way
cargo nextest run --workspace                                   # everything
```

Restart the server after a build. Stop it by name with `-x`, never with `-f`: your own command
line holds this guide, so `pkill -f` with any text from it stops you too.

```
pkill -u agent -x syncserver
PYTHONPATH=$(~/.syncstorage-venv/bin/python -c 'import site; print(site.getsitepackages()[0])') \
  nohup setsid target/debug/syncserver --config ~/.syncstorage.toml > ~/.syncstorage.log 2>&1 < /dev/null &
```

## Proof

`/sync-verify` is the one command to prove a change. It runs the steps below and `/sync-e2e`.

`/sync-e2e` runs two checks:
1. `e2e.py`: a new FxA account gets a Sync token as Firefox does, the token server assigns a
   node, and a Hawk-signed record goes into storage and back.
2. `firefox.py`: a headless Firefox signs in through its own FxA code, adds a bookmark, and
   syncs. The script then counts that account's bookmarks in the `syncstorage` database.

Test accounts use `@restmail.net`: the local mail helper on :9001 reads their codes.

## Rules for this repo

- CI is GitHub Actions. Do not edit `.github/`.
- Never edit a published migration. Add a new forward migration and a rollback.
- Do not read or write `config/local.toml` or the other paths that the repo's `CLAUDE.md` lists.
- Commits use `type(scope): subject` and end with `Closes STOR-<n>` when there is a ticket.
