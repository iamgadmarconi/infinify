// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from DriftWM, repository https://github.com/malbiruk/driftwm, commit 352333a8fa1b22171492d4b71a54102045c9a19d:
// src/input/mod.rs (advance_hot_corner_latch, check_hot_corners) and
// src/config/types.rs (HotCorner::contains, HotCorners' default threshold and
// disable_while_dragging and disable_when_fullscreen). The single latch, its
// stale-output rule, the corner order and the entry recorded before either
// suppression are upstream's. Whether a window is fullscreen on the output is the
// controller's to say (snapshot.outputs[].fullscreen); its hot_corner command applies
// the same rule, so a corner that reaches it another way runs nothing either.
#import "hot-corners.h"
#import "typed-value.h"

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
    for(id listed in DWTyped(outputs,NSArray.class)){
        NSDictionary *entry=DWTyped(listed,NSDictionary.class);NSNumber *output=DWTyped(entry[@"output"],NSNumber.class);
        if(output&&[DWTyped(entry[@"corners"],NSDictionary.class)count])bound[output]=entry;
    }
    _outputs=bound;
}
- (BOOL)armed { return _outputs.count!=0; }
- (NSString *)enter:(CGPoint)point size:(CGSize)size output:(NSNumber *)output fullscreen:(BOOL)fullscreen dragging:(BOOL)dragging {
    NSDictionary *entry=_outputs[output];
    if(!entry){[self leave];return nil;}
    double configured=[DWTyped(entry[@"threshold"],NSNumber.class)doubleValue],threshold=isfinite(configured)&&configured>0?configured:4;
    NSInteger active=-1;for(NSInteger corner=0;corner<4&&active<0;corner++)if(contains(corner,point,size,threshold))active=corner;
    // A latch on another output is stale: the pointer has left that output's corners.
    NSInteger previous=[_latchOutput isEqual:output]?_latch:-1;
    _latchOutput=active<0?nil:output;_latch=active;
    if(active<0||active==previous)return nil;
    // The entry is recorded first: when a drag ends inside a corner, or the window leaves fullscreen, the pointer has to leave and come back.
    NSNumber *suppress=DWTyped(entry[@"disable_while_dragging"],NSNumber.class),*covered=DWTyped(entry[@"disable_when_fullscreen"],NSNumber.class);
    if((fullscreen&&(!covered||covered.boolValue))||(dragging&&(!suppress||suppress.boolValue)))return nil;
    NSString *name=cornerNames()[active];return [self action:name output:output]?name:nil;
}
- (void)leave { _latchOutput=nil;_latch=-1; }
- (NSString *)action:(NSString *)corner output:(NSNumber *)output { return corner?DWTyped(_outputs[output][@"corners"][corner],NSString.class):nil; }
@end
