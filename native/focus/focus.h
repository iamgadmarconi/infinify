// SPDX-License-Identifier: GPL-3.0-or-later
#ifndef DW_FOCUS_H
#define DW_FOCUS_H
#include <ApplicationServices/ApplicationServices.h>
#include <stdbool.h>
#include <sys/types.h>
typedef struct { pid_t pid; uint64_t seconds, microseconds; CGWindowID window; } DWFocusIdentity;
typedef enum { DWFocusObserved, DWFocusFocused, DWFocusInvalid, DWFocusStale,
    DWFocusUnavailable, DWFocusMissing, DWFocusAmbiguous, DWFocusReadbackFailed,
    DWFocusDenied, DWFocusAXFailed, DWFocusTimedOut } DWFocusOutcome;
typedef struct {
    DWFocusOutcome outcome;
    AXError ax_error;
    bool mutation_attempted, focused;
    CGRect bounds;
    pid_t system_pid;
    CGWindowID system_window, app_window;
} DWFocusResult;
// Enrollment is read-only, not authorization. The non-null guard must establish
// explicit selection/ownership and cancel on human input, foreground change or deadline.
// Serial background use; no focus changes occur through observe/identity.
typedef bool (*DWFocusGuard)(DWFocusIdentity selected, void *context);
bool dw_focus_birth(pid_t pid, uint64_t *seconds, uint64_t *microseconds);
bool dw_focus_identity(pid_t pid, CGWindowID window, DWFocusIdentity *out);
bool dw_focus_owner(DWFocusIdentity identity, CGRect *bounds);
DWFocusResult dw_focus_observe(DWFocusIdentity identity);
DWFocusResult dw_focus_select(DWFocusIdentity identity, DWFocusGuard guard, void *context);
const char *dw_focus_outcome_name(DWFocusOutcome outcome);
#endif
