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

BOOL DWNativeWindowParent(NSDictionary *identity,uint32_t *parent){
    id seconds=identity[@"birth_sec"],microseconds=identity[@"birth_usec"];
    if(![seconds isKindOfClass:NSNumber.class]||![microseconds isKindOfClass:NSNumber.class])return NO;
    NSDictionary *query=queryOwnedParent([identity[@"wid"]unsignedIntValue],[identity[@"pid"]intValue],@[seconds,microseconds]);
    if(![query[@"valid"]boolValue])return NO;if(parent)*parent=[query[@"parent_id"]unsignedIntValue];return YES;
}

BOOL DWNativeWindowBelongsToRoot(NSDictionary *member,NSDictionary *root){
    for(NSString *key in @[@"pid",@"birth_sec",@"birth_usec"])if(!member[key]||![member[key]isEqual:root[key]])return NO;
    uint32_t target=[root[@"wid"]unsignedIntValue],cursor=[member[@"wid"]unsignedIntValue];if(!target||!cursor)return NO;
    NSMutableSet<NSNumber *> *seen=[NSMutableSet set];
    for(NSUInteger depth=0;depth<64;depth++){
        if([seen containsObject:@(cursor)])return NO;[seen addObject:@(cursor)];
        NSMutableDictionary *identity=[member mutableCopy];identity[@"wid"]=@(cursor);uint32_t parent=0;
        if(!DWNativeWindowParent(identity,&parent))return NO;
        if(cursor==target)return !parent;
        if(!parent)return NO;cursor=parent;
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
