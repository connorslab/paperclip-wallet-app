# Native desktop prerequisites

Linux, macOS and Windows packages must embed the same web UI and wallet daemon as
StartOS/Umbrel. This directory contains development shells for Linux and macOS,
acceptance tooling and a POSIX daemon ownership module. These previews are not
signed applications or complete desktop releases.

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

`managed_daemon.py` supplies the process ownership layer for the Linux/macOS
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

The runner supplies `browser_url()` for the shell's browser-opening action.
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

`test_browser_handoff.py --binary /absolute/path/to/paperclip-walletd` combines
the real owned daemon with isolated Chromium profiles through Playwright. It
checks authenticated empty-wallet setup at phone and desktop widths, refresh
locking, consumed-code rejection in a new tab, no automatic retry, a fresh grant
after rejection, preserved authentication and clean shutdown without creating
keys. Codes travel only over private stdin. Browser failures report a fixed stage
instead of URLs or credentials. Node and the pinned Playwright/Chromium runtime
must be installed before this test runs. Linux CI uses the packaged preview's
daemon; the shared frontend files also trigger this combined check. This test
does not invoke the OS default-browser handler or accept an installed package.

The development macOS shell in `macos/Launcher.swift` now opens the OS browser
using that handoff. It shows startup, ready, open and retry states, monitors the
owned helper without blocking AppKit, and quits through the lifetime chain.
The helper accepts only bounded open/quit messages over private stdio. A wallet
process exit produces a visible retry action rather than a stale Ready state.
The runner can supervise its packaged Jars child as described below; Tor hosting is separate.
A private `session.active` marker in the application root is written and synced
before daemon launch. Only an observed successful close of a ready, owned child
clears it. Forced shutdown, launcher death, unexpected child exit and failed
startup retain the warning for the next launch. It survives wallet-directory
deletion. Competing launchers cannot clear it; linked, shared or malformed marker
files are rejected without repair. The helper's ready event carries only a
`recovery_required` boolean. The macOS shell then offers Review Wallet and asks
users to check Activity before another payment. A later clean close clears this
advisory, never a payment receipt or an uncertain outcome.
The shared REST server interrupts unfinished request-body reads when shutdown is
requested. An interruption is an error, never a synthetic end-of-body: even valid
JSON received before the HTTP body finishes cannot start a handler during shutdown.
Handlers that already consumed their requests retain the existing graceful-shutdown
behavior. A real-child regression keeps an unfinished authenticated upload open
while closing the launcher, checks a clean exit without wallet creation, and then
checks restart with the original authentication.
`test_managed_shutdown.py --binary /absolute/path/to/paperclip-walletd -v` exercises
an already-dispatched request against an isolated HTTPS Jam fixture. It generates
temporary TLS material with OpenSSL and uses an explicit local trust anchor;
verification stays enabled. Normal close stops accepting connections, lets the
read finish, and clears the session marker only after successful child exit. A
shortened shutdown deadline forces termination, retains the marker and warns on
restart. A launcher-crash case verifies that the orphaned daemon drains its
active read, releases its lock and retains the warning for the replacement owner.
All three paths preserve authentication and do not replay the request. No
wallet or payment is created. Linux CI runs these checks alongside the native
Apple validation. This does not prove active-payment persistence, settlement or
real Jam hosting. Launcher death during a funded payment remains unverified.
First-run service/network configuration,
packaged interpreter/runtime delivery, full OS ACL acceptance
and installed shell acceptance remain release gates. Do not distribute this module
as a complete desktop app or point its acceptance tests at funded storage.

Open work includes installed browser handoff acceptance, full private data/ACL
checks, bundled Tor/Jam,
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
six stdio bridge tests run on the built native daemon in backend CI; the macOS
workflow compiles AppKit separately. Older macOS versions, Intel execution,
installed upgrades and supported-OS coverage remain unverified. The bundled-helper isolation check below covers build-host dependency isolation.


## Development Linux preview

The Linux shell uses the same daemon ownership, private storage, one-use browser
handoff and unclean-session advisory as the macOS preview. A worker owns the daemon;
startup, requests and shutdown do not block the window. Browser opening runs outside
the UI thread, validates the exact loopback handoff URL and requires an explicit
action. Crashes expose Try Again; restarting does not replay a browser request.
Late browser results cannot replace a daemon failure message. The window supports
keyboard activation and a compact recovery layout.

Build on Linux with a reviewed native daemon and an explicit Python interpreter
that includes Tk. Existing output directories are never overwritten:

```
python3 deployment/desktop/linux/build_preview.py \
  --binary /absolute/path/to/paperclip-walletd \
  --python /usr/bin/python3 \
  --output '/absolute/new/path/Paperclip Linux Preview'
'/absolute/new/path/Paperclip Linux Preview/bin/paperclip-preview'
```

The preview embeds the daemon and launcher modules. It uses Python isolated mode
and an external interpreter/Tk runtime; it is unsigned and is not a standalone
installer. The default data root follows XDG data locations. `--qa-root` must be
an explicit absolute isolated directory. Do not use funded storage for acceptance.

Controller tests run with `test_launcher.py --binary /absolute/path/to/paperclip-walletd`.
Linux CI builds the preview in a path with spaces, checks its executable wrapper,
and runs `test_launcher_ui.py` under Xvfb against its packaged daemon/modules.
The GUI test opens only a captured handoff (no real browser), exercises crash/retry,
checks the compact recovery layout, and closes without creating a wallet.
Wayland/desktop integration, real default-browser behavior on installed Linux,
accessibility, runtime bundling, bundled Jam/Tor, signed installers and upgrades
remain separate acceptance requirements.

## Owned Jars in development previews

Both preview builders accept `--jam-python /absolute/pinned-runtime/bin/python`.
They copy the companion and native entry point into the package, and preserve the
interpreter path so a development virtual environment remains selected. The
launcher starts Jam in a separate `jars/` directory, verifies its loopback TLS and
capability response, then supplies only its endpoint and public certificate to the
wallet daemon. Inherited service overrides cannot replace that connection.

The visible shells monitor both children. Normal close drains wallet requests
before closing Jam; failure of either service retains the shared recovery marker.
Explicit retry creates new owned children and displays the recovery warning. It
never replays a payment. The marker is cleared only after both close cleanly.

`test_managed_jam.py --python /absolute/pinned-runtime/bin/python --entry
/absolute/source/deployment/jam/desktop-entry.py --binary /absolute/paperclip-walletd`
checks the real owned service and the wallet's authenticated HTTPS proxy without
creating a wallet. Omitting `--binary` runs the independent Jam ownership checks,
as done inside the two-architecture pinned companion CI. The native Mac package
was also opened through AppKit, queried through its authenticated wallet proxy,
then checked for visible crash/retry and normal window-close cleanup.

This development option still references an external interpreter. It does not
stand in for a bundled runtime, Tor/RPC setup or installed signed distribution.


## Standalone native macOS preview

`macos/build_helpers.py` freezes the explicitly selected reviewed Jam environment
and launcher into separate native helper app bundles with PyInstaller 6.22.3.
Install that build tool in an isolated build directory, then invoke the script
with the pinned Jam interpreter and companion available on the build module path:

```
python deployment/desktop/macos/build_helpers.py \
  --source /absolute/source/deployment \
  --secp256k1 /absolute/reviewed/lib/libsecp256k1.dylib \
  --output '/absolute/new/path/Helpers' --work /absolute/new/build-work
python3 deployment/desktop/macos/build_preview.py \
  --binary /absolute/path/to/paperclip-walletd \
  --helpers '/absolute/new/path/Helpers' \
  --output '/absolute/new/path/Paperclip Preview.app'
python3 deployment/desktop/macos/test_bundle.py \
  --app '/absolute/new/path/Paperclip Preview.app'
```

The crypto installation must include its `COPYING` file. The builder includes
that notice and Python's license, records installed package versions and the
crypto input hash, and verifies each helper signature before assembling the app.
Bundled mode records no external interpreter path. The Jars child selects its
bundled secp256k1 and CA files before importing wallet code. Every Python entry
point disables bytecode writes so execution cannot alter the signed resources.

`test_bundle.py` copies the app into a different path containing spaces, denies
reads of the original app, Homebrew and `/usr/local`, and exercises all 13 actual
Jars/wallet/launcher lifecycle cases. It checks signatures before and after use.
This caught and fixed a post-launch bytecode signature failure and an incorrect
ad-hoc/hardened-runtime signing combination. Local AppKit QA additionally verifies
Ready, authenticated empty Jars discovery through the wallet's TLS proxy, window
close and released process locks. These checks create no wallet or payment.

The result is an ad-hoc development preview. It is not Developer ID signed or
notarized, and the isolation test does not substitute for supported macOS/Intel
installation, upgrades or live payment acceptance.


## Bundled Linux launcher verification

`linux/build_helpers.py` accepts a native Linux Python environment with Tk and
PyInstaller 6.22.3. It produces `PaperclipLauncher` and a separate
`PaperclipLauncherQA` directory. Pass the first directory to
`linux/build_preview.py --helper` instead of `--python`; only the application
helper is copied into the preview. The QA executable freezes the same window code
with its unfunded GUI tests and is never installed into the app package.

The backend Linux workflow builds both helpers in an isolated tool environment,
checks the packaged wrapper, relocates the package into a path with spaces, and
runs the frozen QA window under Xvfb. That verifies included Tk startup, explicit
browser opening through a captured test callback, crash/retry, compact layout,
credential preservation and clean close. It does not open the user's browser.
The frozen application uses `xdg-open` with its original system library path;
PyInstaller's private loader path cannot leak into the browser child. A controller
test checks both absent and explicitly supplied original paths without changing
the launcher's process environment.

`linux/build_jars.py` additionally freezes the reviewed Jars environment, its
Python dependencies, CA bundle and explicitly supplied secp256k1 library. It
requires the crypto license notice and records source/dependency fingerprints.
Pass its `PaperclipJars` directory to `linux/build_preview.py --jam-helper` to
package both runtimes. The wrapper supplies the bundled executable directly;
no external interpreter is selected in this mode. The desktop entry point
requires its bundled crypto library and fails if it is missing.

The Linux workflow installs the pinned JoinBlaket source with hash-checked runtime
requirements, applies the existing hash-checked companion registration, freezes
Jars and packages it alongside the launcher and wallet daemon. It relocates the
package and removes the original runtime/source paths before exercising verified
TLS discovery, wallet proxy requests, child failure/retry and normal window close.
These tests use empty storage and do not send payments. Native execution must pass
before accepting this packaging; Tor/RPC setup and signed installation are
separate acceptance requirements.


## Native Windows ownership and development preview

`windows/private_storage.py` uses native Windows ACL and kernel-lock APIs through
pinned pywin32 311. It accepts only local, unambiguous paths; creates directories
with explicit current-user ownership and user/SYSTEM access; and validates
existing ACLs without silently repairing them. Junctions, other reparse points,
hard-linked files and unexpected owners/permissions fail closed. Ancestor handles
exclude delete-sharing during creation and acquisition. Kernel locks survive
neither normal handle close nor process death, so stale files cannot establish
ownership.

`windows/test_private_storage.py` now defines 14 native cases in temporary,
unfunded directories. These include ACL inheritance with explicit ownership (the
hosted CI token is elevated), shared/null ACL rejection, junction protection,
hard-link rejection, competing/killed processes, recovery records and checked
reader identity. The shared runner uses these native handles on Windows. Its six
owned-daemon checks cover normal close, handoff, duplicate launch, daemon death,
launcher death and malformed recovery state. Windows Jars uses its own pinned
native crypto, Python and storage adapters; it cannot use a POSIX runtime.

A local NTFS session record is held open under the launcher's lock. Before starting
the child it writes and flushes a fixed active state; only an observed clean close
writes and flushes the equal-length closed state. Malformed records fail closed
without starting a child or rewriting the record. A crash preserves the warning.
This public record never authorizes or replays a payment and does not replace the
wallet's payment journal. Tests do not establish physical power-loss durability.

The native Rust daemon has private ACL and atomic-write support. PID files also
use explicit user ownership and protected ACLs at creation, including when the
process runs with an elevated token. Existing files are validated without
truncation or permission repair before acquiring the PID lock. Windows CI builds
it with pinned dependencies and exercises authenticated unfunded startup,
duplicate-instance rejection, malformed-authentication rejection, crash/restart,
graceful shutdown and preservation of saved authentication. It also runs eleven
Rust filesystem, eight PID-lock and four discovery cases. The desktop pipe adapter
has eight native cases for bounded partial reads, deadlines and EOF. Python reads
use the checked native reader with delete sharing so they remain compatible with
the writer's still-open renamed staging handle.

Build the unsigned preview on Windows with Python 3.13, pywin32 311, Tk and
PyInstaller 6.22.3:

```
python deployment/desktop/windows/build_preview.py --binary C:/build/paperclip-walletd.exe --output C:/build/preview --work C:/build/preview-work
C:/build/preview/PaperclipLauncher/PaperclipLauncher.exe
```

The launcher bundles Python/Tk and selects its adjacent daemon. It uses the current
user's Local AppData folder by default; `--qa-root` selects explicit isolated
storage for testing. Its shared window has bounded startup, visible failure,
explicit retry and a recovery warning. Closing the window closes only its owned
child. The browser receives only a validated expiring handoff URL. A separate
short-lived helper resets the frozen loader's DLL path before asking Windows to
open the default browser, following
[PyInstaller's Windows guidance](https://pyinstaller.org/en/stable/common-issues-and-pitfalls.html#windows).
The UI process keeps its loader state throughout.

The builder records source fingerprints, package versions and the copied daemon's
actual version/hash. CI relocates both the app and separate QA runner into a path
with spaces, removes the original desktop sources, then checks the frozen window's
handoff, crash/retry, compact layout, missing-executable error and native window
close against empty storage. `PaperclipLauncherQA` is test tooling and must not be
included in a final installation. Native Windows run `44182029312` passes all three frozen-window cases at
`82387db`, including the separate windowed executable's normal close. Its full
native run passes 58 checks plus the authenticated daemon lifecycle script. The freezer
explicitly includes `win32timezone`, which pywin32 imports from native code while
constructing file metadata timestamps. The negative package failed at that import;
the corrected relocated package starts and recovers successfully. This preview is
unsigned and is not an installer or a complete Windows release.



## Preview build records

Bundled Linux/macOS previews include `build-info.json` with the copied daemon's
own version and SHA-256, builder fingerprint, and helper dependency/source record.
The helper record includes its checkout revision and individual runtime-source
hashes. Builds abort if those source files change during helper assembly. The
Mac launcher is compiled from a captured Swift source copy and its fingerprint
is recorded; the manifest is inside the signed app resources. Records omit the
build machine's absolute source path.

The helper checkout revision does not imply that a supplied daemon came from
that revision or that local files were clean. The separate binary version/hash
and source fingerprints retain that distinction. These development previews can
identify mixed inputs; a release candidate still requires one reviewed revision.
The relocated Mac test and Linux packaging CI compare the copied daemon against
its manifest before exercising the packaged runtime.

## Windows preview with bundled Jars

The `windows-jars.yml` workflow builds the pinned native crypto DLL and an
isolated, hash-locked Jars environment. It applies checksum-gated Windows storage
and TLS adapters, then freezes the runtime with Python and its dependencies.
No separately installed Python or Kilombino app is used by the frozen service.
Its relocated standalone lifecycle/TLS checks pass at `59afef4`.

Pass the resulting `PaperclipJars` directory to `windows/build_preview.py --jars`.
The preview builder requires matching Git revision and source fingerprints and
copies the runtime beside the window. `runtime.json` records that Jars is required;
a missing configured runtime prevents startup. The window owns both the wallet
and Jars and preserves the recovery warning after an unexpected child exit.
Combined wallet/proxy and packaged-window CI is required in addition to standalone
runtime checks. These are unsigned previews, not accepted installers; Tor/RPC
configuration, live payment acceptance and installed upgrades remain separate.


## Owned Tor supervisor

`ManagedDaemon(..., jam_runtime=(python, entry), tor_binary=reviewed_executable)`
can start a separate owned Tor child for bundled Jars and the wallet's Lightning
proxy. The executable must be supplied explicitly. The supervisor never attaches
to a system Tor or falls back to a direct connection. This component does not yet
select a Tor distribution for release or provide the node-RPC setup UI.

Tor starts with networking disabled and private, unique control metadata. The
controller authenticates with the cookie, takes ownership, then enables networking
and discovers its dynamically assigned loopback SOCKS port. Control readiness,
SOCKS readiness and bootstrap progress are distinct. A private cookie path and
explicit loopback ports reach Jam through its isolated arguments and environment.
The wallet receives only the SOCKS proxy address. Shutdown drains the wallet and
Jam before Tor. An unexpected Tor exit preserves the desktop recovery warning.

The lifecycle follows Tor's [owning-controller protocol](https://spec.torproject.org/control-spec/commands.html#takeownership).
Control replies and bootstrap summaries are not copied into user diagnostics.
Parser limits reject oversized, truncated, unsolicited and unsupported replies.

Run `python3 deployment/desktop/test_managed_tor.py --tor /path/to/tor -v` for
local control, ownership and retry checks with networking disabled. Add `--network`
to permit the isolated Tor child to contact relays and test the SOCKS handshake.
Neither mode sends a node request or a payment. Run `test_managed_jam.py` with
`--tor /path/to/tor` and the existing `--python`, `--entry` and `--binary` inputs
for combined ownership, TLS and recovery checks.

Native checks of the pinned Tor 0.4.9.16 input cover Windows x86-64, Linux
x86-64/ARM64 and macOS Intel/ARM64, including private control files, explicit
SOCKS activation and retry. The ARM64 Mac also has a separate successful full
bootstrap check. Combined runtime, installed-host and live-node acceptance are
tracked separately in [the coordinated release checklist](../COORDINATED-RELEASE.md).
A passing Tor component check alone does not accept a complete wallet package.


## Tor package inputs

All three native preview builders accept `--tor-runtime /reviewed/runtime` when
Jars is included. They copy that explicit directory, record its inventory in
build provenance and configure the launcher to use the copy. Linux and macOS
helpers validate it again before wallet startup. Windows validates it before
opening its wallet window and again in the session worker. A configured missing
or damaged runtime cannot silently fall back to a direct connection or system Tor.

The supplied directory contains `runtime.json` with exactly these fields:

- `format`: integer `1`.
- `target`: `macos-arm64`, `macos-x86_64`, `linux-arm64`, `linux-x86_64`, or
  `windows-x86_64`, matching the build host.
- `version`: the four-part Tor version.
- `source`: the reviewed upstream HTTPS source URL.
- `executable`: the relative path of the Tor binary.
- `licenses`: a nonempty list of relative license-file paths.
- `files`: every file except `runtime.json`, mapped to its lowercase SHA-256.

Use ordinary files and directories, with no symbolic links, junctions, special
files, parent traversal or platform-reserved names. Missing, additional, altered
or wrong-target inputs fail validation. Copy verification also detects input
changes during packaging. Native Mac inputs must already have valid code signatures;
the preview builder preserves them and seals the copied runtime under Resources.
The final Developer ID signing procedure remains separate.

The inventory is a completeness check, not a publisher signature or evidence that
shared libraries are self-contained. Review the source, licenses and dependency
closure before supplying a release runtime. Run relocation tests with build-host
dependencies denied. The Mac relocation suite includes Tor when `bundledTor` is
set and still rejects external Homebrew dependencies. No runtime is downloaded,
selected from PATH, or enabled by default by these builders.

Validation uses `test_tor_runtime.py` on all three hosts. The native bridge suite
also accepts `--tor-runtime`, together with either `--jam-executable` or the
explicit development `--jam-python`/`--jam-entry` pair. Those combined lifecycle
tests permit Tor relay connections but do not create keys or make payments.


## Preparing reviewed Tor archives

`tor-artifacts.json` pins the Tor Project expert bundle 16.0.1 archives for the five
listed OS/CPU targets. Each SHA-256 was recorded only after checking the upstream
OpenPGP signature against Tor's published primary fingerprint. See the
[official downloads](https://download.torproject.org/tor/) and
[signature instructions](https://support.torproject.org/tor-browser/getting-started/verifying-tor-browser/).
The records identify tested development inputs, not an automatic release upgrade
policy. Updating them requires a new signature check and native acceptance.

Download the exact `source` URL for the build host, then run:

```
python deployment/desktop/prepare_tor.py \
  --archive /absolute/downloaded-expert-bundle.tar.gz \
  --output /absolute/new/TorRuntime
```

On macOS, also pass `--ad-hoc-sign` for the development copy. Native Apple tools
verify each resulting Mach-O signature before its file inventory is generated.
The signed upstream archive is preserved. Release signing and notarization remain
separate. Preparation never downloads or executes Tor, creates wallet storage,
or changes an installed runtime.

The preparer checks the pinned hash before extraction and again before publishing
the staged directory. It bounds archive size, expanded size and member count;
rejects links, special files, traversal, duplicate/case-colliding names and missing
license notices; and preserves all ordinary upstream files. Existing output is
never overwritten. Pass its output to a preview builder's `--tor-runtime` option.

Linux expert executables have no ELF RPATH/RUNPATH. Their supervisor supplies only
the explicitly selected Tor executable's directory as `LD_LIBRARY_PATH`, without
inheriting loader overrides. The native Linux test inspects the owned process's
loaded libraries to check that crypto, TLS and libevent came from that directory.
The native Tor CI workflow tests prepared, relocated runtimes with networking
disabled on Linux, Windows and macOS. Unrun architectures are not implied by
successful archive verification or another host's tests.
