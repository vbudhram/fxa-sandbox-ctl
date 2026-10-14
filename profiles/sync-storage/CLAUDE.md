This session works on syncstorage-rs (`mozilla-services/syncstorage-rs`), Firefox Sync's storage
and token server, in Rust. FxA runs beside it: its auth server on :9000 verifies the tokens. The
full manual is the Sync Storage section of `/etc/vm-agent-guide.md`.

- Before you run anything, check that `/run/fxa-profile/ready` exists. If not, wait and read
  `/var/log/profile-boot.log`. If `/run/fxa-profile/failed` exists, tell the person what failed.
- The repo's `CLAUDE.md` says to ask before each command. Here you may build, test and run
  without asking: this sandbox is for that. Keep its other rules: no secrets, never edit a
  published migration, and stay out of the paths it lists (`config/local.toml` among them).
- Use the toolchain with `export RUSTUP_HOME=/opt/rust/rustup PATH=/opt/rust/cargo/bin:$PATH`.
  Build with `--no-default-features --features=syncstorage-db/mysql --features=py_verifier`.
- The server runs on :8000 with `~/.syncstorage.toml`; its log is `~/.syncstorage.log`.
- Prove a change with `/sync-verify`: build, lint, the changed crates' tests, then your own
  reproduction checks, the protocol check and a real Firefox sync on the running server.
- Review it with `/sync-review` (the repo's own review skills, then a Sync checklist) and `/ponytail-review`.
- This profile is read-only: the host ships the change as a patch, not a PR.
