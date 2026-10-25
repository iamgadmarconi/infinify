# WindowServer-resident pan/zoom experiment

This is a separate, one-shot benchmark backend for an explicitly spawned
disposable fixture. It does not change the app's backend, inject into Dock,
install an agent, or change SIP, permissions or user settings. Building only
compiles and signs files. With no arguments the loader performs read-only
preflight; it never obtains a task port in that mode.

The payload is C with no AppKit dependency. It runs **inside WindowServer** and
uses reviewed server routines directly, rather than calling SkyLight client
stubs back into the server. Each operation is hoisted onto the server's main
execution context with its default session installed. A frame calls the genuine
`CGXSetWindowTransformList` once for all accepted fixture windows. Original raw
128-byte placement-zero matrices and flags are retained for exact restoration.
The adapter refuses unsupported transform state and every unreviewed image.
See [the exact guest ABI and code pins](SERVER-ABI.md).

The first supported image is the throwaway macOS 27.0.1 guest, build 26A434,
SkyLight UUID `8A3B348E-4637-3685-92D0-6CBC2F36A234`. Other images are refused;
symbol presence alone does not establish an ABI or authorize mutation.

## Build and invoke

Compile/sign without running either artifact:

```sh
./scripts/build-windowserver-prototype.sh
```

The artifacts are `target/windowserver-prototype/ws-loader-arm64e` and
`payload-arm64e.dylib`. All execution and tests belong in the disposable VM;
do not run this experiment or its preflight binary on the owner's laptop.

In the VM, first run the read-only loader preflight as root (an ordinary process
may be unable to read WindowServer's process identity):

```sh
sudo /absolute/path/ws-loader-arm64e --preflight
```

Its JSON reports the exact server PID, UID, birth and reviewed-image result.
Policy and hash checks do not prove task access, successful loading, usable
native output, or performance. Create a new controller-owned 0700 runtime and a
separate fresh controller-owned 0700 `/Library/GPUBundles/InfinifyPerf-*`
directory for the executable payload. The payload and its adjacent `.ifwsp`
sidecar use the GPU bundle directory; the intended `v2.sock` and
`restoration.txt` paths use the short temporary runtime. This staging allowed
the current payload to load and initialize, but it does **not** authorize a
socket listener: the WS09 VM trial was denied at `network-bind` for
`/private/tmp/ifp-*/v2.sock`. File ownership and temporary-file access do not
establish network-bind permission. This staging changes no sandbox profile.
A controller-owned 0600 nonce file contains 64 lowercase
hexadecimal characters. The fixture supervisor must remain alive through the
run and cleanup.

The explicit root invocation is:

```text
ws-loader-arm64e --inject-windowserver /Library/GPUBundles/InfinifyPerf-UNIQUE/payload-arm64e.dylib /tmp/ifp-UNIQUE
  --fixture ABS_FIXTURE_MANIFEST --nonce-file ABS_NONCE_FILE
  --lifetime-ms 60000 --expected-server PID BIRTH_SEC BIRTH_USEC
```

All paths must be absolute. Both prepared directories must be fresh. The loader
also accepts a payload directly inside its runtime, but the current VM
orchestrator uses the split layout above. A separate payload directory is
accepted only directly beneath `/Library/GPUBundles`, with the
`InfinifyPerf-` prefix and exact controller ownership/private mode before load.
The loader verifies the
manifest's fixture PID, process birth, UID, supervisor parent PID, native window
list and actual executable path/hash. Binary config **version 2**, magic
`IFWSP02`, also carries an immutable kernel fixture identity: PID/UID, kernel
unique process ID, executable UUID and PID version. The root loader captures
that token before hashing the fixture executable, then rechecks the token and
the original manifest birth/parent identity after hashing and before remote
writes/thread execution. The payload uses the strict shared kernel guard for
cross-UID fixture checks; it does not fall back to PID alone or a failed query.
The server's own full BSD birth check remains in place. Config version/size
checks refuse older sidecars. See [the identity bridge](SERVER-ABI.md#fixture-process-identity-bridge).

The loader fsyncs this fixed binary sidecar containing the identities and
original transforms before any remote execution. It then
stages the runtime and separate payload directory for WindowServer's UID:
directories 0711, payload 0500, sidecar 0400. Ownership changes affect only the
newly prepared experiment files. The orchestrator retains both directories and
their exact paths; later cleanup requires root after initialization and
restoration are resolved. Do not remove payload/sidecar files while remote
initialization is unresolved.

The loader's success report verifies the socket peer's actual server PID/UID.
It does not submit a transform. A false or missing readiness report is an
unknown outcome once remote execution started; retain the runtime and inspect it.
Never restart WindowServer or blindly retry injection.

## Fixture manifest and protocol

The fixture manifest is JSON schema 1 with
`fixture_kind: "infinify-disposable-cooperative-host"`, `pid`, `birth_sec`,
`birth_usec`, `uid`, `host_path`, `host_sha256`, `supervisor_pid`, and an explicit
`windows` array. Each entry contains `wid`, `owner`, `transform[6]`, `bounds[4]`
and `screen_rect[4]`. The benchmark fixture supervisor supplies independent
read-only native observations for these fields; JSON labels alone do not prove
that a window is disposable.

The intended endpoint is `ABS_RUNTIME/v2.sock`; its listener is currently
blocked by the VM's WindowServer sandbox. The implementation accepts the
existing little-endian DWv2 layouts: HELLO, FRAME, HEARTBEAT, RESTORE_ALL, PROBE,
ENROLLMENT and INSPECT. It advertises ALLOWLIST scope and
ENROLLMENT/INSPECT/RESTORE_WINDOW capabilities. Frames are transform-only:
no alpha, pinning, Spaces or arbitrary-window enrollment. Unix peers must match
the configured controller UID and authenticate the nonce/token. The socket peer
is WindowServer's UID, so clients must explicitly verify that UID/PID rather
than assume their own UID. The fixed originals sidecar replaces the production
helper's dynamic journal for this finite experiment; this is not a replacement
production recovery protocol.

The endpoint permits **one control session at a time**. Its fixed outer lifetime
bounds admission of new requests to 1–60 seconds. On control loss or malformed
traffic it restores the exact originals, then accepts another session only if
restoration succeeded. New tokens and frame counters separate successive trials;
scope and originals remain fixed. A lease expiry or outer lifetime ends admission
and requests original restoration. An executing or
stalled server cannot be preempted; final restoration remains queued until its
main context can run. The supervisor must retain the fixture until independent
restoration checks finish, then close the exact child. `restoration.txt` records
the remaining in-memory restore count; the external geometry/raw checks remain
the acceptance evidence.

Consecutive complete FRAME messages already waiting in the socket are coalesced
to the newest camera pose, with superseded counts in the ordinary DWv2 reply.
PROBE, inspection and restoration remain ordered barriers. No partial future
frame is waited for while draining, and no frame backlog is intentionally built.

After the outer lifetime ends, the dylib remains resident. Reopening the same
path does not rerun its constructor. Run all timing phases/repetitions within
that one bounded lifetime; there is no permanent rearm hook.

## Evidence boundaries

The WS09 VM startup trial on 2026-10-25 passed constructor entry, sidecar
validation, server/fixture identity checks, reviewed ABI binding and worker
thread startup. It then failed at socket bind: the sandbox denied
`network-bind` on `/private/tmp/ifp-*/v2.sock`, with errno 1 (`EPERM`). The
listener never became ready, no FRAME ran, and there are no WindowServer
pan/zoom or latency measurements. This locates the current blocker after
identity/ABI admission; it does not prove the server transform path works.

No WindowServer-versus-Dock performance winner is established. Neither the
loader nor payload edits the sandbox policy to resolve this failure. The
60-second maximum remains unchanged; an unresolved startup is not permission
to extend it or reopen the same resident payload.

Compilation and source/disassembly checks establish only that this experiment
builds against the reviewed guest image. Actual transform application, optical
native-window cadence, input, restoration under all failures, and any advantage
over the Dock backend require separate VM evidence. Applied counters and native
geometry readbacks cannot stand in for optical frame rate or input latency.
No WindowServer-versus-Dock performance claim follows from these sources.

All new implementation is GPL-3.0-or-later. `bootstrap.h` retains the MIT licence
and exact yabai source provenance from `native/privileged/loader.m`:
`asmvik/yabai` commit `dd845723416f5fe92af49fad5ebab00369e07edd`,
`src/osax/loader.m`, with arm64e-path attribution to Jeremy Legendre. The loader
uses those isolated bootstrap bytes without changing the production Dock loader.
No Apple implementation is copied; the ABI documentation records observations
from the installed guest image. The kernel identity declarations are
independently named ABI records checked against Apple XNU commit
`f6217f891ac0bb64f3d375211650a4c1ff8ca1ea`; exact source hashes and references
are retained in `kernel-process-identity.h` and the identity bridge documentation.
