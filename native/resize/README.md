# Native AX resize adapter

GPL-3.0-or-later; Apple Silicon/macOS 26+. `resize.h` exposes a C API for the
Objective-C desktop shell. Link `resize.m` with AppKit/ApplicationServices.
Call synchronously on a serial background queue, outside rendering callbacks.

Build a `DWResizeIdentity` (PID, kernel process-birth seconds and microseconds,
CGWindowID) only for a caller-authorized source.
The adapter validates it against fresh WindowServer ownership on every call. It does not
authorize sources or persist identity.
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

After AXSize, an exact requested size completes immediately. Non-exact results
retain five observations, with retries due 30, 60, 90 and 120 ms after the setter
returns. Readback work counts toward these deadlines instead of extending every
interval by its own duration; the final non-exact observation still starts no
earlier than 120 ms. The shared two-second deadline remains authoritative.
`INFINIFY_DEBUG=1` records one settling receipt per size setter, separating read
and sleep time from the elapsed post-setter interval.

One native position write may precede the size. macOS grants no Accessibility size
that would carry a window past the visible frame of its screen: asked from an
origin the size does not fit from, the window keeps the size it has (rejected). On
each axis the request grows on and would overflow, the window is first moved by the
least that makes room: to where the size ends at the visible frame's far edge, or
to the frame's origin for a size larger than the frame, which is then asked as it
is and comes back clamped. The identity and settable checks stand before
the move, identity and timeout again between the move and the size, and a move that
fails or is not honoured does not stop the size from being asked. `moved` in the
result says that the window was read at another origin afterwards;
`mutation_attempted` remains the size setter's alone.

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

Fullscreen uses the separate `dw_resize_apply_frame` operation to return the
original native origin alongside its saved exact extent. It shares a two-second
deadline across its size and position writes, checks fresh ownership before each
setter, and requires AX and native CG geometry to agree afterward. The final
size write is omitted when the post-position AX and CG extents both exactly match
the saved dimensions, including when an earlier size write restored them. A successful
setter with another origin is clamped or rejected, never applied. This operation
does not bypass the owner's size or position constraints. An already matching
extent needs only the position write, so restoration still works when the
application no longer permits resizing; any size change caused by positioning
is read back and corrected through the size path. The fullscreen reducer
saves the first fresh AX/CG baseline separately from its world/camera return;
`native_origin` is null on ordinary size effects and contains that original point
on a fullscreen restoration. Cancellation drains an already sent operation before
dispatching the frame restore.
Full-frame results count preparatory position writes as mutations, and preserve
an AX timeout from any setter even if later stages return matching geometry. A
position write that exhausts the deadline returns an unresolved timeout; it
cannot report an unobserved success. The controller retains the saved frame
until a final fresh read confirms restoration, including after cancellation or
an application-driven relocation.

Other entry points, as documented in `resize.h`:

- `dw_resize_set_bounds` sets where a window's frame is read from, for every `actual_cg`
  reported and compared with Accessibility's. The default is the window list's
  `kCGWindowBounds`; under native presentation the shell sets a reader of the window's own,
  untransformed frame, and a window it cannot read is then no owner. Set it once, before
  any other call.
- `dw_resize_observe` reads the window's bounds, read-only.
- `dw_resize_fill` is the same-Space app-owned Fill, resolved by its observed menu
  identifier. It requires the exact target to be the frontmost app's focused window and
  never activates it. It is Unsupported before any attempt may use the ordinary size path.
  A press, even one returning an error, must never fall back or be replayed. A qualified
  native Restore still owes verification of the entire saved frame.
- `dw_resize_unfill` is the app-owned Return to Previous Size, with the same one-press
  rules. It requires the exact app-local focused window but permits a background app,
  without activating it. Applied requires the entire saved frame; a different settled
  frame is Clamped. The caller owns any Unsupported fallback or later exact-frame
  correction.
- `dw_resize_reposition` is a short position-only preparation for an externally held
  display update. `absolute_deadline` is CLOCK_MONOTONIC seconds, shared with the caller's
  lease: a 350 ms shared budget and 50 ms per AX call, and one position write only after
  the native frame still exactly equals `expected_before`. The extent must stay unchanged.
- `dw_resize_outcome_name` names an outcome.

`sh tests/e2e/native-frame-restore.sh` exercises the actual adapter and desktop
driver with substituted AX/WindowServer calls: frame ordering, fractional origin,
unchanged-size restoration, ignored position, unavailable positioning, replaced
owner, inconsistent readback, deadline exhaustion, transient and persistent query
timeouts, multi-stage setter timeouts, size settling and strict effect dispatch. It
creates no native window and establishes no third-party or optical runtime capability.

Private-function signature precedent (no upstream implementation copied):
[yabai](https://github.com/asmvik/yabai) commit
`dd845723416f5fe92af49fad5ebab00369e07edd`, `src/misc/extern.h:8` declaration and
`src/misc/helpers.h:499-504` window-ID helper; the frame ordering follows
`src/window_manager.c:729-762` of the same commit. Existing project GPL attribution
continues to apply; the licence text is
[native/desktop/YABAI-NOTICE.txt](../desktop/YABAI-NOTICE.txt).
