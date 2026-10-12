// SPDX-License-Identifier: GPL-3.0-or-later
#import "resize-driver.h"
#import "../resize/resize.h"
#include <dlfcn.h>
#include <sys/sysctl.h>
static NSDictionary *rect(CGRect r){return @{ @"origin":@{@"x":@(r.origin.x),@"y":@(r.origin.y)},@"size":@{@"width":@(r.size.width),@"height":@(r.size.height)}};}
static NSArray *birth(pid_t pid){int mib[]={CTL_KERN,KERN_PROC,KERN_PROC_PID,pid};struct kinfo_proc p={0};size_t n=sizeof(p);if(sysctl(mib,4,&p,&n,NULL,0)||!n)return nil;return @[@(p.kp_proc.p_starttime.tv_sec),@(p.kp_proc.p_starttime.tv_usec)];}
static NSDictionary *cg(uint32_t wid){CFArrayRef a=CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow,wid);NSArray *values=CFBridgingRelease(a);return values.count==1?values[0]:nil;}
#include "../families/window-server-family.h"
static DWResizeIdentity identity(NSDictionary *i){return (DWResizeIdentity){[i[@"pid"]intValue],[i[@"birth_sec"]unsignedLongLongValue],[i[@"birth_usec"]unsignedLongLongValue],[i[@"wid"]unsignedIntValue]};}
@implementation DWNativeResizeDriver
- (NSDictionary *)rootExtent:(NSDictionary *)i {
    if(i[@"owner"]&&i[@"owner"]!=NSNull.null)return nil;
    NSDictionary *f=discoverOwnedFamily([i[@"wid"]unsignedIntValue],[i[@"pid"]intValue],@[i[@"birth_sec"],i[@"birth_usec"]]);
    return [f[@"valid"]boolValue]&&[f[@"members"]count]==1?f[@"native_bounds"]:nil;
}
// The same query once more, for its own account of why it gave no root-only extent: a diagnosis for the person running the app.
- (NSString *)rootExtentRefusal:(NSDictionary *)i {
    if(i[@"owner"]&&i[@"owner"]!=NSNull.null)return @"the window is bound through a WindowServer owner";
    NSDictionary *f=discoverOwnedFamily([i[@"wid"]unsignedIntValue],[i[@"pid"]intValue],@[i[@"birth_sec"],i[@"birth_usec"]]);
    if(![f[@"valid"]boolValue])return [NSString stringWithFormat:@"no root extent: %@",[f[@"error"]isKindOfClass:NSString.class]?f[@"error"]:@"the native family could not be read"];
    if([f[@"members"]count]!=1)return [NSString stringWithFormat:@"no root-only extent: %lu native windows in its family (the window and %lu attached to it)",(unsigned long)[f[@"members"]count],(unsigned long)[f[@"members"]count]-1];
    return @"its family read as root-only when asked again";
}
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
