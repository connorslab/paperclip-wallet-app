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

The development macOS shell in `macos/Launcher.swift` now opens the OS browser
using that handoff. It shows startup, ready, open and retry states, monitors the
owned helper without blocking AppKit, and quits through the lifetime chain.
The helper accepts only bounded open/quit messages over private stdio. A wallet
process exit produces a visible retry action rather than a stale Ready state.
The runner still does not supervise Tor/Jam.
The shared REST server interrupts unfinished request-body reads when shutdown is
requested. An interruption is an error, never a synthetic end-of-body: even valid
JSON received before the HTTP body finishes cannot start a handler during shutdown.
Handlers that already consumed their requests retain the existing graceful-shutdown
behavior. A real-child regression keeps an unfinished authenticated upload open
while closing the launcher, checks a clean exit without wallet creation, and then
checks restart with the original authentication.
Abrupt launcher-death tests cover an unfunded idle daemon: active payment
and long-running handler shutdown still require acceptance. First-run service/network configuration,
packaged interpreter/runtime delivery, full OS ACL acceptance, Windows ownership
support and installed shell acceptance remain release gates. Do not distribute this module
as a complete desktop app or point its acceptance tests at funded storage.

Open work includes Linux/Windows visible launchers and installed browser handoff
acceptance, full private data/ACL checks, bundled Tor/Jam,
signing/notarization, installer upgrades, wallet migrations and full backup/restore.
The pinned Jam runtime and companion currently use POSIX `fcntl` locks; Windows
needs a reviewed equivalent or an explicitly managed packaged runtime before it
can meet parity. Do not remove locking or substitute a separate user-installed Jam
app to claim that gate has passed. See [the coordinated release gates](../COORDINATED-RELEASE.md).

## Development macOS preview

Build on a Mac with native Apple tools. Supply a reviewed native daemon and an
explicit local Python interpreter. Existing output apps are never overwritten:

```
python3 deployment/desktop/macos/build_preview.py \
  --binary /absolute/path/to/paperclip-walletd \
  --python /absolute/path/to/python3 \
  --output '/absolute/new/path/Paperclip Preview.app'
```

This preview embeds the daemon and helper scripts, uses Python isolated mode and
is ad-hoc signed for local development. It references the supplied interpreter;
it is **not standalone, Developer ID signed or notarized**. Its default data root
is the separate `~/Library/Application Support/Paperclip Preview`. QA can supply
an absolute `--qa-root` in a fresh temporary directory. Never point this preview
at funded storage to satisfy release acceptance.

Native Apple Silicon verification covers launch to Ready, opening the real default
browser into empty-wallet setup, a deliberately stopped QA daemon leading to Try
Again, successful retry and window-close cleanup. No wallet was created. The
five stdio bridge tests run on the built native daemon in backend CI; the macOS
workflow compiles AppKit separately. Older macOS versions, Intel execution,
clean-machine Python/runtime bundling and installed upgrades remain unverified.
