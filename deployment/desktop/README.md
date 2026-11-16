# Native desktop prerequisites

Linux, macOS and Windows packages must embed the same web UI and wallet daemon as
StartOS/Umbrel. This directory begins their acceptance tooling; it is not a
launcher, installer, signed application or complete desktop release.

Build `paperclip-walletd` from the reviewed revision with the `barkd-web-ui` and
`sqlite-bundled` features and `BARK_WEB_DIST` pointing to `web/`. Run:

```
python3 deployment/desktop/test_native_daemon.py --binary /absolute/path/to/paperclip-walletd
```

This check creates an isolated, unfunded data directory and binds only loopback.
It checks shared UI assets, owner authentication, cross-origin preflight denial,
Unix file permissions, graceful shutdown and authentication preservation across
restart. It also checks advertised entropy choices and rejects invalid generation
requests before wallet creation. It does not create wallet keys, use real
credentials or contact nodes.
Windows ACL acceptance remains separate from the Unix mode checks.

Open work includes the OS-specific launcher and authenticated browser handoff,
private data locations, a single managed service instance, bundled Tor/Jam,
signing/notarization, installer upgrades, wallet migrations and full backup/restore.
The pinned Jam runtime and companion currently use POSIX `fcntl` locks; Windows
needs a reviewed equivalent or an explicitly managed packaged runtime before it
can meet parity. Do not remove locking or substitute a separate user-installed Jam
app to claim that gate has passed. See [the coordinated release gates](../COORDINATED-RELEASE.md).
