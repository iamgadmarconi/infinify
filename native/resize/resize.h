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
    bool mutation_attempted, observed;
    CGSize requested;
    CGRect actual_ax, actual_cg;
} DWResizeResult;
typedef struct { DWResizeIdentity identity; CGRect original; bool valid; } DWResizeSnapshot;
// Synchronous bounded calls, intended for a serial background queue, never a display callback.
// Identity enrollment is read-only; caller must authorize ownership separately.
bool dw_resize_identity(pid_t pid, CGWindowID window, DWResizeIdentity *identity);
DWResizeResult dw_resize_observe(DWResizeIdentity identity);
DWResizeResult dw_resize_apply(DWResizeIdentity identity, CGSize size);
typedef bool (*DWResizeGuard)(DWResizeIdentity identity, void *context);
DWResizeResult dw_resize_apply_guarded(DWResizeIdentity identity, CGSize size, DWResizeGuard guard, void *context);
// Additive scoped path: guard is slow preparation; final_authorize runs after
// identity/timeout/value setup. Only a local deadline check follows before AXSize.
// Final authorization must not perform AX, family or file operations. It reserves
// the entire configured <=150ms timeout; old wrappers keep their original order.
DWResizeResult dw_resize_apply_scoped(DWResizeIdentity identity, CGSize size, DWResizeGuard guard, DWResizeGuard final_authorize, void *context);
DWResizeResult dw_resize_snapshot(DWResizeIdentity identity, DWResizeSnapshot *snapshot);
// Restore size only. Actual origin is returned: no native position or camera changes occur.
DWResizeResult dw_resize_restore(DWResizeSnapshot snapshot);
const char *dw_resize_outcome_name(DWResizeOutcome outcome);
#endif
