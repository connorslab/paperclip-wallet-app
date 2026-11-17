# Native desktop prerequisites

Linux, macOS and Windows packages must embed the same web UI and wallet daemon as
StartOS/Umbrel. This directory contains acceptance tooling and a POSIX daemon
ownership module; it is not an installed launcher, signed application or complete
desktop release.

Build `paperclip-walletd` from the reviewed revision with the `barkd-web-ui` and
`sqlite-bundled` features and `BARK_WEB_DIST` pointing to `web/`. Run:

```
python3 deployment/desktop/test_native_daemon.py --binary /absolute/path/to/paperclip-walletd
```

This check creates an isolated, unfunded data directory and binds only loopback.
It requests port zero so the OS assigns an available port, then discovers the
actual address in `barkd.url`. The daemon publishes that address only after a
successful bind; an occupied fixed port must leave the last discovery address
unchanged. Unix discovery updates use atomic replacement. Windows atomic
discovery and ACL acceptance remain separate packaging work.
It checks shared UI assets, owner authentication, cross-origin preflight denial,
Unix file permissions, graceful shutdown and authentication preservation across
restart. A competing process uses a different port to verify that the data-directory
lock, rather than a port collision, protects the running instance and its discovery
address. It then kills only its own unfunded child, restarts without deleting lock
files, and verifies that malformed saved authentication fails closed instead of
silently rotating. The Linux backend CI runs this prerequisite too; it is not a
signed-installation test. It also checks advertised entropy choices and rejects
invalid generation requests before wallet creation. It does not create wallet keys, use real
credentials or contact nodes.
Windows ACL acceptance remains separate from the Unix mode checks.

## Daemon ownership module

`managed_daemon.py` supplies the process ownership layer for a future Linux/macOS
shell. Nothing starts on import. The caller supplies the packaged daemon and a
private application root; wallet data lives under its `wallet/` subdirectory.
The separate launcher lock survives wallet deletion. The module provides the
standard macOS Application Support and Linux XDG data locations, rejects loose
or symlinked data directories, and drops inherited service, proxy and loader
overrides. It never reads the user's existing wallet implicitly.

Readiness requires an atomically replaced discovery file, the owned child's PID,
and a successful authenticated loopback request. Stale discovery and independently
started daemons are not adopted. Authentication is never printed or put in command
arguments or a browser URL. Redirects are refused. A stdin lifetime pipe requests
graceful daemon shutdown on normal close or abrupt launcher death. The daemon
opts in explicitly with `--exit-on-stdin-close`; ordinary server launches retain
their existing behavior. The lifetime reader does not hold the Tokio runtime
open when another shutdown signal arrives. Close and failed startup reap only
the owned process; a forced shutdown is reported as a recovery warning.

Run the real-child checks in a temporary, unfunded directory:

```
python3 deployment/desktop/test_managed_daemon.py --binary /absolute/path/to/paperclip-walletd -v
```

The runner supplies `browser_url()` for the future shell's browser-opening action.
It uses the owner credential only in an authenticated local POST and returns a
different, single-use code in the URL fragment. Never log or persist that URL.
The code expires after 60 seconds; issuing a new one replaces the previous code.
The browser removes it from the address before the rest of the UI loads, then
exchanges it through a same-origin POST. The exchange checks exact Host/Origin,
refuses replay, limits request bodies and returns no-store responses. The browser
keeps the resulting owner credential in memory rather than tab storage for this
automatic sign-in. Reopening from the desktop shell creates a fresh handoff;
refreshing a memory-only tab requires signing in again.

The server routes are absent unless `--desktop-handoff` is explicitly enabled
alongside the launcher lifetime flag. Non-loopback, unauthenticated and UI-disabled
configuration is rejected. Host packages and ordinary server launches retain
their existing authentication flow. Browser fixtures cover successful empty-wallet
setup, expired/interrupted/malformed codes, nonlocal pages and no retry at phone
and desktop widths; real-daemon checks cover authenticated issue and one use.

The runner does not yet open an OS browser window or supervise Tor/Jam.
Abrupt launcher-death tests cover an unfunded idle daemon: active payment
and long-running request shutdown still require acceptance. First-run service/network configuration,
packaged interpreter/runtime delivery, full OS ACL acceptance, Windows ownership
support and a visible shell remain release gates. Do not distribute this module
as a complete desktop app or point its acceptance tests at funded storage.

Open work includes the OS-specific visible launcher and installed browser handoff
acceptance, full private data/ACL checks, bundled Tor/Jam,
signing/notarization, installer upgrades, wallet migrations and full backup/restore.
The pinned Jam runtime and companion currently use POSIX `fcntl` locks; Windows
needs a reviewed equivalent or an explicitly managed packaged runtime before it
can meet parity. Do not remove locking or substitute a separate user-installed Jam
app to claim that gate has passed. See [the coordinated release gates](../COORDINATED-RELEASE.md).
