// SPDX-License-Identifier: GPL-3.0-or-later
#import "resize-driver.h"
#import "../resize/resize.h"
static NSDictionary *rect(CGRect r){return @{ @"origin":@{@"x":@(r.origin.x),@"y":@(r.origin.y)},@"size":@{@"width":@(r.size.width),@"height":@(r.size.height)}};}
static DWResizeIdentity identity(NSDictionary *i){return (DWResizeIdentity){[i[@"pid"]intValue],[i[@"birth_sec"]unsignedLongLongValue],[i[@"birth_usec"]unsignedLongLongValue],[i[@"wid"]unsignedIntValue]};}
@implementation DWNativeResizeDriver
- (NSDictionary *)perform:(NSDictionary *)e {
    // The adapter result is passed unchanged, including unresolved timeout flags.
    NSDictionary *s=e[@"requested"];BOOL setter=[s isKindOfClass:NSDictionary.class];
    DWResizeResult r;
    if(!setter)r=dw_resize_observe(identity(e[@"identity"]));
    else r=dw_resize_apply(identity(e[@"identity"]),CGSizeMake([s[@"width"]doubleValue],[s[@"height"]doubleValue]));
    NSDictionary *result=@{@"outcome":@(dw_resize_outcome_name(r.outcome)),@"ax_error":@(r.ax_error),@"mutation_attempted":r.mutation_attempted?@YES:@NO,@"observed":r.observed?@YES:@NO,@"requested":@{@"width":@(r.requested.width),@"height":@(r.requested.height)},@"actual_ax":rect(r.actual_ax),@"actual_cg":rect(r.actual_cg)};
    // The controller's result names its fields exactly, and where the window sits is in actual_ax: that a native position write
    // made room for the size first is for the trace alone.
    if(self.didPerform){NSMutableDictionary *traced=[result mutableCopy];traced[@"moved"]=r.moved?@YES:@NO;self.didPerform(e,traced);}
    return result;
}
@end
