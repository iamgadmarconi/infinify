# Transform helper: protocol v2

This experimental native adapter targets Apple Silicon macOS 26 or later. Its
sole listener is binary protocol v2 on `RUNTIME/v2.sock`. Loading a payload starts
no transformation; a controller must name an exact in-scope process instance and
window in a `FRAME` request. There is no v1 listener, JSON request client, protocol
fallback, or second restoration state machine.

Default commands remain read-only. Build commands compile and sign artifacts but
do not load Dock or launch fixtures. Native mutation tests use only explicitly
spawned disposable fixture windows and restore their original transforms before
cleanup. These tests do not establish Dock-hosted authority or usable third-party
native-window compositing.

## Build and entrypoints

`./scripts/build-privileged.sh` builds the following in `target/privileged`:

- `doctor`: a read-only SIP and arm64e boot-policy report.
- `payload-arm64e.dylib`: the explicit Dock-targeted payload.
- `payload-arm64.dylib` and `host`: an ordinary cooperative fixture process.
- `dwclient.o` and `dwclient-arm64e.o`: the plain C/pthread v2 client library.
- `v2client`: a fixture driver for `bench`, `hold`, `enrollment`, and `inspect`.
- `loader-arm64e`: an opt-in Mach loader with authenticated v2 readiness checks.
- `loadd`: the launch daemon (see [Launch daemon, login start and Dock reload](#launch-daemon-login-start-and-dock-reload)),
  built last with the SHA-256 of the signed loader and payload compiled in.

`--doctor-only` builds only the doctor. `--production` omits the fixture payload,
host and driver. Production builds ad-hoc sign the doctor, arm64e payload,
loader and launch daemon; merely building never executes any of them. When
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
The prior v1 JSON client and Dock spike
scripts, including their separate spike fixture, are retired. Supported
workflows are the owner-run [native desktop launcher](../../scripts/start-native-desktop.sh)
and the v2 disposable-fixture scenarios below; the retired spike's historical
receipts are not validation of this protocol or production compositing.

The cooperative host accepts:

```text
host ABS_PAYLOAD PRIVATE_RUNTIME NONCE64HEX [ALLOWLIST_JSON_FILE]
     [--windows N] [--v2-queue own|main] [--level 0..4] [--alpha 0..1]
     [--family popup|sheet|both|none]
```

The runtime must already be a current-user-owned directory with mode 0700. Keep
its path short: `RUNTIME/v2.sock` must fit macOS's Unix socket path limit. The host
creates 1..16 windows, with a 90-second watchdog. Optional family children count
toward that limit and are all listed explicitly. Capability bit 3 identifies this
finite native-family fixture mode; it expands no process or window authority.
Level and alpha options apply only to the newly created fixture windows.
`READY` is printed only after the sole v2 listener binds and its journal passes
startup validation. Failed startup prints no readiness receipt.

The current C driver can inspect an exact identity without holding it:

```text
v2client inspect RUNTIME NONCE64HEX PID WID BIRTH_SEC BIRTH_USEC
v2client enrollment RUNTIME NONCE64HEX
```

The desktop links the C library; the supported Rust runtime uses typed binary v2
requests. Both must authenticate the helper and audit scope before any frame.
Read-only probe/inspection never enrolls ordinary applications automatically.

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
`target/app/BUILD.json` schema 2 record before calling its bundled launcher.
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
shows that `clock_boottime` can change with calendar adjustment. The pinned
source hashes and Apple license are recorded in the local XNU provenance receipt;
no XNU implementation code is copied into Infinify.

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
including across a reboot. Schema-2 launch records lack the boot UUID and are
preserved with an inspection error rather than inferred or upgraded.

The launcher keeps the previous ready record until the recovery loader reports
authenticated readiness. A private `launch.pending.plist` marker blocks any
retry after an interrupted or uncertain recovery. On success, the old record is
archived byte-for-byte and the new ready record is promoted. The old runtime and
journal remain untouched. Schema-2 and unknown journals are refused because
they lack the retained originals needed for safe connection handoff; the
launcher never reconstructs transforms from native bounds. A same-boot journal
with a mismatched boot-session UUID, unresolved recovery, a live or uncertain
prior Dock, or invalid payloads blocks startup and preserves all state. There is
no compatibility fallback or automatic injection retry. The launcher runs only
the loader as root (through sudo in the owner's terminal, or through the launch
daemon the owner approved once, below) and starts the app as the login user. The login
item starts compositor mode only after `native-desktop enable`; until then it is the
capture-mode startup and does not invoke this helper path.

An earlier UTM run established that a new helper could start after an empty
schema-2 journal, but it did not cover a window whose transform had been touched
by the retiring Dock. A later read-only receipt showed Calculator WID 183 at
transform `[-510,-554]` with `windows: []` before Dock exit, then at identity
transform before the replacement helper was injected. The old empty journal had
already discarded the original transform. The schema-3 retained-original fix
passed one production-launcher handoff with ordinary Calculator on build
`2d9c7d6`: independent native geometry matched the exact original after recovery
and again after normal quit. Its black screenshot provides no optical proof.
A second handoff was interrupted by a guest reboot before the recovery launcher
ran; the reboot cause is undetermined. Receipts are under
`target/native-vm/pending-restore-inspect/` and
`target/native-vm/retained-originals/receipt.json`.
On the following boot, build `5cee261` passed two consecutive handoffs with a
fresh ordinary Calculator instance: exact originals were recovered before
readmission and restored on quit, with awake-display screenshots confirming
its restored position. See
`target/native-vm/retained-originals/two-handoff-receipt.json`. This does not
establish all-app or crash-during-frame recovery. Automatic prior-boot record
archival has focused record validation but has not yet been exercised through
another actual guest reboot.

Direct loader invocation also requires explicit prepared-machine authorization:

```text
loader-arm64e --inject-dock ABS_PAYLOAD ABS_PRIVATE_RUNTIME
  --nonce-file ABS_NONCE_FILE --only-pid PID
  [--expected-dock PID BIRTH_SEC BIRTH_USEC]

loader-arm64e --inject-dock ABS_PAYLOAD ABS_PRIVATE_RUNTIME
  --nonce-file ABS_NONCE_FILE --desktop --expected-dock PID BIRTH_SEC BIRTH_USEC
  --recover-journal ABS_OLD_RUNTIME/v2-journal.json
  --expected-retired-dock OLD_PID OLD_BIRTH_SEC OLD_BIRTH_USEC
```

`--desktop` selects same-login-user scope instead of a finite `--only-pid` scope.
The payload is one of two classes, told apart by its path so that neither can stand in for the
other: any ordinary path must be the login user's own regular file that no one else can write (the
sudo path above), while a path of the exact form
`/private/var/run/infinify-payload.XXXXXX/payload-arm64e.dylib` is a copy the launch daemon staged, accepted
only by a root loader and only if the whole path is root's: every directory above is root's, not
writable by others and writable by a group only if the login user is not in it
(`/private/var/run` is `root:daemon 0775`), the staged directory is root's and writable by no
one else, and the payload is root's regular file, not group/other-writable, with one link; no
component may be a link (`native/privileged/staged-payload.h`, shared with the daemon).
The runtime directory, the nonce file and the journals stay the login user's, private (0700, 0600), as before.
The nonce is a cryptographically random 32-byte value encoded as 64 lowercase
hexadecimal characters, in a login-user-owned regular file with mode 0600; one
trailing newline is accepted. Nonce bytes are never accepted in the loader's
argv. A private, adjacent `ABS_PAYLOAD.json` sidecar opts in the constructor with
runtime, nonce and optional exact-process allowlist. No sidecar means no listener.
The recovery form accepts only a committed same-boot schema-3 journal from the
positively retired Dock recorded by the launcher. It copies those exact bytes to
the fresh runtime and binds their digest and writer identity in the sidecar. The
payload validates the complete journal, then commits the new writer's journal
before any restore setter. Later recovery uses that committed journal; if it is
malformed, the retained import source is not a fallback. The launcher adds a
private pending marker before sudo and promotes its ready record only after
authenticated readiness; an interrupted or uncertain handoff blocks retry.
Schema-2 journals are refused because their original-window ledger was not
retained.
After loading, readiness authenticates v2, verifies scope/process identity,
required restoration/scope/inspection capabilities, `held=restoring=table_count=0`
and `journal_pending=0`, then disconnects without submitting a frame. A missing
or failed v2 listener is startup failure, with no alternate server.

## Launch daemon, login start and Dock reload

The explicit launcher above asks for the owner's sudo password at every load, and a
Dock restart ends the payload, so the helper path alone cannot run at login or survive
`killall Dock`. This section is the prompt-free path, ported from Sunlight's mechanism
(`third_party/sunlight/LiveWindows/README.md`, "Installation boundary" and "Dock
restarts"; Sunlight afeea74b18e70ca49bf462d6fe462cf65deb2b32, MIT, Copyright (c) 2026
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
  No `--only-pid`, no unpinned Dock, no other flag, nothing else.

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

`launch.sh` (reached as `Infinify native-desktop`, `--login` or `--reload`) keeps every existing
check: manifest and signature verification, the doctor, the Dock identity pin, `pending`/`ready`
schema-3 records, payload hashes, the boot-session rule, the retired-Dock journal handoff, no
automatic retry of an uncertain load. Changes:

- The loader step runs through the daemon when `Infinify native-desktop daemon status` says it is
  enabled, else through `sudo` in a terminal as before. In `--login` and `--reload` there is no
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
  reboots, as before.

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

### What was run

All of it in the disposable macOS 27.0.1 (26A434) UTM guest (SIP off, `-arm64e_preview_abi`), with the app signed by the
Developer ID Application identity of team PBKWRHQV74 and installed as `~/Applications/Infinify.app`; none of it on a
physical Mac or on macOS 26. The numbers are from 2026-10-30.

- **Decision regressions** (`tests/e2e/native-daemon.sh`, no daemon, root or Dock; the figures in this bullet are the first guest run's,
  before the hardening run below, which changed the request shape and added checks, see its own numbers): `loadd-request-regression.m` 179 checks
  (caller requirement text, parsing and refusal of an ad-hoc process, acceptance for a real team signature and refusal for
  another team; the launcher's two request forms and dozens of mutations of them; loader and payload digest, ownership, link and
  swap cases) and `dock-reload-regression.m` 68 checks (Sunlight's `DockCrashGuard` tests translated, the pause file, the endpoint
  line, the reloader against a fake Dock, clock and launcher, the login-mode record). `scripts/test-build-app-package.py` passes
  with the daemon artifact, its digest binding, the identity-only property list and the separate signing.
- **Launcher modes** (`tests/e2e/native-launcher.sh`, stub loader/app/daemon client, real launcher script and real bundle
  verification, a throwaway `HOME`): 84 checks passed in the guest with the committed script, and 84 on the host against a copy
  that matches processes by path (the owner's real Infinify runs there). They cover the daemon's arguments in both forms, the
  retired-Dock journal handoff twice in a row, `--reload` accepted only from the one running Infinify as its child, the pause,
  quiet login refusals, no retry of an uncertain load, prior-boot archival and the no-daemon refusals. A host run found that
  macOS `pgrep` leaves out the caller's ancestors unless `-a` is given, which would have refused every real reload.
- **Enable and approval.** `Infinify native-desktop enable` over SSH: the launcher check passed, `SMAppService` registration
  answered "Operation not permitted" and `sfltool dumpbtm` showed `loadd` as `[enabled, disallowed]`; the pane opened. Toggling
  Infinify under Login Items (a synthesized click) raised a sheet asking for the admin password; the guest's password was typed
  into it with the vm-tools helper as HID events. After that: `The launch daemon answers.` (a real XPC `ping` through the
  caller requirement), `login item: on`, and launchd started the login item at once, which started compositor mode: its log shows
  the launcher, `Only the loader runs as root, through the launch daemon.` and `authenticated v2 helper ready in Dock`; no
  password was asked for the load. `disable` then `enable` again needed no second approval (BTM keeps the item as allowed).
- **Login.** `sudo reboot`, auto-login on: about 15 s after SSH answered, Infinify, started by launchd, was running in compositor
  mode; `login.log` shows a start at 00:36:51 that archived the previous boot's record and loaded fresh through the daemon.
  `pkill -9` of that instance: launchd started it again after 4 s, and the launcher reused the helper already in the Dock.
- **Dock restart.** Three TextEdit documents at camera zoom 0.5 (WindowServer transform `[2,0,0,2,-1165,-1037]` and so on,
  read independently with `SLSGetWindowTransform`), `killall Dock`: the new Dock was there at t+1 s, the three windows were drawn
  at transform identity, bounds 0,0, until the reload; the launch record moved to the new Dock at t+8 s (first build) and
  t+6 s (the build with a 1 s poll and a 1 s reload confirmation), and the windows read exactly the same transforms again.
  The app's log: `Native presentation lost; restoring and reconnecting`, `The Dock restarted (4803 -> 5495)`, the launcher's
  recovery load through the daemon, `Dock payload reloaded; reconnecting`, `Native presentation reconnected after authenticated
  restoration audit`. So the windows sit at the screen's top-left corner for about 5 s each time; this is the Dock's own reset of
  the transforms, and shortening it further is open.
- **Crash guard.** Quit, `killall Dock`, `launchctl kickstart gui/$(id -u)/com.marengox.infinify.agent` (a load), then three
  `killall Dock` in a row 8 s apart: the first two were reloaded (launch record moved at t+6 s and t+13 s), the third printed
  the three-restarts line and the stop line, wrote `auto-reload-paused.plist` and the app ended without being restarted (the
  windows were left at transform identity). `native-desktop status` then said `paused`; a login start (`kickstart`) logged
  `Automatic loading is paused for this payload ... compositor mode was not started`; a by-hand `Infinify native-desktop`
  (no terminal needed with the daemon) printed `this start by hand lifts the pause`, performed the journal-handoff load and the
  windows read `[1,0,0,1,-137,-396.5]`, `[1,0,0,1,-735,-396.5]` and `[1,0,0,1,-137,103.5]` again, their original native
  transforms. The three kills were repeated with the final build (the stop line was reworded after the first run): the log lines were as above
  with the new wording, the pause file was written and the app ended; windows were not read that time, and a by-hand run followed.
- **The daemon refuses what it should**, through the real root daemon: an ad-hoc signed XPC client's `ping` got `Couldn't
  communicate with a helper application`; the signed app's `ping` answered with the requirement and the loader digest;
  `daemon load` of a payload outside the runtime and of a form without the Dock pin exited 64; a well-formed load whose runtime
  payload was not the bundled one exited 70; a load pinning the current Dock's PID with another process birth exited 71. Nothing was loaded by
  any of them.
- **Fallback and revert.** With the daemon unregistered, `run-native` loaded through `sudo` exactly as before. `disable`
  removed `login.plist`, unregistered the login item (ending its instance) and the daemon (`launchctl print` found neither
  service), and `status` read `disabled`; BTM keeps both records as `disabled, allowed`. The guest was left with Infinify quit,
  the payload dropped by a Dock restart, Stage Manager off and the four tiling keys on.

### What was run for the hardened runtime and the staged payload

The same guest (macOS 27.0.1, SIP off, `-arm64e_preview_abi`), 2026-10-30, with the Developer ID Application build of team
PBKWRHQV74 made from this tree and installed as `~/Applications/Infinify.app`; none of it on a physical Mac or on macOS 26. Where a
guest result needed a comparison, the comparison was run too.

- **Signatures.** `codesign -dvv`: the app executable, `loadd`, `loader-arm64e` and `doctor` carry `flags=0x10000(runtime)` and the team
  signature, with no entitlements at all (`codesign -d --entitlements -` is empty); the payload is ad hoc. The bundle verifies
  (`--deep --strict`). No entitlement was needed by anything tried: the capture mode, the Dock injection, the daemon and the launcher all
  ran with none.
- **The hardened app still works.** Capture mode (`open`): `msg state` read one output and, with two TextEdit windows open, both;
  `msg screenshot` wrote a 2056x1251 PNG (3.1 MB) showing the TextEdit text rendered over the wallpaper (Screen Recording grant carried over from
  the earlier build: the grant follows the designated requirement, which the hardened runtime does not change). Pointer events posted at
  the HID tap (`CGEventPost`) were seen by `msg cursor`. Compositor mode started the owner-launcher way with the sudo loader (the
  non-daemon path, the Developer ID hardened loader as root through sudo): `authenticated v2 helper ready in Dock (same-user desktop
  scope)`; `msg zoom 0.5` halved the windows in a `screencapture` of the display; a posted F3 key press (a key the app owns, through its
  session event tap when Accessibility is trusted) ran `zoom-to-fit` (zoom 0.5 to 1, camera moved), and the log carries no "System
  shortcut interception unavailable" line. Command-chord hot keys (Command-0, Command-=) posted the same way did not fire; they did not
  in capture mode either and were not compared with the earlier build, so this is unexplained and not shown to be the hardened runtime.
  The guest has no trackpad (`MultitouchSupport lists no trackpad`), so the trackpad gesture path itself was not exercised.
- **Enable and load, hardened.** `enable`: check passed, `The launch daemon answers.` (the ping crossed the new audit-token check and answered
  `answering for a hardened-runtime ...`; the approval from the earlier run persisted, none was asked), `login item: on`. After
  `killall Dock`, `Infinify native-desktop` (launch daemon on): `Only the loader runs as root, through the launch daemon.`, `authenticated v2
  helper ready in Dock`. The Dock's mapping, read as root: `vmmap` lists the payload's `__TEXT/__DATA/__LINKEDIT` regions from
  `/var/run/infinify-payload.FIZ1M3/payload-arm64e.dylib`, `lsof` lists it as the Dock's `txt` file with inode 572489, and `stat` of that
  file gives the same inode, owner root, mode 0644; its SHA-256 `bd1eb48a...cd47` is the bundle's, the manifest's and the digest compiled into the daemon
  (`loadd status`). The directory is `root:daemon 0755`; beside the payload is the sidecar, `admin:staff 0600`. The runtime of that load holds
  no payload copy.
- **The race, with a hostile same-user process.** A direct `daemon load` (so as to hold the runtime) with an evil arm64e dylib, whose
  constructor writes `/tmp/harden-evil-marker`, planted at `RUNTIME/payload-arm64e.dylib` (the path the earlier design would have had the Dock open),
  while a racer run as the login user hammered for 12 s: it rewrote that runtime payload 95,600 times, saw the staged directory 9,746 times, and tried to
  open-for-write, create beside, rename and unlink the staged payload each time: 19,492 write attempts, 9,746 renames and 9,746 unlinks all
  denied, none succeeded. The load returned 0, the marker never appeared, and the Dock mapped the root-owned staged file (inode 572524,
  digest `bd1eb48a...`, root 0644). The racer's file was still on the user-writable path afterwards: the Dock never opened it. (The
  racer wrote its evil file into every runtime directory in `/tmp`, including the recorded one; the launcher then refused to reuse that runtime,
  `recorded runtime payload bytes differ from the launch record`, which is the reuse check doing its job.)
- **Refusals, through the real root daemon.** `Infinify native-desktop daemon ping` from copies of this bundle signed in other ways: the Developer ID
  signature without the hardened runtime (`flags=0x0`), with the runtime and `get-task-allow`, and ad hoc: each `Couldn't communicate with a helper
  application` (no connection); `codesign -R` showed the first two satisfy the daemon's requirement, so it was the hardening check that
  refused them. The installed hardened app: the ping was answered. The hardened app started with `DYLD_INSERT_LIBRARIES` naming a
  dylib: the dylib's constructor ran inside the signed hardened app (the marker file appeared: the flag does not stop this on this SIP configuration) and the daemon
  refused both its ping and a well-formed load. A load after the bundle's payload had been replaced with the evil dylib exited 70, `the bundled payload is not
  the one this daemon was built with`, with nothing staged; the bundle was restored and verified.
- **The loader's own rule, on real root-owned files** (the hardened loader as root, against a pinned current Dock, refused before any sidecar or
  injection): a root-owned payload outside the staged form; at a staged-form path, a 0666 payload, a 0664 payload, a 0777 directory, a 0775
  `root:wheel` directory, a directory owned by the login user, a payload owned by the login user, a payload that is a symlink, a payload
  with a second link, and a directory that is a symlink: ten of ten exited 1 with the matching reason.
- **Dock restart, reuse and revert.** With the daemon on and compositor mode running, `killall Dock`: `The Dock restarted`, the launcher's recovery load through the
  daemon (the retired runtime's sidecar read from its staged directory), `Dock payload reloaded; reconnecting`, `Native presentation reconnected after
  authenticated restoration audit`; the new staged directory replaced the old (`ls /private/var/run` showed one), the record moved to the new Dock. After
  quitting the app, a second `Infinify native-desktop` in the same Dock logged `Reusing the recorded same-Dock desktop helper` (the check read the staged copy through
  `daemon staged`). `disable`: login item off, daemon not registered (`launchctl print` found no service), `status` read `disabled`. The guest was left with
  Infinify quit, the payload dropped by a Dock restart, no staged directory, Stage Manager off and the four tiling keys on.
- **What a same-user process can do to a hardened or an ordinary target** (ad-hoc test binaries, same guest, Developer Mode off): `task_for_pid` by the
  login user failed (5) for a plain target and for a hardened one, and succeeded for a hardened one with `get-task-allow`; root succeeded for all; a binary
  holding the `com.apple.security.cs.debugger` entitlement did not succeed for either. A `DYLD_INSERT_LIBRARIES` dylib loaded into the plain and the hardened target
  alike (the same on the development Mac, whose SIP configuration is the same). These are why the daemon requires no `get-task-allow` and refuses a `DYLD_*` start in addition to the flag.
- **The final build, a short run.** After the refusals were given a log line (`os_log` in the daemon, reason named, the caller told only that the
  connection failed) and the app's message a hint, the build from this tree was deployed again: `enable` answered, a daemon load into a fresh Dock
  was ready with the Dock mapping the root-owned staged copy (inode 572988, digest `bd1eb48a...`), the three re-signed copies and a hardened app started with
  `DYLD_FOO=1` were refused, and `sudo log show --last 5m --predicate 'process == "loadd"'` gave the reasons (`the caller's signature does not carry the
  hardened-runtime flag`, `... (get-task-allow)`, `the caller was started with DYLD_FOO, which can load code into it`); then `disable`. The one change after that
  build is the word `sudo` in the app's hint text (an unprivileged `log show` printed nothing for the daemon), compiled by the regression build but not re-run.
- **Tests of the changed modules.** `tests/e2e/native-daemon.sh target/app/Infinify.app`: `loadd-request-regression.m` 278 checks including a real team
  signature (the new request shape and its mutations, the staged-payload rule on mutated real directories and files, staging and pruning, the caller
  flags, entitlements and environment) and `dock-reload-regression.m` 68 checks, then eight live-process checks of the caller rule on ad-hoc copies of the
  regression binary signed with and without the runtime flag, with `get-task-allow`, `allow-dyld-environment-variables`, `disable-library-validation` and
  `allow-jit`, each started with and without a `DYLD_INSERT_LIBRARIES` dylib; `tests/e2e/native-launcher.sh`: 95 checks (11 added: no payload in the
  daemon-mode runtime, none named in the request, the staged copy checked on reuse, changed or missing refused), on the host and in the guest;
  `scripts/test-build-app-package.py`: ad-hoc builds are signed as before and an identity build signs the daemon and the bundle with `--options runtime` and nothing
  that weakens it.

Not run: macOS 26, a physical Mac, the owner's Mac (its approval sheet may differ, e.g. Touch ID), `/Applications` instead of
`~/Applications`, a Dock that dies during the loader run (the pending-marker path was exercised only with stubs), a second user
logged in (the prune leaves another user's staged copy alone by its sidecar's owner; that was checked in the regression only), a
trackpad, a Mac with Developer Mode on (a debugger-entitled tool attaching to the hardened app), notarization or a secure timestamp
(the builds have neither, as before), the sudo path's payload race (it still exists, with the owner at the terminal), the sidecar being
rewritten during a load, and the Command-chord hot keys posted by HID events. The 60 s window and three-strike limit are Sunlight's and were not tuned.

## Protocol v2

[`protocol2.h`](protocol2.h) is the sole wire schema. All integers and floating
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
same user=3. Queue is own=0 or main=1. Current clients require the relevant current
capabilities and refuse unsupported helpers; there is no old-capability bypass.

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
status-bearing scalar or list setter must also succeed. Private transaction
staging/commit return registers are ignored: on the inspected macOS 27.0.0 build
26A434 they are not trustworthy error statuses, despite the pinned upstream
headers declaring `CGError`. A failed or differing set remains journaled because
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
Zero leaves membership untouched; legacy `FRAME` bytes remain unchanged.
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
`original_space: {id, display, pending_target}`; old entries remain valid. The
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

Real TextEdit at 1x and Finder at .5 scale appeared on a temporary second display
in the macOS 27.0.1 guest, with independent native hits reaching each exact window.
The Finder successor preserved all six canvas world frames, and recovery cleared
the retained request to deleted Space 128. The final Finder handoff-and-quit run
verified all six original memberships and transforms before display removal and
again compared original transforms afterward. Evidence is under
`target/native-vm/space-handoff-20261021/`, in `textedit-observed-1`,
`finder-reflow-1`, `recovery-deployment` and `finder-quit-settle-1`.
Finder's native extent still reflowed from `2056x1130` to `1280x770` on the smaller
display. These runs do not establish native content-extent/detail preservation,
general child-family transfer, physical-display or macOS 26 acceptance.

### Arrival veil

A window an application opens is shown at its native size and place until the shell has listed
it and the first frame has placed it: about 20 to 30 ms when placement works and for its whole life
when it is refused. The `VEIL` request (capability 128) closes that gap from inside the Dock. It is an
adaptation of the idea Sunlight uses (see below), as an alpha write instead of a window level.

- **Offered** only by the explicit same-user helper (not an allowlist or cooperative one) that has
  alpha getters/setters and could register for the window server's announcement of a window added to
  a Space (SkyLight connection notification 1325; payload: Space id u64, then window id u32). A control
  session asks with mode 1 and is answered status 0 and the bound (`DW2_VEIL_TIMEOUT_MS`, 1000 ms), or
  status 1 (refused: no capability, or the client's own process could not be read from the socket); mode 0 ends
  it and releases what is held. A malformed request ends the session like any other. It ends with
  the session. The desktop shell asks after its empty-table audit and carries on without it if refused.
- **Which windows.** The Dock's main thread only receives the announcement and hands its window id to v2q;
  every native call and the journal write run on v2q, which is the helper's own queue unless the sidecar's
  `v2_queue` is `main` (then v2q is the main queue and a veil runs there). A window is
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
- **Not covered.** Windows not at layer 0 (utility panels at the floating level, menus, popovers) are not veiled.
  A window already known to the window server that is announced again for a Space change and not managed by the shell
  is held for up to the bound (while the Dock lives). A window the application animates (TextEdit's document windows, sheets) can have the veil
  overwritten by the application: TextEdit's own open animation wrote alpha 1 about 0.5 s after creation (measured
  501 to 533 ms), before the bound, when nothing placed the window. The veil is not an optical result.
- **A browser's windows: what the veil held, measured, and a test that was not adopted.** The owner's Aside windows "randomly flashed"
  with the veil on; the veil was not the cause (see [the shell's account](../desktop/README.md#a-root-whose-family-cannot-be-read-the-browsers-main-window-flashing)).
  What Chrome 156.0.8078.80 showed in the macOS 27.0.1 guest, every 1325 announcement read from inside the helper with a temporary trace (removed):
  the main window is announced at alpha 0, Chrome fading it in itself, and is not veiled; the windows 1038 wide and 88 to 139 high that appear
  while the address bar is typed into (shadow 0/0/0, alpha 1; probably the completion list) are eligible and were veiled once in the first run,
  0.4 ms after the announcement, and lifted by the first frame of the family 48.6 ms later; the windows 270 by 80 to 122 that appear over a
  hovered tab or link (probably hover cards or tooltips) are announced at alpha 0.01, so they are not eligible; a window 316 to 323 by 22
  (shadow 13.2/0.300/4) is announced at alpha 0, is under the size floor, and was announced 29 times in 70 s (the owner's host log has a
  window of Aside with the same pattern, 61 times, and no decline for it). That 22-point window read alpha 0 for 19 to 107 ms,
  8 to 26 times in a 70 s run, with and without the veil: the application's own fade. A window the helper
  released and the application orders in again is never veiled again (`v2Released`), and a placed one is in the table;
  `restore_identity_test.m` announces such a window three more times and checks that nothing is written and the alpha stays 1.
  Sunlight's `sunbeam_shadow_standard` (`LiveWindows/osax/sunbeam.h:295-308`, which tells a titled window from a panel by
  `SLSGetWindowShadowAndRimParameters`) was tried as an eligibility test. The parameters are readable when the announcement arrives (a main
  window read 32.94/0.700/18 at alpha 0), but on macOS 27 every ordinary window reads density 0.700, not the 0.4 of Sunlight's constants
  (guest 27.0.1, and read only on the owner's 27.2: Ghostty, UTM, Aside, a window server panel), so against those constants nothing is
  standard; with the active look at 0.7 it separates a main window from Chrome's windows of shadow 0/0/0 but also from the completion window
  above, the one window the veil held and the family placed within 49 ms, which would then show at its native place for that long. It was
  built, run through the substituted-call tests and on one Aside sign-in window (veiled, lifted by its first frame), and not adopted; the
  experiment is kept outside the tree (`target/flash/experiments/`). The helper's veil is unchanged.
- **The shell** (`native-presenter.m`, `window-manager.m`, `main.m`) asks after admission, and lets go at once
  of a window it will not manage: `-windowNotAdopted:pid:` is sent once per appearance, from the first discovery
  pass on, for a window of a non-regular application, a window the shareable windows or Accessibility do not count as
  a window, one a read of which settled as not real, one `attach` refused, and one `-windowAppeared:` could not take
  because the canvas was closing or had no panels. The presenter queues one `RESTORE` record for that exact process
  instance (`-declineWindow:`); any reply retires it, since the helper's bound is the backstop. A window the helper
  holds nothing of answers a release with a no-op status 0. If the veil request gets no answer in time or an
  unreadable one, the shell assumes the veil may be on and keeps releasing explicitly: a wrong "on" costs a no-op record,
  a wrong "off" would leave such a window invisible for the whole bound.

What was run (macOS 27.0.1 (26A434) guest, SIP off, final build): `native/privileged/restore_identity_test.m` and
`forward-operations-test.m` use substituted native calls for every rule above (eligibility refusals, journal
before alpha with a failing journal changing nothing, transform-then-alpha in the scalar, transaction and
list paths, decline/bound/end/recovery, closed and replaced windows, the request and the announcement
payload through the real handler on a socket pair); `client_protocol_test.py` checks the C client's request,
refusal and invalid-reply handling against a fake peer; `fixture_v2_test.py`'s frames group, run in the
guest, shows a cooperative helper offering no veil (caps 119) and refusing the request without ending its session.
These are not native evidence. The live numbers below were taken before three later changes: the first frame's re-read and
journal write (`veil_bare`), the conditional veil alpha (`veil_alpha`, and a lift that leaves an alpha the application
took over), and the shell's declines from the first pass on; those are covered by the substituted-call and in-memory
tests only and have not been run live in a guest. Live, in the guest with the full-desktop helper: SkyLight 1325 reached the
Dock's handler for other processes' windows (and for Infinify's own canvas panels, which are refused); from announcement to
alpha 0 read back took 1.25 to 2.1 ms over eight windows (one 6.1 ms): about 0.13 to 0.4 ms to reach v2q,
0.6 ms to check and resolve, 0.4 to 0.9 ms to journal, 0.15 to 0.3 ms to write and read back. `measure-opening 8 0.5`
(TextEdit, camera zoom 0.5, `reset_on_new_window = false`, extended meter at 1 ms) reported, for eight windows,
`unplaced_ms` 0.0 to 2.3 (what the meter sampled before the veil landed), `how=hidden`, visible again at 9.9 to 81.1 ms at
scale 2.000, alpha 1.00, none left hidden; main (`ca88bbd`) had been measured at about 20 to 30 ms at native size. A silent
client (veil asked, nothing placed or declined) held non-animating windows for 1000.9 and 1023.3 ms before
the bound released them. With the shell running: a regular window placed after 131.8 ms hidden; an accessory-app window was released
by the shell's decline after 16.0 ms and a borderless regular-app window (not adopted: AXUnknown) after 132.0 ms, both visible
at scale 1, alpha 1; a 30x62 window was never veiled; the real TextEdit *Save* sheet was not veiled (alpha 0.66 at
first sight, mid-fade) and was placed 22 ms later, still fading in. `quit-native` with managed windows at scale 2.0 and a window
0.1 s into its veil left 47 of 47 layer-0 windows at alpha 1, scale 1. **A Dock exit does not undo
alpha:** an alpha the Dock set on a settled window (0) was still 0 3.5 s after `killall Dock`, while its transform reset
(tx -168 to 0); a veiled non-animating window was still at alpha 0 with the Dock gone, and the launcher's recovery handoff
(`run-native`) restored it to alpha 1.00. A veiled window is therefore invisible after a Dock crash
until that recovery runs: the bound's timer died with the Dock, so nothing limits it, unless the application
rewrites alpha itself. Not run: macOS 26, a physical display, other applications' open animations, optical capture.

**Measuring this: read alpha before the transform.** On the integrated build a meter that read a window's transform and then its
alpha reported `hidden`, `native` (alpha 1, scale 1), `placed` for about one window in six (11 of 72 over six 12-document runs), a few to 30 ms apart. It never
happened: the helper writes a window's transform and then its alpha 0.1 to 0.5 ms later, and a meter whose two reads straddle those
writes pairs the old transform with the new alpha (and stamps the pair at the start of its tick, before a window-list copy that can take
10 ms or more). A helper-side poll of the window's alpha every 150 us for 120 ms after each veil (temporary instrumentation, removed) read 0
continuously until the helper's own alpha write, which followed its transform write, then 1, with no other value, in 24 of 24 windows. A meter that
reads alpha first, then the transform, never shows a visible window at its old transform (the transform is already
scaled by the time alpha is above 0): it reported none in 36 of 36 windows (three runs), while a transform-first meter running at the same time on the same
windows in two of those runs reported two of 24 (wid 1009 and wid 1036). The extended `openmeter` reads alpha first.

One control `HELLO` creates the session and a random token. A second heartbeat
connection uses that token; requests on either renew the 2000 ms lease. The C
client heartbeats every quarter lease; Rust runtime heartbeats every 400 ms.
Control disconnect, malformed control request or lease expiry restores all held
windows. Closing only a heartbeat connection does not end the session. An alive
C heartbeat thread can retain windows while its caller stalls. A fully stopped
client expires; a fully stopped helper cannot restore until it runs again.

Frames use one newest-frame slot, limited to 1024 records. Waiting frames are
superseded instead of building a queue; the next frame reply counts them. One bad
record does not prevent the others. `RESTORE_ALL` discards a waiting frame;
a later frame is processed afterward. Probe, inspect, restore, native calls,
table changes and journal writes run serially on the helper's own queue by
default. `DW_V2_MAIN_QUEUE=1` at build time, a sidecar `v2_queue` of `own`/`main`,
or the fixture's `--v2-queue` can select the main queue. Socket parsing, heartbeats
and lease checks run on connection threads. Acceptance of own-queue native calls
inside Dock still requires scoped real-host evidence.

Production helper builds use `-O2`. For explicit comparisons,
`DW_V2_TRANSACTION_BATCH=1` stages changed transforms in one transaction, while
`DW_V2_WINDOW_LIST_BATCH=1` uses one `SLSSetWindowTransforms` call; if both are
selected the list path takes precedence. Missing APIs/create failures use the
scalar path. Each staged record retains its original and is audited immediately
before submission, read back afterward, and finally identity-checked. Any changed
identity cancels the pending batch. Transaction release without commit was
observed to leave all eight owned fixture windows unchanged on macOS 27.0.0;
that does not establish the same behavior on every supported build.
`DW_V2_TRANSACTION_SYNC=1` and `DW_V2_TRANSACTION_TRACE=1` are diagnostic build
controls, and `DW_V2_ALPHA_DEDUP=0` keeps the previous alpha-write behavior for a
comparison. No protocol layout or per-window restoration contract changes.
Ordinary scalar builds compile the optional batching machinery out entirely;
there are no batch setup objects or extracted finalizer calls on that path.
`forward-operations.h` records exact ABI provenance. The substituted-call
`forward-operations-test.m` uses `DW_FORWARD_ONLY_SCALAR=1` to exercise this exact
production scalar path; its default comparison build includes the explicit
transaction/list paths. It can also compile against a frozen payload using
`DW_FORWARD_PAYLOAD` and `DW_TEST_FROZEN_BASELINE=1`. Its observations are call
counts and controller correctness, not native compositing evidence.

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
original transform (re-based on the native origin read at the write, below) and alpha, and requires exact float
readback. A real cross-display
quit exposed late AppKit reflow after an immediate successful readback. Entries
with a Space obligation now remain pending for at least two seconds from the
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

Legacy `recovery.json`, `recovery.next`, or `helper.sock` artifacts are never
replayed, cleared or converted automatically. Any presence refuses startup and
preserves the files, including a purportedly clean legacy receipt. Existing
`v2.sock` also refuses startup. Bind/listen and journal validation must succeed
before readiness. A process crash, machine failure or stalled helper cannot run
in-process restoration; preserved journals require exact-identity reconciliation,
not blind reinjection or deletion.

### Restoring a window whose native frame moved

A WindowServer transform is the whole map from the screen into the window's own space, so it carries the window's position: a
window that is not transformed reads `[1,0,0,1,-x,-y]` and is drawn at its native origin `(x,y)`. The original captured at
first touch therefore says the origin the window had then. Written back unchanged after the native frame has moved, it draws
the window at its old place while its native frame (hit testing, macOS tiling, the next session's original) is elsewhere.

Measured in the macOS 27.0.1 guest with the helper before this change: Ghostty 1.4.0 at zoom 1, pressed at its title (the
application's own window drag, taken over by the shell: `native/desktop/README.md`, "Takeover"), had its native frame moved
by WindowServer from `(601,417)` to `(494,399)` while the canvas dragged the drawn window; after `quit-native` the window list
drew it at `(601,417)` with transform `[1,0,0,1,-601,-417]` and `SLSGetWindowBounds` read `(494,399)`. Safari showed the same
without any drag: its native origin changed from `(40,136)` to `(41,131)` after its own toolbar re-layout in the first seconds,
and it was put back at transform `[1,0,0,1,-40,-136]`. Without a drag or any other native move the restore was exact. A
session started from such a window then captured the wrong original again, so the mismatch outlived the session.

The native frame moves during a session for reasons the shell cannot all prevent (the application, a window-server drag the
shell took over, a toolbar re-layout), so restoration no longer writes the captured transform as it is:

- **Plain original** (scale 1, no rotation: what an unmanaged window has): written as `[1,0,0,1,-x,-y]` at the origin read now.
  A plain transform is native by definition, which also puts right an original that was captured already displaced (the stale
  windows an earlier restore left behind): the first quit with this helper restored the two windows above to native on
  a session that did nothing else to them.
- **Any other original** keeps its linear part and its place relative to the frame: `t' = t - M*(origin_now - origin_captured)`
  (`v2RestoreTransform`), where `origin_captured` is the first-touch `bounds` the journal already holds. Unmoved, it is exactly
  the original; there is no new journal key.
- **The origin is read before the write and again after it** (`SLSGetWindowBounds`, with the readback of the transform that
  was already required). A window that moved between the two reads is not restored by that write: it stays `restoring` and
  the next pass writes the origin it has then. Without a readable origin the captured original is written as the best that can be
  done and the window stays pending, so the next pass writes the re-based one. The journal keeps the captured transform and
  bounds until release, so a crash between a move and the release is re-based by the next helper the same way.
- **After release** the retained record holds the transform that was written and the bounds read after it, so a later
  re-base (a reattachment after the Dock was replaced) starts from a pair that belongs together. The reattachment guard is as
  strict as before (geometry unchanged, and the transform either the original, the identity reset or the re-based one).
- A veil-only release (`veil_bare`) still adopts the transform in force; the Space settlement samples compare against the
  re-based transform at the bounds sampled.
- The pending receipt's `diagnostic` gained `captured_origin`, `native_origin`, `origin_status` and `target_transform`. Receipts
  stay valid without them.

`restore_identity_test.m` covers this with substituted calls (`rebaseCases`: unmoved, moved, stale plain, scaled and rotated
originals, unreadable origin, a move between write and read, crash recovery, reattachment); its other fixtures were made
consistent (a window whose original says `[1,0,0,1,-25,-35]` is at `(25,35)`; before, they paired it with `(0,0)`). These are not native evidence.
Native evidence, owned fixture only (`fixture_v2_test.py --native-move`, opt-in, needs Accessibility for the test process; the host's own windows are
moved through Accessibility while the helper holds them): in the macOS 27.0.1 guest the whole default run passed with this payload (53 cases, the
unmoved restoration of all eight windows exact), and the new group passed: the two moved windows were restored to `[1,0,0,1,-x,-y]` at the origin
they had (for example the window moved from `(1100,808)` to `(1071,849)` read `[1,0,0,1,-1071,-849]`, drawn at `(1071,849)`, where the captured
original `[1,0,0,1,-1100,-808]` would have put it 29 points right and 41 up of its frame) and the six others exactly their originals. The same group
against the payload without this change fails on the first moved window: it reads `[1,0,0,1,-80,-808]`, drawn at `(80,808)` with the frame at `(117,831)`
(`target/restore/evidence/fixture-native-move-{NEW,OLD}-payload.*` of the working tree). The whole-desktop evidence (Ghostty, Safari, TextEdit, Finder
in the Dock, quit, acceptance check 9) is in the shell's README section "Restore after a native-origin move".

## Focused fixture validation

`./tests/e2e/privileged-fixture.sh` builds only by default. Passing
`--live-owned-fixture` explicitly runs `fixture_v2_test.py` against spawned,
finite-window cooperative hosts. Individual scenarios can be selected directly
with `--inspect`, `--startup`, `--release-window`, or `--enrollment` after building.
`--client-restore` checks only C restore exit status; `--recovery` selects recovery
and read-only audit groups. `--client-and-recovery` also runs the C benchmark
groups without repeating the frames/lease groups. Its C-driver checks require a successful durable restore
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
The `4063db2` helper also passed the existing `--release-window` scenario on
2026-10-12: eight owned windows, transform/alpha writes, per-window release,
rebind and exact restoration, with the host and client closed afterward.
Local hashes and scope are in `target/helper-identity-readiness.json`; the log
is `target/helper-identity-live-release.log`. This does not establish foreign-app
or optical presentation behavior.
The current tests do not inject into Dock, change policy or settings, enroll
another user's applications, or prove third-party visual/input usability. Native
restore API failure and startup restoration of a still-live foreign window remain
separate evidence requirements. Historical files under `evidence/` record their
original runs; they are not receipts for later protocol revisions.

## Attribution and provenance

Original helper/protocol code is GPL-3.0-or-later. Private ABI declarations were
cross-checked against yabai commit
[`dd845723416f5fe92af49fad5ebab00369e07edd`](https://github.com/asmvik/yabai/tree/dd845723416f5fe92af49fad5ebab00369e07edd):
`src/osax/payload.m` and `src/misc/extern.h` (alpha declarations at lines 16, 17
and 79). The loader is adapted from that exact revision's `src/osax/loader.m`,
with the MIT notice retained in [`YABAI-LICENSE.txt`](YABAI-LICENSE.txt). Ad-hoc
signing follows `src/sa.m`'s `scripting_addition_prepare_binaries` at the same
revision (`codesign -f -s -`). The source notices and exact pinned upstream
provenance remain attached to the implementation.
