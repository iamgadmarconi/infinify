// SPDX-License-Identifier: GPL-3.0-or-later
#import <CoreGraphics/CoreGraphics.h>
#include <stdint.h>

// Read-only lookup for an exact, active, unmirrored physical-display viewport.
// Returns its current ordinary Space, or zero when correspondence is unknown.
// No window membership or input eligibility is established by this lookup.
uint64_t DWNativeDisplaySpace(CGRect viewport);

// Read-only membership snapshot: exactly one window Space must equal this
// viewport's current ordinary Space, which is rechecked after membership.
// Unknown/malformed/multiple membership returns NO. This does not establish
// window identity or input eligibility; callers retain those independent guards.
BOOL DWNativeWindowOnDisplaySpace(CGWindowID window, CGRect viewport);
