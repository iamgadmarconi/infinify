# Native AX resize adapter

GPL-3.0-or-later; Apple Silicon/macOS 26+. `DWNativeResize.h` exposes a C API for the
Objective-C desktop shell. Link `DWNativeResize.m` with AppKit/ApplicationServices.
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

After AXSize, an exact requested size completes on the first read where AX and the window list agree. The window list
shows the new frame about 10 ms after AX does (sampled every 4 ms on macOS 27.0.1), so a read where they disagree is retried
after 2 ms, not on the old 30 ms grid. A size that is not the one asked is final on that first agreed read when the request
reaches past the visible frame of the window's screen from where the window sits and the answer is short of it: that is
AppKit's own limit (below) and no second read changes it. Any other non-exact size (a minimum, a maximum, a resize increment,
an app's animation) is accepted when a second agreed read, 8 ms later, shows it unchanged; a size still changing between
reads is followed for up to 120 ms after the setter and the last agreed read stands. A read that itself timed out extends
that window by 30 ms once. Before 2026-10-30 every non-exact answer cost five reads over 120 ms, so a drag held at a limit
spent 120 ms per request; the same drag now spends 0.3 ms (one read) per request past the screen and 8 to 20 ms per
request the app can grant. The shared two-second deadline remains authoritative.
`INFINIFY_DEBUG=1` records one settling receipt per size setter, separating read
and sleep time from the elapsed post-setter interval, and says once per window, `native size limit`, that the
screen's visible frame ended it.

One native position write may precede the size. macOS grants no Accessibility size
that would carry a window past the visible frame of its screen: asked from an
origin the size does not fit from, the window keeps the size it has (rejected). On
each axis the request grows on and would overflow, the window is first moved once, to the
frame's origin on that axis (the most room there is, so the sizes a drag asks next from there need no further move; the least
move that makes room moved a window 4 to 7 times by a few points each in one drag past the screen, and each move
showed as a jump of the drawn window until the shell re-based on the origin the result reported). A size larger than the
frame is then asked as it is and comes back clamped. The identity and settable checks stand before
the move, identity and timeout again between the move and the size, and a move that
fails or is not honoured does not stop the size from being asked. The position read after the move
is polled as the size read is (2 ms on disagreement, a second read 8 ms later for an origin other than the one asked).
`moved` in the result says that the window was read at another origin afterwards;
`mutation_attempted` remains the size setter's alone.

Why a window cannot be made taller than the visible frame (measured on the macOS 27.0.1 guest, 1920x1200 with a 30 point
menu bar and a 90 point Dock, visible frame 30..1110 vertically, 2026-10-30): TextEdit, Terminal, Finder, Safari, Google
Chrome and Ghostty asked for heights of 1400, 2000 and 3000 from every order of position and size (size only; position then
size; size then position; size, position, size as yabai does; with AXEnhancedUserInterface off; position first at y=-200 or
y=5000) ended at 1009 to 1082 points tall with their bottom at 1099 to 1112, within 12 points of the visible frame's
bottom; from y=30 the larger answers were 1079 (TextEdit), 1069 (Terminal, in rows) and 1082 (Finder, Safari, Chrome,
Ghostty). Asking the window to start at the visible frame's top first is what gets the most (1079 against 1009 from y=100).
`AXFrame` is not settable (`kAXErrorAttributeUnsupported`). TextEdit's AppleScript `set bounds` is clamped as well (to
30..1113). Position is clamped too: y=5000 comes back as 1078 and x=-3000 as -760. A window taller than the display
therefore cannot be made by Accessibility, scripting or any order of the two; it takes an app that lifts the constraint
itself (AppKit's `constrainFrameRect:toScreen:`, which Electron's `enableLargerThanScreen` overrides) or a larger
display. Neither Sunlight, yabai nor DriftWM has anything for it: they take the size the app answers with, as this does.
The canvas window is kept at that size, and zoomed out it is simply drawn smaller.

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

Other entry points, as documented in `DWNativeResize.h`:

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
[native/app/Resources/YABAI-NOTICE.txt](../../../../native/app/Resources/YABAI-NOTICE.txt).
