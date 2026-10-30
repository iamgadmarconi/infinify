// SPDX-License-Identifier: GPL-3.0-or-later
// Read-only ABI cross-checked in ../../dock-helper/Payload/DWPayloadState.m and the owned event-hit
// fixture against yabai (MIT), https://github.com/asmvik/yabai,
// dd845723416f5fe92af49fad5ebab00369e07edd:
// src/osax/payload.m; src/misc/extern.h:16,17,79,82. Native parent discovery is
// provided by DWNativeFamily.m. Preserve YABAI-NOTICE.txt (this directory, the
// yabai licence text). No setter or ownership-transfer API is loaded.
#import "DWNativePlacementValidation.h"
#import "DWNativeFamily.h"
#include "DWHelperProtocol.h"
#include <dlfcn.h>
#include <libproc.h>
#include <limits.h>
#include <math.h>
#include <unistd.h>

typedef struct {
    int (*connection)(void);
    CGError (*owner)(int,uint32_t,int *);
    CGError (*connectionPID)(int,pid_t *);
    CGError (*bounds)(int,uint32_t,CGRect *);
    CGError (*transform)(int,uint32_t,CGAffineTransform *);
    CGError (*screen)(int,uint32_t,CGRect *);
    CGError (*alpha)(int,uint32_t,float *);
    CGError (*hit)(int,int,int,int,const CGPoint *,CGPoint *,uint32_t *,int *);
} DWPlacementReadAPI;
static DWPlacementReadAPI placementReadAPI;
static BOOL DWPlacementLoadAPI(void) {
    static dispatch_once_t once;
    dispatch_once(&once,^{
        void *handle=dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",RTLD_NOW|RTLD_LOCAL);
        if(!handle)return;
        placementReadAPI.connection=dlsym(handle,"SLSMainConnectionID");
        placementReadAPI.owner=dlsym(handle,"SLSGetWindowOwner");
        placementReadAPI.connectionPID=dlsym(handle,"SLSConnectionGetPID");
        placementReadAPI.bounds=dlsym(handle,"SLSGetWindowBounds");
        // The effective (catenated) transform, which is what is drawn: the helper writes placement 1, not placement 0 (native/privileged/README.md, "Placements").
        placementReadAPI.transform=dlsym(handle,"SLSGetCatenatedWindowTransform");
        placementReadAPI.screen=dlsym(handle,"SLSGetScreenRectForWindow");
        placementReadAPI.alpha=dlsym(handle,"SLSGetWindowAlpha");
        placementReadAPI.hit=dlsym(handle,"SLSFindWindowAndOwner");
    });
    return placementReadAPI.connection&&placementReadAPI.owner&&placementReadAPI.connectionPID
        &&placementReadAPI.bounds&&placementReadAPI.transform&&placementReadAPI.screen&&placementReadAPI.alpha;
}
static BOOL DWPlacementRefuse(NSString *__autoreleasing *why,NSString *reason) {
    if(why)*why=reason;return NO;
}
static BOOL DWPlacementNumber(id value) {
    return [value isKindOfClass:NSNumber.class]&&CFGetTypeID((__bridge CFTypeRef)value)!=CFBooleanGetTypeID();
}
static BOOL DWPlacementInteger(id value,uint64_t minimum,uint64_t maximum) {
    return DWPlacementNumber(value)&&!CFNumberIsFloatType((__bridge CFNumberRef)value)
        &&[value longLongValue]>=0&&[value unsignedLongLongValue]>=minimum&&[value unsignedLongLongValue]<=maximum;
}
static NSDictionary *DWPlacementIdentity(id value,BOOL ownerRequired) {
    if(![value isKindOfClass:NSDictionary.class])return nil;
    NSDictionary *who=value;
    if(!DWPlacementInteger(who[@"pid"],2,INT_MAX)||!DWPlacementInteger(who[@"wid"],1,UINT32_MAX)
        ||!DWPlacementInteger(who[@"birth_sec"],1,INT64_MAX)||!DWPlacementInteger(who[@"birth_usec"],0,999999))return nil;
    id owner=who[@"owner"];
    if(ownerRequired?!DWPlacementInteger(owner,1,INT_MAX):(owner&&owner!=NSNull.null))return nil;
    return @{@"pid":who[@"pid"],@"wid":who[@"wid"],@"birth_sec":who[@"birth_sec"],@"birth_usec":who[@"birth_usec"]};
}
static BOOL DWPlacementRectValid(CGRect r) {
    return !CGRectIsNull(r)&&!CGRectIsInfinite(r)&&isfinite(r.origin.x)&&isfinite(r.origin.y)
        &&isfinite(r.size.width)&&isfinite(r.size.height)&&r.size.width>0&&r.size.height>0
        &&isfinite(CGRectGetMaxX(r))&&isfinite(CGRectGetMaxY(r));
}
static BOOL DWPlacementRectArray(id value,CGRect *out) {
    if(![value isKindOfClass:NSArray.class]||[value count]!=4)return NO;
    for(id field in value)if(!DWPlacementNumber(field)||!isfinite([field doubleValue]))return NO;
    CGRect r=CGRectMake([value[0]doubleValue],[value[1]doubleValue],[value[2]doubleValue],[value[3]doubleValue]);
    if(!DWPlacementRectValid(r))return NO;*out=r;return YES;
}
static BOOL DWPlacementRectNamed(id value,CGRect *out) {
    if(![value isKindOfClass:NSDictionary.class])return NO;
    id origin=value[@"origin"],size=value[@"size"];
    if(![origin isKindOfClass:NSDictionary.class]||![size isKindOfClass:NSDictionary.class])return NO;
    NSArray *fields=@[origin[@"x"]?:NSNull.null,origin[@"y"]?:NSNull.null,size[@"width"]?:NSNull.null,size[@"height"]?:NSNull.null];
    return DWPlacementRectArray(fields,out);
}
static BOOL DWPlacementMatrixArray(id value,CGAffineTransform *out) {
    if(![value isKindOfClass:NSArray.class]||[value count]!=6)return NO;
    for(id field in value)if(!DWPlacementNumber(field)||!isfinite([field doubleValue])||fabs([field doubleValue])>1e6)return NO;
    CGAffineTransform t=CGAffineTransformMake([value[0]doubleValue],[value[1]doubleValue],[value[2]doubleValue],
        [value[3]doubleValue],[value[4]doubleValue],[value[5]doubleValue]);
    // The presenter emits only positive, axis-aligned screen-to-local matrices.
    // Do not infer admission for an independently rotated/sheared placement.
    if(t.a<=0||t.d<=0||t.b!=0||t.c!=0||!isfinite(t.a*t.d)||t.a*t.d<1e-8)return NO;
    *out=t;return YES;
}
static BOOL DWPlacementMatrixMatches(CGAffineTransform actual,CGAffineTransform requested) {
    // Installed native setter narrows all six coefficients to float, and the
    // helper uses this exact equality. No arbitrary geometric tolerance is added.
    return isfinite(actual.a)&&isfinite(actual.b)&&isfinite(actual.c)&&isfinite(actual.d)&&isfinite(actual.tx)&&isfinite(actual.ty)
        &&actual.a==(double)(float)requested.a&&actual.b==(double)(float)requested.b
        &&actual.c==(double)(float)requested.c&&actual.d==(double)(float)requested.d
        &&actual.tx==(double)(float)requested.tx&&actual.ty==(double)(float)requested.ty;
}
static CGRect DWPlacementScreen(CGRect native,CGAffineTransform t) {
    if(t.a<=0||t.d<=0||t.b!=0||t.c!=0)return CGRectNull;
    return CGRectMake(-t.tx/t.a,-t.ty/t.d,native.size.width/t.a,native.size.height/t.d);
}
static CGRect DWPlacementEnclosing(CGRect r) {
    double x=floor(r.origin.x),y=floor(r.origin.y);
    return CGRectMake(x,y,ceil(CGRectGetMaxX(r))-x,ceil(CGRectGetMaxY(r))-y);
}
static BOOL DWPlacementProcessCurrent(NSDictionary *who) {
    struct proc_bsdinfo info={0};pid_t pid=[who[@"pid"]intValue];
    return proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&info,sizeof(info))==sizeof(info)&&info.pbi_uid==getuid()
        &&info.pbi_start_tvsec==[who[@"birth_sec"]unsignedLongLongValue]&&info.pbi_start_tvusec==[who[@"birth_usec"]unsignedLongLongValue];
}
static NSDictionary *DWPlacementCGWindow(uint32_t wid) {
    NSArray *rows=CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow,wid));
    NSDictionary *found=nil;
    for(id value in rows){
        if(![value isKindOfClass:NSDictionary.class])return nil;
        if(!DWPlacementInteger(value[(id)kCGWindowNumber],1,UINT32_MAX))return nil;
        if([value[(id)kCGWindowNumber]unsignedIntValue]!=wid)continue;
        if(found)return nil;found=value;
    }
    return found;
}
// Bracket every private getter with the exact process, public WID/PID, native
// owner connection and that connection's PID. No owner is borrowed from an ACK.
static BOOL DWPlacementMemberCurrent(NSDictionary *who,int owner,NSDictionary **rowOut) {
    if(!DWPlacementProcessCurrent(who))return NO;
    NSDictionary *row=DWPlacementCGWindow([who[@"wid"]unsignedIntValue]);
    if(!row||!DWPlacementInteger(row[(id)kCGWindowOwnerPID],2,INT_MAX)||[row[(id)kCGWindowOwnerPID]intValue]!=[who[@"pid"]intValue])return NO;
    int actual=0;pid_t pid=0;
    if(placementReadAPI.owner(placementReadAPI.connection(),[who[@"wid"]unsignedIntValue],&actual)!=kCGErrorSuccess
        ||actual<=0||(owner&&actual!=owner)||placementReadAPI.connectionPID(actual,&pid)!=kCGErrorSuccess
        ||pid!=[who[@"pid"]intValue]||!DWPlacementProcessCurrent(who))return NO;
    if(rowOut)*rowOut=row;return YES;
}
NSDictionary *DWNativeEventRecipientAtPoint(CGPoint point) {
    if(!NSThread.isMainThread||!isfinite(point.x)||!isfinite(point.y)||!DWPlacementLoadAPI()||!placementReadAPI.hit)return nil;
    uint32_t wid=0,again=0;int owner=0,againOwner=0;pid_t pid=0;CGPoint local=CGPointZero;
    if(placementReadAPI.hit(placementReadAPI.connection(),0,1,0,&point,&local,&wid,&owner)!=kCGErrorSuccess
        ||!wid||owner<=0||placementReadAPI.connectionPID(owner,&pid)!=kCGErrorSuccess||pid<=1)return nil;
    struct proc_bsdinfo info={0};
    if(proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&info,sizeof(info))!=sizeof(info)||info.pbi_pid!=(uint32_t)pid
        ||info.pbi_uid!=getuid()||!info.pbi_start_tvsec||info.pbi_start_tvusec>=1000000)return nil;
    NSDictionary *identity=@{@"pid":@(pid),@"wid":@(wid),@"birth_sec":@(info.pbi_start_tvsec),@"birth_usec":@(info.pbi_start_tvusec)};
    if(!DWPlacementMemberCurrent(identity,owner,NULL)
        ||placementReadAPI.hit(placementReadAPI.connection(),0,1,0,&point,&local,&again,&againOwner)!=kCGErrorSuccess
        ||again!=wid||againOwner!=owner||!DWPlacementMemberCurrent(identity,owner,NULL))return nil;
    NSMutableDictionary *recipient=[identity mutableCopy];recipient[@"owner"]=@(owner);return recipient.copy;
}
static NSDictionary<NSNumber *,NSDictionary *> *DWPlacementFamily(DWNativeAppliedPlacement *placement) {
    NSDictionary *family=DWNativeWindowFamily(placement.identity,NULL);
    if(!family||![DWPlacementIdentity(family[@"identity"],NO)isEqual:placement.identity]
        ||![family[@"root"]isEqual:placement.identity[@"wid"]]||![family[@"members"]isKindOfClass:NSArray.class]
        ||[family[@"members"]count]!=placement.members.count)return nil;
    NSMutableDictionary *members=[NSMutableDictionary dictionary];
    for(id member in family[@"members"]){
        if(![member isKindOfClass:NSDictionary.class])return nil;
        NSDictionary *who=DWPlacementIdentity(member[@"identity"],NO);CGRect native=CGRectZero;
        if(!who||members[who[@"wid"]]||!DWPlacementInteger(member[@"parent"],0,UINT32_MAX)
            ||!DWPlacementRectNamed(member[@"native_bounds"],&native)||!DWNativeWindowBelongsToRoot(who,placement.identity))return nil;
        members[who[@"wid"]]=member;
    }
    // Preserve exact parent IDs too: an intermediate reparenting is a changed
    // family even if its transitive root is unchanged.
    for(NSDictionary *requested in placement.members){
        NSDictionary *who=DWPlacementIdentity(requested[@"identity"],NO);if(!who)return nil;
        NSDictionary *member=members[who[@"wid"]];CGRect expected=CGRectZero,actual=CGRectZero;
        if(!member||![DWPlacementIdentity(member[@"identity"],NO)isEqual:who]
            ||!DWPlacementInteger(requested[@"parent"],0,UINT32_MAX)||![member[@"parent"]isEqual:requested[@"parent"]]
            ||!DWPlacementRectArray(requested[@"native_bounds"],&expected)||!DWPlacementRectNamed(member[@"native_bounds"],&actual)
            ||!CGRectEqualToRect(expected,actual))return nil;
    }
    return members.copy;
}
typedef struct {
    CGRect native,screen;
    CGAffineTransform transform;
    float alpha;
    int owner;
} DWPlacementObservation;
static BOOL DWPlacementObserve(NSDictionary *requested,CGRect viewport,DWPlacementObservation *out) {
    NSDictionary *who=DWPlacementIdentity(requested[@"identity"],NO);CGRect expected=CGRectZero;CGAffineTransform matrix={0};
    if(!who||!DWPlacementRectArray(requested[@"native_bounds"],&expected)||!DWPlacementMatrixArray(requested[@"requested_transform"],&matrix)
        ||!DWPlacementInteger(requested[@"flags"],0,DW2_RECORD_HAS_ALPHA))return NO;
    uint32_t flags=[requested[@"flags"]unsignedIntValue];id alpha=requested[@"requested_alpha"];
    if(flags&DW2_RECORD_HAS_ALPHA){if(!DWPlacementNumber(alpha)||!isfinite([alpha doubleValue])||[alpha doubleValue]<=0||[alpha doubleValue]>1)return NO;}
    else if(alpha!=NSNull.null)return NO;
    uint32_t wid=[who[@"wid"]unsignedIntValue];DWPlacementObservation seen={0};
    if(!DWPlacementMemberCurrent(who,0,NULL)||placementReadAPI.owner(placementReadAPI.connection(),wid,&seen.owner)!=kCGErrorSuccess
        ||!DWPlacementMemberCurrent(who,seen.owner,NULL))return NO;
    if(placementReadAPI.bounds(placementReadAPI.connection(),wid,&seen.native)!=kCGErrorSuccess
        ||!CGRectEqualToRect(seen.native,expected)||!DWPlacementMemberCurrent(who,seen.owner,NULL))return NO;
    if(placementReadAPI.transform(placementReadAPI.connection(),wid,&seen.transform)!=kCGErrorSuccess
        ||!DWPlacementMatrixMatches(seen.transform,matrix)||!DWPlacementMemberCurrent(who,seen.owner,NULL))return NO;
    CGRect precise=DWPlacementScreen(seen.native,seen.transform);
    if(!DWPlacementRectValid(precise)||!CGRectContainsRect(viewport,precise))return NO;
    if(placementReadAPI.screen(placementReadAPI.connection(),wid,&seen.screen)!=kCGErrorSuccess
        ||!DWPlacementRectValid(seen.screen)||!CGRectEqualToRect(seen.screen,DWPlacementEnclosing(precise))
        ||!CGRectContainsRect(viewport,seen.screen)||!DWPlacementMemberCurrent(who,seen.owner,NULL))return NO;
    NSDictionary *row=nil;
    if(placementReadAPI.alpha(placementReadAPI.connection(),wid,&seen.alpha)!=kCGErrorSuccess
        ||!isfinite(seen.alpha)||seen.alpha<=0||seen.alpha>1||(flags&DW2_RECORD_HAS_ALPHA&&seen.alpha!=[alpha floatValue])
        ||!DWPlacementMemberCurrent(who,seen.owner,&row))return NO;
    id publicAlpha=row[(id)kCGWindowAlpha],onscreen=row[(id)kCGWindowIsOnscreen];
    if(![onscreen isEqual:@YES]||!DWPlacementNumber(publicAlpha)||!isfinite([publicAlpha doubleValue])
        ||[publicAlpha doubleValue]<=0||[publicAlpha doubleValue]>1||(float)[publicAlpha doubleValue]!=seen.alpha)return NO;
    *out=seen;return YES;
}
static BOOL DWPlacementVerify(DWNativePresenter *presenter,DWNativeAppliedPlacement *placement,
    NSDictionary *recipient,CGPoint point,BOOL input,NSString *__autoreleasing *why) {
    if(why)*why=nil;
    if(!NSThread.isMainThread||!presenter||!placement||![presenter isAcknowledgedPlacementCurrent:placement])
        return DWPlacementRefuse(why,@"Native placement receipt is not current");
    NSDictionary *root=DWPlacementIdentity(placement.identity,NO),*target=input?DWPlacementIdentity(recipient,YES):nil;
    if(!root||(input&&(!target||!isfinite(point.x)||!isfinite(point.y)))||!placement.members.count||placement.members.count>64
        ||!DWPlacementRectValid(placement.requestedScreenRect)||!DWPlacementRectValid(placement.requestedClipRect)
        ||!DWPlacementRectValid(placement.requestedViewport)||!CGRectEqualToRect(placement.requestedClipRect,placement.requestedScreenRect)
        ||!CGRectContainsRect(placement.requestedViewport,placement.requestedScreenRect))
        return DWPlacementRefuse(why,@"Native placement is incomplete or requires unsupported clipping");
    if(!DWPlacementLoadAPI()||(input&&!placementReadAPI.hit))return DWPlacementRefuse(why,@"Native placement getters are unavailable");
    NSDictionary *before=DWPlacementFamily(placement);if(!before)return DWPlacementRefuse(why,@"Native placement family or basis changed");
    NSMutableData *observations=[NSMutableData dataWithLength:placement.members.count*sizeof(DWPlacementObservation)];
    DWPlacementObservation *values=observations.mutableBytes;NSUInteger targetIndex=NSNotFound;uint32_t last=0;CGRect rootNative=CGRectZero;
    if(!DWPlacementRectNamed(before[root[@"wid"]][@"native_bounds"],&rootNative))return DWPlacementRefuse(why,@"Native root is missing");
    NSUInteger index=0;
    for(NSDictionary *member in placement.members){
        NSDictionary *who=DWPlacementIdentity(member[@"identity"],NO);CGRect native=CGRectZero;CGAffineTransform requested={0};
        if(!who||[who[@"wid"]unsignedIntValue]<=last||!DWPlacementRectArray(member[@"native_bounds"],&native)
            ||!DWPlacementMatrixArray(member[@"requested_transform"],&requested))return DWPlacementRefuse(why,@"Native placement member is invalid");
        last=[who[@"wid"]unsignedIntValue];double mx=rootNative.size.width/placement.requestedScreenRect.size.width,my=rootNative.size.height/placement.requestedScreenRect.size.height;
        CGAffineTransform expected=CGAffineTransformMake(mx,0,0,my,-placement.requestedScreenRect.origin.x*mx-(native.origin.x-rootNative.origin.x),
            -placement.requestedScreenRect.origin.y*my-(native.origin.y-rootNative.origin.y));
        if(!CGAffineTransformEqualToTransform(expected,requested)||!DWPlacementObserve(member,placement.requestedViewport,&values[index]))
            return DWPlacementRefuse(why,@"Native placement geometry or visibility is not observed");
        if(input&&[who isEqual:target])targetIndex=index;
        index++;
    }
    // Getters are separate server requests. A second complete read and a fresh
    // association/ancestry query reject a family or placement changing mid-check.
    if(![before isEqual:DWPlacementFamily(placement)])return DWPlacementRefuse(why,@"Native family changed during verification");
    index=0;
    for(NSDictionary *member in placement.members){
        DWPlacementObservation again={0},seen=values[index++];
        if(!DWPlacementObserve(member,placement.requestedViewport,&again)||seen.owner!=again.owner
            ||!CGRectEqualToRect(seen.native,again.native)||!CGRectEqualToRect(seen.screen,again.screen)
            ||!CGAffineTransformEqualToTransform(seen.transform,again.transform)||seen.alpha!=again.alpha)
            return DWPlacementRefuse(why,@"Native placement changed during verification");
    }
    if(![before isEqual:DWPlacementFamily(placement)])return DWPlacementRefuse(why,@"Native family changed after geometry verification");
    if(input){
        if(targetIndex==NSNotFound||values[targetIndex].owner!=[recipient[@"owner"]intValue]
            ||!CGRectContainsPoint(placement.requestedViewport,point)||!CGRectContainsPoint(values[targetIndex].screen,point))
            return DWPlacementRefuse(why,@"Native input recipient is not at the requested placement");
        uint32_t wid=0;int owner=0;pid_t pid=0;CGPoint local=CGPointZero;
        if(placementReadAPI.hit(placementReadAPI.connection(),0,1,0,&point,&local,&wid,&owner)!=kCGErrorSuccess
            ||wid!=[target[@"wid"]unsignedIntValue]||owner!=[recipient[@"owner"]intValue]
            ||placementReadAPI.connectionPID(owner,&pid)!=kCGErrorSuccess||pid!=[target[@"pid"]intValue])
            return DWPlacementRefuse(why,@"Native event-eligible recipient differs from the requested recipient");
        for(NSUInteger i=0;i<placement.members.count;i++)if(!DWPlacementMemberCurrent(placement.members[i][@"identity"],values[i].owner,NULL))
            return DWPlacementRefuse(why,@"Native member identity changed at input admission");
        if(![before isEqual:DWPlacementFamily(placement)])return DWPlacementRefuse(why,@"Native family changed at input admission");
    }
    // This is deliberately last: no native query or yielding work after this
    // fence. The caller must still fence its own transfer/grab before input.
    if(![presenter isAcknowledgedPlacementCurrent:placement])return DWPlacementRefuse(why,@"Native placement receipt changed during verification");
    return YES;
}
BOOL DWNativeValidateAppliedPlacementGeometry(DWNativePresenter *presenter,DWNativeAppliedPlacement *placement,NSString *__autoreleasing *why) {
    return DWPlacementVerify(presenter,placement,nil,CGPointZero,NO,why);
}
BOOL DWNativeValidateAppliedPlacementInput(DWNativePresenter *presenter,DWNativeAppliedPlacement *placement,
    NSDictionary *recipient,CGPoint physicalPoint,NSString *__autoreleasing *why) {
    return DWPlacementVerify(presenter,placement,recipient,physicalPoint,YES,why);
}
