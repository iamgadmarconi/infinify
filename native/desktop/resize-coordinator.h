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
