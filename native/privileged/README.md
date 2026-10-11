# Transform helper — experimental, explicit enrollment

`./scripts/build-privileged.sh` builds macOS 26+ Apple Silicon artifacts in
`target/privileged`. `./tests/e2e/privileged-fixture.sh` exercises a disposable
NSWindow host, its dlopened arm64 payload, actual Unix RPC, and independent
parent-process SkyLight screen rectangles. It never injects into Dock.
The test launcher builds only by default; pass `--live-owned-fixture` to run that
disposable fixture test.
`target/privileged/doctor` is a read-only SIP/boot-policy report. This host's SIP
policy prevents injection. Transform-only code uses dynamically resolved SkyLight
symbols, without Dock offsets, Space functions or pattern scanning; no claim that
macOS 27 is inherently unsupported is made.

## Build artifacts

- `payload-arm64e.dylib`: Dock-targeted payload. Loading alone never enrolls a window.
- `payload-arm64.dylib`, `host`: ordinary cooperative fixture build. Host invocation:
  `host ABS_PAYLOAD PRIVATE_RUNTIME NONCE64HEX`. Runtime directory must already be
  owned by the current user with mode 0700. A relative path keeps test sockets
  below macOS's 103-byte path limit. Host has a 90-second watchdog.
  With trailing `--windows N` (1..16) the host opens N small windows and offers all
  of them to protocol v2 (v1 keeps the first); `--v2-queue own|main` chooses where
  v2's native calls run. Without either flag the host is the one-window fixture.
  `--level 0..4` and `--alpha 0..1` set only the new fixture windows through
  AppKit before ordering them. Alpha defaults to 1; helper restoration checks
  capture the initial value after this setup. These options support scoped
  visibility diagnostics without changing another application's windows.
  `--family popup|sheet|both|none` (default `none`) creates explicit native
  children of its first root and enrolls every new child in the same finite
  owned-window list. Roots plus children must total at most 16. Its separate
  family entrypoint advertises capability bit 3 so the desktop exercises the
  native parent/child path; no other process or late unlisted window is admitted.
- `dwclient.o` (`dwclient.h`, `dwclient.c`): the protocol v2 client library the
  shell will link; plain C and pthreads. `v2client`: a test driver built on it.
- `client`: POSIX socket client with JSON encoding. Invocation:
  `client PRIVATE_RUNTIME NONCE64HEX`. Reads JSON lines from stdin, adds `v` and
  `nonce`, prints responses, closes on stdin EOF or rejected operation. Holding
  stdin open does **not** send heartbeats automatically.
- `spike-fixture`: a disposable ordinary (regular-activation) process with one
  titled window, one large button and a large click-count label, at a fixed place.
  `spike-fixture ABS_STATUS_JSON SECONDS` writes its pid, process birth, window
  number, click and key counts, key/active/visible flags and its global top-left
  frame to the status file atomically four-plus times a second, and exits by itself
  after `SECONDS` (capped at 600) or on SIGTERM. It owns no other window.
- `loader-arm64e`: explicit Mach loader adapted from yabai. Merely building it
  does not execute it. Every load requires an explicit scope and a private nonce file:
  `loader-arm64e --inject-dock ABS_PAYLOAD ABS_PRIVATE_RUNTIME --nonce-file ABS_NONCE_FILE --only-pid PID`,
  or `--desktop` instead of `--only-pid PID` for same-login-user desktop scope.
  `--dock-identity` reads Dock's `{pid,birth_sec,birth_usec,uid}` as JSON without
  loading anything; desktop callers may pin that process with
  `--expected-dock PID SEC USEC`. The production launcher always pins it and
  records pending/ready state before loading, refusing an uncertain retry.
  `--only-pid` resolves that login-user process's start time (refusing a PID not
  owned by Dock's login user, and Dock itself) and writes a one-entry
  `{pid,birth_sec,birth_usec}` allowlist into the sidecar, pinning the helper to
  that one process. Loading Dock requires the owner's explicit prepared-machine
  authorization. The readiness audit authenticates v2, checks the requested scope,
  process identity, required capabilities and empty window table, then disconnects
  without submitting a frame. It never changes policy,
  runs sudo, restarts Dock, or modifies windows itself. After linking,
  `scripts/build-privileged.sh` ad-hoc signs this binary and `payload-arm64e.dylib`
  with `codesign --force --sign -`, as yabai signs its scripting addition; whether
  Dock accepts an ad-hoc dylib on 27.2 is unproven.

Before an authorized loader run, the login user must create a fresh private
runtime directory and generate a cryptographically random 32-byte nonce encoded
as 64 lowercase hexadecimal characters. Store it in an absolute, login-user-owned
regular file with mode 0600; one trailing newline is allowed. The loader rejects
symlink files and never accepts nonce bytes in argv. Choose a short absolute runtime path;
`ABS_PRIVATE_RUNTIME/helper.sock` must fit 103 bytes. Loader creates an adjacent
0600 login-user-owned `ABS_PAYLOAD.json` opt-in sidecar containing runtime and
nonce. Existing sidecars, sockets, or journals fail closed. Dock's constructor
reads this private sidecar and starts a listener with no enrollment. Production
`enroll` is an explicit controller request with a fresh full native identity;
fixture `enroll` is restricted to the host's one NSWindow. Do not put real nonce
values in tracked files or published logs.

Loader failures before remote execution deallocate remote allocations/task rights
and remove the new sidecar. After remote execution begins, remote code and stack
allocations are deliberately retained because the separate dlopen pthread may
still execute there. They disappear with Dock process exit. A bootstrap sentinel
alone is not success: loader checks a nonce-authenticated v1 `probe` response on
the new socket, with `getpeereid` and `LOCAL_PEERPID` matching the actual Dock UID
and PID. Only a bootstrap confirmed at its terminal spin sentinel may be terminated. If
that sentinel is not observed, the remote bootstrap thread is left running along
with its allocations and sidecar; local Mach send rights are released. This
avoids killing a thread inside pthread/dyld initialization while it may hold
process-wide locks. Unknown post-execution outcomes require inspection before retrying.

## Protocol v1

One UTF-8 JSON object per newline over AF_UNIX/SOCK_STREAM. At most 4096 bytes
before newline. Server authenticates peer UID with `getpeereid`; socket mode is
0600 inside the validated 0700 directory. Every request includes integer `v:1`,
`nonce`, and `op`. Unknown fields, malformed input, unknown versions and invalid
operations are rejected and connection is closed. There is one serviced
controller at a time, with a small listen backlog. Socket writes have a one-second
timeout; idle and partial input expire two seconds after the last successful
request. A valid `heartbeat` renews the lease; sessions have no total request cap.

- `probe`, `heartbeat`, `restore`: only the common fields above.
- `enroll`: adds `identity:{pid,birth_sec,birth_usec,wid,owner}`. All fields are
  numeric; server independently resolves current owner connection, PID and process
  birth timestamp and verifies process UID equals Dock's login UID. Dirty or
  unresolved recovery blocks changing enrollment. Enrollment snapshots and
  persists the actual original transform before any mutation. When the sidecar
  carries a spike allowlist, enroll refuses (`allowlist scope violation`) any
  identity whose `pid`/`birth` are not listed, before resolving or touching
  anything. Every later mutation re-resolves the enrolled window's identity from the
  window server (`enrolled window identity changed` otherwise) and restates the
  allowlist invariant (`enrolled window left allowlist scope`), so a window that left
  the allowlisted process cannot be mutated.
- `transform`: adds the exact enrolled `identity` and `matrix:[a,b,c,d,tx,ty]`.
  Matrices must contain six finite numeric values with absolute value <=1e6 and
  absolute determinant >=1e-8. Native identity and process UID are revalidated
  before mutation, even after successful enrollment.

Successful `probe`/`heartbeat` includes `identity` (null until enrollment),
`dirty`, `lease_ms:2000`, `scope`, and `readback`. `scope` names the restriction:
`cooperative fixture only`, `spike allowlist: N window(s) only`, or
`explicit same-UID enrollment` when no allowlist is set.

```json
{"readback_ok":true,"matrix":[1,0,0,1,0,0],"bounds":[80,400,480,342],"screen_rect":[80,400,480,342]}
```

Bounds come from `SLSGetWindowBounds`; screen rectangle comes from
`SLSGetScreenRectForWindow`. Transform responses include `set_status`,
`readback_matches_requested`, `recovery_persisted`, `readback` and `ok`.
`ok` requires the requested native transform to be read back, not merely status
zero. A failed set/readback closes the lease and attempts restoration. Restore
responses include `restored`, `reason`, `identity`, `original`, `set_status`,
`readback`, and `recovery_persisted`. Failed operations include `ok:false,error`.
A clean no-op restore has no new recovery write or set status.

All native calls and enrollment state changes serialize on the main queue.
Protocol parsing/socket waits run off the main queue. First mutation fsyncs a
journal before the set; each later mutation persists the same original, never
replacing it with a previously applied camera transform. Disconnect, invalid
request, oversize packet and lease expiry attempt restore, compare actual native
readback with the original and persist the result. Recovery uses exclusive
no-follow files relative to a retained directory FD and atomic rename + fsync.
An unresolved restoration/persistence error disables future mutation. Native
restoration and receipt persistence are tracked separately: an unsuccessful
receipt remains pending even after native readback matches the original. Explicit
restore retries revalidate identity/readback and commit that receipt before
reporting recovery success. Recovery also retries autonomously on the main queue
after 250 ms, then 500 ms, 1 s, and at most once every 2 s while unresolved,
including when no client is connected. At most one retry is scheduled; successful
durable recovery clears the mutation block. Native identity and UID are
revalidated on every retry. There is no deadline that silently abandons recovery.

## Protocol v2

Protocol v2 does for many windows, at display rate, what v1 does for one. It lives
beside v1 in the same payload (`payload-v2.m`, compiled into `payload.m`); v1's
socket, code path and replies are unchanged. Constants and structs: `protocol2.h`.

The desktop shell now uses this client for its explicitly scoped
[cooperative native presentation mode](../desktop/README.md#native-presentation-through-a-cooperative-helper).
Its fixture test independently checks transform and alpha restoration through
normal quit, client death and a stalled main thread. Cooperative helpers remain
limited to their own process. The desktop can also accept an allowlist helper
after its negotiated `ENROLLMENT` audit matches exactly the desktop's `--only-pid`
PIDs and birth timestamps. Same-user scope is refused. This prepares broader
support in code; it does not validate a Dock host or third-party native compositing.

**Transport.** A second listener, `RUNTIME/v2.sock` (0600, same 0700 directory,
peer UID checked with `getpeereid`). A JSON line with `v:2` on `helper.sock` is
still refused by v1. Messages are binary, little-endian: a 16-byte header
`{u32 length, u16 type, u16 flags=0, u64 seq}` and `length` body bytes, at most
131072. A reply carries `type|0x8000` and the request's `seq`. A bad header, a
wrong body length, an unknown type or a frame `seq` that does not rise (the first
must be above 0) is a protocol error: the connection is closed. At most 8 connections are held, each on its own
thread; the first message must be `HELLO` and arrive within 2 s. The count includes
connections that have not yet said `HELLO`, so a process of the same user without
the nonce can keep a new controller out for as long as it keeps eight of them open
(it cannot move a window or disturb a live session); not addressed in this stage.

| Type | Body | Reply body |
|---|---|---|
| 1 `HELLO` | `"DWv2"`, u16 version 2, u16 role (1 control, 2 heartbeat), 64-byte nonce, 16-byte token (zero for control) | u32 status, lease_ms 2000, max_records 1024, max_body, caps (bit 0 alpha, bit 1 per-window restore, bit 2 scope audit, bit 3 explicitly enrolled fixture family), scope (1 cooperative, 2 allowlist, 3 same user), queue (0 own, 1 main), i32 server pid, 16-byte token |
| 2 `FRAME` | u32 count, u32 0, count × 80-byte record | u32 disposition (0 applied, 1 dropped), u32 count, u32 superseded, u32 0, u64 frames applied in total, count × u8 status |
| 3 `HEARTBEAT` | empty | u32 status, lease_ms, held, restoring |
| 4 `RESTORE_ALL` | empty | u32 count, pending, journal_persisted, 0, count × 32-byte result |
| 5 `PROBE` | empty | counters, then one 112-byte entry per table window, then (cooperative scope only) the host's own window identities |
| 6 `ENROLLMENT` | empty; requires capability bit 2 | u32 scope, count, i32 server pid, u32 0, then count × `{i32 pid, u32 0, u64 birth_sec, u64 birth_usec}` |

`ENROLLMENT` reads the fixed process scope and changes nothing. A cooperative
reply contains its one host instance; an allowlist reply contains all enrolled
instances; same-user scope has no finite list. There are at most 1024 entries.
The C client rejects inconsistent scope/server identity, duplicates, malformed
timestamps, trailing data and insufficient output space. Allowlist parsing also
rejects fractional/negative identities, duplicates and oversized lists. A legacy
cooperative helper still works without this capability; a legacy allowlist helper
cannot be accepted by the desktop. `v2client enrollment RUNTIME NONCE` is a
read-only CLI audit; `fixture_v2_test.py --enrollment` runs only that owned-host
scenario and independently checks unchanged native geometry, transform and alpha.

Before allocating frame buffers, the C client bounds the negotiated frame count,
body size and lease and validates scope and queue enums. The server PID must be
the Unix socket's kernel `LOCAL_PEERPID`; control and heartbeat handshakes must
match exactly, including their session token. Reply headers and record statuses
are validated. A heartbeat that supplies only part of its reply remains bounded
by the lease, then closes both connections so helper restoration can proceed.

`HELLO` status: 0 ok, 1 wrong nonce, 2 wrong magic or version, 3 another session
is live, 4 unknown token, 5 malformed. Anything but 0 closes the connection.

A record is `{i32 pid, u32 wid, u64 birth_sec, u64 birth_usec, f64 m[6], f32 alpha,
u32 flags}`: the window as the shell holds it (no owner connection: the helper
resolves and records that itself), the affine `a,b,c,d,tx,ty` from screen to
window-local in global top-left points, and an alpha that is used only when flag
bit 0 is set. Matrices obey v1's bounds; alpha must be within 0..1. When capability
bit 1 is negotiated, a record with flag bit 1 alone restores that identity's
journalled original; its matrix and alpha fields are ignored. Combining the two
flags is malformed. Restoration wins over a transform of the same window in
that frame: the transform receives status 8. Record status:
0 applied, 1 out of scope, 2 identity (no such window, or not that process
instance, or not this user), 3 matrix, 4 alpha (invalid, or the capability is
absent), 5 the original could not be read, 6 the journal could not be written,
7 not applied (the set failed or read back differently; the window stays in the
table because it may have been changed), 8 a restore of this window is still
pending, 9 protocol v1 holds a window, 10 table full (1024), 11 malformed. For a
transform record, "applied" means the set returned 0 **and** the value read back equals the request after
rounding to 32-bit floats, which is how the window server keeps a transform; status
0 alone is never enough.

**Session.** A control `HELLO` with the nonce opens the one session and returns a
random token. A heartbeat connection is a second connection whose `HELLO` carries
that token. The session ends when the control connection closes, on a protocol
error on it, or when the lease runs out; closing a heartbeat connection ends
nothing. Ending a session restores everything (below).

**Frames: the newest wins.** A frame names any number of windows (up to 1024; the
largest is 81 944 bytes, far over v1's 4096). The connection thread reads up to
64 KiB at a time and never waits for the window server: a complete frame goes into
a one-frame slot, replacing a frame still waiting there. The replaced frame is
never applied and gets no reply of its own; the next reply's `superseded` counts
it, so a reply for `seq` m answers every unanswered frame up to m. A slow window
server therefore applies fewer frames, not later ones, and the last frame sent is
always applied. One bad or stale record fails by itself: the rest of the frame is
applied and the session and lease go on. `RESTORE_ALL` and the end of the session
discard a waiting frame (it is answered with disposition 1); a frame sent after
`RESTORE_ALL` is applied after it. `PROBE` is answered in turn on the same queue
and reports what is true when it runs. A reply waits for its reader for at most
250 ms, on the apply queue: a client that leaves a reply unread that long loses its
connection.

**Table and journal.** The helper keeps a table of every window it has touched,
with what the window was before the first touch: transform, alpha (when the
capability is present, whether or not that record sets it), bounds, and the owner
connection it resolved. The capture happens before the first change. The journal,
`RUNTIME/v2-journal.json` (staged at `v2-journal.next`, written like v1's:
exclusive no-follow staging, fsync, rename, fsync of the directory; `recovery.json`
is v1's and is not touched), lists the table with those originals. It is written
when a frame brings windows into the table, once for the whole frame and before any
of them is changed; when a window's alpha is changed for the first time (the journal
then says its alpha must be put back); and when windows leave the table. A frame of
known windows writes nothing. If it cannot be written, the new windows get status 6
and are not changed. `generation` and the probe's `journal_writes` count the writes.
A staging file left by an instance that died mid-write is removed at the next start,
before the journal is read.

**Restore.** Everything is put back on an explicit `RESTORE_ALL`, when the control
connection closes, on a protocol error, and when the lease runs out. For each
window the helper resolves the identity again: if it is still the recorded window
of the recorded process instance on the recorded connection, in scope, the original
transform (and alpha, if it was changed) is set and read back: `restored`, and the
window leaves the table. If the window or its process is gone, or the number now
names something else, nothing is touched: `gone`, and it leaves the table. If the
set or the readback fails, or the window is listed but cannot be resolved, it stays
as `pending`: it blocks nothing else, records naming it get status 8, and it is
retried after 250 ms, 500 ms, 1 s and then every 2 s without a deadline, as v1
retries its one window. After full restoration with nothing pending the table is empty and the
journal says `"state":"empty"` with the per-window results under `last_restore`. A
journal that could not be written after a restore is retried on the same schedule.
Restores made without a request are logged to stderr as `V2_RESTORE {json}`.

A negotiated per-window restore record marks only its recorded identity for
restoration, using the same original values, identity checks, journal and retry
path. Other held windows keep their transforms and alpha. Status 0 means it was
restored or has no held entry (including one already restored or gone); status 8
means restoration remains pending, and status 6 means the journal update remains
pending. The desktop retains release records until acknowledged and retries them
at most four times per second while frames are being submitted. Rebinding starts
a new sequence, so an older release acknowledgement cannot remove that request.
An older helper without the capability causes the desktop to restore and end the
whole session when a window is unbound.

**Lease and heartbeats.** The lease is 2000 ms. Any valid message on either
connection renews it; a heartbeat is answered on its own connection's thread from
counters and never waits for the window server. So a sender whose frame loop is
stalled while its process is alive (its heartbeat thread still beating on the second
connection) keeps its windows where they are; a process that died closes its
connections and is restored at once; a process that is stopped or hangs in every
thread is restored when the lease runs out. **A caller hung for good in its own
thread, in a process that is otherwise alive, keeps its windows without end:** the
library's heartbeat thread beats whatever the caller does, which is what keeps a
stalled frame loop from losing them. Bounding that (the heartbeat stopping when the
caller has not checked in for some seconds) belongs to the shell stage. Likewise a
window-server call that never returns stalls the apply queue and the restore queued
behind it while heartbeats are still answered; a client sees it only as a
`last_applied_seq` that stops rising.

**Scope** is enforced in the payload as v1 enforces it, from the record alone
before any lookup and again after resolving, for every record of every frame and
every window of every restore: the cooperative host only its own pid and the
windows it was started with; with a spike allowlist only the listed process
instances; otherwise only windows of processes of the helper's own user. One
protocol holds windows at a time: while v2's table is not empty v1's `enroll` and
`transform` fail with `protocol v2 holds windows`, and while v1 holds its window v2
records get status 9.

**Where the calls run, and what is not known.** v1 serializes its native calls on
the process's main queue. In Dock that would put every frame behind Dock's own UI
work and would stop restores whenever Dock's main thread stalls, so v2's native
calls, its table, its journal, restore and the retries run on the helper's own
serial queue; socket reading, heartbeats and the lease watch run on connection
threads. **Whether the window server accepts these calls from a thread other than
the main one inside Dock on macOS 27.2 is not known.** yabai makes them from its own
thread, and the cooperative host accepts them here, but neither is evidence about
Dock on this build: it is one of the things the owner's spike will show. The choice
can be flipped without rewriting: `DW_V2_MAIN_QUEUE=1 ./scripts/build-privileged.sh`
builds a payload that uses the main queue; the sidecar key `"v2_queue":"own"|"main"`
overrides the build (any other value refuses to start); the cooperative host takes
`--v2-queue`. The loader does not write that key today, so for Dock the build-time
switch is the usable one.

**A helper that died holding windows.** A dead process restores nothing. At its
next start on the same runtime directory v2 reads `v2-journal.json`: each recorded
window is restored only if its whole recorded identity (pid, start time, window
number, owner connection) still resolves to the same process instance and passes
the new instance's scope, and the value written is the one captured before any
helper touched the window; the others are recorded as `gone`. A journal that cannot
be parsed, or a `v2.sock` already there, leaves v2 off (v1 still starts) with one
line in the log; the loader's fresh-runtime check does not look at v2's files. The loader and v1 still demand a fresh
directory, so in Dock this path waits for the per-instance runtime of a later stage.

**Client library** (`dwclient.h`). `dw_client_open` (bounded by its timeout,
retrying while another session is live), `dw_client_submit_frame` (copies the
records into a one-frame slot for a writer thread and returns; it never touches a
socket), `dw_client_probe`, `dw_client_restore_all` (bounded waits), a heartbeat
thread on the second connection every quarter lease, and a `lost` callback, fired
once when either connection ends, a write does not complete within a second, or no
heartbeat is answered for a whole lease. On loss the library closes its side, so the
helper restores as soon as it can; there is no automatic reconnect. Its clock is
`CLOCK_UPTIME_RAW`, which stops during sleep as the helper's lease clock does, so
waking the machine is not a loss. `dw_client_open` returns `DW_CLIENT_NO_V2`
instead of a timeout when the runtime has `helper.sock` and no `v2.sock`: a helper
whose v2 did not start. A `v2.sock` left by a dead helper still reads as a timeout.

**Tested** (`fixture_v2_test.py`, cooperative host with eight windows; rectangles
are the window server's `SLSGetScreenRectForWindow` and alpha is `kCGWindowAlpha`,
both read from the test process; the journal is read from disk): a frame of eight
with two alphas; a second frame with non-dyadic values; a missing window and a
wrong process birth failing alone among good records (in cooperative scope the
missing number is refused as out of scope, status 1, before any lookup; only the
wrong birth reaches the identity check); a frame over 4096 bytes; a burst of 2000
frames, each drawing a rectangle no other does, ending exactly at the last frame's
with fewer applied than sent (the applied count is the helper's own, from replies
and counters); the
journal written once for all those frames; restore-all; close without restore-all;
a malformed message; a heartbeat connection alone holding for three leases and
letting go one lease after it stops; SIGKILL of a client; an obstructed journal;
the client library at 120 Hz for five seconds; the helper's process stopped under a
running sender and under an idle one; the helper killed while holding (only the
`gone` path: its windows die with it), with a staging file left behind; a helper
whose v2 did not start, as the library reports it; the main-queue switch; allowlist
refusal; and v1/v2 exclusion. The focused
`python3 native/privileged/fixture_v2_test.py --release-window` case also passed:
exact original transform and alpha restored for one released window, seven other
windows unchanged, scope and malformed-flag refusals, repeated release, rebind,
and release versus transform in the same frame. These transforms and alpha are
read over the test's independent WindowServer connection. **Not tested:** anything in Dock; any window of
another process; another user's session; a native set or readback that fails (so
`pending` and its retries run in no test); a window of the table that closes during
a session; statuses 7, 8 and 10; startup recovery of a window that still exists;
the library across a real sleep and wake; a failed thread start in the library; the
accept loop's wait when descriptors run out.

**Later stages:** ordering, levels and sub-level; native move and Spaces; pruning
closed windows when a client never sends their per-window release; the restore
target for a window moved natively after first touch; skipping unchanged records;
reconciling a previous Dock instance's journal, the per-instance runtime and the
fixed-path loader; a loader-written `v2_queue`; third-party shell integration.

## Recovery limits and evidence

A process crash, forced server termination, suspended/hung Dock/main queue, or
machine failure cannot execute an in-process timer or restoration. A durable
`recovery.json` remains pending for a controller to inspect and reconcile against
fresh identity. There is no automatic post-crash recovery agent in this increment;
helper refuses to start over any existing journal. Never replay a journal against
only a numeric window ID. These tests kill only their own fixture host at cleanup.

`evidence/fixture.json` and `evidence/host.log` preserve the focused passing run.
They prove cooperative transport, real WindowServer geometry, private modes,
identity/schema validation and disconnect/lease restoration. The fixture also
creates a directory at its own `recovery.next` staging path to induce a real
persistence failure after native restoration. It verifies failed retry responses,
blocked mutation, durable explicit retry and autonomous recovery after removing
that obstruction without another client request. This controlled filesystem
fault does not introduce a production fault-injection API. Native API restoration
failure itself is not injected or proven by that persistence regression. They do not prove
Dock injection, foreign-window authority, cross-UID behavior (enforced in code but
not tested using another user's session), or usable third-party compositing.
No loaded helper or temporary window remains after E2E cleanup.

## Dock spike (owner-run)

The spike answers, on this OS build, whether Infinify's helper loads into Dock
(1a), and whether a transform issued from Dock's connection draws **another
process's** window scaled at a target rectangle while a real click there reaches it
(1b) — then puts the window back. It is driven by `native/privileged/spike.py`
(`--dock`) through `scripts/spike-compositor.sh`.

**What it establishes.** That the helper loaded (loader exit 0 after its own
authenticated probe of Dock); that the allowlisted scope refused two deliberately
out-of-scope enrollments before touching anything; that a half-size transform read
back exactly as requested and a 240-step slide held frame rate; and — resting
**only** on the owner's own answer plus the fixture's click count rising after a
real click — whether the scaled window was actually displayed and clickable. A
status code, a resolved symbol, or the fixture's own self-report is never treated as
proof of display; the evidence file's `claims` object says what each claim rests on.

**What it does not establish.** Anything about real third-party application windows
(it touches only one disposable fixture), occlusion, menus, multi-window behaviour,
latency against a live shell, or protocol v2. Those are later, separately scoped.

**Owner-only preparation.** Each command changes the machine and is run by the owner.
These are the yabai wiki's commands for Apple Silicon macOS 13+
(https://github.com/asmvik/yabai/wiki/Disabling-System-Integrity-Protection, read
2026-10-10); they are **not yet tried on macOS 27.2**.

1. Relax SIP. In Recovery (hold the power button for startup options → Options →
   Terminal): `csrutil enable --without fs --without debug --without nvram`, then
   reboot. This downgrades machine-wide SIP (filesystem and task-port protection).
   Undo: `csrutil enable` in Recovery, reboot.
2. Allow third-party arm64e code: `sudo nvram boot-args=-arm64e_preview_abi`, then
   reboot. This changes NVRAM boot-args. Undo: `sudo nvram -d boot-args`, reboot.

`target/privileged/doctor` (read-only) must then report `injection_preflight_passed`
before the spike will do anything; with SIP on it reports 0 and the driver stops,
having started and changed nothing.

**The one command.** `./scripts/spike-compositor.sh` (it builds, then runs
`spike.py --dock`). The script never runs sudo itself; only the driver's own step
does, letting sudo prompt on your terminal.

**Before running it.** Quit Infinify itself (Control-Option-Escape): its canvas
covers every window, the test window included, and the driver stops if it finds it
running.

**What the owner sees and is asked.** A test window titled "DriftWM disposable spike
fixture" opens at the lower left of the main display. It stays above other windows
and never takes the keyboard, so the terminal cannot cover it and the password goes
to the terminal. The driver waits until the window server shows it where AppKit put
it, prints the fixture's pid and window number, then the exact
`sudo target/privileged/loader-arm64e --inject-dock … --only-pid PID` line (the nonce
is never printed) and runs it; sudo prompts for the password on the terminal, and
whatever the loader says is printed. The driver then enrolls the fixture, draws it at
half size 120 points down and right, asks the owner to click the big button once
(waiting up to 90 s for the click count to rise), and asks what they saw: `y` for
half size at the new place, `n` for unchanged or not visible, or a few words. It
records the answer verbatim, runs the slide loop, restores, and prints a five-line
result. A run that stops early prints `STOPPED:` with the reason, and says whether
anything was loaded into Dock. The driver resolves the foreign fixture's owner connection with
`SLSMainConnectionID`/`SLSGetWindowOwner` (via ctypes on SkyLight), since a foreign
window's owner is not otherwise available to it.

**Afterwards.** The helper stays loaded inside Dock — listening, holding nothing —
until Dock restarts. `killall Dock` relaunches Dock clean and removes it. Left on
disk afterwards: the 0600 sidecar `target/privileged/payload-arm64e.dylib.json` and
the fresh runtime directory under `target/privileged/spike-…`; delete both before a
new run (the loader also fails closed on a stale sidecar, socket or journal). The
evidence is written to `target/privileged/spike-evidence.json`.

**Safety.** The spike transforms exactly one disposable fixture window that the
driver spawned, and the `--only-pid` allowlist makes the payload refuse every other
window whatever a client sends. It restores on every exit path, including Ctrl-C. It
never changes SIP, boot-args, permissions or any other window.

The loader takes the nonce as a command argument, so for the one sudo run it is
briefly visible in `ps` and recorded by sudo's command logging. It is bounded by the
payload's same-UID `getpeereid` peer check, the 0700 runtime directory and the
allowlist, and the driver never prints it. A stop before injection — SIP preflight
not passed, or a stale sidecar present — writes `target/privileged/spike-preflight.json`
and never touches `spike-evidence.json`, so it cannot clobber a real run's evidence.

The cooperative half (`spike.py --cooperative`) exercises the same driver body —
socket handling, the heartbeat thread, the affine, the readback checks, the 240-step
loop, restore, the finally path and the evidence file — against the cooperative host
and its own window, with no Dock, no sudo and no owner; the owner-only steps become
recorded skips. It is the developer- and reviewer-run check of the driver;
`tests/e2e/privileged-fixture.sh` runs only the cooperative `fixture_test.py` and
`fixture_v2_test.py`.

## Attribution

`loader.m` retains the full MIT license and copyright from yabai at commit
`dd845723416f5fe92af49fad5ebab00369e07edd`, plus its Jeremy Legendre arm64e path
attribution. `YABAI-LICENSE.txt` is the exact upstream license. Loader changes
are documented in its header. Other files are original GPL-3.0-or-later code;
private ABI declarations were cross-checked against that same yabai revision. The
three optional declarations protocol v2 uses (`SLSGetWindowAlpha`,
`SLSSetWindowAlpha`, `SLSConnectionGetPID`) follow that revision's
`src/misc/extern.h` and say so where they are declared in `payload.m`.
