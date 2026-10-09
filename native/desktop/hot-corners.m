// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from malbiruk/driftwm 352333a8fa1b22171492d4b71a54102045c9a19d:
// src/input/mod.rs (advance_hot_corner_latch, check_hot_corners) and
// src/config/types.rs (HotCorner::contains, HotCorners' default threshold and
// disable_while_dragging). The single latch, its stale-output rule, the corner
// order and the entry recorded before suppression are upstream's. Its
// disable_when_fullscreen has nothing to suppress: no window is fullscreen here.
#import "hot-corners.h"

static id typed(id value,Class type) { return [value isKindOfClass:type]?value:nil; }
// Upstream's order; bit 0 is the right edge, bit 1 the bottom.
static NSArray<NSString *> *cornerNames(void) { return @[@"top_left",@"top_right",@"bottom_left",@"bottom_right"]; }
// HotCorner::contains: within `threshold` of the corner on both axes.
static BOOL contains(NSInteger corner,CGPoint p,CGSize size,double threshold) {
    return (corner&1?p.x>size.width-threshold:p.x<threshold)&&(corner&2?p.y>size.height-threshold:p.y<threshold);
}
@implementation DWHotCorners {
    NSDictionary<NSNumber *,NSDictionary *> *_outputs; // output to its entry, bound corners only
    NSNumber *_latchOutput; // the output whose corner the pointer was last seen in
    NSInteger _latch;       // that corner, -1 for none
}
- (instancetype)init { if((self=[super init])){_outputs=@{};_latch=-1;}return self; }
- (void)arm:(NSArray *)outputs {
    NSMutableDictionary *bound=[NSMutableDictionary dictionary];
    for(id listed in typed(outputs,NSArray.class)){
        NSDictionary *entry=typed(listed,NSDictionary.class);NSNumber *output=typed(entry[@"output"],NSNumber.class);
        if(output&&[typed(entry[@"corners"],NSDictionary.class)count])bound[output]=entry;
    }
    _outputs=bound;
}
- (BOOL)armed { return _outputs.count!=0; }
- (NSString *)enter:(CGPoint)point size:(CGSize)size output:(NSNumber *)output dragging:(BOOL)dragging {
    NSDictionary *entry=_outputs[output];
    if(!entry){[self leave];return nil;}
    double configured=[typed(entry[@"threshold"],NSNumber.class)doubleValue],threshold=isfinite(configured)&&configured>0?configured:4;
    NSInteger active=-1;for(NSInteger corner=0;corner<4&&active<0;corner++)if(contains(corner,point,size,threshold))active=corner;
    // A latch on another output is stale: the pointer has left that output's corners.
    NSInteger previous=[_latchOutput isEqual:output]?_latch:-1;
    _latchOutput=active<0?nil:output;_latch=active;
    if(active<0||active==previous)return nil;
    // The entry is recorded first: when a drag ends inside a corner, the pointer has to leave and come back.
    NSNumber *suppress=typed(entry[@"disable_while_dragging"],NSNumber.class);
    if(dragging&&(!suppress||suppress.boolValue))return nil;
    NSString *name=cornerNames()[active];return [self action:name output:output]?name:nil;
}
- (void)leave { _latchOutput=nil;_latch=-1; }
- (NSString *)action:(NSString *)corner output:(NSNumber *)output { return corner?typed(_outputs[output][@"corners"][corner],NSString.class):nil; }
@end
