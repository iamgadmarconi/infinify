// SPDX-License-Identifier: GPL-3.0-or-later
#import "DWNavigationCoordinator.h"
@protocol DWResizeDriver <NSObject>
- (NSDictionary *)perform:(NSDictionary *)effect;
@end
@interface DWResizeCoordinator : NSObject
- (instancetype)initWithCommand:(DWCommand)command driver:(id<DWResizeDriver>)driver worker:(DWSchedule)worker main:(DWSchedule)main;
@property BOOL enabled;
// A different transaction may wait behind the previous picture's reveal.
// Not admitted: no worker/preparation watchdog. Retry after presentation retires.
@property (copy) BOOL (^beforeAdmission)(NSDictionary *effect);
- (void)retryAdmission;
// Includes timed-out native jobs until their actual worker completion.
- (BOOL)hasNativeWorkForTransaction:(NSNumber *)transaction;
// Main-only asynchronous admission, before worker dispatch or its watchdog.
// Reply once; NO settles an unattempted effect. Preparation is capped at 2.5 s.
@property (copy) void (^prepare)(NSDictionary *effect, void (^ready)(BOOL));
// Seconds after which an effect nobody has answered is reported as timed out. 0, the default, never.
@property NSTimeInterval timeout;
// Runs a job on the main thread after a delay: the watchdog's clock. The default is dispatch_after on the main queue.
@property (copy) void (^delay)(NSTimeInterval seconds, DWJob job);
@property (readonly) NSUInteger obligations;
@property (copy) DWJob changed;
@property (readonly) NSString *failure;
- (NSDictionary *)request:(NSDictionary *)command;
- (void)consume:(NSDictionary *)reply;
- (void)cancel;
- (void)shutdown;
- (BOOL)canRemove:(NSNumber *)window;
// The window whose size transaction is still owed a result, else nil. While it is, the controller refuses observe,
// window_closed and remove_source for that window, so the shell asks none of it. Read from the obligations, without a snapshot: in
// native readback a live transaction always has one (-reap sees to the one that does not).
- (NSNumber *)busyWindow;
// Once a second: a live transaction whose effect nobody is performing (a reply whose effect never reached -consume:)
// is answered as unanswered the second time it is seen, so that it ends like any other.
- (void)reap;
// An exact pending baseline may wait for navigation before any worker/watchdog
// starts. The owner must eventually consume it or discard it; ordinary orphans
// and held pointer transactions keep their existing recovery policy.
@property (copy) BOOL (^deferred)(NSDictionary *effect);
// Retire only an exact, never-admitted pending baseline without native work.
// Setters, superseded effects and effects with running obligations are refused.
- (void)discardDeferredEffect:(NSDictionary *)effect;
// Is this transaction held by input that is still down (a resize press whose button is down, a resize swipe whose fingers
// are)? A pointer at rest sends nothing and no effect is owed for it: such a transaction is no orphan, and -reap leaves it alone. Whoever
// answers YES ends the transaction itself when that input ends or is lost. Unset, nothing is held.
@property (copy) BOOL (^held)(NSNumber *transaction);
@end
