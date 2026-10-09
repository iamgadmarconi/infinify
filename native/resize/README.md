# Native AX resize adapter

GPL-3.0-or-later; Apple Silicon/macOS 26+. `resize.h` exposes a C API for the
Objective-C desktop shell. Link `resize.m` with AppKit/ApplicationServices.
Call synchronously on a serial background queue, outside rendering callbacks.

Enroll only a caller-authorized source with `dw_resize_identity(pid, window, &id)`.
The adapter validates PID + process birth seconds/microseconds + CGWindowID against
fresh WindowServer ownership. It does not authorize sources or persist identity.
It enumerates AX windows and resolves exact IDs through dynamically loaded
`_AXUIElementGetWindow`; no title/geometry guessing or fallback. Missing private
symbol, permissions, unknown AX elements, ambiguous IDs, stale ownership and
unavailable readback fail closed. No permission prompt is issued.

`dw_resize_apply` sets only AXSize after checking settable. Requests must have
finite dimensions in [1, 32768] points. Each AX message has a <=150 ms timeout;
resolution/readback retries share a two-second deadline. Synchronous WindowServer
and process-info calls are OS calls without a cancellable timeout. The remaining
AX timeout is refreshed per message. No activation, input posting, camera state,
position changes, UI loop, or background observer is owned by this adapter.

Results distinguish observed/applied/clamped/rejected/unsupported, invalid/stale,
unavailable/missing/ambiguous, and readback failures/timeouts. `mutation_attempted`
means a setter was sent, including when final identity/readback is lost. `observed`
means AX and fresh CG bounds agreed within one point, and `actual_ax`/`actual_cg`
are those actual dimensions **and origin**. Setter success does not establish a
resize. An unchanged non-requested size is reported rejected (it may also be a
constraint holding an already-clamped size). Reconcile the world from actual
bounds only when `observed` is true; otherwise re-observe before proceeding.
A receiver may process a timed-out setter late; do not blindly retry mutation.
Private APIs may change across OS versions. Identity checks narrow but cannot
eliminate the cross-process race between final validation and an AX message.

Snapshot captures identity and actual geometry. Restore restores **size only**;
it never forces an origin or changes camera state. Compare returned origin with
the snapshot and reconcile any native movement. The owned test fixture also saves
and restores its full original frames locally during teardown, including signals,
parent death and a 30-second deadline. Decoys must remain unchanged.

`./tests/e2e/native-resize.sh` builds only this adapter. An explicit
`./tests/e2e/native-resize.sh --live-owned-fixture [evidence-directory]` runs an
external AppKit fixture with three identical-title windows: selected,
non-settable decoy and an ignoring-setter window. The controller proves native
geometry through independent AX + CG reads, including minimum constraints,
stale identity, invalid dimensions, ignored success, native relocation with retained
identity, size snapshot restoration and
cleanup, plus bounded failure when the fixture briefly stalls AX servicing.
Fixture self-reports cover cleanup only. This is a resize capability
proof, not evidence of full DriftWM parity or arbitrary third-party app support.
Default build does not launch anything. All output stays under this worktree's
`target/resize`; exported evidence uses no runtime credentials.

Private-function signature precedent (no upstream implementation copied):
[yabai](https://github.com/asmvik/yabai) commit
`dd845723416f5fe92af49fad5ebab00369e07edd`, `src/misc/extern.h:8` declaration and
`src/misc/helpers.h:499-504` window-ID helper. Existing project GPL attribution
continues to apply.
