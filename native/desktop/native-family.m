// SPDX-License-Identifier: GPL-3.0-or-later
// Original adapter over ../families/window-server-family.h, whose read-only ABI
// and parent-query sequence preserve yabai's MIT attribution and exact source
// provenance. See ../families/YABAI-NOTICE.txt.
#import "native-family.h"
#import "native-presenter.h"
#import <ApplicationServices/ApplicationServices.h>
#include <dlfcn.h>
#include <libproc.h>
#include <unistd.h>
#include <time.h>
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

static double captureControlNow(void){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec+t.tv_nsec/1e9;}
static BOOL captureControlTimeout(AXUIElementRef element,double end){
    double remaining=end-captureControlNow();return remaining>0&&AXUIElementSetMessagingTimeout(element,(float)fmin(.1,remaining))==kAXErrorSuccess;
}
static id captureControlAttribute(AXUIElementRef element,CFStringRef attribute,double end){
    CFTypeRef value=NULL;if(!captureControlTimeout(element,end))return nil;
    AXError error=AXUIElementCopyAttributeValue(element,attribute,&value);
    if(error||captureControlNow()>=end){if(value)CFRelease(value);return nil;}return CFBridgingRelease(value);
}
static BOOL captureControlIdentity(NSDictionary *identity){
    if(![identity isKindOfClass:NSDictionary.class])return NO;
    if(identity[@"owner"]&&identity[@"owner"]!=NSNull.null)return NO;
    for(NSString *key in @[@"pid",@"wid",@"birth_sec",@"birth_usec"]){id n=identity[key];
        if(![n isKindOfClass:NSNumber.class]||CFGetTypeID((__bridge CFTypeRef)n)==CFBooleanGetTypeID()
            ||CFNumberIsFloatType((__bridge CFNumberRef)n)||[n compare:@0]==NSOrderedAscending
            ||![n isEqual:@([n unsignedLongLongValue])])return NO;}
    return [identity[@"pid"]unsignedLongLongValue]>1&&[identity[@"pid"]unsignedLongLongValue]<=INT32_MAX
        &&[identity[@"wid"]unsignedLongLongValue]>0&&[identity[@"wid"]unsignedLongLongValue]<=UINT32_MAX
        &&[identity[@"birth_sec"]unsignedLongLongValue]>0&&[identity[@"birth_usec"]unsignedLongLongValue]<1000000;
}
static BOOL captureControlRect(CGRect r){return isfinite(r.origin.x)&&isfinite(r.origin.y)&&isfinite(r.size.width)&&isfinite(r.size.height)
    &&r.size.width>0&&r.size.height>0&&isfinite(CGRectGetMaxX(r))&&isfinite(CGRectGetMaxY(r));}
static BOOL captureControlCurrent(NSDictionary *member,NSDictionary *root,CGRect rootBounds,CGRect memberBounds){
    uint32_t parent=0,rootParent=0;CGRect own=CGRectNull,child=CGRectNull;
    return DWNativeWindowParent(root,&rootParent)&&!rootParent&&DWNativeWindowParent(member,&parent)&&parent==[root[@"wid"]unsignedIntValue]
        &&DWNativeBounds([root[@"wid"]unsignedIntValue],&own)&&CGRectEqualToRect(own,rootBounds)
        &&DWNativeBounds([member[@"wid"]unsignedIntValue],&child)&&CGRectEqualToRect(child,memberBounds)
        &&ownedCGWindow([root[@"wid"]unsignedIntValue],[root[@"pid"]intValue],@[root[@"birth_sec"],root[@"birth_usec"]])
        &&ownedCGWindow([member[@"wid"]unsignedIntValue],[member[@"pid"]intValue],@[member[@"birth_sec"],member[@"birth_usec"]]);
}
BOOL DWNativeWindowIsCaptureControl(NSDictionary *member,NSDictionary *root,CGRect rootBounds,CGRect memberBounds){@autoreleasepool{
    if(!captureControlIdentity(member)||!captureControlIdentity(root)||[member[@"wid"]isEqual:root[@"wid"]]
        ||!captureControlRect(rootBounds)||!captureControlRect(memberBounds)||!CGRectContainsRect(rootBounds,memberBounds))return NO;
    for(NSString *key in @[@"pid",@"birth_sec",@"birth_usec"])if(![member[key]isEqual:root[key]])return NO;
    // Same established private getter as focus/resize: pinned yabai
    // dd845723416f5fe92af49fad5ebab00369e07edd src/misc/extern.h:8.
    AXError (*getWindow)(AXUIElementRef,uint32_t *)=dlsym(RTLD_DEFAULT,"_AXUIElementGetWindow");
    if(!getWindow||!AXIsProcessTrusted()||!captureControlCurrent(member,root,rootBounds,memberBounds))return NO;
    // The real Finder's first AXWindows response exceeded the former 20 ms
    // call allowance. This bounded worker read remains within the observer's
    // two-second request fence; every native identity/bounds check stays exact.
    double end=captureControlNow()+.5;pid_t expected=[member[@"pid"]intValue];uint32_t wanted=[member[@"wid"]unsignedIntValue];
    AXUIElementRef app=AXUIElementCreateApplication(expected);if(!app)return NO;
    id windows=captureControlAttribute(app,kAXWindowsAttribute,end);CFRelease(app);
    if(![windows isKindOfClass:NSArray.class]||![windows count]||[windows count]>256)return NO;
    id found=nil;
    for(id item in windows){
        if(CFGetTypeID((__bridge CFTypeRef)item)!=AXUIElementGetTypeID())return NO;
        AXUIElementRef element=(__bridge AXUIElementRef)item;pid_t pid=0;uint32_t wid=0;
        if(!captureControlTimeout(element,end)||AXUIElementGetPid(element,&pid)||pid!=expected)return NO;
        if(!captureControlTimeout(element,end))return NO;
        AXError error=getWindow(element,&wid);
        // Finder's verified same-process desktop is the established sole
        // windowless exception; an unreadable actual window is uncertainty.
        if(error==kAXErrorIllegalArgument&&[captureControlAttribute(element,kAXRoleAttribute,end)isEqual:(__bridge NSString *)kAXScrollAreaRole])continue;
        if(error||captureControlNow()>=end)return NO;
        if(wid==wanted){if(found)return NO;found=item;}
    }
    if(!found)return NO;AXUIElementRef window=(__bridge AXUIElementRef)found;
    if(![captureControlAttribute(window,kAXRoleAttribute,end)isEqual:(__bridge NSString *)kAXWindowRole]
        ||![captureControlAttribute(window,kAXSubroleAttribute,end)isEqual:(__bridge NSString *)kAXDialogSubrole])return NO;
    id children=captureControlAttribute(window,kAXChildrenAttribute,end);
    if(![children isKindOfClass:NSArray.class]||[children count]!=1||CFGetTypeID((__bridge CFTypeRef)children[0])!=AXUIElementGetTypeID())return NO;
    AXUIElementRef button=(__bridge AXUIElementRef)children[0];pid_t pid=0;uint32_t wid=0;
    // This control's button has no private window ID (IllegalArgument on the
    // observed Finder). Bind it through the exact window's sole direct child,
    // same PID and the repeated CFEqual membership check below instead.
    if(!captureControlTimeout(button,end)||AXUIElementGetPid(button,&pid)||pid!=expected
        ||![captureControlAttribute(button,kAXRoleAttribute,end)isEqual:(__bridge NSString *)kAXButtonRole]
        ||![captureControlAttribute(button,kAXTitleAttribute,end)isEqual:@"WindowSharingSessionButton"]
        ||!captureControlTimeout(window,end)||AXUIElementGetPid(window,&pid)||pid!=expected
        ||!captureControlTimeout(window,end)||getWindow(window,&wid)||wid!=wanted
        ||captureControlNow()>=end)return NO;
    id afterChildren=captureControlAttribute(window,kAXChildrenAttribute,end);
    if(![afterChildren isKindOfClass:NSArray.class]||[afterChildren count]!=1
        ||!CFEqual((__bridge CFTypeRef)children[0],(__bridge CFTypeRef)afterChildren[0]))return NO;
    return captureControlCurrent(member,root,rootBounds,memberBounds);
}}
