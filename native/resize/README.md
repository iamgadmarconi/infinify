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
resolution and all readback attempts share a two-second deadline. Synchronous WindowServer
and process-info calls are OS calls without a cancellable timeout. The remaining
AX timeout is refreshed per message. No activation, input posting, camera state,
UI loop, or background observer is owned by this adapter.
An `AXCannotComplete` during position/size observation retries the complete
read with fresh ownership checks within that same deadline. Other errors,
invalid geometry and AX/CG disagreement fail closed. This never repeats a setter.

One native position write may precede the size. macOS grants no Accessibility size
that would carry a window past the visible frame of its screen: asked from an
origin the size does not fit from, the window keeps the size it has (rejected). On
each axis the request grows on and would overflow, the window is first moved by the
least that makes room: to where the size ends at the visible frame's far edge, or
to the frame's origin for a size larger than the frame, which is then asked as it
is and comes back clamped. The identity, settable and guard checks stand before
the move, identity and timeout again between the move and the size, and a move that
fails or is not honoured does not stop the size from being asked. `moved` in the
result says that the window was read at another origin afterwards;
`mutation_attempted` remains the size setter's alone. Nothing is moved under
`dw_resize_apply_scoped`'s final authorization, which is one ticket for one setter.

`dw_resize_apply_scoped` adds separate slow preparation and final lightweight
caller-authorization callbacks. Existing `apply`/`apply_guarded` wrappers retain
their identity recheck and timeout setup order. After slow preparation, the adapter
freshly checks ownership, sets the AX timeout, and allocates the size value. Final
authorization then runs; only a local monotonic deadline check follows before
AXSize. It must not perform AX, family, or file work. The scoped path reserves the
entire configured <=150 ms setter timeout and refuses if insufficient time remains.
Frozen prior adapter evidence remains historical. The former orange-handle
desktop gate and its executable probe were retired on 2026-10-12; these adapter
entry points remain available to independent, explicitly scoped fixtures.

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
it never puts an origin back or changes camera state. Compare returned origin with
the snapshot and reconcile any native movement. The owned test fixture also saves
and restores its full original frames locally during teardown, including signals,
parent death and a 30-second deadline. Decoys must remain unchanged.

Fullscreen uses the separate `dw_resize_apply_frame` operation to return the
original native origin alongside its saved exact extent. It shares a two-second
deadline across size/position/size writes, checks fresh ownership before each
setter, and requires AX and native CG geometry to agree afterward. A successful
setter with another origin is clamped or rejected, never applied. This operation
does not bypass the owner's size or position constraints. An already matching
extent needs only the position write, so restoration still works when the
application no longer permits resizing; any size change caused by positioning
is read back and corrected through the size path. The fullscreen reducer
saves the first fresh AX/CG baseline separately from its world/camera return;
`native_origin` is null on ordinary size effects and contains that original point
on a fullscreen restoration. Cancellation drains an already sent operation before
dispatching the frame restore. Existing size-only snapshot restoration is unchanged.
Full-frame results count preparatory position writes as mutations, and preserve
an AX timeout from any setter even if later stages return matching geometry. A
position write that exhausts the deadline returns an unresolved timeout; it
cannot report an unobserved success. The controller retains the saved frame
until a final fresh read confirms restoration, including after cancellation or
an application-driven relocation.

`sh tests/e2e/native-frame-restore.sh` exercises the actual adapter and desktop
driver with substituted AX/WindowServer calls: frame ordering, fractional origin,
unchanged-size restoration, ignored position, unavailable positioning, replaced
owner, inconsistent readback, deadline exhaustion, transient and persistent query
timeouts, multi-stage setter timeouts, strict effect dispatch, and the size-only legacy
contract. It creates no native window and establishes no third-party or optical
runtime capability.

`sh tests/e2e/native-frame-restore-live.sh` builds the separate real-AX probe and
owned AppKit fixture without launching them. Its explicit
`--live-owned-fixture [evidence-directory]` form first checks existing
Accessibility authority without requesting it, plus read-only session/display
metadata, then creates one fixture process. It refuses known screen lock, an
unavailable/inactive console login, display query failure, no active awake display,
or an inactive/asleep main display. The private `CGSSessionScreenIsLocked` key is
only a negative gate: missing/malformed lock metadata stays `unknown`, never
usable-session proof. The supervisor preserves preflight metadata and refusal
reasons and checks again before starting the mutation probe; the probe also checks
immediately before each expansion. Restoration and child cleanup remain unconditional
if session state changes. The build-only command runs substituted metadata checks
without launching a native fixture.
The probe asks a fullscreen-sized frame, demonstrates the displaced origin left
by size-only restoration, and exercises both origin-only and full-frame recovery.
Independent CG and WindowServer reads must match the original native bounds and
transform exactly; both same-title decoys must remain unchanged. The supervisor
checks restoration before fixture cleanup, reaps the child, and records source
and executable hashes alongside OS, build, architecture and hardware. It does
not exercise the whole desktop app, capture, native presentation, or optical
fullscreen coverage.

The 2026-10-21 run passed on the disposable UTM guest, arm64 macOS 27.0.1
(26A434), VirtualMac2,1. The selected fixture started at `(90,798,460,332)`;
the fullscreen-sized request produced `(0,30,900,700)`. Size-only restoration
left `(0,30,460,332)`, reproducing the lost native origin. Both the subsequent
origin-only restore and a second full-frame restore returned exactly to
`(90,798,460,332)`, including the independently read original transform.
Both decoys were unchanged, and the fixture was already restored before its
own cleanup and was reaped. No settings or permissions changed. The receipt is
`target/native-vm/fullscreen-frame-restore-20261021/evidence/run-83i1716z/receipt.json`,
SHA-256 `20470cd8c9bce86c4d4af6b51cbf4b36de986a75f345cdd202dc79c7e9c417b8`;
it records the final adapter/probe source and executable hashes. This is owned
adapter evidence, not third-party or whole-app fullscreen acceptance.

Whole-app validation remains open. A later owned-fixture replay failed during
fullscreen exit on a pre-mutation `AXCannotComplete` observation
(`target/native-vm/fullscreen-and-move-diagnostic-20261021/run-y2qm062x/receipt.json`).
The bounded readback retry above addresses that error and passes substituted-AX
regressions, including a query timeout after a setter without repeating writes.
The next app replay instead failed earlier, during window resolution with
`AXIllegalArgument`, before any resize setter
(`target/native-vm/fullscreen-and-move-read-retry-20261021/run-r11debyk/receipt.json`).
Its initial CG bounds differed from native bounds; the guest was confirmed locked
and asleep afterward, which does not establish its state during the test.
Both failed runs restored all original fixture geometry and reaped the children.
Window resolution and settable queries still fail immediately on an AX error;
this change retries only position/size observations.

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
