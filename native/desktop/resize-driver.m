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
static bool rootOnly(DWResizeIdentity i,void *context){(void)context;NSDictionary *f=discoverOwnedFamily(i.window,i.pid,@[@(i.birth_seconds),@(i.birth_microseconds)]);return [f[@"valid"]boolValue]&&[f[@"members"]count]==1;}
typedef struct { __unsafe_unretained DWNativeResizeDriver *driver; __unsafe_unretained NSDictionary *effect; } DWScopedResizeGuard;
static bool scopedGuard(DWResizeIdentity i,void *context){
    DWScopedResizeGuard *scope=context;
    return rootOnly(i,NULL)&&(!scope->driver.mutationPreparation||scope->driver.mutationPreparation(scope->effect));
}
static bool finalGuard(DWResizeIdentity i,void *context){
    (void)i;DWScopedResizeGuard *scope=context;
    return scope->driver.mutationGuard&&scope->driver.mutationGuard(scope->effect);
}
@implementation DWNativeResizeDriver
- (NSDictionary *)rootExtent:(NSDictionary *)i {
    if(i[@"owner"]&&i[@"owner"]!=NSNull.null)return nil;
    NSDictionary *f=discoverOwnedFamily([i[@"wid"]unsignedIntValue],[i[@"pid"]intValue],@[i[@"birth_sec"],i[@"birth_usec"]]);
    return [f[@"valid"]boolValue]&&[f[@"members"]count]==1?f[@"native_bounds"]:nil;
}
- (NSDictionary *)perform:(NSDictionary *)e {
    // The adapter result is passed unchanged, including unresolved timeout flags.
    NSDictionary *s=e[@"requested"];BOOL setter=[s isKindOfClass:NSDictionary.class];
    DWScopedResizeGuard scope={self,e};
    DWResizeResult r;
    if(!setter)r=dw_resize_observe(identity(e[@"identity"]));
    else if(self.mutationGuard)r=dw_resize_apply_scoped(identity(e[@"identity"]),CGSizeMake([s[@"width"]doubleValue],[s[@"height"]doubleValue]),scopedGuard,finalGuard,&scope);
    else r=dw_resize_apply_guarded(identity(e[@"identity"]),CGSizeMake([s[@"width"]doubleValue],[s[@"height"]doubleValue]),rootOnly,NULL);
    NSDictionary *result=@{@"outcome":@(dw_resize_outcome_name(r.outcome)),@"ax_error":@(r.ax_error),@"mutation_attempted":r.mutation_attempted?@YES:@NO,@"observed":r.observed?@YES:@NO,@"requested":@{@"width":@(r.requested.width),@"height":@(r.requested.height)},@"actual_ax":rect(r.actual_ax),@"actual_cg":rect(r.actual_cg)};
    if(self.didPerform)self.didPerform(e,result);
    return result;
}
@end
