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
    // brought_forward: the window was off screen and in no Accessibility list (another desktop) and was first brought forward by window number.
    bool mutation_attempted, focused, brought_forward;
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
// Where a window's frame is read from, for every bounds this file reports and compares with Accessibility's. NULL (the default):
// the window list's kCGWindowBounds. Under native presentation (native/desktop/native-presenter.h) that is where the transform
// helper draws the window, not the window's own frame, and the shell sets a reader of the latter; a window it cannot read is
// then no owner. Set once, before any other call here.
void dw_focus_set_bounds(bool (*read)(uint32_t window, CGRect *bounds));
DWFocusResult dw_focus_observe(DWFocusIdentity identity);
DWFocusResult dw_focus_select(DWFocusIdentity identity, DWFocusGuard guard, void *context);
const char *dw_focus_outcome_name(DWFocusOutcome outcome);
#endif
