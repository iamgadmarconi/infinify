// SPDX-License-Identifier: GPL-3.0-or-later
#ifndef DW_NATIVE_RESIZE_H
#define DW_NATIVE_RESIZE_H
#include <ApplicationServices/ApplicationServices.h>
#include <stdbool.h>
#include <sys/types.h>

typedef struct { pid_t pid; uint64_t birth_seconds, birth_microseconds; CGWindowID window; } DWResizeIdentity;
typedef enum {
    DWResizeObserved, DWResizeApplied, DWResizeClamped, DWResizeRejected,
    DWResizeInvalidRequest, DWResizeStaleIdentity, DWResizeUnavailable,
    DWResizeMissingWindow, DWResizeAmbiguousWindow, DWResizeUnsupported,
    DWResizeReadbackFailed, DWResizeTimedOut
} DWResizeOutcome;
typedef struct {
    DWResizeOutcome outcome;
    AXError ax_error;
    // Size-only calls report the size setter in mutation_attempted. Full-frame
    // calls include position setters. moved reports an observed origin change.
    bool mutation_attempted, observed, moved;
    CGSize requested;
    CGRect actual_ax, actual_cg;
} DWResizeResult;
typedef struct { DWResizeIdentity identity; CGRect original; bool valid; } DWResizeSnapshot;
// Synchronous bounded calls, intended for a serial background queue, never a display callback.
// Identity enrollment is read-only; caller must authorize ownership separately.
bool dw_resize_identity(pid_t pid, CGWindowID window, DWResizeIdentity *identity);
// Where a window's frame is read from, for every actual_cg reported and compared with Accessibility's. NULL (the default): the
// window list's kCGWindowBounds. Under native presentation (native/desktop/native-presenter.h) the shell sets a reader of the
// window's own, untransformed frame; a window it cannot read is then no owner. Set once, before any other call here.
void dw_resize_set_bounds(bool (*read)(uint32_t window, CGRect *bounds));
DWResizeResult dw_resize_observe(DWResizeIdentity identity);
// A size that does not fit the visible frame of the window's screen from where the window sits is preceded by one native
// position write, the least that makes room (resize.m, room()); under a scoped final authorization nothing is moved.
DWResizeResult dw_resize_apply(DWResizeIdentity identity, CGSize size);
// Same-Space app-owned Fill, resolved by its observed menu identifier. Requires
// the exact target to be the frontmost app's focused window; never activates it.
// Unsupported before any attempt may use the ordinary size path. A press, even
// one returning an error, must never fall back or be replayed. A qualified
// native Restore still owes verification of the entire saved frame below.
DWResizeResult dw_resize_fill(DWResizeIdentity identity, CGSize requested);
// App-owned Return to Previous Size. Same one-press rules as Fill; requires the
// exact app-local focused window but permits a background app, without activating
// it. Applied requires the entire saved frame; a different settled frame is Clamped.
// The caller owns any Unsupported fallback or later exact-frame correction.
DWResizeResult dw_resize_unfill(DWResizeIdentity identity, CGRect saved_frame);
// Short position-only preparation for an externally held display update.
// absolute_deadline is CLOCK_MONOTONIC seconds, shared with the caller's lease.
// A 350ms shared budget and 50ms per AX call; one position write only after the
// native frame still exactly equals expected_before. Extent must stay unchanged.
DWResizeResult dw_resize_reposition(DWResizeIdentity identity, CGRect expected_before, CGPoint origin, double absolute_deadline);
// Explicit full-frame request for fullscreen restoration. Sizes before positioning
// when the extent differs, and repeats size only when the post-position AX and
// native CG extents do not both exactly match. Rechecks ownership before every setter.
// Owner constraints remain applied/clamped/rejected; this does not bypass them.
DWResizeResult dw_resize_apply_frame(DWResizeIdentity identity, CGRect frame);
typedef bool (*DWResizeGuard)(DWResizeIdentity identity, void *context);
DWResizeResult dw_resize_apply_guarded(DWResizeIdentity identity, CGSize size, DWResizeGuard guard, void *context);
// Additive scoped path: guard is slow preparation; final_authorize runs after
// identity/timeout/value setup. Only a local deadline check follows before AXSize.
// Final authorization must not perform AX, family or file operations. It reserves
// the entire configured <=150ms timeout; old wrappers keep their original order.
DWResizeResult dw_resize_apply_scoped(DWResizeIdentity identity, CGSize size, DWResizeGuard guard, DWResizeGuard final_authorize, void *context);
DWResizeResult dw_resize_snapshot(DWResizeIdentity identity, DWResizeSnapshot *snapshot);
// Restore size only. Actual origin is returned: no camera changes occur, and no native position is written but to make room.
DWResizeResult dw_resize_restore(DWResizeSnapshot snapshot);
const char *dw_resize_outcome_name(DWResizeOutcome outcome);
#endif
