# WindowServer-resident fixture prototype

This GPL-3.0-or-later experiment now applies native transforms inside the pinned
WindowServer of the disposable macOS27.0.1/26A434 VM. It is a finite,
transform-only benchmark, not a production desktop backend. All builds, tests,
preflight and execution belong in that VM, not the owner's laptop.

See [the measured comparison](../performance/RESULTS-WINDOWSERVER-20261025.md)
and [the server ABI and exact provenance](SERVER-ABI.md).

## Build in the VM

```sh
sh scripts/build-windowserver-prototype.sh
```

This only compiles and signs the arm64e payload/loader and arm64 C mailbox client.
No payload is loaded by building. The loader with no arguments or `--preflight`
is read-only. Root preflight reports the expected server PID/birth and image pins;
it is not evidence that native transforms work.

The explicit invocation remains:

```text
ws-loader-arm64e --inject-windowserver ABS_PAYLOAD ABS_RUNTIME
  --fixture ABS_FIXTURE_MANIFEST --nonce-file ABS_NONCE_FILE
  --lifetime-ms 60000 --expected-server PID BIRTH_SEC BIRTH_USEC
```

The loader verifies the exact supervised disposable process, executable hash,
process birth, UID, parent and explicit window list. The manifest remains JSON
schema1 and the messages retain DWv2. Binary config is version3 (`IFWSP03`);
older sidecars are refused. It adds server/fixture kernel identity, boot/image
hashes and pinned runtime/file inodes. Existing root birth/hash/parent checks
bridge to strict kernel uniqueID, executableUUID and PIDversion guards inside
the server. There is no PID-only fallback.

Stage only a fresh controller-owned0700 runtime and fresh controller-owned0700
`/Library/GPUBundles/InfinifyPerf-*` payload directory. The loader changes ownership
and permissions only on these experiment artifacts. It records originals before
execution. The reviewed guest allows executable GPU bundle mappings and temporary
file I/O. No sandbox profile is modified.

## File transport

The earlier Unix listener failed with a sandbox `network-bind` denial. The working
transport uses two fixed-size file mappings in the short temporary runtime:

- `requests.shm`: controller owns0600; server has one read-data-only named ACL.
- `replies.shm`: server owns0600; controller has one read-data-only named ACL.

The server-owned0711 directory has no extended ACL. It prevents the controller
from replacing the pinned entries. Both sides verify no symlinks, single-link
regular files, exact owners/modes/sizes and pinned inodes. Peer mappings are
read-only. Control and heartbeat have separate bounded SPSC lanes; a complete
packet is release-published and its slot is not reused before consumption.
Shared-address wait/wake uses Apple's public `os_sync_wait_on_address` API.
A combined doorbell prevents lost heartbeat wakes; wake-all handles both client
threads. No network listener or broad world-readable/writable mailbox is used.

The reply file contains a nonce-bound HMAC attestation of server kernel identity,
boot, image/payload/config hashes and a constructor-based deadline. The loader
checks it against its captured config. The native client verifies it and the
actual current kernel process identity before HELLO. Nonce/token and exact
fixture scope remain mandatory. There is one control producer and one heartbeat
producer, with monotonic generation/ring counters across sequential sessions.

Consecutive complete FRAMEs may coalesce to the newest pose. INSPECT, PROBE and
RESTORE remain ordered barriers. A lost controller, lease expiry or malformed
traffic requests exact restoration before rearm. The fixed outer lifetime is
still at most60seconds; it bounds admission, not preemption of an executing or
stalled server callback. Final restore cannot be canceled while queued. After
the worker ends, the dylib remains resident until that server exits. Retain its
payload/sidecar until initialization and restoration are resolved.

The C client separates shutdown from close: shutdown wakes bounded IO while
retaining storage; threads finish before unmapping. The Python adapter never
unmaps storage still borrowed by an active native call.

## Native operations and proof

Native operations are unchanged: a reviewed default-session/main-context adapter
calls real server routines, including one `CGXSetWindowTransformList` for a frame.
Exact raw128-byte original placement matrices and flags are retained. Unsupported
initial stack state, unreviewed image hashes or changed identities are refused.
There is no alpha, Spaces, pinning or arbitrary-window enrollment support.

The VM smoke submitted240poses and independently verified final placement and
exact restoration. Captured display pixels provide separate observation evidence.
This establishes operation on the named fixture; it does not establish third-party
application usability or physical input-to-photon latency.

All bootstrap MIT licensing and exact yabai provenance remain in `bootstrap.h`:
`asmvik/yabai` commit `dd845723416f5fe92af49fad5ebab00369e07edd`,
`src/osax/loader.m`, with arm64e-path attribution to Jeremy Legendre. New source
is GPL-3.0-or-later. No Apple implementation is copied. The independently named
kernel ABI records retain exact XNU source pins in `kernel-process-identity.h`.
