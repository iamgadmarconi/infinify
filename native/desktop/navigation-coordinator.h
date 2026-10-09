// SPDX-License-Identifier: GPL-3.0-or-later
#import <Foundation/Foundation.h>
typedef NSDictionary *(^DWCommand)(NSDictionary *);
typedef void (^DWJob)(void);
typedef void (^DWSchedule)(DWJob);
typedef BOOL (^DWGuard)(void);
// Drivers return an exact independently observed identity, or nil (unknown).
@protocol DWNavigationDriver <NSObject>
- (DWGuard)authorization:(NSDictionary *)identity;
- (BOOL)select:(NSDictionary *)identity guard:(DWGuard)guard;
- (NSDictionary *)observe;
@end
// Performs the controller's focus requests through the driver, follows native focus
// the user moved themselves, keeps a held cycle open until its modifiers are let go,
// and ticks camera flights. Main thread only; the driver runs on `worker`.
@interface DWNavigationCoordinator : NSObject
- (instancetype)initWithCommand:(DWCommand)command driver:(id<DWNavigationDriver>)driver clock:(uint64_t (^)(void))clock worker:(DWSchedule)worker main:(DWSchedule)main;
@property BOOL enabled;
// NO keeps focus logical: every request is answered focus_logical, which claims nothing
// about native focus and lets the window into the cycle order, and the driver is never asked.
@property BOOL focusAllowed;
@property (copy) DWJob changed;
@property (copy) DWJob settled;
// The active output, for the camera to follow native focus on; unset or nil sends null.
@property (copy) NSNumber *(^output)(void);
// The focus request of any controller reply — "effect", or the focus_native_window
// entry of "effects" — goes to the driver and its result back as focus_result, or with
// focusAllowed NO is answered focus_logical at once. A reply without one withdraws work
// in flight only if the controller has dropped that request.
- (void)perform:(NSDictionary *)reply;
// One command and -perform: of its reply; nil when the controller refused it.
- (NSDictionary *)navigate:(NSDictionary *)command;
// Hold-to-commit. -hold: opens it with the modifiers that keep a cycle session open, as
// any mask the caller also samples; -poll: takes the modifiers physically down now and
// answers whether it is still open. The first poll without all of them ends the cycle.
- (void)hold:(NSUInteger)modifiers;
- (BOOL)poll:(NSUInteger)down;
- (void)releaseCycle;
- (void)interrupt; // unrelated input: -cancelFocus while a request is in flight, else nothing
- (void)cancelFocus; // pending focus work and the held cycle; camera flights keep flying
- (void)invalidate; // cancelFocus, and stops every camera flight
- (void)shutdown;
- (void)observe;
- (BOOL)frame;
@end
