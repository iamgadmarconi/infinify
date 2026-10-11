// SPDX-License-Identifier: GPL-3.0-or-later
#import <Foundation/Foundation.h>
#import "canvas-renderer.h"

// Capture only freshly parented members of roots already bound by the shell.
// Each root is {window,identity,generation,native_bounds,density}. Native
// identities and bounds stay here; the renderer receives normalized images.
// Main thread only. Observation and frame identity checks run on serial workers.
@interface DWNativeReplicaFamilies : NSObject
- (instancetype)initWithChanged:(void (^)(NSNumber *window))changed;
- (void)describe:(NSArray<NSDictionary *> *)roots rate:(NSInteger)rate;
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
- (NSDictionary *)hit:(NSNumber *)window local:(CGPoint)local;
// Select only this exact currently captured opaque attachment key.
- (NSDictionary *)hit:(NSNumber *)window key:(NSString *)key local:(CGPoint)local;
- (BOOL)contains:(NSNumber *)window identity:(NSDictionary *)identity generation:(NSNumber *)generation bounds:(CGRect)bounds;
- (void)invalidatePID:(pid_t)pid;
- (void)reset;
@end
