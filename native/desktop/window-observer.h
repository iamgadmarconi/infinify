// SPDX-License-Identifier: GPL-3.0-or-later
// Read-only batched window observations. Native bounds use native-presenter.h's
// pinned SkyLight ABI; this adapter introduces no native mutation API.
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

typedef NS_ENUM(NSUInteger,DWWindowObservationState) {
    DWWindowObservationPresent,
    DWWindowObservationAbsent,
    DWWindowObservationIdentityChanged,
    DWWindowObservationReadFailed,
};

@interface DWWindowObservation : NSObject
// Copied request: logical, generation, identity (PID/birth/WID), optional
// prior_bounds and families. Family failure never makes the root absent.
@property(nonatomic,copy,readonly) NSDictionary *request;
@property(nonatomic,copy,readonly) NSDictionary *info;
@property(nonatomic,copy,readonly) NSString *failure;
@property(nonatomic,copy,readonly) NSDictionary *family;
@property(nonatomic,copy,readonly) NSString *familyFailure;
@property(nonatomic,readonly) DWWindowObservationState state;
@property(nonatomic,readonly) CGRect bounds;
@property(nonatomic,readonly) BOOL hasBounds;
@property(nonatomic,readonly) CFTimeInterval sampledAt;
@end

@interface DWWindowObservationSnapshot : NSObject
@property(nonatomic,readonly) uint64_t generation;
// False means the on-screen list could not be read; an empty failed list is not
// evidence that previously discovered windows disappeared.
@property(nonatomic,readonly) BOOL listSucceeded;
@property(nonatomic,copy,readonly) NSDictionary<NSNumber *,NSDictionary *> *onScreen;
// Scoped rows in the actual front-to-back CG list order, for adoption order.
@property(nonatomic,copy,readonly) NSArray<NSDictionary *> *orderedOnScreen;
@property(nonatomic,copy,readonly) NSArray<DWWindowObservation *> *sources;
@property(nonatomic,readonly) CFTimeInterval startedAt,finishedAt,deliveredAt;
@end

// All methods and callbacks belong to main. At most one batch is in flight;
// request returns NO rather than queueing another. No native API waits on main.
@interface DWWindowObserver : NSObject
@property(nonatomic,readonly) BOOL inFlight;
// scope is PID -> [birth seconds, microseconds]. Each source has immutable
// numeric logical/generation keys and an identity dictionary. Optional
// prior_bounds is copied for the consumer's event/resize invalidation check.
// families=YES requests the audited read-only native family adapter on the
// worker. Omit it for ordinary cooperative fixtures to avoid extra queries.
// Completion must revalidate request identity + binding generation, reject
// stale sampledAt/finishedAt, and retain fresh synchronous event/input/resize
// reads. A snapshot never establishes authority to deliver native input.
- (BOOL)requestSources:(NSArray<NSDictionary *> *)sources
                 scope:(NSDictionary<NSNumber *,NSArray<NSNumber *> *> *)scope
            completion:(void (^)(DWWindowObservationSnapshot *snapshot))completion;
// Irreversible: pending native reads may finish, but their callbacks are dropped.
- (void)cancel;
@end
