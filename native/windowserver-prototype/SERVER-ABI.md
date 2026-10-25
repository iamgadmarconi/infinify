> Update: binary config is now version3 (`IFWSP03`) with file-backed directional
> transport. The server routine ABI and code pins below are unchanged. The earlier
> network-bind blocker is resolved without a sandbox edit; actual fixture mutation,
> exact restore and captured-pose results are in
> [the completed comparison](../performance/RESULTS-WINDOWSERVER-20261025.md).

<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# WindowServer prototype: reviewed server ABI

This adapter calls WindowServer's real, process-local implementation. It does
not call `SLSSetWindowTransform` or another client stub from inside the server.
It is independent of the application and production Dock helper.

The implementation was derived from read-only inspection of the Apple binaries
listed below. No Apple implementation or instruction bytes are copied into this
source tree. The adapter itself is new GPL-3.0-or-later code. Runtime code hashes
are compatibility checks, not evidence of correct native presentation.

## Exact enabled image

- System: Apple Silicon macOS **27.0.1**, build **26A434**, in the disposable UTM
  guest. The product version is the value returned by that guest's `sw_vers`.
- Image: `/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight`.
- Image UUID: `8A3B348E-4637-3685-92D0-6CBC2F36A234`.
- Unslid image base: `0x187093000`.
- Inspection: Apple's `/usr/bin/dyld_info -uuid -segments -disassemble` plus
  guest-only `dladdr` and SHA-256 over the indicated loaded code ranges. These
  inspections called no window getter, setter, server routine, or injection API.
- Reviewed disassembly is retained in ignored
  `target/ws-abi/guest-skylight-disassembly.txt`. Host comparison disassembly is
  `target/ws-abi/skylight-disassembly.txt`.

Only this guest image is enabled. The laptop's macOS 27.2/26B118 image, UUID
`1AD26AFB-B313-3086-95F0-43FC18B8FBCA`, was inspected as a comparison but is
deliberately absent from the adapter's allowed image table. No prototype
executable or payload was launched on the laptop. Compilation is separate from
runtime validation.

The following names are local symbols, not `dlsym` exports. The adapter locates
SkyLight through its exported `SLXServer`, validates the Mach-O UUID, hashes every
complete indicated routine, and signs the reviewed offsets as arm64e function
pointers. A differing image or code range disables the adapter.

| Local server routine | Unslid address | Bytes hashed | Role |
| --- | --- | ---: | --- |
| `WSSessionDispatchMainBlockAsync` | `0x1872b5098` | 204 | Serial/main-context callback with selected session installed |
| `window_by_id(unsigned)` | `0x1873e91c8` | 52 | Lookup within the current server session |
| `get_transform_entry` | `0x1871c7790` | 192 | Read exact placement transform and flags |
| `CGXSetWindowTransformList` | `0x1871c8818` | 480 | Direct batch of affine transforms and display invalidation |
| `WSWindowGetOwningPID` | `0x1873ff318` | 220 | Window's owning process |
| `WSWindowOwnerID` | `0x1873ff3f4` | 192 | Window's effective native owner connection |
| `WSWindowGetScreenRect` | `0x1873fcf7c` | 236 | Current transformed screen rectangle |
| `WSCurrentUntransformedWindowBounds` | `0x18732e534` | 56 | Untransformed native shape bounds |
| `WSSetWindowTransform` | `0x1871c82a0` | 224 | Restore original raw placement transform and flags |

SHA-256 values live beside the offsets and exact lengths in `server-abi.c`.

## Calling convention and ownership

`WSSessionDispatchMainBlockAsync(uint32_t sessionID, block(CGXSession *))`
copies/enqueues a callback through `WSMainThreadBlockHoistEnqueueBlock`. Its
callback selects the requested session, installs it as the current session,
invokes the supplied block with that session pointer, then restores the previous
session. ID zero selects the server's default session. The prototype requires
the callback to run on the process main thread. It performs no lookup before
that callback. A fixture outside the selected session therefore fails admission
instead of causing an attempt against another session.

`ifwsp_server_call` is called only from the separate socket worker. Pending
callbacks can be cancelled after 500 ms without retaining caller-owned stack
storage. A callback that has already started must complete before that storage
can be released; native server calls cannot be preempted. This is not a hard
execution-time guarantee for private server code.
Final cleanup uses `ifwsp_server_restore_call`, which never cancels a queued
restoration: the worker retains its operation/context until the callback
executes. A completely stalled WindowServer therefore prevents finite cleanup
completion; a timeout cannot safely be called a completed restoration.

The direct batch routine has this reviewed ABI:

```c
int CGXSetWindowTransformList(
    CGXConnection *connection, const uint32_t *windows, uint32_t window_count,
    const uint32_t *placements, uint32_t flags,
    const CGAffineTransform *transforms, uint32_t transform_count);
```

The fifth argument is **flags**, not a placement count. This was checked against
both its block capture fields and the matching `__CGXSetWindowTransformList`
MIG implementation. The server uses one placement value and one affine per
window. Its block captures a placement count of one and loads
`placements[min(windowIndex, placementCount - 1)]`, broadcasting placement zero
to every window; the matrix index is independently clamped to the supplied
matrix count. The adapter supplies a full zeroed placement array as well.
A null connection is an existing server-internal path; the actual
window list still comes only from the prototype's explicit disposable fixture
allowlist. The adapter passes placement zero and flags zero, with float-rounded
affine fields matching the ordinary client path's wire precision.

The routine executes synchronously: it creates a stack block and directly calls
`accumulate_window_display_updates`, which iterates the windows and invokes that
block inline. Each invocation converts/sets the matrix and calls
`window_update_transform`; only the subsequent display redraw is scheduled.
The borrowed window-ID, placement and matrix arrays are consumed before the
batch routine returns, rather than retained by a queued callback.

`SLSSetWindowTransform` and `SLSGetWindowTransform` were traced only as ABI
references. Both select placement zero. The ordinary setter narrows six double
values to floats before the server handles them. Neither client function is
called by this adapter.

`get_transform_entry(window, placement)` returns a borrowed 144-byte entry;
flags are at byte 4 and the 128-byte transform at byte 16. The matching server
getter reads these same fields. The raw transform has `CATransform3D` layout.
The adapter uses public, data-only QuartzCore conversion helpers, requires an
affine transform, and allows only flags zero apart from the server's internal
`0x01000000` identity marker, which its getter masks out.
Admission also requires an existing placement-zero entry: reconstructing an
identity entry cannot restore the exact absence of an entry, and a removal ABI
has not been reviewed. Restoration checks entry presence, full raw matrix bytes
and flags, not just the six rounded affine values.

The native setter also clears two reserved transform placements,
`0x1ffffffe` and `0x1ffffffd`, before applying placement zero. Admission refuses
any existing entry there, including an identity entry, because clearing such an
entry would change retained state. The prototype retains the original raw placement-zero
matrix and flags before mutation, compares its affine readback with the
controller's pre-injection original, and restores through:

```c
void WSSetWindowTransform(CGXConnection *connection, CGXWindow *window,
    uint32_t placement, uint32_t flags, const CATransform3D *transform);
```

This avoids reconstructing a placement matrix from a composed display transform.
No global compositor configuration, event state, alpha, layer order, shape or
unlisted window is intentionally changed.

## Fixture process identity bridge

Binary config version **2**, magic `IFWSP02`, retains the fixture manifest's
PID, UID, process birth and native window identities, and adds the loader's
captured kernel process identity. The original root-loader manifest checks
remain: process birth, supervisor parent PID, actual executable path/hash and
explicit owned window list. The loader captures the kernel token before the
executable hash check, then rechecks the original BSD birth/parent identity and
that token after hashing and before remote allocations/writes/thread execution.
This bridges the manifest's original process instance to the token used later
inside WindowServer rather than independently binding a replacement PID.

The shared declarations and guards are in `kernel-process-identity.h`. The
runtime token contains PID/UID, the kernel's 64-bit unique process ID,
16-byte main-executable UUID and PID version. Each capture brackets the public
`PROC_PIDT_SHORTBSDINFO` PID/UID query with two complete
`PROC_PIDUNIQIDENTIFIERINFO` queries and requires their unique ID, executable
UUID and PID version to match. Payload and server-adapter fixture guards use
this same strict token. Partial queries, permission errors, PID reuse, exec
changes and mismatches are refused; there is no PID-only or cached-success
fallback. The server's own full BSD process-birth check remains unchanged.
Version/size checks reject older binary sidecars before the added fields are
used. The JSON fixture manifest remains schema 1 and the DWv2 wire layouts are
unchanged; those are separate formats from the version 2 binary config.

The private query's exact 56-byte result layout was checked against Apple XNU
commit `f6217f891ac0bb64f3d375211650a4c1ff8ca1ea`:

- [`bsd/sys/proc_info_private.h`](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/sys/proc_info_private.h),
  lines 45–55 and 145–147; SHA-256
  `ccc01e88d5bf47bc9c3f5ba3a25c3e6202bbcd7b86aa967af31d714657571c3b`.
- [`bsd/kern/proc_info.c`](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/kern/proc_info.c),
  lines 1507–1516 and 2198–2205; SHA-256
  `557092f14fbad3341100f59e0391d2e812c54b79a7404c89b2af97471ad67082`.

The first source defines the executable UUID, unique IDs and PID-version
fields and flavor 17. The second fills them from the process and exempts
flavors 13 and 17 from the same-user check. That exemption does not bypass
MAC/sandbox policy. The installed public short BSD record supplies UID/PID;
compile-time size/offset assertions pin both result layouts. These are
independently named declarations and new guard logic, not copied XNU
implementation code.

## Runtime limits

Image/routine pinning and successful compilation do not validate the private
calls. Before any benchmark result is accepted, the guest run must establish
successful fixture-only admission, actual changed transform/geometry, exact
original restoration, and independent native visual presentation. The adapter
may refuse runtime admission if WindowServer's sandbox denies the kernel
identity queries, the fixture has unsupported transform flags, its native bounds differ
from the supplied originals, or its window is outside the default session.

The WS09 startup trial on 2026-10-25 passed sidecar/config version 2,
server/fixture identity and reviewed ABI validation, and started the worker.
Its attempted listener was then denied by the WindowServer sandbox:
`network-bind /private/tmp/ifp-*/v2.sock`, errno 1 (`EPERM`). No listener
readiness, FRAME operation, or WindowServer performance measurement followed.
Successful loading and ABI binding therefore do not establish transform
application or a timing comparison. No sandbox policy change is implemented
to bypass this blocker, and the fixed maximum lifetime remains 60 seconds.

The first socket/handshake/frame result and the host source's baseline numbers
must never stand in for that evidence. No direct-vs-Dock timing conclusion is
established by this source or by the pin hashes.
