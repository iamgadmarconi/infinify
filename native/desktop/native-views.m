// SPDX-License-Identifier: GPL-3.0-or-later
#import "native-views.h"
#include <math.h>

@implementation DWNativeViews {
    NSDictionary<NSNumber *,NSNumber *> *_owners;
    NSDictionary<NSNumber *,NSDictionary *> *_identities;
    NSDictionary<NSNumber *,NSSet<NSNumber *> *> *_replicas;
    NSDictionary<NSNumber *,NSDictionary<NSNumber *,NSDictionary *> *> *_placements;
}
- (void)reset { _owners=@{};_identities=@{};_replicas=@{};_placements=@{}; }
- (NSSet<NSNumber *> *)capturedWindows { return [NSSet setWithArray:_replicas.allKeys?:@[]]; }
- (BOOL)replica:(NSNumber *)window output:(NSNumber *)output { return window&&output&&[_replicas[window]containsObject:output]; }
- (NSDictionary *)placement:(NSNumber *)window output:(NSNumber *)output { return window&&output?_placements[window][output]:nil; }
- (NSDictionary *)describe:(NSDictionary *)snapshot bound:(NSDictionary<NSNumber *,NSDictionary *> *)identities {
    NSMutableDictionary *choices=[NSMutableDictionary dictionary],*areas=[NSMutableDictionary dictionary],*copies=[NSMutableDictionary dictionary],*placements=[NSMutableDictionary dictionary];
    for(NSDictionary *placement in snapshot[@"placements"]){
        NSNumber *window=placement[@"window"],*output=placement[@"output"];
        if(!window||!output||!identities[window])continue;
        NSDictionary *size=placement[@"clip_rect"][@"size"];
        double area=[size[@"width"]doubleValue]*[size[@"height"]doubleValue];
        if(!isfinite(area)||area<=0)continue;
        NSMutableDictionary *views=placements[window];if(!views)placements[window]=views=[NSMutableDictionary dictionary];views[output]=placement;
        NSMutableSet *outputs=copies[window];if(!outputs)copies[window]=outputs=[NSMutableSet set];[outputs addObject:output];
        // Keep the existing native site while it is visible. Crossing an area
        // tie during a pan must not move the real window to another display.
        NSNumber *owner=[_identities[window]isEqual:identities[window]]?_owners[window]:nil;
        NSDictionary *chosen=choices[window];
        if(chosen&&([chosen[@"output"]isEqual:owner]||(![output isEqual:owner]&&area<=[areas[window]doubleValue])))continue;
        choices[window]=placement;areas[window]=@(area);
    }
    NSMutableDictionary *owners=[NSMutableDictionary dictionary],*replicas=[NSMutableDictionary dictionary];
    NSMutableArray *native=[NSMutableArray array];
    // Preserve the controller's order. The helper sorts its records separately.
    for(NSDictionary *placement in snapshot[@"placements"]){
        NSNumber *window=placement[@"window"];
        if(choices[window]!=placement)continue;
        NSNumber *owner=placement[@"output"];owners[window]=owner;[native addObject:placement];
        NSMutableSet *outputs=copies[window];[outputs removeObject:owner];if(outputs.count)replicas[window]=outputs.copy;
    }
    _owners=owners.copy;_identities=identities.copy;_replicas=replicas.copy;_placements=placements.copy;
    NSMutableDictionary *result=[snapshot mutableCopy];result[@"placements"]=native.copy;return result;
}
@end
