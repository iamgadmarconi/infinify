// SPDX-License-Identifier: GPL-3.0-or-later
#import <Foundation/Foundation.h>
#import "DWController+Focus.h"
// Shared scheduling vocabulary; DWCommand remains for the resize adapter.
typedef NSDictionary *(^DWCommand)(NSDictionary *);
typedef void (^DWJob)(void);
typedef void (^DWSchedule)(DWJob);
typedef BOOL (^DWGuard)(void);
// A worker-only native read associates a child with a typed immutable logical
// binding captured on main. It never creates controller projections on worker.
typedef DWSourceBinding *(^DWObservedBinding)(NSDictionary *observed);
// Drivers return an exact independently observed native identity, or nil.
@protocol DWNavigationDriver <NSObject>
- (DWGuard)authorization:(NSDictionary *)identity;
- (BOOL)select:(NSDictionary *)identity guard:(DWGuard)guard;
- (NSDictionary *)observe;
@optional
- (DWGuard)authorization:(NSDictionary *)identity overridingPID:(pid_t)intruderPID;
- (pid_t)frontmostPID;
@end
// Performs focus through the native driver; scheduling, epochs, held modifiers
// and native-click geometry live here. Controller owns focus/arrival policy.
@interface DWNavigationCoordinator : NSObject
- (instancetype)initWithController:(id<DWNavigationController>)controller driver:(id<DWNavigationDriver>)driver clock:(uint64_t (^)(void))clock worker:(DWSchedule)worker main:(DWSchedule)main;
@property BOOL enabled;
@property BOOL focusAllowed;
@property (copy) DWJob changed;
@property (copy) DWJob settled;
@property (copy) NSNumber *(^output)(void);
@property (copy) DWObservedBinding (^observationBinding)(void);
- (void)perform:(DWControllerReply *)reply;
@property (copy) BOOL (^arrivalProtection)(void);
- (void)cancelBackgroundArrival;
- (DWControllerReply *)attach:(DWAttachRequest *)request arrived:(BOOL)arrived adopted:(BOOL)adopted utility:(BOOL)utility;
// One typed command, size postprocessing and -perform: in the old order.
- (DWControllerReply *)navigate:(DWControllerReply *(^)(void))command;
- (void)hold:(NSUInteger)modifiers;
- (BOOL)poll:(NSUInteger)down;
- (void)releaseCycle;
- (void)interrupt;
- (void)cancelFocus;
- (void)invalidate;
- (void)shutdown;
- (void)observe;
// Native geometry ownership stays separate from controller source identity.
- (void)beginNativeClick:(DWSourceBinding *)binding output:(NSNumber *)output;
- (void)endNativeClick:(DWSourceBinding *)binding completed:(BOOL)completed;
- (void)cancelNativeClick;
@property (copy) BOOL (^nativeClickReleaseReady)(DWSourceBinding *binding,NSNumber *output);
@property BOOL filterUnsolicitedActivations;
- (uint64_t)nowNanoseconds;
- (void)noteSystemSwitchHeld:(BOOL)held;
- (void)noteSystemUIIntent;
- (void)noteLaunchIntentForBundle:(NSString *)bundle;
- (void)noteWindowClick:(NSNumber *)window;
- (void)noteApplicationLaunched:(pid_t)pid birth:(NSArray<NSNumber *> *)birth bundle:(NSString *)bundle at:(uint64_t)at;
- (void)noteApplicationActivated:(pid_t)pid birth:(NSArray<NSNumber *> *)birth bundle:(NSString *)bundle regular:(BOOL)regular at:(uint64_t)at;
- (BOOL)frame;
@end
