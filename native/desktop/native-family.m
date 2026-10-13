// SPDX-License-Identifier: GPL-3.0-or-later
// Original adapter over ../families/window-server-family.h, whose read-only ABI
// and parent-query sequence preserve yabai's MIT attribution and exact source
// provenance. See ../families/YABAI-NOTICE.txt.
#import "native-family.h"
#import "native-presenter.h"
#include <dlfcn.h>
#include <libproc.h>
#include <unistd.h>
static NSDictionary *rect(CGRect r){return @{ @"origin":@{@"x":@(r.origin.x),@"y":@(r.origin.y)},@"size":@{@"width":@(r.size.width),@"height":@(r.size.height)}};}
static NSArray *birth(pid_t pid){struct proc_bsdinfo info={0};if(proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&info,sizeof(info))!=sizeof(info)||info.pbi_uid!=getuid())return nil;return @[@(info.pbi_start_tvsec),@(info.pbi_start_tvusec)];}
static NSDictionary *cg(uint32_t wid){CFArrayRef a=CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow,wid);NSArray *rows=CFBridgingRelease(a);for(NSDictionary *row in rows)if([row[(id)kCGWindowNumber]unsignedIntValue]==wid)return row;return nil;}
#include "../families/window-server-family.h"

NSDictionary *DWNativeWindowDiscoveryBasis(NSDictionary *identity){
    pid_t pid=[identity[@"pid"]intValue];uint32_t wid=[identity[@"wid"]unsignedIntValue];
    id seconds=identity[@"birth_sec"],microseconds=identity[@"birth_usec"];
    if(pid<=1||!wid||![seconds isKindOfClass:NSNumber.class]||![microseconds isKindOfClass:NSNumber.class])return nil;
    NSArray *enrolled=@[seconds,microseconds];NSDictionary *before=ownedCGWindow(wid,pid,enrolled);
    if(![before[(id)kCGWindowIsOnscreen]boolValue])return nil;
    // Getter ABI: yabai dd845723416f5fe92af49fad5ebab00369e07edd,
    // src/osax/payload.m:54,606; the same reader as native/backend/bridge.m.
    static int (*connection)(void);static CGError (*transform)(int,uint32_t,CGAffineTransform *);static dispatch_once_t once;
    dispatch_once(&once,^{void *sky=dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",RTLD_NOW|RTLD_LOCAL);if(!sky)return;connection=dlsym(sky,"SLSMainConnectionID");transform=dlsym(sky,"SLSGetWindowTransform");});
    CGRect bounds=CGRectZero,afterBounds=CGRectZero;CGAffineTransform matrix=CGAffineTransformIdentity;
    if(!connection||!transform||!DWNativeBounds(wid,&bounds)||transform(connection(),wid,&matrix)!=kCGErrorSuccess||!DWNativeBounds(wid,&afterBounds)||!CGRectEqualToRect(bounds,afterBounds))return nil;
    for(NSNumber *value in @[@(matrix.a),@(matrix.b),@(matrix.c),@(matrix.d),@(matrix.tx),@(matrix.ty)])if(!isfinite(value.doubleValue))return nil;
    double determinant=matrix.a*matrix.d-matrix.b*matrix.c;if(!isfinite(determinant)||fabs(determinant)<1e-8)return nil;
    NSDictionary *after=ownedCGWindow(wid,pid,enrolled);if(![after[(id)kCGWindowIsOnscreen]boolValue])return nil;
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
        [members addObject:@{@"identity":who,@"native_bounds":rect(native),@"parent":member[@"parent_id"]}];
    }
    if(![birth(pid)isEqual:enrolled]||!ownedCGWindow(root,pid,enrolled)){if(why)*why=@"Native root identity changed during the family read";return nil;}
    return @{@"root":@(root),@"identity":[identity copy],@"members":members.copy};
}
