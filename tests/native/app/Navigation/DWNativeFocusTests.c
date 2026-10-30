// SPDX-License-Identifier: GPL-3.0-or-later
// Headless regression of the focus adapter's C ABI against native/app/Navigation/DWNativeFocus.m: an identity that
// is not a live window of the process it names is never owned, dw_focus_select refuses it before
// its guard runs, and neither it nor dw_focus_set_minimized changes anything for it. Read-only: no
// window is activated, no Accessibility message is sent, no permission is requested and no input
// is posted.
#include "DWNativeFocus.h"
#include <assert.h>
#include <string.h>
#include <unistd.h>

static int guard_calls;
static bool counting_guard(DWFocusIdentity selected, void *context) {
    (void)selected;
    (void)context;
    guard_calls++;
    return true;
}

int main(void) {
    DWFocusIdentity invalid = {0};
    CGRect bounds;

    // Process birth is read for a live PID only.
    uint64_t seconds = 0, microseconds = 0;
    assert(!dw_focus_birth(0, &seconds, &microseconds));
    assert(!dw_focus_birth(getpid(), NULL, &microseconds));
    assert(dw_focus_birth(getpid(), &seconds, &microseconds) && seconds > 0);

    // Ownership requires a window number, a matching birth and a window the list gives to that PID.
    assert(!dw_focus_owner(invalid, NULL));
    assert(!dw_focus_owner(invalid, &bounds));
    DWFocusIdentity unlisted = {.pid = getpid(), .seconds = seconds, .microseconds = microseconds, .window = 0xFFFFFFFFu};
    assert(!dw_focus_owner(unlisted, NULL));
    DWFocusIdentity reborn = {.pid = getpid(), .seconds = seconds + 1, .microseconds = microseconds, .window = 1};
    assert(!dw_focus_owner(reborn, NULL));
    DWFocusIdentity enrolled = {.pid = -1};
    assert(!dw_focus_identity(getpid(), 0xFFFFFFFFu, &enrolled) && enrolled.pid == 0 && enrolled.window == 0);
    assert(!dw_focus_identity(getpid(), 1, NULL));

    // Selection needs a guard, and a stale identity never reaches it or any setter.
    DWFocusResult result = dw_focus_select(invalid, NULL, NULL);
    assert(result.outcome == DWFocusInvalid && !result.mutation_attempted && !result.focused);
    result = dw_focus_select(unlisted, NULL, NULL);
    assert(result.outcome == DWFocusInvalid && !result.mutation_attempted);
    guard_calls = 0;
    result = dw_focus_select(invalid, counting_guard, NULL);
    assert(result.outcome == DWFocusStale && !result.mutation_attempted && !result.focused && guard_calls == 0);
    result = dw_focus_select(unlisted, counting_guard, NULL);
    assert(result.outcome == DWFocusStale && !result.mutation_attempted && !result.focused && guard_calls == 0);
    result = dw_focus_observe(invalid);
    assert(result.outcome == DWFocusStale && !result.mutation_attempted && !result.focused);

    // Minimizing needs a guard that approves, and a stale identity is never written.
    result = dw_focus_set_minimized(unlisted, true, NULL, NULL);
    assert(result.outcome == DWFocusDenied && !result.mutation_attempted);
    result = dw_focus_set_minimized(unlisted, true, counting_guard, NULL);
    assert(result.outcome == DWFocusStale && !result.mutation_attempted);
    bool minimized = true;
    assert(!dw_focus_minimized(invalid, &minimized));
    assert(!dw_focus_minimized(invalid, NULL));

    assert(strcmp(dw_focus_outcome_name(DWFocusInvalid), "invalid") == 0);
    assert(strcmp(dw_focus_outcome_name(DWFocusStale), "stale_identity_or_bounds") == 0);
    assert(strcmp(dw_focus_outcome_name((DWFocusOutcome)99), "unknown") == 0);
    return 0;
}
