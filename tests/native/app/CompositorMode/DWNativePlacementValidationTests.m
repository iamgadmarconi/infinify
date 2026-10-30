// SPDX-License-Identifier: GPL-3.0-or-later
// Actual verifier with substituted process/public-window/private-native reads.
// No native windows, sessions, getters, setters, events or pasteboard are used.
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#include <dlfcn.h>
#include <libproc.h>
#include <unistd.h>
static int validationProc(int pid,int flavor,uint64_t arg,void *buffer,int size);
static CFArrayRef validationRows(CGWindowListOption options,CGWindowID wid);
static void *validationOpen(const char *path,int flags);
static void *validationSymbol(void *handle,const char *name);
#define proc_pidinfo validationProc
#define CGWindowListCopyWindowInfo validationRows
#define dlopen validationOpen
#define dlsym validationSymbol
#import "DWNativePlacementValidation.m"
#undef proc_pidinfo
#undef CGWindowListCopyWindowInfo
#undef dlopen
#undef dlsym

@interface DWValidationReceipt : NSObject
@property(nonatomic,copy) NSDictionary *identity;
@property(nonatomic,copy) NSArray<NSDictionary *> *members;
@property(nonatomic) CGRect requestedScreenRect,requestedClipRect,requestedViewport;
@end
@implementation DWValidationReceipt @end
@interface DWValidationPresenter : NSObject
@property(nonatomic) BOOL current,loseAtFinal;
@property(nonatomic) NSUInteger fences;
@property(nonatomic,strong) DWValidationReceipt *receipt;
@end
@implementation DWValidationPresenter
- (BOOL)isAcknowledgedPlacementCurrent:(id)receipt {
    self.fences++;return self.current&&receipt==self.receipt&&!(self.loseAtFinal&&self.fences>1);
}
@end
static NSUInteger checks,reads,hitReads,familyReads;
static NSString *fault;
static DWValidationPresenter *presenter;
static DWValidationReceipt *receipt;
static NSDictionary *root,*child,*recipient;
static CGRect rootNative,childNative;
static CGAffineTransform rootMatrix,childMatrix;
static void check(BOOL value,NSString *message) {
    checks++;if(!value){fprintf(stderr,"FAIL: %s\n",message.UTF8String);exit(1);}
}
static NSDictionary *who(uint32_t wid) { return @{@"pid":@123,@"wid":@(wid),@"birth_sec":@100,@"birth_usec":@20}; }
static NSDictionary *named(CGRect r) { return @{@"origin":@{@"x":@(r.origin.x),@"y":@(r.origin.y)},@"size":@{@"width":@(r.size.width),@"height":@(r.size.height)}}; }
static NSArray *box(CGRect r) { return @[@(r.origin.x),@(r.origin.y),@(r.size.width),@(r.size.height)]; }
static NSArray *matrix(CGAffineTransform t) { return @[@(t.a),@(t.b),@(t.c),@(t.d),@(t.tx),@(t.ty)]; }
static CGRect native(uint32_t wid) { return wid==42?rootNative:childNative; }
static CGAffineTransform requested(uint32_t wid) { return wid==42?rootMatrix:childMatrix; }
static CGAffineTransform narrowed(uint32_t wid) {
    CGAffineTransform t=requested(wid);return CGAffineTransformMake((float)t.a,(float)t.b,(float)t.c,(float)t.d,(float)t.tx,(float)t.ty);
}
static int validationProc(int pid,int flavor,uint64_t arg,void *buffer,int size) {
    (void)arg;reads++;if(pid!=123||flavor!=PROC_PIDTBSDINFO||size!=sizeof(struct proc_bsdinfo)||[fault isEqual:@"process_unavailable"])return 0;
    struct proc_bsdinfo info={.pbi_pid=(uint32_t)pid,.pbi_uid=getuid(),.pbi_start_tvsec=100,.pbi_start_tvusec=20};
    if([fault isEqual:@"process_pid_changed"])info.pbi_pid++;
    if([fault isEqual:@"birth_changed"])info.pbi_start_tvusec++;
    if([fault isEqual:@"uid_changed"])info.pbi_uid++;
    memcpy(buffer,&info,sizeof(info));return sizeof(info);
}
static CFArrayRef validationRows(CGWindowListOption options,CGWindowID wid) {
    (void)options;reads++;if([fault isEqual:@"public_unavailable"])return NULL;
    if(wid!=42&&wid!=43)return CFBridgingRetain(@[]);
    return CFBridgingRetain(@[@{(id)kCGWindowNumber:@(wid),(id)kCGWindowOwnerPID:[fault isEqual:@"public_pid_changed"]?@124:@123,
        (id)kCGWindowIsOnscreen:@(![fault isEqual:@"offscreen"]),(id)kCGWindowAlpha:[fault isEqual:@"public_alpha_changed"]?@.5:@1}]);
}
static int connection(void) { return 12; }
static CGError owner(int cid,uint32_t wid,int *out) {
    (void)cid;reads++;if(wid!=42&&wid!=43)return kCGErrorFailure;
    *out=wid==42?700:701;if([fault isEqual:@"owner_changed"]&&wid==43)*out=702;return kCGErrorSuccess;
}
static CGError connectionPID(int cid,pid_t *out) {
    reads++;if(cid!=700&&cid!=701&&cid!=702)return kCGErrorFailure;
    *out=[fault isEqual:@"owner_pid_changed"]?124:123;return kCGErrorSuccess;
}
static CGError bounds(int cid,uint32_t wid,CGRect *out) {
    (void)cid;reads++;if([fault isEqual:@"bounds_unavailable"])return kCGErrorFailure;
    *out=native(wid);if([fault isEqual:@"bounds_changed"]&&wid==43)out->size.width++;
    if([fault isEqual:@"nonfinite_bounds"])out->origin.x=NAN;return kCGErrorSuccess;
}
static NSUInteger transforms;
static CGError transform(int cid,uint32_t wid,CGAffineTransform *out) {
    (void)cid;reads++;transforms++;if([fault isEqual:@"transform_unavailable"])return kCGErrorFailure;
    *out=narrowed(wid);if([fault isEqual:@"transform_changed"]||([fault isEqual:@"second_pass_changed"]&&transforms>2))out->tx++;
    if([fault isEqual:@"nonfinite_transform"])out->a=NAN;return kCGErrorSuccess;
}
static CGError screen(int cid,uint32_t wid,CGRect *out) {
    (void)cid;reads++;if([fault isEqual:@"screen_unavailable"])return kCGErrorFailure;
    *out=DWPlacementEnclosing(DWPlacementScreen(native(wid),narrowed(wid)));
    if([fault isEqual:@"screen_changed"])out->origin.x++;return kCGErrorSuccess;
}
static CGError alpha(int cid,uint32_t wid,float *out) {
    (void)cid;(void)wid;reads++;if([fault isEqual:@"alpha_unavailable"])return kCGErrorFailure;
    *out=[fault isEqual:@"hidden"]?0:[fault isEqual:@"alpha_changed"]?.5f:1;
    if([fault isEqual:@"nonfinite_alpha"])*out=NAN;return kCGErrorSuccess;
}
static CGError hit(int cid,int first,int second,int third,const CGPoint *point,CGPoint *local,uint32_t *wid,int *outOwner) {
    (void)point;check(cid==12&&first==0&&second==1&&third==0,@"use established event-eligible query arguments");hitReads++;
    if([fault isEqual:@"hit_unavailable"])return kCGErrorFailure;
    *local=CGPointZero;*wid=[fault isEqual:@"wrong_hit"]?42:43;*outOwner=[fault isEqual:@"wrong_hit_owner"]?700:701;
    if([fault isEqual:@"second_hit_changed"]&&hitReads>1){*wid=42;*outOwner=700;}
    if([fault isEqual:@"birth_after_second_hit"]&&hitReads>1)fault=@"birth_changed";
    if([fault isEqual:@"family_after_hit"])fault=@"family_changed";
    if([fault isEqual:@"disconnect_after_hit"])presenter.current=NO;
    if([fault isEqual:@"birth_after_hit"])fault=@"birth_changed";
    return kCGErrorSuccess;
}
static void *validationOpen(const char *path,int flags) { (void)path;(void)flags;return (void *)1; }
static void *validationSymbol(void *handle,const char *name) {
    (void)handle;
    if(!strcmp(name,"SLSMainConnectionID"))return (void *)connection;
    if(!strcmp(name,"SLSGetWindowOwner"))return (void *)owner;
    if(!strcmp(name,"SLSConnectionGetPID"))return (void *)connectionPID;
    if(!strcmp(name,"SLSGetWindowBounds"))return (void *)bounds;
    if(!strcmp(name,"SLSGetCatenatedWindowTransform"))return (void *)transform;
    if(!strcmp(name,"SLSGetWindowTransform"))return NULL; // placement 0 alone is not what is drawn: the reader must not use it
    if(!strcmp(name,"SLSGetScreenRectForWindow"))return (void *)screen;
    if(!strcmp(name,"SLSGetWindowAlpha"))return (void *)alpha;
    if(!strcmp(name,"SLSFindWindowAndOwner"))return (void *)hit;
    return NULL;
}
NSDictionary *DWNativeWindowFamily(NSDictionary *identity,NSString *__autoreleasing *why) {
    (void)why;familyReads++;if(![identity isEqual:root]||[fault isEqual:@"family_unavailable"])return nil;
    NSDictionary *descendant=@{@"identity":[fault isEqual:@"family_identity_changed"]?who(44):child,
        @"native_bounds":named(childNative),@"parent":([fault isEqual:@"parent_changed"]&&familyReads>1)||[fault isEqual:@"parent_changed_before_read"]?@44:@42};
    NSArray *members=@[@{@"identity":root,@"native_bounds":named(rootNative),@"parent":@0},descendant];
    if([fault isEqual:@"family_changed"])members=@[members[0]];
    return @{@"root":@42,@"identity":root,@"members":members};
}
BOOL DWNativeWindowBelongsToRoot(NSDictionary *member,NSDictionary *ancestor) {
    return [ancestor isEqual:root]&&([member isEqual:root]||[member isEqual:child])&&![fault isEqual:@"ancestry_changed"];
}
static void reset(void) {
    fault=nil;reads=hitReads=familyReads=transforms=0;root=who(42);child=who(43);
    rootNative=CGRectMake(80,100,320,232);childNative=CGRectMake(130,125,90,60);
    rootMatrix=CGAffineTransformMake(2,0,0,2,-500,-400);childMatrix=CGAffineTransformMake(2,0,0,2,-550,-425);
    receipt=[DWValidationReceipt new];receipt.identity=root;receipt.requestedScreenRect=CGRectMake(250,200,160,116);
    receipt.requestedClipRect=receipt.requestedScreenRect;receipt.requestedViewport=CGRectMake(0,0,1200,900);
    receipt.members=@[@{@"identity":root,@"native_bounds":box(rootNative),@"parent":@0,@"requested_transform":matrix(rootMatrix),@"requested_alpha":NSNull.null,@"flags":@0},
        @{@"identity":child,@"native_bounds":box(childNative),@"parent":@42,@"requested_transform":matrix(childMatrix),@"requested_alpha":NSNull.null,@"flags":@0}];
    presenter=[DWValidationPresenter new];presenter.current=YES;presenter.receipt=receipt;
    NSMutableDictionary *target=[child mutableCopy];target[@"owner"]=@701;recipient=target.copy;
}
static BOOL geometry(NSString *__autoreleasing *why) { return DWNativeValidateAppliedPlacementGeometry((id)presenter,(id)receipt,why); }
static BOOL input(CGPoint point,NSString *__autoreleasing *why) { return DWNativeValidateAppliedPlacementInput((id)presenter,(id)receipt,recipient,point,why); }
static void reject(NSString *name,BOOL pointer) {
    reset();fault=name;NSString *why=nil;check(!(pointer?input(CGPointMake(285,225),&why):geometry(&why))&&why.length>0,[NSString stringWithFormat:@"refuse %@",name]);
}
int main(void) {@autoreleasepool {
    reset();check([DWNativeEventRecipientAtPoint(CGPointMake(285,225))isEqual:recipient]&&hitReads==2&&familyReads==0,
        @"fresh discovery brackets exact recipient PID/birth/WID/owner without claiming placement or family admission");
    reset();check(!DWNativeEventRecipientAtPoint(CGPointMake(NAN,225))&&reads==0&&hitReads==0,@"nonfinite point cannot query an event recipient");
    for(NSString *name in @[@"process_unavailable",@"process_pid_changed",@"birth_after_second_hit",@"uid_changed",@"public_unavailable",@"public_pid_changed",@"owner_pid_changed",@"wrong_hit_owner",@"hit_unavailable",@"second_hit_changed"]){
        reset();fault=name;check(!DWNativeEventRecipientAtPoint(CGPointMake(285,225)),[NSString stringWithFormat:@"recipient discovery refuses %@",name]);
    }
    reset();check(geometry(NULL)&&hitReads==0&&presenter.fences==2,@"geometry checks complete family and final receipt without requiring a pointer");
    reset();check(input(CGPointMake(285,225),NULL)&&hitReads==1&&presenter.fences==2,@"fresh exact descendant event recipient is admitted only at this call");
    for(NSString *name in @[@"process_unavailable",@"birth_changed",@"uid_changed",@"public_unavailable",@"public_pid_changed",@"owner_pid_changed",@"bounds_unavailable",@"bounds_changed",@"nonfinite_bounds",@"transform_unavailable",@"transform_changed",@"nonfinite_transform",@"screen_unavailable",@"screen_changed",@"alpha_unavailable",@"hidden",@"nonfinite_alpha",@"public_alpha_changed",@"offscreen",@"family_unavailable",@"family_changed",@"family_identity_changed",@"ancestry_changed",@"parent_changed",@"parent_changed_before_read",@"second_pass_changed"])
        reject(name,NO);
    for(NSString *name in @[@"wrong_hit",@"wrong_hit_owner",@"hit_unavailable",@"owner_changed",@"family_after_hit",@"disconnect_after_hit",@"birth_after_hit"])reject(name,YES);
    reset();presenter.current=NO;check(!geometry(NULL)&&reads==0,@"lost/stale ACK refuses before native reads");
    reset();presenter.loseAtFinal=YES;check(!geometry(NULL),@"receipt invalidation during independent read refuses at final fence");
    reset();check(!input(CGPointMake(900,800),NULL)&&hitReads==0,@"pointer outside requested recipient does not query a foreign event site");
    reset();NSMutableDictionary *bad=[recipient mutableCopy];bad[@"owner"]=NSNull.null;recipient=bad;check(!input(CGPointMake(285,225),NULL),@"numeric recipient owner is mandatory");
    reset();bad=[recipient mutableCopy];bad[@"owner"]=@700;recipient=bad;check(!input(CGPointMake(285,225),NULL)&&hitReads==0,@"recipient owner must match independent member owner");
    reset();receipt.requestedClipRect=CGRectMake(250,200,100,116);check(!geometry(NULL)&&reads==0,@"partial root clip is refused");
    reset();receipt.requestedViewport=CGRectMake(250,200,170,116);childNative.origin.x=390;
    childMatrix.tx=-500-(childNative.origin.x-rootNative.origin.x);NSMutableArray *members=[receipt.members mutableCopy];NSMutableDictionary *member=[members[1]mutableCopy];
    member[@"native_bounds"]=box(childNative);member[@"requested_transform"]=matrix(childMatrix);members[1]=member;receipt.members=members;
    check(!geometry(NULL),@"fully visible root cannot authorize a descendant outside viewport");
    reset();members=[receipt.members mutableCopy];member=[members[1]mutableCopy];member[@"requested_alpha"]=@.5;member[@"flags"]=@(DW2_RECORD_HAS_ALPHA);members[1]=member;receipt.members=members;
    check(!geometry(NULL),@"requested alpha must be independently observed");
    reset();members=[receipt.members mutableCopy];member=[members[1]mutableCopy];member[@"requested_transform"]=@[@2,@0,@0,@2,@(-560),@(-425)];members[1]=member;receipt.members=members;
    check(!geometry(NULL),@"receipt matrix must correspond to requested root geometry and member basis");
    reset();members=[receipt.members mutableCopy];[members addObject:members[1]];receipt.members=members;check(!geometry(NULL),@"duplicate member cannot certify complete family");
    reset();double fractionalScale=320.0/240;
    rootMatrix=CGAffineTransformMake(fractionalScale,0,0,fractionalScale,-250.25*fractionalScale,-200.25*fractionalScale);
    childMatrix=CGAffineTransformMake(rootMatrix.a,0,0,rootMatrix.d,rootMatrix.tx-50,rootMatrix.ty-25);
    receipt.requestedScreenRect=CGRectMake(250.25,200.25,240,174);receipt.requestedClipRect=receipt.requestedScreenRect;
    members=[receipt.members mutableCopy];for(NSUInteger i=0;i<2;i++){member=[members[i]mutableCopy];member[@"requested_transform"]=matrix(i?childMatrix:rootMatrix);members[i]=member;}receipt.members=members;
    check(geometry(NULL),@"documented native float narrowing and whole-point enclosure handle fractional placement without arbitrary tolerance");
    reset();
    CGError (*savedHit)(int,int,int,int,const CGPoint *,CGPoint *,uint32_t *,int *)=placementReadAPI.hit;placementReadAPI.hit=NULL;
    check(geometry(NULL),@"rendering geometry does not depend on event-hit availability");presenter.fences=0;
    check(!input(CGPointMake(285,225),NULL),@"input refuses missing event-hit API");placementReadAPI.hit=savedHit;
    printf("PASS: %lu native placement verifier checks; substituted reads only\n",(unsigned long)checks);
}return 0;}
