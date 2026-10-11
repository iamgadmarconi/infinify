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
    // mutation_attempted is the size setter's alone. moved: a position write was sent first, to make room for the size on the
    // window's screen, and the window was then read at another origin than before.
    bool mutation_attempted, observed, moved;
    CGSize requested;
    CGRect actual_ax, actual_cg;
} DWResizeResult;
typedef struct { DWResizeIdentity identity; CGRect original; bool valid; } DWResizeSnapshot;
// Synchronous bounded calls, intended for a serial background queue, never a display callback.
// Identity enrollment is read-only; caller must authorize ownership separately.
bool dw_resize_identity(pid_t pid, CGWindowID window, DWResizeIdentity *identity);
DWResizeResult dw_resize_observe(DWResizeIdentity identity);
// A size that does not fit the visible frame of the window's screen from where the window sits is preceded by one native
// position write, the least that makes room (resize.m, room()); under a scoped final authorization nothing is moved.
DWResizeResult dw_resize_apply(DWResizeIdentity identity, CGSize size);
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
