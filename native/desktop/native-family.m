// SPDX-License-Identifier: GPL-3.0-or-later
// Original adapter over window-server-family.h, whose read-only ABI and
// parent-query sequence preserve the MIT attribution and exact source provenance of
// yabai, https://github.com/asmvik/yabai, commit dd845723416f5fe92af49fad5ebab00369e07edd.
// See YABAI-NOTICE.txt.
#import "native-family.h"
#import "native-presenter.h"
#import "native-geometry-json.h"
#import <ApplicationServices/ApplicationServices.h>
#include <dlfcn.h>
#include <libproc.h>
#include <unistd.h>
#include <time.h>
#include <stdatomic.h>
static NSArray *birth(pid_t pid){struct proc_bsdinfo info={0};if(proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&info,sizeof(info))!=sizeof(info)||info.pbi_uid!=getuid())return nil;return @[@(info.pbi_start_tvsec),@(info.pbi_start_tvusec)];}
static NSDictionary *cgWithReason(uint32_t wid,const char **why){
    CFArrayRef a=CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow,wid);NSArray *rows=CFBridgingRelease(a);
    if(why)*why=rows?"row_absent":"list_unavailable";
    for(NSDictionary *row in rows)if([row[(id)kCGWindowNumber]unsignedIntValue]==wid){if(why)*why=NULL;return row;}return nil;
}
static NSDictionary *cg(uint32_t wid){return cgWithReason(wid,NULL);}
// window-server-family.h relies on birth() and cg() above, and on DWRectJSON() from native-geometry-json.h.
#include "window-server-family.h"

// Bounded diagnostic labels only; each label reuses the failing read above it.
static NSDictionary *discoveryBasisRefused(pid_t pid,uint32_t wid,const char *reason) {
    static atomic_uint lines;
    if(getenv("INFINIFY_DEBUG")&&atomic_load_explicit(&lines,memory_order_relaxed)<128&&atomic_fetch_add_explicit(&lines,1,memory_order_relaxed)<128){
        struct timespec at;clock_gettime(CLOCK_MONOTONIC,&at);
        fprintf(stderr,"debug: native creation basis pid=%d wid=%u at=%.6f refusal=%s\n",pid,wid,at.tv_sec+at.tv_nsec/1e9,reason);
    }
    return nil;
}
NSDictionary *DWNativeWindowDiscoveryBasis(NSDictionary *identity){
    pid_t pid=[identity[@"pid"]intValue];uint32_t wid=[identity[@"wid"]unsignedIntValue];
    id seconds=identity[@"birth_sec"],microseconds=identity[@"birth_usec"];
    if(pid<=1||!wid||![seconds isKindOfClass:NSNumber.class]||![microseconds isKindOfClass:NSNumber.class])return discoveryBasisRefused(pid,wid,"identity_format");
    NSArray *enrolled=@[seconds,microseconds];
    if(![birth(pid)isEqual:enrolled])return discoveryBasisRefused(pid,wid,"birth_before");
    const char *missing=NULL;NSDictionary *before=cgWithReason(wid,&missing);
    if(!before)return discoveryBasisRefused(pid,wid,!strcmp(missing,"row_absent")?"row_absent_before":"list_unavailable_before");
    if([before[(id)kCGWindowOwnerPID]intValue]!=pid)return discoveryBasisRefused(pid,wid,"pid_mismatch_before");
    if(![before[(id)kCGWindowIsOnscreen]boolValue])return discoveryBasisRefused(pid,wid,"offscreen_before");
    // Getter ABI: yabai dd845723416f5fe92af49fad5ebab00369e07edd,
    // src/osax/payload.m:54,606 (SLSGetWindowTransform, same signature). The effective transform is SLSGetCatenatedWindowTransform: the helper
    // writes placement 1 (native/privileged/README.md, "Placements"), which SLSGetWindowTransform (placement 0) does not show.
    static int (*connection)(void);static CGError (*transform)(int,uint32_t,CGAffineTransform *);static dispatch_once_t once;
    dispatch_once(&once,^{void *sky=dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",RTLD_NOW|RTLD_LOCAL);if(!sky)return;connection=dlsym(sky,"SLSMainConnectionID");transform=dlsym(sky,"SLSGetCatenatedWindowTransform");});
    CGRect bounds=CGRectZero,afterBounds=CGRectZero;CGAffineTransform matrix=CGAffineTransformIdentity;
    if(!connection||!transform)return discoveryBasisRefused(pid,wid,"getter_unavailable");
    if(!DWNativeBounds(wid,&bounds))return discoveryBasisRefused(pid,wid,"bounds_before");
    if(transform(connection(),wid,&matrix)!=kCGErrorSuccess)return discoveryBasisRefused(pid,wid,"transform_read");
    if(!DWNativeBounds(wid,&afterBounds))return discoveryBasisRefused(pid,wid,"bounds_after");
    if(!CGRectEqualToRect(bounds,afterBounds))return discoveryBasisRefused(pid,wid,"bounds_changed");
    for(NSNumber *value in @[@(matrix.a),@(matrix.b),@(matrix.c),@(matrix.d),@(matrix.tx),@(matrix.ty)])if(!isfinite(value.doubleValue))return discoveryBasisRefused(pid,wid,"matrix_nonfinite");
    double determinant=matrix.a*matrix.d-matrix.b*matrix.c;if(!isfinite(determinant)||fabs(determinant)<1e-8)return discoveryBasisRefused(pid,wid,"matrix_singular");
    if(![birth(pid)isEqual:enrolled])return discoveryBasisRefused(pid,wid,"birth_after");
    NSDictionary *after=cgWithReason(wid,&missing);
    if(!after)return discoveryBasisRefused(pid,wid,!strcmp(missing,"row_absent")?"row_absent_after":"list_unavailable_after");
    if([after[(id)kCGWindowOwnerPID]intValue]!=pid)return discoveryBasisRefused(pid,wid,"pid_mismatch_after");
    if(![after[(id)kCGWindowIsOnscreen]boolValue])return discoveryBasisRefused(pid,wid,"offscreen_after");
    return @{@"identity":[identity copy],@"native_bounds":CFBridgingRelease(CGRectCreateDictionaryRepresentation(bounds)),
        @"transform":@[@(matrix.a),@(matrix.b),@(matrix.c),@(matrix.d),@(matrix.tx),@(matrix.ty)]};
}

BOOL DWNativeWindowParent(NSDictionary *identity,uint32_t *parent){
    id seconds=identity[@"birth_sec"],microseconds=identity[@"birth_usec"];
    if(![seconds isKindOfClass:NSNumber.class]||![microseconds isKindOfClass:NSNumber.class])return NO;
    NSDictionary *query=queryOwnedParent([identity[@"wid"]unsignedIntValue],[identity[@"pid"]intValue],@[seconds,microseconds]);
    if(![query[@"valid"]boolValue])return NO;if(parent)*parent=[query[@"parent_id"]unsignedIntValue];return YES;
}

BOOL DWNativeWindowBelongsToRoot(NSDictionary *member,NSDictionary *root){
    for(NSString *key in @[@"pid",@"birth_sec",@"birth_usec"])if(!member[key]||![member[key]isEqual:root[key]])return NO;
    uint32_t target=[root[@"wid"]unsignedIntValue],cursor=[member[@"wid"]unsignedIntValue];if(!target||!cursor)return NO;
    id seconds=member[@"birth_sec"],microseconds=member[@"birth_usec"];
    if(![seconds isKindOfClass:NSNumber.class]||![microseconds isKindOfClass:NSNumber.class])return NO;
    pid_t pid=[member[@"pid"]intValue];NSArray *enrolled=@[seconds,microseconds];
    if(!loadFamilyAPI()||!ownedCGWindow(cursor,pid,enrolled))return NO;
    uint32_t seen[64];
    for(NSUInteger depth=0;depth<64;depth++){
        for(NSUInteger i=0;i<depth;i++)if(seen[i]==cursor)return NO;seen[depth]=cursor;
        FamilyParentQuery query=readFamilyParent(cursor);
        if(!query.exact||!ownedCGWindow(cursor,pid,enrolled))return NO;
        if(cursor==target)return !query.parent;
        // This fresh parent check is also the next iterator read's before
        // guard. Nothing is retained past this operation, and that next read
        // still gets its own process-birth/ownership check afterward.
        if(!query.parent||!ownedCGWindow(query.parent,pid,enrolled))return NO;
        cursor=query.parent;
    }
    return NO;
}

NSDictionary *DWNativeWindowFamily(NSDictionary *identity,NSString *__autoreleasing *why){
    pid_t pid=[identity[@"pid"]intValue];uint32_t root=[identity[@"wid"]unsignedIntValue];
    id seconds=identity[@"birth_sec"],microseconds=identity[@"birth_usec"];
    if(!root||pid<=1||![seconds isKindOfClass:NSNumber.class]||![microseconds isKindOfClass:NSNumber.class]){if(why)*why=@"Incomplete native root identity";return nil;}
    NSArray *enrolled=@[seconds,microseconds];NSDictionary *family=discoverOwnedFamily(root,pid,enrolled);
    if(![family[@"valid"]boolValue]){if(why)*why=family[@"error"]?:@"Native family is unavailable";return nil;}
    NSMutableArray *members=[NSMutableArray array];
    for(NSDictionary *member in family[@"members"]){
        uint32_t wid=[member[@"id"]unsignedIntValue];CGRect native=CGRectZero;
        if(!ownedCGWindow(wid,pid,enrolled)||!DWNativeBounds(wid,&native)){if(why)*why=@"Native family changed or its own bounds are unavailable";return nil;}
        NSDictionary *who=@{@"pid":@(pid),@"wid":@(wid),@"birth_sec":seconds,@"birth_usec":microseconds};
        [members addObject:@{@"identity":who,@"native_bounds":DWRectJSON(native),@"parent":member[@"parent_id"]}];
    }
    if(![birth(pid)isEqual:enrolled]||!ownedCGWindow(root,pid,enrolled)){if(why)*why=@"Native root identity changed during the family read";return nil;}
    return @{@"root":@(root),@"identity":[identity copy],@"members":members.copy};
}
