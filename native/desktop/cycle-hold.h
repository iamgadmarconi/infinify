// SPDX-License-Identifier: GPL-3.0-or-later
#import <Foundation/Foundation.h>
// The physical modifier state of the login session, for cycle-windows: whether a real
// modifier is down as the action fires, and when the modifiers holding a cycle session
// open are let go. Read from CGEventSourceFlagsState, which needs no event tap, no
// Input Monitoring grant and no key window. Main thread only.
@interface DWCycleHold : NSObject
// Carbon mask (controlKey|optionKey|shiftKey|cmdKey) of the modifiers down now. Caps
// lock and fn are not modifiers here, as upstream's Modifiers::from_state ignores locks.
+ (uint32_t)modifiersDown;
// Calls `sample` with +modifiersDown 60 times a second until it answers NO, or -stop.
// A second -start: replaces the first.
- (void)start:(BOOL (^)(uint32_t down))sample;
- (void)stop;
@end
