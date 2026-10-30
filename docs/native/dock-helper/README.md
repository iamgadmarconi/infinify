# Dock helper

This native adapter targets Apple Silicon macOS 26 or later. Its listener is
binary protocol v2 on `RUNTIME/v2.sock`. Loading a payload starts no
transformation; a controller must name an exact in-scope process instance and
window in a `FRAME` request.

Default commands remain read-only. Build commands compile and sign artifacts but
do not load Dock or launch fixtures. Native mutation tests use only explicitly
spawned disposable fixture windows and restore their original transforms before
cleanup. These tests do not establish Dock-hosted authority or usable third-party
native-window compositing.

## Documents

| Document | What it holds |
| --- | --- |
| [Loader/README.md](Loader/README.md) | The explicit production launcher: loader, doctor, manifest |
| [Daemon/README.md](Daemon/README.md) | The launch daemon, login start and Dock reload |
| [Client/README.md](Client/README.md) | Protocol v2 and the client library |
| [Payload/README.md](Payload/README.md) | The arrival veil, the journal and strict recovery, placements |
| [../testing.md](../testing.md) | The native regressions and the focused fixture validation |

## Build and entrypoints

`./scripts/build-privileged.sh` builds the following in `target/privileged`
(helper code at `-O2`):

- `doctor`: a read-only SIP and arm64e boot-policy report.
- `payload-arm64e.dylib`: the explicit Dock-targeted payload.
- `payload-arm64.dylib` and `host`: an ordinary cooperative fixture process.
- `dwclient.o` and `dwclient-arm64e.o`: the plain C/pthread v2 client library.
- `fixture-client`: a fixture driver for `stream`, `hold`, `enrollment`, and `inspect`.
- `loader-arm64e`: an opt-in Mach loader with authenticated v2 readiness checks.
- `loadd`: the launch daemon (see [Launch daemon, login start and Dock reload](Daemon/README.md#launch-daemon-login-start-and-dock-reload)),
  built last with the SHA-256 of the signed loader and payload compiled in.

`--production` omits the fixture payload, host and driver. Production builds ad-hoc
sign the doctor, arm64e payload, loader and launch daemon; merely building never
executes any of them. When
`INFINIFY_SIGN_IDENTITY` names an identity (as `scripts/build-app.sh` passes it down) the
doctor and the loader are signed with it and the hardened runtime instead, without
entitlements; the payload stays ad hoc, being no executable, mapped by the Dock and pinned by
exact bytes.
`scripts/build-app.sh` packages those files and the standalone launcher into
`Infinify.app/Contents/Resources/NativeDesktop`, signs the daemon on its own
with the build identity when there is one (hardened runtime, `--options runtime`), then signs
(the same way) and verifies the complete app. Its plist manifest binds the final helper, daemon and launcher bytes;
`scripts/install-app.sh` checks the executable and helper hashes and deep app
signature after copying the already-signed build; it does not re-sign the copy.
Supported workflows are the owner-run [native desktop launcher](../../../scripts/start-native-desktop.sh)
and the v2 disposable-fixture scenarios below.

The cooperative host accepts:

```text
host ABS_PAYLOAD PRIVATE_RUNTIME NONCE64HEX [ALLOWLIST_JSON_FILE]
     [--windows N] [--size WIDTHxHEIGHT] [--activation accessory|regular]
     [--watchdog SECONDS] [--level 0..4] [--all-spaces yes|no]
     [--family popup|sheet|both|none] [--floating-panel yes|no]
```

The runtime must already be a current-user-owned directory with mode 0700. Keep
its path short: `RUNTIME/v2.sock` must fit macOS's Unix socket path limit. The host
creates 1..16 windows, with a 90-second watchdog (`--watchdog` takes 1..900 seconds).
Optional family children count toward that limit and are all listed explicitly.
Capability bit 3 identifies this finite native-family fixture mode; it expands no
process or window authority. The level, size and Space options apply only to the newly
created fixture windows. `READY` is printed only after the v2 listener binds and
its journal passes startup validation. Failed startup prints no readiness receipt.

The current C driver can inspect an exact identity without holding it:

```text
fixture-client inspect RUNTIME NONCE64HEX PID WID BIRTH_SEC BIRTH_USEC
fixture-client enrollment RUNTIME NONCE64HEX
```

The desktop links the C library, which must authenticate the helper and audit
scope before any frame. Read-only probe/inspection never enrolls ordinary
applications automatically.

## Attribution and provenance

Original helper/protocol code is GPL-3.0-or-later. Private ABI declarations were
cross-checked against yabai (<https://github.com/asmvik/yabai>) commit
[`dd845723416f5fe92af49fad5ebab00369e07edd`](https://github.com/asmvik/yabai/tree/dd845723416f5fe92af49fad5ebab00369e07edd):
`src/osax/payload.m` and `src/misc/extern.h` (alpha declarations at lines 16, 17
and 79). The loader is adapted from that exact revision's `src/osax/loader.m`,
with the MIT notice retained in the loader's header and in
[`native/app/Resources/YABAI-NOTICE.txt`](../../../native/app/Resources/YABAI-NOTICE.txt). Ad-hoc
signing follows `src/sa.m`'s `scripting_addition_prepare_binaries` at the same
revision (`codesign -f -s -`). The source notices and exact pinned upstream
provenance remain attached to the implementation.

The launch daemon, its caller requirement and its property list come from Sunlight
(<https://github.com/spacefarm-digital/sunlight>, commit `afeea74b18e70ca49bf462d6fe462cf65deb2b32`, MIT, Copyright (c) 2026
spacefarm; notice in [`native/app/Resources/SUNLIGHT-NOTICE.txt`](../../../native/app/Resources/SUNLIGHT-NOTICE.txt)): `Daemon.m` copies ranges of
`LiveWindows/helper.m` and lists them in its header, `DWLoaddRequest.m` follows the form of its caller requirement, and
`com.marengox.infinify.loader.plist` adapts `Resources/LaunchDaemons/com.spacefarm.sunlight.live-windows.plist`. The arrival veil in
`DWPayload.m` adapts an idea and the window server announcement of Sunlight (`LiveWindows/README.md`, `LiveWindows/osax/sunbeam.h`,
`Sources/Canvas/RealWindows/WindowServerEvents.swift`), as its header lists.
