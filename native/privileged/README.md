# Transform helper

This native adapter targets Apple Silicon macOS 26 or later. Its listener is
binary protocol v2 on `RUNTIME/v2.sock`. Loading a payload starts no
transformation; a controller must name an exact in-scope process instance and
window in a `FRAME` request.

Default commands remain read-only. Build commands compile and sign artifacts but
do not load Dock or launch fixtures. Native mutation tests use only explicitly
spawned disposable fixture windows and restore their original transforms before
cleanup. These tests do not establish Dock-hosted authority or usable third-party
native-window compositing.

## Build and entrypoints

`./scripts/build-privileged.sh` builds the following in `target/privileged`
(helper code at `-O2`):

- `doctor`: a read-only SIP and arm64e boot-policy report.
- `payload-arm64e.dylib`: the explicit Dock-targeted payload.
- `payload-arm64.dylib` and `host`: an ordinary cooperative fixture process.
- `dwclient.o` and `dwclient-arm64e.o`: the plain C/pthread v2 client library.
- `fixture-client`: a fixture driver for `stream`, `hold`, `enrollment`, and `inspect`.
- `loader-arm64e`: an opt-in Mach loader with authenticated v2 readiness checks.
- `loadd`: the launch daemon (see [Launch daemon, login start and Dock reload](#launch-daemon-login-start-and-dock-reload)),
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
Supported workflows are the owner-run [native desktop launcher](../../scripts/start-native-desktop.sh)
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

## Explicit production launcher

The installed owner entrypoint is
`~/Applications/Infinify.app/Contents/MacOS/Infinify native-desktop`, run from a
terminal. Its `native-desktop --check` form validates the bundled manifest,
artifact hashes and deep app signature, then runs the doctor without sudo,
runtime creation, loading or app launch. The bundled launcher uses only macOS
system tools and files inside its own app, so it does not need Python, Homebrew,
or the checkout. It never changes SIP, permissions or settings, restarts Dock,
or retries an uncertain injection automatically.

The repository wrapper `./scripts/start-native-desktop.sh` is checkout-aware.
It verifies the selected bundle against current source and the standard app's
`target/app/BUILD.json` schema 1 record before calling its bundled launcher.
That record binds the post-sign app executable, native manifest, payload and
complete tracked/nonignored source snapshot. Pass `--app /absolute/path/Infinify.app`
to check an installed bundle; `--build` explicitly rebuilds production artifacts
and the app first. A stale bundle requires a rebuild. This checks delivery
freshness, not native usability.

The bundled launcher obtains Dock's exact PID, process birth, UID and stable
boot-session UUID from the loader's read-only `--dock-identity` query. It pins
the current Dock during the explicit loader step and binds the `pending`/`ready`
launch record (schema 3) to the Dock PID, process birth, boot-session UUID and
bundled payload SHA-256. Reuse also hashes the payload the recorded Dock opened and
requires it to match both the bundle and record: the runtime's own private copy when the sudo
loader loaded it, or, when the launch daemon did, the daemon's root-owned staged copy
(`Infinify native-desktop daemon staged RUNTIME`, which applies the loader's own path rule
read-only; see [below](#what-the-daemon-is-and-does)). A ready record for the
exact same Dock instance and boot session can be reused after those payload
checks pass.

The boot identity is the canonical uppercase `kern.bootsessionuuid`. XNU's
[`kern_sysctl.c`](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/kern/kern_sysctl.c)
exposes that UUID read-only, while
[`clock.c`](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/osfmk/kern/clock.c)
shows that `clock_boottime` can change with calendar adjustment. No XNU implementation code is copied into Infinify.

For a retired Dock, the launcher accepts only a committed schema-3 journal
written by the recorded Dock process, same login UID and same
`kern.bootsessionuuid`. The loader rechecks the journal's private file and
directory, exact writer identity, positive old-process retirement and schema-3
header, then copies its bytes to
the new private runtime as `recovery-source.json`. The sidecar binds the copy by
SHA-256 and recorded writer identity; the payload validates its complete schema
and identities before any restore setter. On first import, the fresh runtime has
no committed journal yet, so this exact source supplies the initial recovery
state. The payload commits that state under the new writer before any restore
setter. On later starts, the new runtime's committed `v2-journal.json` is the
replay authority; a malformed committed journal never falls back to the older
source. When that runtime is retired, its own current journal is the only handoff
input. Any retained `recovery-source.json` is hash-checked historical provenance,
never merged or used as a fallback.

When a ready schema-3 record belongs to a different boot session, the launcher
archives its exact bytes and starts fresh without replaying the old journal;
any remaining runtime and journal are left untouched. A missing runtime in the
same boot session remains an error. Pending/unknown outcomes remain refused,
including across a reboot. A launch record of any other version, or without the boot UUID,
is refused with an inspection error and preserved; it is never inferred or upgraded.

The launcher keeps the previous ready record until the recovery loader reports
authenticated readiness. A private `launch.pending.plist` marker blocks any
retry after an interrupted or uncertain recovery. On success, the old record is
archived byte-for-byte and the new ready record is promoted. The old runtime and
journal remain untouched. Journals of any schema but 3 are refused: schema 3 is the one
that retains the originals needed for safe connection handoff, and the
launcher never reconstructs transforms from native bounds. A same-boot journal
with a mismatched boot-session UUID, unresolved recovery, a live or uncertain
prior Dock, or invalid payloads blocks startup and preserves all state. There is
no fallback or automatic injection retry. The launcher runs only
the loader as root (through sudo in the owner's terminal, or through the launch
daemon the owner approved once, below) and starts the app as the login user. The login
item starts compositor mode only after `native-desktop enable`; until then it is the
capture-mode startup and does not invoke this helper path.

Direct loader invocation also requires explicit prepared-machine authorization:

```text
loader-arm64e --inject-dock ABS_PAYLOAD ABS_PRIVATE_RUNTIME
  --nonce-file ABS_NONCE_FILE --desktop
  [--expected-dock PID BIRTH_SEC BIRTH_USEC]

loader-arm64e --inject-dock ABS_PAYLOAD ABS_PRIVATE_RUNTIME
  --nonce-file ABS_NONCE_FILE --desktop --expected-dock PID BIRTH_SEC BIRTH_USEC
  --recover-journal ABS_OLD_RUNTIME/v2-journal.json
  --expected-retired-dock OLD_PID OLD_BIRTH_SEC OLD_BIRTH_USEC
```

`--desktop` is required: it selects same-login-user scope, the only scope the loader offers.
The payload is one of two classes, told apart by its path so that neither can stand in for the
other: any ordinary path must be the login user's own regular file that no one else can write (the
sudo path above), while a path of the exact form
`/private/var/run/infinify-payload.XXXXXX/payload-arm64e.dylib` is a copy the launch daemon staged, accepted
only by a root loader and only if the whole path is root's: every directory above is root's, not
writable by others and writable by a group only if the login user is not in it
(`/private/var/run` is `root:daemon 0775`), the staged directory is root's and writable by no
one else, and the payload is root's regular file, not group/other-writable, with one link; no
component may be a link (`native/privileged/staged-payload.h`, shared with the daemon).
The runtime directory, the nonce file and the journals stay the login user's, private (0700, 0600).
The nonce is a cryptographically random 32-byte value encoded as 64 lowercase
hexadecimal characters, in a login-user-owned regular file with mode 0600; one
trailing newline is accepted. Nonce bytes are never accepted in the loader's
argv. A private, adjacent `ABS_PAYLOAD.json` sidecar opts in the constructor with
the runtime, the nonce and, for a recovery, the recovery source digest and writer identity
(the payload also accepts an exact-process `allowlist` key, which the loader never writes).
No sidecar means no listener.
The recovery form accepts only a committed same-boot schema-3 journal from the
positively retired Dock recorded by the launcher. It copies those exact bytes to
the fresh runtime and binds their digest and writer identity in the sidecar. The
payload validates the complete journal, then commits the new writer's journal
before any restore setter. Later recovery uses that committed journal; if it is
malformed, the retained import source is not a fallback. The launcher adds a
private pending marker before sudo and promotes its ready record only after
authenticated readiness; an interrupted or uncertain handoff blocks retry.
Journals of any other schema are refused.
After loading, readiness authenticates v2, verifies scope/process identity,
required restoration/scope/inspection capabilities, `held=restoring=table_count=0`
and `journal_pending=0`, then disconnects without submitting a frame. A missing
or failed v2 listener is startup failure, with no alternate server.

## Launch daemon, login start and Dock reload

The explicit launcher above asks for the owner's sudo password at every load, and a
Dock restart ends the payload, so the helper path alone cannot run at login or survive
`killall Dock`. This section is the prompt-free path, ported from Sunlight's mechanism
(`LiveWindows/README.md`, "Installation boundary" and "Dock restarts", of
<https://github.com/spacefarm-digital/sunlight> at commit
afeea74b18e70ca49bf462d6fe462cf65deb2b32; MIT, Copyright (c) 2026
spacefarm). Nothing here is installed or registered by building or by installing the app.

**Owner commands** (the installed app, in a terminal):

```text
~/Applications/Infinify.app/Contents/MacOS/Infinify native-desktop enable
~/Applications/Infinify.app/Contents/MacOS/Infinify native-desktop status
~/Applications/Infinify.app/Contents/MacOS/Infinify native-desktop disable
```

`enable` runs the launcher's `--check`, registers the launch daemon with `SMAppService`
(macOS then lists Infinify under System Settings > General > Login Items & Extensions >
Allow in the Background and the command opens that pane; the owner turns it on once and the
command waits up to three minutes), asks the daemon `ping` to prove it answers this app,
writes `login.plist` in the launch-state directory (`mode: compositor`, and whether `enable`
itself added the login item), lifts any pause, and registers the login item if it was not on.
The login item's program is `Infinify login-start`: it reads `login.plist` and runs the
launcher as `launch.sh --login` in compositor mode, else starts capture mode as before.
`disable` removes `login.plist` and the pause file, unregisters the daemon, and unregisters
the login item only if `enable` had added it. It does not stop a running instance (`Infinify
msg action quit`) and leaves launch records, runtimes and journals as the launcher keeps them.
`status` reads and changes nothing.

### Why a launch daemon over XPC, not a sudoers rule

Sunlight offers both: a daemon for team-signed builds and, for ad-hoc builds, a sudoers rule
pinned to the helper's SHA-256 for exactly `<helper> load`. Infinify's owner builds are signed
with a Developer ID team (PBKWRHQV74), so the daemon is available, and it fits the existing
safety design better:

- Sunlight's helper takes no arguments, so a sudoers rule can name one static command. Infinify's
  loader takes a fresh runtime path, nonce file, pinned Dock identity and, on recovery, a retired
  runtime's journal. A rule for those would need wildcards, and a passwordless wildcard rule lets
  any process of the login user inject any user-owned dylib into the Dock. The daemon accepts
  only the signed app and checks the arguments' exact shape (below).
- A sudoers rule is `/etc` state that survives removal of the app; the daemon is registered and
  unregistered through `SMAppService`, which the owner sees and controls in Login Items.
- An ad-hoc build cannot use the daemon (launchd will not run it, and it names its caller by its
  team); such a build keeps the sudo step in the owner's terminal, unchanged. No sudoers rule is
  written by anything here.

### What the daemon is and does

`native/privileged/loadd.m` builds to `Contents/Resources/NativeDesktop/loadd`; the property list
`native/privileged/com.marengox.infinify.loader.plist` (shipped as
`Contents/Library/LaunchDaemons/com.marengox.infinify.loader.plist` only in builds signed with an
identity) names it as `BundleProgram` and the Mach service `com.marengox.infinify.loader`.
launchd starts it on the first request; it quits a minute after the last one. Its code comes from
Sunlight's `LiveWindows/helper.m` (header of `loadd.m` lists the copied and the edited line
ranges). It answers two commands:

- `ping` (no arguments): proves the caller check and the daemon.
- `load`: the arguments of the bundled loader's `--inject-dock` after the payload, only in the launcher's two forms
  (`loadd-request.m`): `RUNTIME --nonce-file NONCE --desktop --expected-dock PID SEC USEC`
  and, for recovery, `... --recover-journal JOURNAL --expected-retired-dock PID SEC USEC`.
  RUNTIME is `/tmp/if-native.XXXXXX`; NONCE is that runtime's `nonce`; JOURNAL is the
  `v2-journal.json` of a different such runtime; PID/SEC/USEC are canonical decimals in range.
  There is no payload argument and the request cannot name one: the daemon supplies the file the Dock opens (below).
  No unpinned Dock, no other flag, nothing else.

Checks, in order:

1. **Caller.** The XPC connection carries the code-signing requirement
   `anchor apple generic and identifier "com.marengox.infinify" and certificate leaf[subject.OU] = "<team>"`,
   where `<team>` is the team identifier of the daemon's own signature (ten capital letters and
   digits, else the daemon refuses to start). macOS checks it on every message. The caller must also
   run as the console user, and the daemon checks the live process behind the connection's audit token on
   the connection and again on every request (`DWLoadCallerRefusal`): its signature carries the
   hardened-runtime flag and the process enforces it, `get-task-allow` is not in force or in its entitlements,
   it holds neither `allow-dyld-environment-variables` nor `disable-library-validation`, and the environment it was started with
   (the kernel's `KERN_PROCARGS2` copy) has no `DYLD_*` or `__XPC_DYLD_*` variable. A caller that fails any of these is refused
   (status 65, or no connection) before its command is looked at.
2. **Request shape** as above (`DWLoadRefusal`).
3. **Artifacts.** The loader and the payload beside the daemon, in the bundle, are each read once, without
   following a link, hashed and compared with the SHA-256 digests compiled into the daemon (`scripts/build-privileged.sh`
   passes the digests of the loader and payload it has just signed). Those bytes, not the paths, are what is used next.
   The payload copy in the caller's runtime (the sudo path puts one there) is never read.
4. **Dock.** The pinned PID and process birth must be the console user's Dock now.
5. **Stage and run.** The daemon makes `/private/var/run/infinify-payload.<the runtime's six characters>` (it fails
   if that exists), writes the checked payload bytes into it as `payload-arm64e.dylib` while the directory is
   still root-only (0700), reads the file back and compares its SHA-256 with the digest compiled in, and only then
   opens the directory to the Dock (0755; the file is root's, 0644). It writes the checked loader bytes to a mode-0700
   directory it creates in `/var/run`, confirms that copy hashes the same, runs that copy with `--inject-dock STAGED_PAYLOAD`
   and the request's arguments, returns its status and output, and removes the loader copy. The loader then makes every check it always
   made: preflight, the pinned Dock, the private 0700 runtime, the 0600 nonce file, the journal validation, the
   authenticated v2 readiness audit; and for a payload of the staged form it applies the staged-payload rule to the whole
   path (see Direct loader invocation above), so a daemon that staged wrongly loads nothing. Its two changes to `loader.m`
   are the staged-payload class of payload, and that a root loader falls back to finding the console user's Dock by executable
   path and owner (libproc) when LaunchServices lists none, as in a launch daemon (Sunlight does the same, `helper.m` lines 128-148).
6. **Afterwards.** On success the staged copy and its sidecar stay (the launcher checks them on a reuse and reads the sidecar
   as the provenance of a later recovery), and the staged copies of the login user's earlier runtimes are removed. If the loader
   failed without leaving its sidecar, execution never began, so the copy is removed. If it failed with the sidecar present, the
   remote thread may still `dlopen` the copy, so everything stays, like the loader's own allocations, for the owner to inspect. `/var/run`
   is emptied by a reboot. `disable` removes nothing of this.

### What the staging and the hardened runtime close, and what they do not

**The payload race is closed by construction, not by timing.** The Dock opens a file of root's, in a directory of root's,
below directories only root writes; no component can be replaced, linked or rewritten by the login user, so there is no
instant between the daemon's hash check and the Dock's `dlopen` at which the bytes could change. The check that matters is
re-made by the root loader just before it injects, on the exact path it injects (the same code, `staged-payload.h`). The bundle's
own payload, in the login user's `~/Applications`, can still be swapped, but only before the daemon reads it, and the bytes it
reads once are the bytes it hashes and writes. Two things in the daemon path remain the login user's, and neither is code the Dock maps:
the runtime (socket, nonce, journals, the recovery source), as ever; and the payload's sidecar `payload-arm64e.dylib.json`, which the payload must
read as the Dock's user and which therefore is the user's file (0600) in root's directory. It cannot be renamed, replaced or
linked, but its bytes can be rewritten, which only changes how the user's own helper is configured (its runtime, nonce, scope, journal import); a
rewrite that changes the scope or the recovery import fails the loader's authenticated readiness audit, which checks the scope, capabilities and journal
state it asked for, and a rewritten runtime or nonce is the user's own helper pointed at the user's own directory. (Not exercised: no rewrite of the sidecar
during a load was tried.) The owner-run sudo path is not changed and not closed: the Dock opens a user-owned copy in the runtime
there, so the race between the launcher's check and the Dock's open remains, with the owner typing the password at the terminal.

**The hardened runtime does less than it sounds like on a Mac that allows the Dock injection, and the daemon does the rest.**
The daemon refuses an Infinify that is not hardened or that has `get-task-allow`. Measured in the guest (macOS 27.0.1, SIP
configuration of the owner's Mac: debugging restrictions off) with ad-hoc test binaries: a same-user process cannot get the task port
of a process that lacks `get-task-allow`, hardened or not (it can for one that has it), so `get-task-allow` is the setting that
matters for `task_for_pid`; and a hardened-runtime process still loads a `DYLD_INSERT_LIBRARIES` dylib, so the flag alone does not keep
a same-user process from starting a genuine, correctly signed Infinify with its own code inside. The daemon therefore refuses a caller
started with any `DYLD_*` variable too, which closes that way in; it is read from the kernel's copy of the process arguments, by pid
(a pid reused between the connection and the read would be judged by the other process's environment, a race this does not close;
the signature checks are by audit token). Not closed: a caller holding the debugger entitlement with developer-tools access
on a Mac with Developer Mode on (not tested: Developer Mode was off in the guest), root (which can do anything), and any injection into
Infinify that does not go through its start-up environment or its task port. What a successful impersonation would buy is
what a request can ask for: a load of the bundle's own payload into the pinned, current Dock, with the launcher's own arguments.

### Launcher modes

`launch.sh` (reached as `Infinify native-desktop`, `--login` or `--reload`) makes every check of the
explicit launcher above: manifest and signature verification, the doctor, the Dock identity pin, `pending`/`ready`
schema-3 records, payload hashes, the boot-session rule, the retired-Dock journal handoff, no
automatic retry of an uncertain load. Its modes:

- The loader step runs through the daemon when `Infinify native-desktop daemon status` says it is
  enabled, else through `sudo` in a terminal. In `--login` and `--reload` there is no
  terminal, so a missing daemon is a refusal.
- `--login` (the login item): waits up to about five minutes for a Dock whose identity reads the same
  twice three seconds apart, writes to `native-desktop/login.log`, exits 0 for every refusal (launchd
  restarts a failed login item; a refusal needs a decision), does nothing when an Infinify runs.
- `--reload` (the running app, after a Dock restart): requires that the one running Infinify is its
  parent, waits for a stable new Dock, runs the same recovery path (journal handoff from the retired
  Dock, same boot session) through the daemon, and writes only `INFINIFY-NATIVE-ENDPOINT RUNTIME
  NONCE_FILE` to the app's pipe.
- Pause: `auto-reload-paused.plist` (below). A manual `Infinify native-desktop` removes it; `--login`
  and `--reload` refuse while it names this payload's digest.
- An interrupted or uncertain load keeps its pending marker and blocks every mode, including across
  reboots.

### Dock reload in the app

When the launcher started the app with the daemon on, it sets `INFINIFY_DOCK_RELOAD=1`,
`INFINIFY_NATIVE_PAYLOAD_SHA256` and `INFINIFY_NATIVE_LOADED_AT` (when it loaded, 0 when it reused a
helper). The app (`native/desktop/dock-reload.m`, a function-by-function translation of Sunlight's
`AdditionReloader.swift`/`DockCrashGuard`; the file header names the line ranges) watches the Dock's
PID and process birth (workspace notifications plus a 1 s clock). When a new Dock appears it waits
1.5 s for it to settle, runs `launch.sh --reload` off the main thread, and on success hands the new
runtime and nonce to the presenter, whose ordinary authenticated re-admission (scope, capabilities,
empty restore table) puts the windows back. A failed reload is retried once after 10 s; a Dock gets
two tries.

**Crash guard.** Each Dock restart during a load, or within 60 s of one ending, is a strike; a restart
farther from a load clears them. The launcher's own load before the app started counts as the first.
At the third strike in a row the app writes `auto-reload-paused.plist` (the payload digest; the file is
read by the launcher too, so it holds across launches), stops reloading, prints why, and quits with
status 0 (the login item is not restarted). The Dock that restarted had reset the windows' transforms, so they are drawn at the
screen's top-left corner until a recovery loads the payload again: that is the owner's manual run, below, which restores them from the
journal. A payload with
another digest is not paused. The owner lifts it by running `Infinify native-desktop` (or `enable`).
The ready launch record is kept, so that run performs the journal handoff from the last Dock.

## Protocol v2

[`protocol.h`](protocol.h) is the wire schema. All integers and floating
values are little-endian, matching the fixed arm64 layouts. A 16-byte header is
`{u32 length, u16 type, u16 flags=0, u64 seq}`, followed by `length` body bytes
(maximum 131072). Replies carry `type|0x8000` and the request's sequence. Bad
headers, unknown types, wrong lengths, or non-increasing frame sequences close
the control connection and schedule restoration. The socket is mode 0600 inside
the retained private runtime directory; both ends check peer UID. The client also
matches the reported helper PID with the kernel socket peer PID.

| Type | Request | Reply |
|---|---|---|
| 1 `HELLO` | `DWv2`, u16 version 2, u16 role, 64-byte nonce, 16-byte token | status, lease 2000 ms, record/body limits, capabilities, scope, queue, server PID, session token |
| 2 `FRAME` | u32 count, u32 zero, count × 80-byte record | disposition, count, superseded, zero, u64 applied-frame count, count status bytes |
| 3 `HEARTBEAT` | empty | status, lease, held, restoring |
| 4 `RESTORE_ALL` | empty | count, pending, journal_persisted, zero, count × 32-byte restore result |
| 5 `PROBE` | empty | 72-byte summary, table entries, then explicit cooperative fixture identities |
| 6 `ENROLLMENT` | empty | scope, count, server PID, zero, count × 24-byte process instance |
| 7 `INSPECT` | one 24-byte window identity | one 144-byte inspection result |
| 8 `FRAME_SPACE` | u32 count, u32 zero, count × 88-byte Space record | same frame reply, matching opcode |
| 9 `VEIL` | u32 mode (1 on, 0 off), u32 zero | u32 status (0, or 1 = refused), u32 bound in ms |

Capabilities are alpha=1, per-window restoration=2, enrollment audit=4, explicit
fixture family=8, inspection=16, Space migration=32, pinned sublevel=64 and
arrival veil=128. Scopes are cooperative=1, allowlist=2, and
same user=3. Queue is own=0: the helper runs its native calls on its own queue and always
reports 0 (clients accept 0 or 1). Current clients require the relevant current
capabilities and refuse unsupported helpers. Protocol v2 advertises no native clipping
capability and display-boundary clipping is not implemented.

A window identity is `{i32 pid, u32 wid, u64 birth_sec, u64 birth_usec}`. The helper
resolves its current WindowServer owner connection and process birth itself,
checks the user and scope, and never trusts a numeric window ID alone. Cooperative
scope admits only the host's explicitly created windows. An allowlist pins exact
PID/birth pairs; same-user scope requires the helper's login UID. `ENROLLMENT`
returns the cooperative host instance or finite allowlist; same-user scope has no
finite process list. It does not hold any window.

`INSPECT` reads transform, native bounds and screen rectangle for an unheld or
held window. Its fixed reply is identity (24 bytes), u32 status, i32 owner,
f64 transform[6], bounds[4] and screen_rect[4]. Scope is checked before lookup;
identity, owner and UID are resolved before all native getters and revalidated
afterward. The requested identity is echoed. Success is status 0; refusal is scope
1, identity 2 or snapshot 5 with owner and all geometry zero. Inspection is
serialized on the native queue and neither mutates nor journals. It provides
original geometry before the first frame and authoritative readback after table
removal. It is not visual validation.

`PROBE`'s 72-byte summary is scope/caps/queue/lease, i32 server PID,
held/restoring/journal_pending, four u64 counters (received/applied/superseded
frames and journal writes), and table_count/fixture_count. `journal_pending` is
0 or 1 and means the in-memory table or restoration receipt is not yet durable.
An empty table with this flag set is not an empty recovery obligation. Each table
entry is a 112-byte identity/state/alpha/current-transform/current-screen-rect
record. Only cooperative scope appends up to 16 fixture identities. Probe table
readbacks can be unavailable; use `INSPECT` for a validated geometry result.

A frame record contains identity, f64 affine transform `[a,b,c,d,tx,ty]`, f32
alpha and u32 flags. The affine maps global top-left screen points to window-local
points. Matrix values must be finite and within ±1,000,000, with determinant
magnitude at least 1e-8. Alpha must be finite in 0..1 when flag 1 requests it.
Flag 2 alone requests restoration of that identity's journaled original; its
matrix/alpha are ignored. Combining flags is malformed. Restoration wins over a
transform of the same window in the same frame.

Record statuses are applied=0, scope=1, identity=2, matrix=3, alpha=4,
snapshot=5, journal=6, not applied=7, restore pending=8, table full=9, malformed=10,
Space admission=11 (retryable without a setter).
An applied transform requires fresh readback equality after float rounding,
matching WindowServer transform storage, and a current final identity. A called
status-bearing scalar setter must also succeed. Space moves return no usable status
and cannot substitute for readback. A failed or differing set remains journaled because
it may have changed the window. A status or symbol alone is not evidence of
usable native presentation.
The helper revalidates exact process birth, owner connection, UID and scope
after journal persistence and immediately before each transform or alpha write,
then again before acknowledging the frame. Earlier batch admission cannot
authorize a window number replaced during disk I/O or another record's work.
Restoration also rechecks identity between its transform and alpha writes.
Previously verified unchanged transforms and alpha omit their setters only after
fresh native getters still equal the current request. A mismatch gets a new
identity fence before correction. The saved originals remain unchanged.

`FRAME_SPACE` adds `u64 target_space` after each unchanged 80-byte record.
Zero leaves membership untouched; `FRAME` is the same request without Space targets
and keeps the 80-byte record.
`dw_client_submit_space_frame` requires capability 32. Forward migration requires
singleton ordinary source membership and an ordinary target currently active on
a different active, awake physical display. It cannot gather windows from an
inactive Space or another Space on the same display. Already-on-target windows
receive no Space setter or new Space restoration obligation. A window that has no
Space membership at all is refused `SPACE` with no write and no journal change; the
guest showed this for a document being closed (destroyed in WindowServer, still
named by the owner cache) for the few frames before the client released it, and
`restore_identity_test.m` covers that sequence with substituted calls. Duplicate WIDs in
an extended frame, or a nonzero target on a restoration record, are malformed.

Before a Space write, schema-3 entries optionally persist
`original_space: {id, display, pending_target}`; an entry without that key has no Space obligation. The
original singleton and display UUID never change. The void move API is accepted
only after exact membership readback; an unobserved pending target cannot be
superseded. Restoration returns to the original existing ordinary Space even if
inactive, and cannot report `RESTORED` with unconfirmed forward debt or differing
membership. Uncertain obligations survive lease loss and crash recovery. A root
move that carries a child preserves that child's independently journaled original.
Restoration may durably clear a deleted forward target only when a complete,
valid managed-Space inventory covers every active display, the target is absent,
and the exact window is back on its original Space on the saved display. A failed
per-Space getter alone does not establish deletion.

The Space-handoff runs in the macOS 27.0.1 guest (TextEdit at 1x and Finder at .5 scale on a temporary second display) do not establish native
content-extent/detail preservation, general child-family transfer, physical-display or macOS 26 acceptance.

### Arrival veil

A window an application opens is shown at its native size and place until the shell has listed
it and the first frame has placed it: about 20 to 30 ms when placement works and for its whole life
when it is refused. The `VEIL` request (capability 128) closes that gap from inside the Dock. It is an
adaptation of the idea Sunlight uses (see [Attribution and provenance](#attribution-and-provenance)), as an alpha write instead of a window level.

- **Offered** only by the explicit same-user helper (not an allowlist or cooperative one) that has
  alpha getters/setters and could register for the window server's announcement of a window added to
  a Space (SkyLight connection notification 1325; payload: Space id u64, then window id u32). A control
  session asks with mode 1 and is answered status 0 and the bound (`DW2_VEIL_TIMEOUT_MS`, 1000 ms), or
  status 1 (refused: no capability, or the client's own process could not be read from the socket); mode 0 ends
  it and releases what is held. A malformed request ends the session like any other. It ends with
  the session. The desktop shell asks after its empty-table audit and carries on without it if refused.
- **Which windows.** The Dock's main thread only receives the announcement and hands its window id to v2q;
  every native call and the journal write run on v2q, the helper's own queue. A window is
  veiled when it is at layer 0, at alpha exactly 1, at least 40x40 native points (the shell's own candidate
  floor), of the login user, in scope, with a process birth that resolves, not in the table or released
  table, and not a window of the Dock or of the client's process (the control connection's `LOCAL_PEERPID`).
  A window below alpha 1 is fading in under its application's own animation (a TextEdit
  *Save* sheet was read at 0.79, and its next animation frames overwrote the veil); it is left alone, and a
  fractional alpha is never taken for an original. The window need not be on screen: the announcement
  comes before it is ordered in, and its row has no on-screen key yet.
- **How.** A veiled window is an ordinary table entry with its original transform, bounds and alpha
  (and `alpha_touched`), journalled (the whole table, fsync, rename, directory fsync) **before** alpha 0 is
  written and read back. Two optional journal keys mark what the veil has and has not touched:
  `veil_bare` (only alpha was changed, so no transform is owed) and `veil_alpha` (the alpha obligation is the
  veil's, so it is put back only while the window still reads alpha 0). If the record cannot be written nothing
  is changed and the journal is retried. If the write or readback fails or identity changes, the ordinary
  release runs. A full table first prunes released windows proven gone, like a frame; if it is still full the
  window is not veiled.
- **Ways out.** (a) A frame record for it. The first one re-reads the window's transform and bounds, because
  the application may have moved or resized it since the announcement, and writes one journal record
  (the fresh values, `veil_bare` cleared, `veil_alpha` cleared too if the record carries an alpha) **before any
  write**; if that record cannot be written the status is `JOURNAL`, nothing is written, and the window stays
  veiled with what it was read as. Then the transform, then the record's alpha, or, when it has none, the original
  alpha lifted only if the window still reads 0 (an application that has taken the alpha over is not
  overwritten). The window is never left invisible by a transform that did not take. Later frames write no journal
  and no alpha for it. (b) A `RESTORE` record for it, or `RESTORE_ALL`, the end of the session or `VEIL` mode 0: the
  ordinary release. (c) `DW2_VEIL_TIMEOUT_MS` after it was veiled, if still veiled and held: the same release. The
  timer lives in the Dock: if the Dock dies there is no bound and no release until recovery. (d) A window that closes or
  is replaced is dropped by the identity logic of the release, with no write. A crash or lost helper is covered by
  the journal replay like any entry. A release of a window that was only veiled (`veil_bare`) writes no transform
  (the window server's transform follows the window's position): it reads the transform and takes it as the
  original, and a replay of such an entry does the same. After the first frame the journal says a transform is
  owed, with the values read then. An alpha obligation with `veil_alpha` is written back only while alpha reads 0, so
  a window that was placed with no alpha of its own is never written again, and a window an application has taken
  over keeps its alpha; an alpha the shell asked for is its own obligation and is put back as before. `veiled`
  (whether alpha is being held now) is memory only.
- **Not covered.** Windows not at layer 0 (utility panels at the floating level, menus, popovers) are not veiled; a child of a window the
  shell has placed gets *arrival placement* instead (next bullet).
  A window already known to the window server that is announced again for a Space change and not managed by the shell
  is held for up to the bound (while the Dock lives). A window the application animates (TextEdit's document windows, sheets) can have the veil
  overwritten by the application: TextEdit's own open animation wrote alpha 1 about 0.5 s after creation (measured
  501 to 533 ms), before the bound, when nothing placed the window. The veil is not an optical result.
- **Arrival placement: a child of a placed root.** The veil holds a window by alpha, and only at layer 0 and alpha 1. A context menu is
  announced already at level 101 and on screen (the notification arrives with layer 101, ordered in, alpha 1), and the shell's family frame placed it 23 to 40 ms after the announcement (four timed cases). A sheet, a
  popover or a completion list is announced at alpha 0 to 0.9 under the application's own fade, which no veil can hold. Without
  this path, 12 of 12 such popups in a guest were on screen where the application
  put them, not where their root is drawn, for 1.3 to 191.3 ms: context menus 10.9 to 36.2 ms, pop-up button and pull-down menus 81.4 and
  114.6 ms, a popover 191.3 ms (fading in), a sheet 13.2 ms (alpha up to 0.16), a combo list 1.3 ms. So for such a window the helper does
  not hide it: at the announcement it gives it the placement the shell gives every member of its root's family. Conditions, all read fresh
  on v2q: the window's exact WindowServer parent chain (the single-window query the shell's family audit uses, `v2ParentOf`; every link one
  process instance of the login user) ends at a root that is a held table entry the shell has placed (`appliedTransformKnown`, not
  restoring, not merely veiled, its transform still the one applied, no rotation), the window is in scope and is neither the Dock's nor the
  client's, it is in neither the table nor the released table, and the placement differs from what it has. The placement is the root's
  transform with its translation moved by the window's native offset from the root (the shell's `m[4]-=dx, m[5]-=dy`, native-presenter.m
  `-describe:`), both bounds read now. The entry is an ordinary one: original transform, bounds and alpha journalled before the write, the
  write read back (a transform that does not take is released at once), no alpha touched. The first frame that names the window claims it and
  replaces the placement (normally by an equal one: a repeated record writes nothing); otherwise `DW2_ARRIVAL_TIMEOUT_MS` (500 ms) after the
  announcement, RESTORE, RESTORE_ALL, the end of the veil (mode 0 or the session) or a closed window release it by the ordinary release, which
  puts the original transform back. Nothing else is touched: a window with no parent (the global menu bar's menus, status items, every
  application's own windows) is left alone, as is a child of a window the shell has not placed. It is gated by the veil request. Announcement to the read-back placement took 1.0 to 3.4 ms for 27 of 29 windows in the trace
  build and 22.6 and 26.5 ms for two opened while frames were being applied (the helper's queue is serial). A window that the helper has
  released and the application shows again (Chromium and AppKit reuse windows) is in `v2Released` and is not placed again by this path.
  No wire change. Results with the shell running are in [the shell's account](../desktop/COMPOSITOR-MODE.md#popups-and-menus-of-a-transformed-window-full-desktop-dock-helper).
- **The shell** (`native-presenter.m`, `window-manager.m`, `main.m`) asks after admission, and lets go at once
  of a window it will not manage: `-windowNotAdopted:pid:` is sent once per appearance, from the first discovery
  pass on, for a window of a non-regular application, a window the shareable windows or Accessibility do not count as
  a window, one a read of which settled as not real, one `attach` refused, and one `-windowAppeared:` could not take
  because the canvas was closing or had no panels. The presenter queues one `RESTORE` record for that exact process
  instance (`-declineWindow:`); any reply retires it, since the helper's bound is the backstop. A window the helper
  holds nothing of answers a release with a no-op status 0. If the veil request gets no answer in time or an
  unreadable one, the shell assumes the veil may be on and keeps releasing explicitly: a wrong "on" costs a no-op record,
  a wrong "off" would leave such a window invisible for the whole bound.

`restore_identity_test.m` and `forward-operations-test.m` use substituted native calls for every rule above (eligibility
refusals, journal before alpha with a failing journal changing nothing, transform-then-alpha, decline/bound/end/recovery, closed and replaced
windows, the request and the announcement payload through the real handler on a socket pair), and `restore_identity_test.m`
covers the arrival placement cases (`arrivalCases`). `client_protocol_test.py` checks the C client's request, refusal and invalid-reply
handling against a fake peer. These are not native evidence.

One control `HELLO` creates the session and a random token. A second heartbeat
connection uses that token; requests on either renew the 2000 ms lease. The C
client heartbeats every quarter lease.
Control disconnect, malformed control request or lease expiry restores all held
windows. Closing only a heartbeat connection does not end the session. An alive
C heartbeat thread can retain windows while its caller stalls. A fully stopped
client expires; a fully stopped helper cannot restore until it runs again.

Frames use one newest-frame slot, limited to 1024 records. Waiting frames are
superseded instead of building a queue; the next frame reply counts them. One bad
record does not prevent the others. `RESTORE_ALL` discards a waiting frame;
a later frame is processed afterward. Probe, inspect, restore, native calls,
table changes and journal writes run serially on the helper's own queue. Socket parsing, heartbeats
and lease checks run on connection threads. Acceptance of own-queue native calls
inside Dock still requires scoped real-host evidence.

## Journal and strict recovery

Schema-3 `v2-journal.json` preserves the current Dock writer identity and each
first-touch identity, owner, original transform, alpha, alpha-restoration
obligation and native bounds. Its `released_windows` table retains exact original
records after a successful restore, because a later Dock replacement may reset
WindowServer transforms again. When retiring a runtime, its current journal is
the handoff input. A fresh recovery runtime initially imports the exact staged
`recovery-source.json`; the payload commits a journal under its new writer before
any native setter. From then on that committed journal is the replay authority,
and a malformed one never falls back to the import source. The source and its
sidecar digest remain provenance only after import. Originals are captured before
any change. The entire new-window batch is journaled before applying any of it;
unchanged held windows require no journal write. A first alpha change is journaled
before setting it. Persistence uses exclusive no-follow mode-0600
`v2-journal.next`, file fsync, rename and directory fsync. Failed persistence
blocks unjournaled mutation and leaves `journal_pending=1` until a durable retry.

Restoration re-resolves the exact identity, owner, UID and scope, sets the captured
original transform (re-based on the native origin read at the write, below; written at placement 1, see "Placements") and alpha,
and requires a readback equal after float rounding (a translation within 1/256 of a point, `v2SameTransform`). A real cross-display
quit exposed late AppKit reflow after an immediate successful readback. Entries
with a Space obligation remain pending for at least two seconds from the
start of restoration and until native bounds, original membership and exact
transform/owed alpha stay stable for 500 ms. Samples precede corrective writes;
settlement checks run every 250 ms, and their transient timing evidence is never
imported from a journal. This waits for native reflow without promising to restore
the original native bounds. Confirmed restored or gone windows leave the table;
uncertain windows remain restoring. Failed owner, window enumeration or
process-birth queries cannot establish absence. A still-live
matching original outside the new helper's scope is retained as pending too.
Other retries run after 250 ms, 500 ms, 1 second and then every 2 seconds without
an abandonment deadline. If native restoration completes but its journal update
fails, the table can be empty while `journal_pending=1`. Controllers must require both native
emptiness and a durable receipt before admitting new presentation. Removing the
persistence obstruction permits autonomous retry without another request.

On restart, the helper validates the entire committed journal before deleting any
interrupted staging file or replaying it: exact schema/version and keys, integral
bounded identities/counters, no duplicate windows, valid transform/bounds/alpha,
consistent states, and valid restoration receipts. It refuses unknown or malformed
journals and preserves their bytes. A replay restores only still-matching windows
within the new helper's scope; changed or gone identities are left alone. An
alpha obligation is refused if the required native symbols are unavailable.
Only a private regular staging file may be removed after successful validation,
or when no committed journal could have authorized a mutation.

`recovery.json`, `recovery.next` or `helper.sock` artifacts left by an earlier
helper are never replayed, cleared or converted automatically. Any presence
refuses startup and preserves the files, including a purportedly clean receipt.
Existing `v2.sock` also refuses startup. Bind/listen and journal validation must succeed
before readiness. A process crash, machine failure or stalled helper cannot run
in-process restoration; preserved journals require exact-identity reconciliation,
not blind reinjection or deletion.

### Restoring a window whose native frame moved

A WindowServer transform is the whole map from the screen into the window's own space, so it carries the window's position: a
window that is not transformed reads `[1,0,0,1,-x,-y]` and is drawn at its native origin `(x,y)`. The original captured at
first touch therefore says the origin the window had then. Written back unchanged after the native frame has moved, it draws
the window at its old place while its native frame (hit testing, macOS tiling, the next session's original) is elsewhere.

The native frame moves during a session for reasons the shell cannot all prevent (the application, a window-server drag the
shell took over, a toolbar re-layout), so restoration does not write the captured transform as it is:

- **Plain original** (scale 1, no rotation: what an unmanaged window has): written as `[1,0,0,1,-x,-y]` at the origin read now.
  A plain transform is native by definition, which also puts right an original that was captured already displaced (the stale
  windows an earlier restore left behind).
- **Any other original** keeps its linear part and its place relative to the frame: `t' = t - M*(origin_now - origin_captured)`
  (`v2RestoreTransform`), where `origin_captured` is the first-touch `bounds` the journal already holds. Unmoved, it is exactly
  the original; the journal needs no extra key.
- **The origin is read before the write and again after it** (`SLSGetWindowBounds`, with the readback of the transform that
  was already required). A window that moved between the two reads is not restored by that write: it stays `restoring` and
  the next pass writes the origin it has then. Without a readable origin the captured original is written as the best that can be
  done and the window stays pending, so the next pass writes the re-based one. The journal keeps the captured transform and
  bounds until release, so a crash between a move and the release is re-based by the next helper the same way.
- **After release** the retained record holds the transform that was written and the bounds read after it, so a later
  re-base (a reattachment after the Dock was replaced) starts from a pair that belongs together. The reattachment guard is
  strict (geometry unchanged, and the transform either the original, the identity reset or the re-based one).
- A veil-only release (`veil_bare`) adopts the transform in force; the Space settlement samples compare against the
  re-based transform at the bounds sampled.
- The pending receipt's `diagnostic` carries `captured_origin`, `native_origin`, `origin_status` and `target_transform`; it is
  informational, and a receipt is valid without it.

`restore_identity_test.m` covers this with substituted calls (`rebaseCases`: unmoved, moved, stale plain, scaled and rotated
originals, unreadable origin, a move between write and read, crash recovery, reattachment); its fixtures pair an original of
`[1,0,0,1,-25,-35]` with a window at `(25,35)`. These are not native evidence.

The owned-fixture native evidence is `fixture_test.py --native-move` (opt-in, needs Accessibility for the test process).
The whole-desktop evidence is in the shell's README section "Restore after a native-origin move".

## Placements: why transforms are written at placement 1

Established on the disposable guest vm1 (macOS 27.0.1 26A434, SIP off) on 2026-10-30; nothing here was run on another build or on
the owner's Mac. The problem and the placement semantics below are what the investigation measured (probe payloads loaded into the
Dock; its notes are not in this repository); "What the guest showed" is this change's own run.

**The problem.** After `quit-native` had restored every window correctly, `killall Dock` drew every window the helper had ever
written at the top-left corner of the display (`SLSGetWindowTransform` = `[1,0,0,1,0,0]`, `SLSGetWindowBounds` still the native
origin) until its application was restarted, and the next helper session took that state as the window's original. The window
server keeps one transform entry per window **per placement**; each entry remembers the connection that last wrote it, and when
that connection dies (here the Dock: `killall`, `kill -9` and `abort()` behaved alike) the window server resets its entries to
identity. `SLSSetWindowTransform` is placement 0 (its disassembly is a tail call into
`SLSSetWindowTransformAtPlacement(cid, wid, 0, 0, &t)`), and the placement-0 entry encodes the window's position: untransformed it
reads `[1,0,0,1,-x,-y]`, so identity there means "drawn at (0,0)". No repair from outside the Dock's connection restored such a
window (Accessibility position and size writes, the application's own `setFrame`, hide/unhide, minimize, fullscreen, `AXRaise`,
`SLSMoveWindow`, `SLSTransactionResetWindow`, `SLSResetWindows`, a window-server drag, Mission Control, screen lock); only a
placement-0 write from a Dock connection did, and that claims the entry again for the next death. A second connection's
placement-0 write was silently ignored (status 0, no effect).

**What is written instead.** A placement of 1 or more is a layer applied after placement 0 whose identity means "as placement 0
has it". A reset layer is therefore harmless: the window is where its native frame is. Every helper write is now
`SLSSetWindowTransformAtPlacement(cid, wid, 1, 0, &layer)` (flags 0, relative) and every read is
`SLSGetCatenatedWindowTransform` (the disassembly: `SLSGetWindowTransformAtPlacement` with placement `0x7fffff00`), the effective
matrix. `payload.m` keeps its call sites' meaning, an absolute matrix (the whole map from the screen into the window's space), in
two functions, `dwReadAbsolute` and `dwWriteAbsolute`, which `getTransform` and `setTransform` point to:

- `dwWriteAbsolute(A)` reads placement 0 (`T0`, which follows the native frame) and writes the layer `L = A after T0^-1`
  (`CGAffineTransformConcat(CGAffineTransformInvert(T0), A)`; for a plain `T0 = [1,0,0,1,-x,-y]` this is `A.t - M*T0.t`, linear
  part unchanged). A layer within 1/256 pt of the identity is written as exactly the identity, so a natural window's restore writes
  `identity` at placement 1. Placement 0 is never written; `SLSSetWindowTransform` is not even resolved, and a missing
  placement symbol refuses the helper's start rather than falling back to it.
- `dwReadAbsolute` is the catenated read. The window server composes the layers in float, so a request read back after a layered
  write can differ by a rounding: `v2SameTransform` (every readback check, the repeated-frame skip, reattachment and the Space
  settlement) accepts a translation within 1/256 pt and a linear part within 1e-6.
- Originals, the journal (schema 3, unchanged), the re-base of a restore on the native origin, recovery replay and the retained
  original are all in absolute terms and are unchanged; they are now natural placement-0 values for a window nobody had touched.
  There is no optional transaction or list-batch transform path in the tree (`SLSTransactionSetWindowTransform`,
  `SLSSetWindowTransforms` are not used), so none had to be moved.

**What the guest showed** (real TextEdit, Safari and Finder windows, build of this change, read from an ordinary process with
`SLSGetWindowTransformAtPlacement` for placements 0 and 1, `SLSGetCatenatedWindowTransform`, `SLSGetWindowBounds` and
`SLSGetScreenRectForWindow`):

- Session at zoom 0.5: the five placed windows read placement 0 = `[1,0,0,1,-x,-y]` (unchanged), placement 1 = `[2,0,0,2,..]`, and
  catenated equal to placement 0 composed with placement 1 on every one of them (the order assumed above; only a translation-only
  placement 0 was observed). After `quit-native`: placement 1 identity and catenated `[1,0,0,1,-x,-y]` on all eight windows
  (five placed, three untouched). Then `killall Dock` with Infinify not running: all eight unchanged, and the screenshot shows
  the windows where they were. (The investigation measured the unchanged build leaving three such windows at `[1,0,0,1,0,0]`
  after that step.)
- `killall Dock` during a session: six reads, the first about 1.5 s after the kill and then every 1.5 s, all show the three polled
  windows natural (placement 1 identity, catenated `[1,0,0,1,-x,-y]`, drawn at their native rectangle), not at the corner; an
  earlier read was not taken. Infinify reported "native presentation lost (no heartbeat
  was answered for a whole lease)" and was left waiting for a helper; the guest has no launch daemon, so nothing reloaded the
  payload. After `quit-native` and a manual `run-native` the same windows were placed again with the same layers.
- Ordinary acceptance points in that session: a new TextEdit window read `alpha=0.00` from its first on-screen sample (bounds
  set, 51.7 ms after the first sample) and `alpha=1.00` only at 199.8 ms, when it was already drawn at the placed rectangle
  (the 3 ms poll of `kCGWindowListOptionAll`; before that sample its bounds were 0x0 and it was off screen); a real HID title drag of
  (-300,+150) moved a window's drawn rectangle from (881,518) to (581,668), exactly that; a real right click opened the context
  menu at the drawn window (native frame (615,433), drawn at (728,797) for a click at (728,800)); real clicks on two drawn
  windows focused them in turn (TextEdit's front window and Infinify's focus both followed); `quit-native` put every window back to natural.
- `native/privileged/fixture_test.py` (51 cases) and `--native-move` pass on the guest; the cooperative host (an ordinary process
  writing its own windows) writes placement 1 as well.

**Not established.** Windows already broken by an earlier build (placement 0 = identity) are drawn natural by a session of this
build (the layer carries the difference) and restored to natural, but that is only modelled (`restore_identity_test.m`,
`placementCases`), not run on the guest, and they return to the corner at the next Dock death: only the application's restart fixes
them. Whether the composition order holds for a placement 0 that is not a translation was not observed. While a new window
animates open (TextEdit, the first ~250 ms) the catenated read differs from placement 0 composed with placement 1 (both identity or
natural): some further placement, the application's or the window server's, contributes. A frame in that interval would read back
as not applied and be repeated (not observed in the helper's counters); the window was at alpha 0 through most of it in the poll above. Other writers of placement 1 (Mission Control, Stage Manager, tiling animations) were not looked for:
placement 1 read identity on every window at rest. The in-app Dock reload path and the launch daemon, a second display, Spaces and
the owner's Mac were not exercised for this change.

## Focused fixture validation

`./tests/e2e/privileged-fixture.sh` builds only by default. Passing
`--live-owned-fixture` explicitly runs `fixture_test.py` against spawned,
finite-window cooperative hosts. Individual scenarios can be selected directly
with `--inspect`, `--startup`, `--release-window`, or `--enrollment` after building.
`--client-restore` checks only C restore exit status; `--recovery` selects recovery
and read-only audit groups. `--client-and-recovery` also runs the C-client groups
without repeating the frames/lease groups. Its C-driver checks require a successful durable restore
to exit zero; a staging obstruction produces nonzero exit even when native
geometry has already been restored, until autonomous persistence retry completes.
The harness cleans up its children on all exits, independently reads transforms
and screen rectangles through its own WindowServer connection, and checks the
journal on disk.

Relevant scenarios cover multiwindow frames and alpha, malformed identities,
newest-frame bursts, disconnect and lease restoration, client/helper loss, the
C client, per-window release, process-scope audit, read-only inspection before
first touch and after restoration, strict startup refusals with byte preservation,
and a filesystem obstruction that leaves an empty table with a pending journal.
`restore_identity_test.m` (also the arrival veil cases) compiles the actual apply/restore code with native
call substitutes to check unavailable enumeration, owner/process lookup, changed
identity/scope, and retention of the original in the table and durable journal.
It also replaces the simulated owner after journal fsync and between setters,
checking that no later property write or successful frame acknowledgement reaches
that replacement. This regression creates no window and is not native API evidence.

The current tests do not inject into Dock, change policy or settings, enroll
another user's applications, or prove third-party visual/input usability. Native
restore API failure and startup restoration of a still-live foreign window remain
separate evidence requirements.

The headless tests, which need no window and no Dock, are `restore_identity_test.m`, `forward-operations-test.m`
(alpha de-duplication, drift correction, failed readback, identity loss during an alpha readback, veil ordering and exact restoration),
`loadd-request-regression.m` and `client_protocol_test.py`.

## Attribution and provenance

Original helper/protocol code is GPL-3.0-or-later. Private ABI declarations were
cross-checked against yabai (<https://github.com/asmvik/yabai>) commit
[`dd845723416f5fe92af49fad5ebab00369e07edd`](https://github.com/asmvik/yabai/tree/dd845723416f5fe92af49fad5ebab00369e07edd):
`src/osax/payload.m` and `src/misc/extern.h` (alpha declarations at lines 16, 17
and 79). The loader is adapted from that exact revision's `src/osax/loader.m`,
with the MIT notice retained in the loader's header and in
[`native/desktop/YABAI-NOTICE.txt`](../desktop/YABAI-NOTICE.txt). Ad-hoc
signing follows `src/sa.m`'s `scripting_addition_prepare_binaries` at the same
revision (`codesign -f -s -`). The source notices and exact pinned upstream
provenance remain attached to the implementation.

The launch daemon, its caller requirement and its property list come from Sunlight
(<https://github.com/spacefarm-digital/sunlight>, commit `afeea74b18e70ca49bf462d6fe462cf65deb2b32`, MIT, Copyright (c) 2026
spacefarm; notice in [`native/desktop/SUNLIGHT-NOTICE.txt`](../desktop/SUNLIGHT-NOTICE.txt)): `loadd.m` copies ranges of
`LiveWindows/helper.m` and lists them in its header, `loadd-request.m` follows the form of its caller requirement, and
`com.marengox.infinify.loader.plist` adapts `Resources/LaunchDaemons/com.spacefarm.sunlight.live-windows.plist`. The arrival veil in
`payload.m` adapts an idea and the window server announcement of Sunlight (`LiveWindows/README.md`, `LiveWindows/osax/sunbeam.h`,
`Sources/Canvas/RealWindows/WindowServerEvents.swift`), as its header lists.
