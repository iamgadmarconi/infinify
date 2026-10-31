# Launch daemon

The launch daemon that loads the payload for the signed app, the login start and the Dock reload (code in `native/dock-helper/Daemon`). The parity contract, [docs/parity/README.md](../../../parity/README.md), keeps what this document describes at `implemented_unverified` or below.

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

`native/dock-helper/Daemon/Daemon.m` builds to `Contents/Resources/NativeDesktop/loadd`; the property list
`native/dock-helper/Daemon/com.marengox.infinify.loader.plist` (shipped as
`Contents/Library/LaunchDaemons/com.marengox.infinify.loader.plist` only in builds signed with an
identity) names it as `BundleProgram` and the Mach service `com.marengox.infinify.loader`.
launchd starts it on the first request; it quits a minute after the last one. Its code comes from
Sunlight's `LiveWindows/helper.m` (header of `Daemon.m` lists the copied and the edited line
ranges). It answers two commands:

- `ping` (no arguments): proves the caller check and the daemon.
- `load`: the arguments of the bundled loader's `--inject-dock` after the payload, only in the launcher's two forms
  (`DWLoaddRequest.m`): `RUNTIME --nonce-file NONCE --desktop --expected-dock PID SEC USEC`
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
   path (see Direct loader invocation above), so a daemon that staged wrongly loads nothing. Its two changes to `DWLoader.m`
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
re-made by the root loader just before it injects, on the exact path it injects (the same code, `DWStagedPayload.h`). The bundle's
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
  twice three seconds apart, writes to `native-desktop/login.log`, and never exits non-zero on a refusal (launchd
  restarts a failed login item; a refusal needs a decision): once the app bundle's signature is verified it releases
  its launch lock and replaces itself with `Infinify setup --refused REASON`, whose assistant shows the reason and
  offers to try again by hand or the demo (before that point it exits 0). It does nothing when an Infinify runs. A
  start by hand from that assistant (`INFINIFY_LAUNCH_FROM_SETUP=1`) hands its refusal back the same way.
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
helper). The app (`native/app/System/DWDockReloader.m`, a function-by-function translation of Sunlight's
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
