// SPDX-License-Identifier: GPL-3.0-or-later
// DWNativeReplicaFamilies's internal interface: the shared helpers, the class extension and the category interfaces of the DWNativeReplicaFamilies*.m files.
// Split from native/app/CompositorMode/DWNativeReplicaFamilies.m (0b3f028; native/desktop/native-replica-family.m at 37b27b1), moved verbatim.
#import "DWNativeReplicaFamilies.h"
#import "DWNativeFamily.h"
#import "DWNativePresenter.h"
#import "DWGeometryJSON.h"
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <QuartzCore/QuartzCore.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <limits.h>
#include <mach/mach_time.h>
#include <libproc.h>
#include <unistd.h>
#import "DWReplicaMember.h"
#import "DWReplicaRecovery.h"
#import "DWReplicaOrder.h"
static inline BOOL familySize(CGRect r) {
    return !CGRectIsNull(r)&&!CGRectIsInfinite(r)&&!CGRectIsEmpty(r)
        &&isfinite(r.origin.x)&&isfinite(r.origin.y)&&isfinite(r.size.width)&&isfinite(r.size.height);
}
static inline BOOL familyBinding(NSDictionary *a,NSDictionary *b) {
    if(!a||!b)return NO;
    for(NSString *key in @[@"window",@"identity",@"generation",@"native_bounds"])if(!a[key]||![a[key]isEqual:b[key]])return NO;
    return YES;
}
static inline BOOL frameNumber(id value) {
    return [value isKindOfClass:NSNumber.class]&&CFGetTypeID((__bridge CFTypeRef)value)!=CFBooleanGetTypeID()&&isfinite([value doubleValue]);
}
// Camera/output demand is not a native observation epoch. An in-flight audit
// remains valid when only capture sites, density or rate change.
static inline BOOL familyCohortMatches(NSDictionary *a,NSDictionary *b) {
    if(a.count!=b.count)return NO;
    for(NSNumber *window in a)if(!familyBinding(a[window],b[window]))return NO;
    return YES;
}
static inline BOOL familyDemandRect(id value,CGRect *out) {
    if(![value isKindOfClass:NSDictionary.class])return NO;
    id origin=value[@"origin"],size=value[@"size"];
    if(![origin isKindOfClass:NSDictionary.class]||![size isKindOfClass:NSDictionary.class]
       ||!frameNumber(origin[@"x"])||!frameNumber(origin[@"y"])||!frameNumber(size[@"width"])||!frameNumber(size[@"height"]))return NO;
    *out=DWRectFromJSON(value);
    return familySize(*out)&&isfinite(CGRectGetMaxX(*out))&&isfinite(CGRectGetMaxY(*out));
}
// Only a proven zero intersection may suppress capture. These are drawing
// demand calculations, never input/identity authority or an opacity inference.
static inline BOOL familyIntersectsCapture(NSDictionary *root,CGRect bounds) {
    if([root[@"capture"]isEqual:@NO])return NO;
    if(![root[@"capture_all"]isEqual:@NO])return YES;
    CGRect native;
    if(!familyDemandRect(root[@"native_bounds"],&native)||!familySize(bounds))return YES;
    id sites=root[@"capture_sites"];if(![sites isKindOfClass:NSArray.class])return YES;
    BOOL uncertain=NO;
    for(id site in sites){CGRect screen,viewport;
        if(![site isKindOfClass:NSDictionary.class]||!familyDemandRect(site[@"screen_rect"],&screen)||!familyDemandRect(site[@"viewport"],&viewport)
           ||!frameNumber(site[@"pixel_margin"])||[site[@"pixel_margin"]doubleValue]<0){uncertain=YES;continue;}
        CGRect projected=CGRectMake(screen.origin.x+(bounds.origin.x-native.origin.x)/native.size.width*screen.size.width,
                                    screen.origin.y+(bounds.origin.y-native.origin.y)/native.size.height*screen.size.height,
                                    bounds.size.width/native.size.width*screen.size.width,bounds.size.height/native.size.height*screen.size.height);
        if(!familySize(projected)||!isfinite(CGRectGetMaxX(projected))||!isfinite(CGRectGetMaxY(projected))){uncertain=YES;continue;}
        projected=CGRectInset(projected,-[site[@"pixel_margin"]doubleValue],-[site[@"pixel_margin"]doubleValue]);
        if(!familySize(projected)||!isfinite(CGRectGetMaxX(projected))||!isfinite(CGRectGetMaxY(projected))){uncertain=YES;continue;}
        if(!CGRectIsEmpty(CGRectIntersection(projected,viewport)))return YES;
    }
    return uncertain;
}
static inline BOOL familyProcessMatches(NSDictionary *identity) {
    pid_t pid=[identity[@"pid"]intValue];struct proc_bsdinfo process={0};
    return pid>1&&proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&process,sizeof(process))==sizeof(process)&&process.pbi_uid==getuid()
        &&[identity[@"birth_sec"]isEqual:@(process.pbi_start_tvsec)]&&[identity[@"birth_usec"]isEqual:@(process.pbi_start_tvusec)];
}
static inline dispatch_queue_t familyQueue(const char *label) {
    dispatch_queue_attr_t attributes=dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,QOS_CLASS_USER_INITIATED,0);
    attributes=dispatch_queue_attr_make_with_autorelease_frequency(attributes,DISPATCH_AUTORELEASE_FREQUENCY_WORK_ITEM);
    return dispatch_queue_create(label,attributes);
}
static inline NSNumber *familyRank(NSDictionary *ranks,NSDictionary *owners,NSDictionary *identity) {
    NSNumber *wid=identity[@"wid"];
    return wid&&[owners[wid]isEqual:identity[@"pid"]]?ranks[wid]:nil;
}
static inline BOOL familyBarrier(NSDictionary *token) {
    id barrier=token[@"barrier"];
    return barrier&&(![barrier isKindOfClass:NSNumber.class]||[barrier boolValue]);
}
static inline NSNumber *familyBucket(NSDictionary *token) {
    id bucket=token[@"bucket"];
    if(!bucket)return @0;
    return frameNumber(bucket)&&floor([bucket doubleValue])==[bucket doubleValue]?bucket:nil;
}
// Desktop-independent captures can name the transformed screen rectangle while
// their content still describes the original window. These are separate spaces:
// validate both observations and derive sampling only from the frame's metadata.
static inline BOOL familyPixels(NSDictionary *info,CVPixelBufferRef pixels,NSDictionary *identity,CGRect own,uint64_t cutoff,CGRect *crop,uint64_t *timestamp) {
    id time=info[SCStreamFrameInfoDisplayTime],scale=info[SCStreamFrameInfoScaleFactor],contentScale=info[SCStreamFrameInfoContentScale];
    if(!frameNumber(time)||[time doubleValue]<=0||floor([time doubleValue])!=[time doubleValue]||[time doubleValue]>=18446744073709551616.0||[time unsignedLongLongValue]<=cutoff
       ||!frameNumber(scale)||!frameNumber(contentScale)||[scale doubleValue]<=0||[contentScale doubleValue]<=0)return NO;
    CGRect screen=CGRectZero,content=CGRectZero;
    if(![info[SCStreamFrameInfoScreenRect]isKindOfClass:NSDictionary.class]||![info[SCStreamFrameInfoContentRect]isKindOfClass:NSDictionary.class]
       ||!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)info[SCStreamFrameInfoScreenRect],&screen)
       ||!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)info[SCStreamFrameInfoContentRect],&content)||!familySize(screen)||!familySize(content))return NO;
    NSArray *windows=CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow,[identity[@"wid"]unsignedIntValue]));CGRect actual=CGRectZero;BOOL current=NO;
    for(NSDictionary *window in windows)if([window[(id)kCGWindowNumber]isEqual:identity[@"wid"]]&&[window[(id)kCGWindowOwnerPID]isEqual:identity[@"pid"]])current=CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)window[(id)kCGWindowBounds],&actual);
    if(!current||(!CGRectEqualToRect(screen,own)&&!CGRectEqualToRect(screen,actual))
       ||fabs(content.size.width/[contentScale doubleValue]-own.size.width)>1||fabs(content.size.height/[contentScale doubleValue]-own.size.height)>1)return NO;
    CGFloat s=[scale doubleValue];CGRect result=CGRectMake(content.origin.x*s,content.origin.y*s,content.size.width*s,content.size.height*s);
    if(!familySize(result)||result.origin.x<0||result.origin.y<0||CGRectGetMaxX(result)>CVPixelBufferGetWidth(pixels)||CGRectGetMaxY(result)>CVPixelBufferGetHeight(pixels))return NO;
    *crop=result;*timestamp=[time unsignedLongLongValue];return YES;
}
static inline SCStreamConfiguration *familyConfiguration(CGRect bounds,double density,NSInteger rate) {
    SCStreamConfiguration *config=[SCStreamConfiguration new];config.width=(size_t)MIN(16384,MAX(2,ceil(bounds.size.width*density)));config.height=(size_t)MIN(16384,MAX(2,ceil(bounds.size.height*density)));
    config.pixelFormat=kCVPixelFormatType_32BGRA;config.colorSpaceName=kCGColorSpaceSRGB;config.queueDepth=3;config.minimumFrameInterval=CMTimeMake(1,(int32_t)rate);config.showsCursor=NO;config.ignoreShadowsSingleWindow=YES;config.ignoreGlobalClipSingleWindow=YES;config.includeChildWindows=NO;
    return config;
}
static inline BOOL familySameOrder(NSDictionary<NSNumber *,DWReplicaOrder *> *a,NSDictionary<NSNumber *,DWReplicaOrder *> *b) {
    if(a.count!=b.count)return NO;
    for(NSNumber *window in a){DWReplicaOrder *old=a[window],*next=b[window];
        if(!next||!familyBinding(old.root,next.root)||![old.rank isEqual:next.rank]
           ||![old.ranks isEqual:next.ranks]||![old.members isEqual:next.members])return NO;
    }
    return YES;
}
static inline void familyNormalizeOrder(NSDictionary<NSNumber *,DWReplicaOrder *> *ordering) {
    // Only relative order among managed roots/children affects composition.
    // Unrelated desktop windows may shift every absolute enumeration index.
    NSMutableSet<NSNumber *> *ranks=[NSMutableSet set];
    for(DWReplicaOrder *order in ordering.allValues){[ranks addObject:order.rank];[ranks addObjectsFromArray:order.ranks.allValues];}
    NSArray<NSNumber *> *sorted=[ranks.allObjects sortedArrayUsingSelector:@selector(compare:)];NSMutableDictionary *dense=[NSMutableDictionary dictionary];
    for(NSUInteger i=0;i<sorted.count;i++)dense[sorted[i]]=@(i);
    for(DWReplicaOrder *order in ordering.allValues){NSMutableDictionary *children=[NSMutableDictionary dictionary];
        order.rank=dense[order.rank];for(NSString *key in order.ranks)children[key]=dense[order.ranks[key]];order.ranks=children.copy;
    }
}
@interface DWNativeReplicaFamilies ()
@property(copy) void (^changed)(NSNumber *);
@property NSDictionary<NSNumber *,NSDictionary *> *roots;
@property(nonatomic,readwrite) NSDictionary<NSNumber *,NSDictionary *> *descriptions;
@property NSMutableDictionary<NSNumber *,NSArray<DWReplicaMember *> *> *members;
@property NSMutableDictionary<NSNumber *,NSArray<DWCanvasAttachment *> *> *drawableAttachments;
@property NSMutableDictionary<NSNumber *,NSMutableDictionary<NSNumber *,DWReplicaRecovery *> *> *recoveries;
// Scheduling only, never native authority. Weak cold attempts survive a WID
// replacement in the history until their actual retirement/first valid image.
@property NSHashTable<DWReplicaMember *> *coldAttempts;
@property NSMutableArray<NSNumber *> *admissionRoots;
@property uint64_t admissionSequence;
@property dispatch_queue_t observer;
@property NSUInteger epoch;
@property NSUInteger requestSequence;
@property NSUInteger orderingEpoch;
@property NSUInteger orderingObservation;
@property NSDictionary<NSNumber *,DWReplicaOrder *> *ordering;
@property(readwrite) uint64_t orderRevision;
@property NSUInteger changeDepth;
@property NSMutableSet<NSNumber *> *changedWindows;
@property BOOL orderingChanged;
@property BOOL reading;
@property BOOL requestPending;
@property CFTimeInterval nextRead;
@property NSInteger rate;
- (void)request;
- (void)beginChanges;
- (void)endChanges;
- (void)changedWindow:(NSNumber *)window;
- (void)markOrderingChanged;
- (void)invalidateOrdering;
- (void)replaceDescriptions:(NSDictionary<NSNumber *,NSDictionary *> *)descriptions;
- (NSArray<NSDictionary *> *)capturePlans:(NSArray<NSDictionary *> *)plans root:(NSDictionary *)root;
- (void)pruneCaptureDemand;
@end
// Defined in DWReplicaMember.m: one lifecycle trace for the process (its log limit is shared).
void familyTrace(DWReplicaMember *member,const char *event,const char *reason,NSInteger error);
static inline NSDictionary *familyHit(DWReplicaMember *member,NSDictionary *root,CGPoint local) {
    if(![member imageAvailable]||!member.image.buffer||!familyBinding(member.root,root))return nil;
    CGPoint own=CGPointMake(local.x+member.rootBounds.origin.x-member.bounds.origin.x,local.y+member.rootBounds.origin.y-member.bounds.origin.y);
    if(!CGRectContainsPoint(CGRectMake(0,0,member.bounds.size.width,member.bounds.size.height),own))return nil;
    return @{@"identity":member.identity,@"generation":member.root[@"generation"],@"native_bounds":DWRectJSON(member.bounds),@"local":@{@"x":@(own.x),@"y":@(own.y)}};
}
// DWNativeReplicaFamilies+Recovery.m
@interface DWNativeReplicaFamilies (Recovery)
- (void)memberFailed:(DWReplicaMember *)member;
- (void)memberBecameDrawable:(DWReplicaMember *)member;
- (void)memberBecameUnavailable:(DWReplicaMember *)member;
- (DWReplicaRecovery *)recovery:(NSDictionary *)identity root:(NSDictionary *)root bounds:(CGRect)bounds;
- (DWReplicaRecovery *)admitRecovery:(NSDictionary *)identity root:(NSDictionary *)root bounds:(CGRect)bounds starting:(NSUInteger *)starting;
- (NSArray<NSNumber *> *)admissionRootOrder;
- (NSArray<NSDictionary *> *)admissionPlans:(NSArray<NSDictionary *> *)plans root:(NSDictionary *)root;
- (void)acceptRecoveryCohort:(NSArray<NSDictionary *> *)plans root:(NSDictionary *)root sampledAt:(NSNumber *)began;
- (void)invalidatePID:(pid_t)pid discardRecovery:(BOOL)discard;
@end
// DWNativeReplicaFamilies+Ordering.m
@interface DWNativeReplicaFamilies (OrderingInternal)
- (NSArray<NSDictionary *> *)orderedRun:(NSArray<NSDictionary *> *)tokens range:(NSRange)range;
@end
