// SPDX-License-Identifier: GPL-3.0-or-later
#import <Foundation/Foundation.h>

// Adapter-only presentation plan. A native window has one WindowServer
// transform; other output placements are live images with independent cameras.
// No world/camera state is changed here. Main thread only.
@interface DWNativeViews : NSObject
- (NSDictionary *)describe:(NSDictionary *)snapshot bound:(NSDictionary<NSNumber *,NSDictionary *> *)identities;
- (BOOL)replica:(NSNumber *)window output:(NSNumber *)output;
- (NSDictionary *)placement:(NSNumber *)window output:(NSNumber *)output;
@property(nonatomic,readonly) NSSet<NSNumber *> *capturedWindows;
- (void)reset;
@end
