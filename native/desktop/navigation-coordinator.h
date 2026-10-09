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
@interface DWNavigationCoordinator : NSObject
- (instancetype)initWithCommand:(DWCommand)command driver:(id<DWNavigationDriver>)driver clock:(uint64_t (^)(void))clock worker:(DWSchedule)worker main:(DWSchedule)main;
@property BOOL enabled;
@property BOOL focusAllowed;
@property (copy) DWJob changed;
@property (copy) DWJob settled;
- (void)navigate:(NSDictionary *)command;
- (void)releaseCycle;
- (void)cancelFocus; // pending focus work and the held cycle; camera flights keep flying
- (void)invalidate; // cancelFocus, and stops every camera flight
- (void)shutdown;
- (void)observe;
- (BOOL)frame;
@end
// Pure event-order boundary shared by the actual listen tap and headless host.
// Modifiers: Option=1, Shift=2, any other modifier=4.
@interface DWNavigationInput : NSObject
- (NSInteger)flagsChanged:(NSUInteger)flags; // 0 none, 1 cancel, 2 release
- (BOOL)tabDown:(NSUInteger)flags;
- (BOOL)tabUp;
- (NSNumber *)takeShortcut:(BOOL)backward; // nil rejects; value is held
- (void)cancel;
@end
