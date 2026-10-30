// SPDX-License-Identifier: GPL-3.0-or-later
#import <Foundation/Foundation.h>
#import "DWCanvasRenderer.h"

// Capture only freshly parented members of roots already bound by the shell.
// Each root is {window,identity,generation,native_bounds,density,capture?,
// capture_sites,capture_all}. Required sites are {screen_rect,viewport,pixel_margin}
// in the same global screen points. Margin covers pre/post-zoom raster rounding.
// Children need a positive conservatively padded projected viewport
// intersection on some site, with two seconds of grace for installed streams.
// capture_all conservatively retains children during family geometry animation.
// Mutable demand never changes the audited binding epoch or full description.
// capture:NO observes ancestry/geometry without starting child streams. Native
// identities and bounds stay here; the renderer receives normalized images.
// Main thread only. Observation and frame identity checks run on serial workers.
@interface DWNativeReplicaFamilies : NSObject
- (instancetype)initWithChanged:(void (^)(NSNumber *window))changed;
- (void)describe:(NSArray<NSDictionary *> *)roots rate:(NSInteger)rate;
// Freshly observed geometry for offscreen-child projection, keyed by logical
// root. Matches the exact root binding; contains no pixel/input acknowledgement.
@property(nonatomic,readonly) NSDictionary<NSNumber *,NSDictionary *> *descriptions;
- (NSArray<DWCanvasAttachment *> *)attachments:(NSNumber *)window;
// Full back-to-front tokens: {window,key? ,bucket?}, with barrier:YES separating
// physical roots, stand-ins and closing elements. Reorders a whole same-bucket
// run only with complete membership and one coherent native ordering observation
// whose root order agrees with the controller. Otherwise preserves that run.
// Extra fields and exact token membership are preserved. This is drawing/order
// evidence only; it grants no native input authority.
- (NSArray<NSDictionary *> *)orderedTokens:(NSArray<NSDictionary *> *)tokens;
// Changes when the ordering meaning or captured membership changes, not for
// another pixel frame or an unchanged observation. Main-thread reads only.
@property(readonly) uint64_t orderRevision;
// A child hit in untransformed root-local points; never authorizes posting by
// itself. The caller must still validate root binding and fresh native parentage.
// Hits/contains require a published Complete image after the latest unavailable
// callback. Idle preserves that image but cannot revive revoked capture.
- (NSDictionary *)hit:(NSNumber *)window local:(CGPoint)local;
// Select only this exact currently captured opaque attachment key.
- (NSDictionary *)hit:(NSNumber *)window key:(NSString *)key local:(CGPoint)local;
- (BOOL)contains:(NSNumber *)window identity:(NSDictionary *)identity generation:(NSNumber *)generation bounds:(CGRect)bounds;
- (void)invalidatePID:(pid_t)pid;
- (void)reset;
@end
