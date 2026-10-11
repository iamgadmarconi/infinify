// SPDX-License-Identifier: GPL-3.0-or-later
#import "navigation-coordinator.h"
#import <CoreMedia/CoreMedia.h>
@protocol DWResizeDriver <NSObject>
- (NSDictionary *)perform:(NSDictionary *)effect;
// Fresh read-only family query. nil is unknown/unsupported, never root-only.
- (NSDictionary *)rootExtent:(NSDictionary *)identity;
@optional
// Why -rootExtent: answers nil for this window, in a few words, for a person to read. Read-only, and asked only when that is news.
- (NSString *)rootExtentRefusal:(NSDictionary *)identity;
@end
@interface DWResizeCoordinator : NSObject
- (instancetype)initWithCommand:(DWCommand)command driver:(id<DWResizeDriver>)driver clock:(uint64_t (^)(void))clock worker:(DWSchedule)worker main:(DWSchedule)main;
@property BOOL enabled;
// NO: readback mode, every normal run without --experimental-native-resize (crates/desktop/NATIVE_RESIZE.md). The size a window took is
// settled by the native read alone: no result invalidates a capture, none waits for a frame, and no obligation outlives its effect. An
// effect the driver does not answer, or whose answer the controller refuses, is reported as timed out and unobserved, which the
// controller ends its transaction on. YES, the default, is the capture-acknowledged mode every caller had before.
@property BOOL acknowledges;
// Readback mode: seconds after which an effect nobody has answered is reported as timed out. 0, the default, never.
@property NSTimeInterval timeout;
// Runs a job on the main thread after a delay: the watchdog's clock. The default is dispatch_after on the main queue.
@property (copy) void (^delay)(NSTimeInterval seconds, DWJob job);
@property (readonly) NSUInteger obligations;
@property (copy) DWJob changed;
@property (readonly) NSString *failure;
@property (readonly) NSNumber *installingWindow;
- (NSDictionary *)request:(NSDictionary *)command;
- (void)consume:(NSDictionary *)reply;
- (void)cancel;
- (void)observeBindings;
- (BOOL)validate:(NSNumber *)window;
- (void)shutdown;
- (BOOL)canRemove:(NSNumber *)window;
// Readback mode: the window whose size transaction is still owed a result, else nil. While it is, the controller refuses observe,
// window_closed and remove_source for that window, so the shell asks none of it. Read from the obligations, without a snapshot: in
// readback mode a live transaction always has one (-reap sees to the one that does not).
- (NSNumber *)busyWindow;
// Readback mode, once a second: a live transaction whose effect nobody is performing (a reply whose effect never reached -consume:)
// is answered as unanswered the second time it is seen, so that it ends like any other.
- (void)reap;
// Readback mode: is this transaction held by input that is still down (a resize press whose button is down, a resize swipe whose fingers
// are)? A pointer at rest sends nothing and no effect is owed for it: such a transaction is no orphan, and -reap leaves it alone. Whoever
// answers YES ends the transaction itself when that input ends or is lost. Unset, nothing is held.
@property (copy) BOOL (^held)(NSNumber *transaction);
- (void)invalidate:(NSNumber *)window;
- (NSDictionary *)captureState:(NSNumber *)window;
// Why the last capture offered for the window was not acknowledged, for a person to read: a short reason (family, geometry, metadata,
// stale frame, refused, not installed) and, in `detail`, what was compared. nil once one is acknowledged, and nil again from the moment
// the controller's observation of the window moves on until a frame has been judged against the new one. Diagnosis only: nothing reads it back.
- (NSString *)refusal:(NSNumber *)window detail:(NSString *__autoreleasing *)detail;
- (void)bind:(NSNumber *)window stream:(id)stream;
- (BOOL)accept:(CMSampleBufferRef)sample window:(NSNumber *)window stream:(id)stream install:(BOOL (^)(CMSampleBufferRef))install;
@end
// Eight handles at actual world edges; never synthesize edges at viewport clips.
NSArray<NSDictionary *> *DWResizeHandles(CGRect full,CGRect clip);
