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
- `client`: POSIX socket client with JSON encoding. Invocation:
  `client PRIVATE_RUNTIME NONCE64HEX`. Reads JSON lines from stdin, adds `v` and
  `nonce`, prints responses, closes on stdin EOF or rejected operation. Holding
  stdin open does **not** send heartbeats automatically.
- `loader-arm64e`: explicit Mach loader adapted from yabai. Merely building it
  does not execute it. Its only accepted action is:
  `loader-arm64e --inject-dock ABS_PAYLOAD ABS_PRIVATE_RUNTIME NONCE64HEX`.
  This is **not exercised** by tests or this implementation task. It requires
  a separately reviewed, explicitly authorized manual run under compatible
  SIP/boot/library-validation policy and sufficient task-port authority. It never
  changes policy, runs sudo, restarts Dock, or modifies windows itself.

Before an authorized loader run, the login user must create a fresh private
runtime directory and generate a cryptographically random 32-byte nonce encoded
as 64 lowercase hexadecimal characters. Choose a short absolute runtime path;
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
  persists the actual original transform before any mutation.
- `transform`: adds the exact enrolled `identity` and `matrix:[a,b,c,d,tx,ty]`.
  Matrices must contain six finite numeric values with absolute value <=1e6 and
  absolute determinant >=1e-8. Native identity and process UID are revalidated
  before mutation, even after successful enrollment.

Successful `probe`/`heartbeat` includes `identity` (null until enrollment),
`dirty`, `lease_ms:2000`, `scope`, and `readback`:

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

## Attribution

`loader.m` retains the full MIT license and copyright from yabai at commit
`dd845723416f5fe92af49fad5ebab00369e07edd`, plus its Jeremy Legendre arm64e path
attribution. `YABAI-LICENSE.txt` is the exact upstream license. Loader changes
are documented in its header. Other files are original GPL-3.0-or-later code;
private ABI declarations were cross-checked against that same yabai revision.
