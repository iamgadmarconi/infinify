// SPDX-License-Identifier: GPL-3.0-or-later
#import "native-replica-family.h"
#import "native-family.h"
#import "native-presenter.h"
#import "native-geometry-json.h"
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

static BOOL familySize(CGRect r) {
    return !CGRectIsNull(r)&&!CGRectIsInfinite(r)&&!CGRectIsEmpty(r)
        &&isfinite(r.origin.x)&&isfinite(r.origin.y)&&isfinite(r.size.width)&&isfinite(r.size.height);
}
static BOOL familyBinding(NSDictionary *a,NSDictionary *b) {
    if(!a||!b)return NO;
    for(NSString *key in @[@"window",@"identity",@"generation",@"native_bounds"])if(!a[key]||![a[key]isEqual:b[key]])return NO;
    return YES;
}
static BOOL frameNumber(id value) {
    return [value isKindOfClass:NSNumber.class]&&CFGetTypeID((__bridge CFTypeRef)value)!=CFBooleanGetTypeID()&&isfinite([value doubleValue]);
}
// Camera/output demand is not a native observation epoch. An in-flight audit
// remains valid when only capture sites, density or rate change.
static BOOL familyCohortMatches(NSDictionary *a,NSDictionary *b) {
    if(a.count!=b.count)return NO;
    for(NSNumber *window in a)if(!familyBinding(a[window],b[window]))return NO;
    return YES;
}
static BOOL familyDemandRect(id value,CGRect *out) {
    if(![value isKindOfClass:NSDictionary.class])return NO;
    id origin=value[@"origin"],size=value[@"size"];
    if(![origin isKindOfClass:NSDictionary.class]||![size isKindOfClass:NSDictionary.class]
       ||!frameNumber(origin[@"x"])||!frameNumber(origin[@"y"])||!frameNumber(size[@"width"])||!frameNumber(size[@"height"]))return NO;
    *out=DWRectFromJSON(value);
    return familySize(*out)&&isfinite(CGRectGetMaxX(*out))&&isfinite(CGRectGetMaxY(*out));
}
// Only a proven zero intersection may suppress capture. These are drawing
// demand calculations, never input/identity authority or an opacity inference.
static BOOL familyIntersectsCapture(NSDictionary *root,CGRect bounds) {
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
static BOOL familyProcessMatches(NSDictionary *identity) {
    pid_t pid=[identity[@"pid"]intValue];struct proc_bsdinfo process={0};
    return pid>1&&proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&process,sizeof(process))==sizeof(process)&&process.pbi_uid==getuid()
        &&[identity[@"birth_sec"]isEqual:@(process.pbi_start_tvsec)]&&[identity[@"birth_usec"]isEqual:@(process.pbi_start_tvusec)];
}
static dispatch_queue_t familyQueue(const char *label) {
    dispatch_queue_attr_t attributes=dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,QOS_CLASS_USER_INITIATED,0);
    attributes=dispatch_queue_attr_make_with_autorelease_frequency(attributes,DISPATCH_AUTORELEASE_FREQUENCY_WORK_ITEM);
    return dispatch_queue_create(label,attributes);
}
static NSNumber *familyRank(NSDictionary *ranks,NSDictionary *owners,NSDictionary *identity) {
    NSNumber *wid=identity[@"wid"];
    return wid&&[owners[wid]isEqual:identity[@"pid"]]?ranks[wid]:nil;
}
static BOOL familyBarrier(NSDictionary *token) {
    id barrier=token[@"barrier"];
    return barrier&&(![barrier isKindOfClass:NSNumber.class]||[barrier boolValue]);
}
static NSNumber *familyBucket(NSDictionary *token) {
    id bucket=token[@"bucket"];
    if(!bucket)return @0;
    return frameNumber(bucket)&&floor([bucket doubleValue])==[bucket doubleValue]?bucket:nil;
}
// Desktop-independent captures can name the transformed screen rectangle while
// their content still describes the original window. These are separate spaces:
// validate both observations and derive sampling only from the frame's metadata.
static BOOL familyPixels(NSDictionary *info,CVPixelBufferRef pixels,NSDictionary *identity,CGRect own,uint64_t cutoff,CGRect *crop,uint64_t *timestamp) {
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
static SCStreamConfiguration *familyConfiguration(CGRect bounds,double density,NSInteger rate) {
    SCStreamConfiguration *config=[SCStreamConfiguration new];config.width=(size_t)MIN(16384,MAX(2,ceil(bounds.size.width*density)));config.height=(size_t)MIN(16384,MAX(2,ceil(bounds.size.height*density)));
    config.pixelFormat=kCVPixelFormatType_32BGRA;config.colorSpaceName=kCGColorSpaceSRGB;config.queueDepth=3;config.minimumFrameInterval=CMTimeMake(1,(int32_t)rate);config.showsCursor=NO;config.ignoreShadowsSingleWindow=YES;config.ignoreGlobalClipSingleWindow=YES;config.includeChildWindows=NO;
    return config;
}
@class DWReplicaMember;
// Main-owned negative capture history, never identity or input authority. Keep
// the exact attempt weakly: callbacks from a retired stream cannot charge a
// replacement with the same numeric WID. The native family reader is bounded to
// 64 associations; stale observations cannot grow this table without bound.
@interface DWReplicaRecovery : NSObject
@property NSDictionary *root,*identity;
@property CGRect bounds;
@property(weak) DWReplicaMember *attempt;
@property NSUInteger failures;
@property CFTimeInterval notBefore;
@property uint64_t waiting;
@end
@implementation DWReplicaRecovery @end
static BOOL familyRecoveryMatches(DWReplicaRecovery *recovery,NSDictionary *root,NSDictionary *identity,CGRect bounds) {
    return recovery&&familyBinding(recovery.root,root)&&[recovery.identity isEqual:identity]&&CGRectEqualToRect(recovery.bounds,bounds);
}
static CFTimeInterval familyRecoveryDelay(NSDictionary *identity,NSUInteger failures) {
    uint64_t hash=1469598103934665603ULL;
    for(NSString *key in @[@"pid",@"birth_sec",@"birth_usec",@"wid"]){hash^=[identity[key]unsignedLongLongValue];hash*=1099511628211ULL;}
    hash^=failures;hash*=1099511628211ULL;
    // Half a second, doubling to a thirty-second ceiling. Positive jitter
    // remains at the ceiling too, so simultaneous failures do not stay aligned.
    return MIN(29.75,ldexp(.5,(int)MIN(MAX(failures,1)-1,6)))+.25*(double)(1+hash%1024)/1024.;
}
@interface DWReplicaOrder : NSObject
@property NSDictionary *root;
@property NSNumber *rank;
@property NSArray<DWReplicaMember *> *members;
@property NSDictionary<NSString *,NSNumber *> *ranks;
@end
@implementation DWReplicaOrder @end
static BOOL familySameOrder(NSDictionary<NSNumber *,DWReplicaOrder *> *a,NSDictionary<NSNumber *,DWReplicaOrder *> *b) {
    if(a.count!=b.count)return NO;
    for(NSNumber *window in a){DWReplicaOrder *old=a[window],*next=b[window];
        if(!next||!familyBinding(old.root,next.root)||![old.rank isEqual:next.rank]
           ||![old.ranks isEqual:next.ranks]||![old.members isEqual:next.members])return NO;
    }
    return YES;
}
static void familyNormalizeOrder(NSDictionary<NSNumber *,DWReplicaOrder *> *ordering) {
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
- (void)memberFailed:(DWReplicaMember *)member;
- (void)memberBecameDrawable:(DWReplicaMember *)member;
- (void)memberBecameUnavailable:(DWReplicaMember *)member;
- (DWReplicaRecovery *)recovery:(NSDictionary *)identity root:(NSDictionary *)root bounds:(CGRect)bounds;
- (DWReplicaRecovery *)admitRecovery:(NSDictionary *)identity root:(NSDictionary *)root bounds:(CGRect)bounds starting:(NSUInteger *)starting;
- (NSArray<NSNumber *> *)admissionRootOrder;
- (NSArray<NSDictionary *> *)admissionPlans:(NSArray<NSDictionary *> *)plans root:(NSDictionary *)root;
- (void)acceptRecoveryCohort:(NSArray<NSDictionary *> *)plans root:(NSDictionary *)root sampledAt:(NSNumber *)began;
- (void)invalidatePID:(pid_t)pid discardRecovery:(BOOL)discard;
- (NSArray<NSDictionary *> *)capturePlans:(NSArray<NSDictionary *> *)plans root:(NSDictionary *)root;
- (void)pruneCaptureDemand;
@end

// Each object owns exactly one immutable native membership/geometry epoch and
// one stream. Retiring it invalidates queued callbacks before any new filter is
// installed. At most one frame per member waits for the main queue.
@interface DWReplicaMember : NSObject <SCStreamOutput,SCStreamDelegate> {
@public
    _Atomic BOOL alive;
    _Atomic BOOL pending;
    _Atomic BOOL received;
    _Atomic BOOL stopped;
    _Atomic BOOL withdrawalPending;
    _Atomic uint64_t callbackSequence,publishedSequence,unavailableSequence;
}
@property NSDictionary *root,*identity;
@property CGRect rootBounds,bounds;
@property DWCanvasAttachment *image;
@property SCStream *stream;
@property dispatch_queue_t samples;
@property(weak) DWNativeReplicaFamilies *owner;
@property(copy) NSString *failure;
@property double density;
@property BOOL started;
@property BOOL hadImage;
@property BOOL updating;
@property NSInteger rate;
@property NSUInteger configuration;
@property uint64_t frameTime;
@property CFTimeInterval startDeadline;
@property CFTimeInterval firstFrameDeadline;
@property CFTimeInterval lastVisible;
- (void)retire;
- (void)start;
- (void)expireStart;
- (void)expireFirstFrame;
- (BOOL)imageAvailable;
@end
// Explicit diagnostic only: bounded lifecycle records, never titles, pixels or
// unrestricted error text. It does not change capture or validation decisions.
static void familyTrace(DWReplicaMember *member,const char *event,const char *reason,NSInteger error) {
    static BOOL enabled;static dispatch_once_t once;static NSUInteger records;
    dispatch_once(&once,^{const char *value=getenv("INFINIFY_DEBUG_FAMILIES");enabled=value&&!strcmp(value,"1");});
    if(!enabled||records>=4096)return;
    records++;
    fprintf(stderr,"family_capture: event=%s window=%llu root=%u member=%u pid=%d generation=%llu density=%.5f rate=%ld reason=%s native_error=%ld\n",
        event,[member.root[@"window"]unsignedLongLongValue],[member.root[@"identity"][@"wid"]unsignedIntValue],
        [member.identity[@"wid"]unsignedIntValue],[member.identity[@"pid"]intValue],[member.root[@"generation"]unsignedLongLongValue],
        member.density,(long)member.rate,reason,(long)error);
    if(records==4096)fputs("family_capture: event=log_limit\n",stderr);
}
@implementation DWReplicaMember
- (instancetype)init {
    if((self=[super init])){atomic_init(&alive,YES);atomic_init(&pending,NO);atomic_init(&received,NO);atomic_init(&stopped,NO);atomic_init(&withdrawalPending,NO);
        atomic_init(&callbackSequence,0);atomic_init(&publishedSequence,0);atomic_init(&unavailableSequence,0);}
    return self;
}
- (BOOL)imageAvailable { return atomic_load(&alive)&&!atomic_load(&stopped)&&atomic_load(&publishedSequence)>atomic_load(&unavailableSequence); }
- (void)retire {
    if(atomic_load(&alive))familyTrace(self,"retire","none",0);
    atomic_store(&alive,NO);self.image.buffer=NULL;[self.owner.coldAttempts removeObject:self];
    SCStream *stream=self.stream;if(!stream)return;self.stream=nil;
    [stream removeStreamOutput:self type:SCStreamOutputTypeScreen error:nil];
    [stream stopCaptureWithCompletionHandler:^(NSError *error){(void)error;}];
}
- (void)fail:(NSString *)failure code:(const char *)code error:(NSInteger)error {
    if(!atomic_load(&alive))return;familyTrace(self,"fail",code,error);self.failure=failure;[self retire];
    [self.owner memberFailed:self];
}
- (void)start {
    // Preserve the existing two-second start bound. A successful start gets its
    // own two seconds for a valid first image, counted before its main-queue
    // handoff. Neither delayed closure keeps a retired attempt alive.
    self.startDeadline=CACurrentMediaTime()+2;__weak DWReplicaMember *weak=self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),dispatch_get_main_queue(),^{[weak expireStart];});
    [self.stream startCaptureWithCompletionHandler:^(NSError *failure){CFTimeInterval completed=CACurrentMediaTime();dispatch_async(dispatch_get_main_queue(),^{
        DWReplicaMember *started=weak;if(!started||!atomic_load(&started->alive))return;
        if(failure)[started fail:failure.localizedDescription code:"start_failed" error:failure.code];
        else{started.started=YES;familyTrace(started,"started","none",0);started.firstFrameDeadline=completed+2;
            if(!started.hadImage)dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(MAX(0,started.firstFrameDeadline-CACurrentMediaTime())*NSEC_PER_SEC)),dispatch_get_main_queue(),^{[weak expireFirstFrame];});
        }
    });}];
}
- (void)expireStart {
    if(atomic_load(&alive)&&!self.started&&CACurrentMediaTime()>=self.startDeadline)
        [self fail:@"Family capture start timed out" code:"start_timeout" error:0];
}
- (void)expireFirstFrame {
    if(!atomic_load(&alive)||!self.started||CACurrentMediaTime()<self.firstFrameDeadline)return;
    if(!self.hadImage)[self fail:@"Family capture produced no valid image within two seconds"
        code:atomic_load(&received)?"first_frame_timeout_no_valid_frame":"first_frame_timeout_no_callback" error:0];
}
- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
    if(!atomic_load(&alive)||stream!=self.stream)return;
    // The delegate need not run on the serial sample queue. Revoke immediately
    // without changing that queue's sequence or bypassing main's failure path.
    if(atomic_exchange(&stopped,YES))return;
    dispatch_async(dispatch_get_main_queue(),^{if(stream==self.stream)[self fail:error.localizedDescription?:@"Family capture stopped" code:"stream_stopped" error:error.code];});
}
- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sample ofType:(SCStreamOutputType)type {
    if(!atomic_load(&alive)||atomic_load(&stopped)||stream!=self.stream||type!=SCStreamOutputTypeScreen)return;
    atomic_store(&received,YES);
    BOOL valid=CMSampleBufferIsValid(sample);CVPixelBufferRef pixels=valid?CMSampleBufferGetImageBuffer(sample):NULL;
    CFArrayRef attachments=valid?CMSampleBufferGetSampleAttachmentsArray(sample,NO):NULL;
    id value=attachments&&CFArrayGetCount(attachments)==1?(__bridge id)CFArrayGetValueAtIndex(attachments,0):nil;
    NSDictionary *info=[value isKindOfClass:NSDictionary.class]?value:nil;id status=info[SCStreamFrameInfoStatus];
    BOOL known=valid&&frameNumber(status)&&floor([status doubleValue])==[status doubleValue]
        &&[status doubleValue]>=SCFrameStatusComplete&&[status doubleValue]<=SCFrameStatusStopped;
    // This member's serial sample queue defines callback order. Availability is
    // atomic so a status-only callback revokes input before main can run. Idle
    // preserves a published image, but never repairs a previous revocation.
    uint64_t sequence=atomic_load(&callbackSequence);if(sequence!=UINT64_MAX)sequence++;
    atomic_store(&callbackSequence,sequence);
    BOOL complete=known&&[status integerValue]==SCFrameStatusComplete&&pixels;
    if(sequence==UINT64_MAX||!known||(!complete&&[status integerValue]!=SCFrameStatusIdle)){
        uint64_t previous=atomic_exchange(&unavailableSequence,sequence);
        if(atomic_load(&publishedSequence)>previous&&!atomic_exchange(&withdrawalPending,YES)){
            dispatch_async(dispatch_get_main_queue(),^{
                if(atomic_load(&self->alive)&&stream==self.stream&&![self imageAvailable]&&self.image.buffer){
                    self.image.buffer=NULL;[self.owner memberBecameUnavailable:self];
                }
                atomic_store(&self->withdrawalPending,NO);
            });
        }
        return;
    }
    if(!complete)return;
    BOOL expected=NO;if(!atomic_compare_exchange_strong(&pending,&expected,YES))return;
    CGRect rootNow=CGRectZero,ownNow=CGRectZero;
    BOOL current=DWNativeWindowBelongsToRoot(self.identity,self.root[@"identity"])
        &&DWNativeBounds([self.root[@"identity"][@"wid"]unsignedIntValue],&rootNow)
        &&DWNativeBounds([self.identity[@"wid"]unsignedIntValue],&ownNow)
        &&CGRectEqualToRect(rootNow,self.rootBounds)&&CGRectEqualToRect(ownNow,self.bounds);
    if(!current){dispatch_async(dispatch_get_main_queue(),^{atomic_store(&self->pending,NO);[self fail:@"Native family changed during capture" code:"membership_changed" error:0];});return;}
    CGRect crop=CGRectNull;uint64_t timestamp=0;
    if(!familyPixels(info,pixels,self.identity,self.bounds,self.frameTime,&crop,&timestamp)){dispatch_async(dispatch_get_main_queue(),^{atomic_store(&self->pending,NO);[self fail:@"Family capture metadata does not match its window" code:"frame_metadata_mismatch" error:0];});return;}
    self.frameTime=timestamp;
    NSArray *dirty=info[SCStreamFrameInfoDirtyRects];BOOL unchanged=[dirty isKindOfClass:NSArray.class]&&!dirty.count;
    CVPixelBufferRetain(pixels);
    dispatch_async(dispatch_get_main_queue(),^{
        if(atomic_load(&self->alive)&&!atomic_load(&self->stopped)&&stream==self.stream&&sequence>atomic_load(&self->unavailableSequence)
            &&familyBinding(self.owner.roots[self.root[@"window"]],self.root)){
            CVPixelBufferRef old=self.image.buffer;
            BOOL newlyAvailable=![self imageAvailable];
            BOOL changed=!unchanged||!old||newlyAvailable||!CGRectEqualToRect(self.image.contentRect,crop)||CVPixelBufferGetWidth(old)!=CVPixelBufferGetWidth(pixels)||CVPixelBufferGetHeight(old)!=CVPixelBufferGetHeight(pixels);
            if(changed){
                self.image.buffer=pixels;self.image.contentRect=crop;self.image.generation++;
            }
            self.hadImage=YES;atomic_store(&self->publishedSequence,sequence);
            // A later status may arrive while the main queue installs pixels.
            // Its revocation must win even over this successful publication.
            if(![self imageAvailable]){self.image.buffer=NULL;[self.owner memberBecameUnavailable:self];}
            else if(!old||newlyAvailable){familyTrace(self,"first_frame","none",0);[self.owner memberBecameDrawable:self];}
            else if(changed)[self.owner changedWindow:self.root[@"window"]];
        }
        CVPixelBufferRelease(pixels);atomic_store(&self->pending,NO);
    });
}
@end

static NSDictionary *familyHit(DWReplicaMember *member,NSDictionary *root,CGPoint local) {
    if(![member imageAvailable]||!member.image.buffer||!familyBinding(member.root,root))return nil;
    CGPoint own=CGPointMake(local.x+member.rootBounds.origin.x-member.bounds.origin.x,local.y+member.rootBounds.origin.y-member.bounds.origin.y);
    if(!CGRectContainsPoint(CGRectMake(0,0,member.bounds.size.width,member.bounds.size.height),own))return nil;
    return @{@"identity":member.identity,@"generation":member.root[@"generation"],@"native_bounds":DWRectJSON(member.bounds),@"local":@{@"x":@(own.x),@"y":@(own.y)}};
}

@implementation DWNativeReplicaFamilies
- (instancetype)initWithChanged:(void (^)(NSNumber *))changed {
    if((self=[super init])){_changed=[changed copy];_roots=@{};_members=[NSMutableDictionary dictionary];_drawableAttachments=[NSMutableDictionary dictionary];_recoveries=[NSMutableDictionary dictionary];
        _coldAttempts=[NSHashTable weakObjectsHashTable];_admissionRoots=[NSMutableArray array];
        _observer=familyQueue("org.infinify.native-family-replicas");}
    return self;
}
- (void)beginChanges {
    if(!self.changeDepth)self.changedWindows=[NSMutableSet set];
    self.changeDepth++;
}
- (void)endChanges {
    if(--self.changeDepth)return;
    if(self.orderingChanged){self.orderRevision++;self.orderingChanged=NO;}
    NSSet<NSNumber *> *changed=self.changedWindows;self.changedWindows=nil;
    for(NSNumber *window in changed)if(self.changed)self.changed(window);
}
- (void)changedWindow:(NSNumber *)window {
    if(!window)return;
    if(self.changeDepth)[self.changedWindows addObject:window];
    else if(self.changed)self.changed(window);
}
- (void)markOrderingChanged {
    BOOL own=!self.changeDepth;if(own)[self beginChanges];
    self.orderingChanged=YES;
    [self.changedWindows addObjectsFromArray:self.roots.allKeys];
    [self.changedWindows addObjectsFromArray:self.ordering.allKeys?:@[]];
    if(own)[self endChanges];
}
- (void)invalidateOrdering {
    if(self.ordering.count)[self markOrderingChanged];
    self.ordering=nil;self.orderingEpoch=0;self.orderingObservation=0;
}
- (DWReplicaRecovery *)recovery:(NSDictionary *)identity root:(NSDictionary *)root bounds:(CGRect)bounds {
    NSNumber *logical=root[@"window"],*wid=identity[@"wid"];
    NSMutableDictionary<NSNumber *,DWReplicaRecovery *> *family=self.recoveries[logical];
    DWReplicaRecovery *recovery=family[wid];
    if(!familyRecoveryMatches(recovery,root,identity,bounds)){
        // The caller just validated this exact replacement on the observer and
        // checked birth/freshness on main. Density/rate alone never reset it.
        if(!recovery&&family.count>=64)return nil;
        if(!family){family=[NSMutableDictionary dictionary];self.recoveries[logical]=family;}
        recovery=[DWReplicaRecovery new];recovery.root=root;recovery.identity=identity;recovery.bounds=bounds;recovery.waiting=++self.admissionSequence;family[wid]=recovery;
    }
    return recovery;
}
- (DWReplicaRecovery *)admitRecovery:(NSDictionary *)identity root:(NSDictionary *)root bounds:(CGRect)bounds starting:(NSUInteger *)starting {
    DWReplicaRecovery *recovery=[self recovery:identity root:root bounds:bounds];
    if(!recovery||*starting>=2||(recovery.failures&&CACurrentMediaTime()<recovery.notBefore))return nil;
    NSUInteger all=0,family=0;
    for(DWReplicaMember *attempt in self.coldAttempts.allObjects){
        if(!atomic_load(&attempt->alive)||attempt.image.buffer){[self.coldAttempts removeObject:attempt];continue;}
        all++;family+=[attempt.root[@"window"]isEqual:root[@"window"]];
    }
    if(all>=4||family>=2)return nil;
    (*starting)++;recovery.waiting=++self.admissionSequence;
    NSNumber *logical=root[@"window"];[self.admissionRoots removeObject:logical];[self.admissionRoots addObject:logical];
    return recovery;
}
- (NSArray<NSNumber *> *)admissionRootOrder {
    for(NSNumber *logical in self.admissionRoots.copy)if(!self.roots[logical])[self.admissionRoots removeObject:logical];
    for(NSNumber *logical in [self.roots.allKeys sortedArrayUsingSelector:@selector(compare:)])if(![self.admissionRoots containsObject:logical])[self.admissionRoots addObject:logical];
    return self.admissionRoots.copy;
}
- (NSArray<NSDictionary *> *)admissionPlans:(NSArray<NSDictionary *> *)plans root:(NSDictionary *)root {
    if(plans.count<2)return plans;
    // FIFO tickets, not numeric WID order or unconditional new-child priority:
    // a due persistent child keeps its place despite endlessly replaced peers.
    NSDictionary<NSNumber *,DWReplicaRecovery *> *family=self.recoveries[root[@"window"]];
    return [plans sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){
        DWReplicaRecovery *left=family[a[@"identity"][@"wid"]],*right=family[b[@"identity"][@"wid"]];
        uint64_t x=familyRecoveryMatches(left,root,a[@"identity"],DWRectFromJSON(a[@"native_bounds"]))?left.waiting:UINT64_MAX;
        uint64_t y=familyRecoveryMatches(right,root,b[@"identity"],DWRectFromJSON(b[@"native_bounds"]))?right.waiting:UINT64_MAX;
        return x<y?NSOrderedAscending:x>y?NSOrderedDescending:[a[@"identity"][@"wid"]compare:b[@"identity"][@"wid"]];
    }];
}
- (void)acceptRecoveryCohort:(NSArray<NSDictionary *> *)plans root:(NSDictionary *)root sampledAt:(NSNumber *)began {
    NSMutableDictionary<NSNumber *,DWReplicaRecovery *> *family=self.recoveries[root[@"window"]];
    if(!plans.count&&!family.count)return;
    if(!began||!familyBinding(self.roots[root[@"window"]],root)||!familyProcessMatches(root[@"identity"]))return;
    CFTimeInterval age=CACurrentMediaTime()-began.doubleValue;if(age<0||age>.1)return;
    NSMutableDictionary *current=[NSMutableDictionary dictionary];for(NSDictionary *plan in plans)current[plan[@"identity"][@"wid"]]=plan;
    for(NSNumber *wid in family.allKeys){NSDictionary *plan=current[wid];
        if(!plan||!familyRecoveryMatches(family[wid],root,plan[@"identity"],DWRectFromJSON(plan[@"native_bounds"])))
            [family removeObjectForKey:wid];
    }
    if(!family.count)[self.recoveries removeObjectForKey:root[@"window"]];
    // A fresh complete observation gives waiting members a stable place before
    // capacity is consulted. Merely waiting never consumes a start allowance.
    for(NSDictionary *plan in plans)[self recovery:plan[@"identity"] root:root bounds:DWRectFromJSON(plan[@"native_bounds"])];
}
- (void)memberFailed:(DWReplicaMember *)member {
    NSNumber *window=member.root[@"window"];
    DWReplicaRecovery *recovery=self.recoveries[window][member.identity[@"wid"]];
    if(recovery.attempt!=member||!familyRecoveryMatches(recovery,member.root,member.identity,member.bounds)
       ||!familyBinding(self.roots[window],member.root))return;
    recovery.failures=MIN(7,recovery.failures+1);
    recovery.notBefore=CACurrentMediaTime()+familyRecoveryDelay(member.identity,recovery.failures);
    [self beginChanges];
    [self.drawableAttachments removeObjectForKey:window];
    self.epoch++;self.reading=NO;self.nextRead=MIN(self.nextRead,CACurrentMediaTime()+.25);
    [self markOrderingChanged];[self invalidateOrdering];[self changedWindow:window];
    [self endChanges];
}
- (void)memberBecameDrawable:(DWReplicaMember *)member {
    [self.coldAttempts removeObject:member];
    NSNumber *window=member.root[@"window"];
    DWReplicaRecovery *recovery=self.recoveries[window][member.identity[@"wid"]];
    if(recovery.attempt==member&&familyRecoveryMatches(recovery,member.root,member.identity,member.bounds)){
        recovery.failures=0;recovery.notBefore=0;
    }
    // A first image changes the default token membership and may complete an
    // observed family. Later pixel frames leave ordering/revision untouched.
    [self beginChanges];[self.drawableAttachments removeObjectForKey:window];[self markOrderingChanged];[self changedWindow:window];[self endChanges];
}
- (void)memberBecameUnavailable:(DWReplicaMember *)member {
    NSNumber *window=member.root[@"window"];
    if(![self.members[window]containsObject:member]||!familyBinding(self.roots[window],member.root))return;
    // Availability changes drawing/input only: the stream, immutable audit and
    // retry history remain intact until a real lifecycle failure occurs.
    [self beginChanges];[self.drawableAttachments removeObjectForKey:window];[self markOrderingChanged];[self changedWindow:window];[self endChanges];
}
- (void)reset {
    [self beginChanges];
    NSArray<NSNumber *> *changed=self.members.allKeys;
    if(self.roots.count||self.members.count||self.ordering.count)[self markOrderingChanged];
    self.epoch++;self.reading=NO;self.nextRead=0;
    [self invalidateOrdering];
    for(NSArray<DWReplicaMember *> *family in self.members.allValues)for(DWReplicaMember *member in family)[member retire];
    [self.members removeAllObjects];[self.drawableAttachments removeAllObjects];[self.recoveries removeAllObjects];[self.coldAttempts removeAllObjects];[self.admissionRoots removeAllObjects];self.admissionSequence=0;self.roots=@{};
    [self replaceDescriptions:@{}];
    for(NSNumber *window in changed)[self changedWindow:window];
    [self endChanges];
}
- (NSArray<NSDictionary *> *)capturePlans:(NSArray<NSDictionary *> *)plans root:(NSDictionary *)root {
    if([root[@"capture"]isEqual:@NO])return @[];
    CFTimeInterval now=CACurrentMediaTime();NSMutableArray *wanted=[NSMutableArray array];
    for(NSDictionary *plan in plans){CGRect bounds=DWRectFromJSON(plan[@"native_bounds"]);DWReplicaMember *installed=nil;
        for(DWReplicaMember *member in self.members[root[@"window"]])if(atomic_load(&member->alive)&&familyBinding(member.root,root)&&[member.identity isEqual:plan[@"identity"]]&&CGRectEqualToRect(member.bounds,bounds)){installed=member;break;}
        BOOL visible=familyIntersectsCapture(root,bounds);
        if(visible&&installed)installed.lastVisible=now;
        // Match the root's two-second grace: crossing a viewport boundary
        // briefly must not repeatedly stop/start a healthy child's stream.
        if(visible||(installed&&now-installed.lastVisible<2))[wanted addObject:plan];
    }
    return wanted.copy;
}
- (void)pruneCaptureDemand {
    CFTimeInterval now=CACurrentMediaTime();
    for(NSNumber *window in self.members.allKeys){NSDictionary *root=self.roots[window];NSArray *old=self.members[window];NSMutableArray *kept=[NSMutableArray array];
        for(DWReplicaMember *member in old){BOOL visible=familyIntersectsCapture(root,member.bounds);
            if(visible)member.lastVisible=now;
            if(visible||(![root[@"capture"]isEqual:@NO]&&now-member.lastVisible<2))[kept addObject:member];else [member retire];
        }
        if(kept.count==old.count)continue;
        self.members[window]=kept.copy;[self.drawableAttachments removeObjectForKey:window];
        // The same audited native ranks remain valid for a smaller drawn
        // subset. Do not replace them with controller/default grouping.
        DWReplicaOrder *prior=self.ordering[window];
        if(prior){DWReplicaOrder *order=[DWReplicaOrder new];order.root=prior.root;order.rank=prior.rank;order.members=kept.copy;
            NSMutableDictionary *ranks=[NSMutableDictionary dictionary];for(DWReplicaMember *member in kept)if(prior.ranks[member.image.key])ranks[member.image.key]=prior.ranks[member.image.key];order.ranks=ranks.copy;
            NSMutableDictionary *ordering=[self.ordering mutableCopy];ordering[window]=order;self.ordering=ordering.copy;
        }
        [self markOrderingChanged];[self changedWindow:window];
    }
}
- (void)describe:(NSArray<NSDictionary *> *)roots rate:(NSInteger)rate {
    NSMutableDictionary *wanted=[NSMutableDictionary dictionary];
    for(NSDictionary *root in roots)if(root[@"window"]&&root[@"identity"]&&root[@"generation"]&&familySize(DWRectFromJSON(root[@"native_bounds"])))wanted[root[@"window"]]=root;
    NSInteger hz=MAX(1,MIN(rate,240));BOOL bindingChanged=!familyCohortMatches(self.roots,wanted),configurationChanged=self.rate!=hz;
    for(NSNumber *window in wanted)if(![self.roots[window][@"density"]isEqual:wanted[window][@"density"]]||[self.roots[window][@"capture"]isEqual:@NO]!=[wanted[window][@"capture"]isEqual:@NO])configurationChanged=YES;
    BOOL visibilityGained=NO;
    if(!bindingChanged)for(NSNumber *window in wanted){NSDictionary *before=self.roots[window],*after=wanted[window],*known=self.descriptions[window];
        if(!familyBinding(known,after))continue;
        for(NSDictionary *member in known[@"members"]){
            if([member[@"identity"][@"wid"]isEqual:after[@"identity"][@"wid"]])continue;
            CGRect bounds=DWRectFromJSON(member[@"native_bounds"]);
            if(!familyIntersectsCapture(before,bounds)&&familyIntersectsCapture(after,bounds)){visibilityGained=YES;break;}
        }
        if(visibilityGained)break;
    }
    [self beginChanges];
    if(bindingChanged){self.epoch++;self.reading=NO;[self invalidateOrdering];}
    for(NSNumber *window in self.members.allKeys)if(!familyBinding(self.roots[window],wanted[window])||[wanted[window][@"capture"]isEqual:@NO]){
        for(DWReplicaMember *member in self.members[window])[member retire];[self.members removeObjectForKey:window];
        [self.drawableAttachments removeObjectForKey:window];
        [self changedWindow:window];
    }
    for(NSNumber *window in self.recoveries.allKeys)if(!familyBinding(self.roots[window],wanted[window])||[wanted[window][@"capture"]isEqual:@NO])[self.recoveries removeObjectForKey:window];
    for(NSNumber *window in self.admissionRoots.copy)if(!familyBinding(self.roots[window],wanted[window])||[wanted[window][@"capture"]isEqual:@NO])[self.admissionRoots removeObject:window];
    self.roots=wanted.copy;self.rate=hz;
    [self pruneCaptureDemand];
    NSMutableDictionary *descriptions=[self.descriptions mutableCopy]?:[NSMutableDictionary dictionary];
    for(NSNumber *window in descriptions.allKeys)if(!familyBinding(descriptions[window],wanted[window]))[descriptions removeObjectForKey:window];
    [self replaceDescriptions:descriptions.copy];
    if(bindingChanged)[self markOrderingChanged];
    // A known child becoming visible wakes discovery once, rather than waiting
    // for the idle refresh. Persistent visibility or missing pixels do not
    // continually wake audits or bypass the child's recovery backoff.
    if(bindingChanged||configurationChanged||visibilityGained)self.nextRead=0;
    [self endChanges];
    if(self.roots.count&&CACurrentMediaTime()>=self.nextRead)[self request];
}
- (NSArray<DWCanvasAttachment *> *)attachments:(NSNumber *)window {
    NSArray<DWReplicaMember *> *members=self.members[window];if(!members.count)return @[];
    NSArray<DWCanvasAttachment *> *cached=self.drawableAttachments[window];
    // Revoke cached drawing immediately even before the queued withdrawal runs.
    for(DWReplicaMember *member in members)if(member.image.buffer&&![member imageAvailable]){cached=nil;[self.drawableAttachments removeObjectForKey:window];break;}
    if(cached)return cached;
    // Pixel frames update these same attachment objects. Materialize only when
    // capture membership or first-image availability changes, on the main queue.
    NSMutableArray *images=[NSMutableArray array];
    for(DWReplicaMember *member in members)if([member imageAvailable]&&member.image.buffer)[images addObject:member.image];
    cached=images.copy;self.drawableAttachments[window]=cached;return cached;
}
- (NSArray<NSDictionary *> *)orderedRun:(NSArray<NSDictionary *> *)tokens range:(NSRange)range {
    NSMutableDictionary<NSNumber *,DWReplicaOrder *> *families=[NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber *,NSMutableSet<NSString *> *> *keys=[NSMutableDictionary dictionary];
    NSMutableSet<NSNumber *> *roots=[NSMutableSet set],*seenRanks=[NSMutableSet set];
    NSMutableArray<NSArray *> *ranked=[NSMutableArray arrayWithCapacity:range.length];NSNumber *previousRoot=nil;
    for(NSUInteger i=range.location;i<NSMaxRange(range);i++){
        NSDictionary *token=tokens[i];NSNumber *window=token[@"window"];id key=token[@"key"];
        if(![window isKindOfClass:NSNumber.class])return nil;
        DWReplicaOrder *order=self.ordering[window];
        if(!order)return nil;
        if(!families[window]){
            if(!familyBinding(order.root,self.roots[window])||![order.members isEqual:self.members[window]]
               ||order.ranks.count!=order.members.count)return nil;
            families[window]=order;keys[window]=[NSMutableSet set];
        }
        NSNumber *rank=nil;
        if(key){
            if(![key isKindOfClass:NSString.class]||![key length]||[keys[window]containsObject:key])return nil;
            rank=order.ranks[key];[keys[window]addObject:key];
        }else{
            if([roots containsObject:window])return nil;
            rank=order.rank;if(!rank)return nil;
            // WindowServer enumeration is front to back; the supplied root
            // tokens are the controller's back-to-front order and must agree.
            if(previousRoot&&[previousRoot compare:rank]!=NSOrderedDescending)return nil;
            previousRoot=rank;[roots addObject:window];
        }
        if(!rank||[seenRanks containsObject:rank])return nil;
        [seenRanks addObject:rank];[ranked addObject:@[token,rank]];
    }
    for(NSNumber *window in families){DWReplicaOrder *order=families[window];
        if(![roots containsObject:window]||keys[window].count!=order.members.count)return nil;
        for(DWReplicaMember *member in order.members){
            if(![member imageAvailable]||!member.image.buffer||!familyBinding(member.root,self.roots[window])
               ||!member.image.key||![keys[window]containsObject:member.image.key]||!order.ranks[member.image.key])return nil;
        }
    }
    [ranked sortUsingComparator:^NSComparisonResult(NSArray *a,NSArray *b){return [b[1]compare:a[1]];}];
    NSMutableArray *result=[NSMutableArray arrayWithCapacity:range.length];for(NSArray *entry in ranked)[result addObject:entry[0]];
    return result;
}
- (NSArray<NSDictionary *> *)orderedTokens:(NSArray<NSDictionary *> *)tokens {
    if(!self.ordering.count||self.orderingEpoch!=self.epoch||!self.orderingObservation)return tokens;
    NSMutableArray *result=nil;
    for(NSUInteger start=0;start<tokens.count;){
        NSDictionary *token=tokens[start];
        if(![token isKindOfClass:NSDictionary.class]||familyBarrier(token)){start++;continue;}
        NSNumber *bucket=familyBucket(token);if(!bucket){start++;continue;}
        NSUInteger end=start+1;
        while(end<tokens.count&&[tokens[end]isKindOfClass:NSDictionary.class]
              &&!familyBarrier(tokens[end])&&[bucket isEqual:familyBucket(tokens[end])])end++;
        NSRange range=NSMakeRange(start,end-start);NSArray *ordered=[self orderedRun:tokens range:range];
        if(ordered){BOOL changed=NO;for(NSUInteger i=0;i<ordered.count;i++)if(ordered[i]!=tokens[start+i]){changed=YES;break;}
            if(changed){if(!result)result=[tokens mutableCopy];[result replaceObjectsInRange:range withObjectsFromArray:ordered];}
        }
        start=end;
    }
    return result?result.copy:tokens;
}
- (NSDictionary *)hit:(NSNumber *)window local:(CGPoint)local {
    for(DWReplicaMember *member in [self.members[window]reverseObjectEnumerator]){
        NSDictionary *hit=familyHit(member,self.roots[window],local);if(hit)return hit;
    }
    return nil;
}
- (NSDictionary *)hit:(NSNumber *)window key:(NSString *)key local:(CGPoint)local {
    if(![key isKindOfClass:NSString.class]||!key.length)return nil;
    DWReplicaMember *found=nil;
    for(DWReplicaMember *member in self.members[window])if([member.image.key isEqual:key]){if(found)return nil;found=member;}
    return found?familyHit(found,self.roots[window],local):nil;
}
- (BOOL)contains:(NSNumber *)window identity:(NSDictionary *)identity generation:(NSNumber *)generation bounds:(CGRect)bounds {
    for(DWReplicaMember *member in self.members[window])if([member imageAvailable]&&member.image.buffer&&[member.identity isEqual:identity]&&[member.root[@"generation"]isEqual:generation]&&CGRectEqualToRect(member.bounds,bounds)&&familyBinding(member.root,self.roots[window])){
        CGRect rootNow=CGRectZero,memberNow=CGRectZero;
        return DWNativeBounds([member.root[@"identity"][@"wid"]unsignedIntValue],&rootNow)&&DWNativeBounds([member.identity[@"wid"]unsignedIntValue],&memberNow)
            &&CGRectEqualToRect(rootNow,member.rootBounds)&&CGRectEqualToRect(memberNow,member.bounds);
    }
    return NO;
}
- (void)invalidatePID:(pid_t)pid {
    [self invalidatePID:pid discardRecovery:YES];
}
- (void)invalidatePID:(pid_t)pid discardRecovery:(BOOL)discard {
    [self beginChanges];[self invalidateOrdering];
    self.epoch++;self.reading=NO;self.nextRead=0;
    for(NSNumber *window in self.members.allKeys)if(!pid||[self.roots[window][@"identity"][@"pid"]intValue]==pid){
        for(DWReplicaMember *member in self.members[window])[member retire];[self.members removeObjectForKey:window];[self.drawableAttachments removeObjectForKey:window];[self markOrderingChanged];[self changedWindow:window];
    }
    if(discard)for(NSNumber *window in self.recoveries.allKeys)if(!pid||[self.roots[window][@"identity"][@"pid"]intValue]==pid)[self.recoveries removeObjectForKey:window];
    if(discard)for(NSNumber *window in self.admissionRoots.copy)if(!pid||[self.roots[window][@"identity"][@"pid"]intValue]==pid)[self.admissionRoots removeObject:window];
    NSMutableDictionary *descriptions=[self.descriptions mutableCopy]?:[NSMutableDictionary dictionary];
    for(NSNumber *window in descriptions.allKeys)if(!pid||[descriptions[window][@"identity"][@"pid"]intValue]==pid)[descriptions removeObjectForKey:window];
    [self replaceDescriptions:descriptions.copy];
    [self endChanges];
}
- (void)replaceDescriptions:(NSDictionary<NSNumber *,NSDictionary *> *)descriptions {
    if([self.descriptions isEqual:descriptions])return;
    NSDictionary *prior=self.descriptions;self.descriptions=descriptions.copy;
    NSMutableSet *windows=[NSMutableSet setWithArray:prior.allKeys?:@[]];[windows addObjectsFromArray:descriptions.allKeys];
    for(NSNumber *window in windows)if(![prior[window]isEqual:descriptions[window]])[self changedWindow:window];
}
- (void)request {
    // An uncancellable shareable-content request remains outstanding even after
    // its deadline. Never pile later observations behind a stalled native read.
    if(self.reading||self.requestPending||!self.roots.count)return;
    // A request sequence is not a binding epoch: keep the last complete order
    // during an ordinary refresh, then replace the whole cohort atomically.
    self.reading=YES;self.requestPending=YES;NSUInteger sequence=++self.requestSequence,epoch=self.epoch;NSDictionary *roots=self.roots;self.nextRead=CACurrentMediaTime()+1;
    dispatch_queue_t observer=self.observer;__weak DWNativeReplicaFamilies *weak=self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),dispatch_get_main_queue(),^{
        DWNativeReplicaFamilies *owner=weak;if(!owner||!owner.reading||owner.epoch!=epoch||owner.requestSequence!=sequence)return;
        [owner invalidatePID:0 discardRecovery:NO];owner.nextRead=CACurrentMediaTime()+1;
    });
    dispatch_async(self.observer,^{
        // TCC preflight may synchronously wait on another process. Check once
        // per bounded observation here, never in the main-thread description
        // path (including empty families). This is not a cached grant: every
        // discovery rechecks, and stream errors still retire revoked captures.
        if(!CGPreflightScreenCaptureAccess()){
            dispatch_async(dispatch_get_main_queue(),^{
                DWNativeReplicaFamilies *owner=weak;if(!owner)return;owner.requestPending=NO;
                if(!owner.reading||owner.epoch!=epoch||owner.requestSequence!=sequence||!familyCohortMatches(owner.roots,roots))return;
                [owner invalidatePID:0];owner.nextRead=CACurrentMediaTime()+1;
            });
            return;
        }
        NSMutableDictionary *plans=[NSMutableDictionary dictionary],*descriptions=[NSMutableDictionary dictionary],*sampledAt=[NSMutableDictionary dictionary];NSMutableSet *completeRoots=[NSMutableSet set];
        // This option documents front-to-back order. Offscreen captures remain
        // eligible for default grouping, but cannot borrow an inferred rank.
        NSArray *ordered=CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly,kCGNullWindowID));
        NSMutableDictionary *ranks=[NSMutableDictionary dictionary],*owners=[NSMutableDictionary dictionary];NSMutableSet *seen=[NSMutableSet set];
        for(NSUInteger i=0;i<ordered.count;i++){
            NSNumber *wid=ordered[i][(id)kCGWindowNumber],*pid=ordered[i][(id)kCGWindowOwnerPID];
            if(!frameNumber(wid)||[wid doubleValue]<=0||[wid doubleValue]>UINT32_MAX||floor([wid doubleValue])!=[wid doubleValue])continue;
            if([seen containsObject:wid]){[ranks removeObjectForKey:wid];[owners removeObjectForKey:wid];continue;}[seen addObject:wid];
            if(!frameNumber(pid)||[pid doubleValue]<=1||[pid doubleValue]>INT_MAX||floor([pid doubleValue])!=[pid doubleValue])continue;
            ranks[wid]=@(i);owners[wid]=pid;
        }
        for(NSNumber *window in roots){CFTimeInterval began=CACurrentMediaTime();NSString *why=nil;NSDictionary *family=DWNativeWindowFamily(roots[window][@"identity"],&why);
            NSMutableArray *children=[NSMutableArray array],*members=[NSMutableArray array];CGRect rootBounds=DWRectFromJSON(roots[window][@"native_bounds"]);NSUInteger rootCount=0;BOOL rankedChildren=YES;
            for(NSDictionary *member in family[@"members"]){
                if([member[@"identity"][@"wid"]isEqual:roots[window][@"identity"][@"wid"]]){rootCount++;if(!CGRectEqualToRect(DWRectFromJSON(member[@"native_bounds"]),rootBounds))family=nil;[members addObject:member];continue;}
                [members addObject:member];
                [children addObject:member];if(!familyRank(ranks,owners,member[@"identity"]))rankedChildren=NO;
            }
            if(!family||rootCount!=1){plans[window]=@[];continue;}
            sampledAt[window]=@(began);
            NSMutableDictionary *description=[family mutableCopy];description[@"window"]=window;description[@"generation"]=roots[window][@"generation"];description[@"native_bounds"]=roots[window][@"native_bounds"];description[@"members"]=members.copy;descriptions[window]=description.copy;
            if(rankedChildren)[children sortUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){return [ranks[b[@"identity"][@"wid"]]compare:ranks[a[@"identity"][@"wid"]]];}];
            plans[window]=children.copy;
            if(rankedChildren&&familyRank(ranks,owners,roots[window][@"identity"]))[completeRoots addObject:window];
        }
        BOOL children=NO;for(NSNumber *window in plans)if([plans[window]count]&&![roots[window][@"capture"]isEqual:@NO]){children=YES;break;}
        void (^reconcile)(SCShareableContent *,NSError *)=^(SCShareableContent *content,NSError *error){dispatch_async(observer,^{
            NSMutableDictionary *windows=[NSMutableDictionary dictionary];for(SCWindow *window in content.windows)windows[@(window.windowID)]=window;
            NSMutableDictionary *checkedMembers=[NSMutableDictionary dictionary];
            if(!error)for(NSNumber *logical in roots)if(![roots[logical][@"capture"]isEqual:@NO]){
                NSMutableDictionary *checked=[NSMutableDictionary dictionary];
                for(NSDictionary *plan in plans[logical]){
                    CFTimeInterval began=CACurrentMediaTime();
                    NSDictionary *identity=plan[@"identity"];CGRect bounds=DWRectFromJSON(plan[@"native_bounds"]);SCWindow *window=windows[identity[@"wid"]];
                    CGRect rootNow=CGRectZero,memberNow=CGRectZero;
                    if(window&&window.owningApplication.processID==[identity[@"pid"]intValue]&&familySize(bounds)
                       &&DWNativeWindowBelongsToRoot(identity,roots[logical][@"identity"])
                       &&DWNativeBounds([roots[logical][@"identity"][@"wid"]unsignedIntValue],&rootNow)
                       &&DWNativeBounds([identity[@"wid"]unsignedIntValue],&memberNow)
                       &&CGRectEqualToRect(rootNow,DWRectFromJSON(roots[logical][@"native_bounds"]))&&CGRectEqualToRect(memberNow,bounds))checked[identity[@"wid"]]=@(began);
                }
                checkedMembers[logical]=checked.copy;
            }
            // Root-only runs cannot change controller order. Only a cohort
            // containing captured children needs other roots' ranks to place
            // those children across families. Validate that geometry evidence
            // on the observer too; it never grants input or native authority.
            NSMutableDictionary *checkedRoots=[NSMutableDictionary dictionary];
            if(children&&!error)for(NSNumber *logical in completeRoots){
                CFTimeInterval began=CACurrentMediaTime();CGRect rootNow=CGRectZero;
                if(DWNativeWindowBelongsToRoot(roots[logical][@"identity"],roots[logical][@"identity"])
                   &&DWNativeBounds([roots[logical][@"identity"][@"wid"]unsignedIntValue],&rootNow)
                   &&CGRectEqualToRect(rootNow,DWRectFromJSON(roots[logical][@"native_bounds"])))checkedRoots[logical]=@(began);
            }
            dispatch_async(dispatch_get_main_queue(),^{
            DWNativeReplicaFamilies *owner=weak;if(!owner)return;owner.requestPending=NO;if(!owner.reading||owner.epoch!=epoch||owner.requestSequence!=sequence||!familyCohortMatches(owner.roots,roots))return;owner.reading=NO;
            [owner beginChanges];
            NSMutableDictionary *nextMembers=[NSMutableDictionary dictionary],*nextOrdering=[NSMutableDictionary dictionary];
            NSUInteger starting=0;
            for(NSNumber *logical in [owner admissionRootOrder]){NSMutableArray *installed=[NSMutableArray array];NSArray<DWReplicaMember *> *old=owner.members[logical]?:@[];
                NSDictionary *currentRoot=owner.roots[logical];NSInteger rate=owner.rate;
                // Only a fresh, complete native membership read may forget an
                // absent failed binding. An error/stalled request cannot turn
                // every old failure back into an unthrottled initial attempt.
                if(owner.epoch==epoch&&descriptions[logical])[owner acceptRecoveryCohort:plans[logical] root:roots[logical] sampledAt:sampledAt[logical]];
                NSArray<NSDictionary *> *wanted=error?@[]:[owner capturePlans:plans[logical] root:currentRoot];
                for(NSDictionary *plan in [owner admissionPlans:wanted root:roots[logical]]){
                    NSDictionary *identity=plan[@"identity"];CGRect bounds=DWRectFromJSON(plan[@"native_bounds"]);SCWindow *window=windows[identity[@"wid"]];
                    // The observer proved this exact child/root binding. Its
                    // deadline includes every native read and queue wait; a
                    // stalled result never becomes fresh at completion. This
                    // admits only stream setup/reuse: frames and input retain
                    // their own fresh native validation before publication.
                    NSNumber *began=checkedMembers[logical][identity[@"wid"]];
                    if(!began||!familyProcessMatches(identity))continue;
                    CFTimeInterval age=CACurrentMediaTime()-began.doubleValue;
                    if(age<0||age>.1)continue;
                    double density=[currentRoot[@"density"]doubleValue];if(!isfinite(density)||density<=0)density=2;
                    density=MIN(2,MAX(1./32,density));DWReplicaMember *member=nil;
                    for(DWReplicaMember *candidate in old)if(atomic_load(&candidate->alive)&&[candidate.identity isEqual:identity]&&CGRectEqualToRect(candidate.bounds,bounds)&&familyBinding(candidate.root,roots[logical])){member=candidate;break;}
                    if(!member){DWReplicaRecovery *recovery=[owner admitRecovery:identity root:roots[logical] bounds:bounds starting:&starting];if(!recovery)continue;
                        member=[DWReplicaMember new];member.owner=owner;member.root=currentRoot;member.identity=identity;member.bounds=bounds;member.rootBounds=DWRectFromJSON(currentRoot[@"native_bounds"]);member.density=density;member.rate=rate;member.lastVisible=CACurrentMediaTime();member.frameTime=mach_absolute_time();recovery.attempt=member;
                        [owner.coldAttempts addObject:member];
                        familyTrace(member,"create","none",0);
                        DWCanvasAttachment *image=[DWCanvasAttachment new];image.key=[NSString stringWithFormat:@"%@:%@:%@:%@",identity[@"pid"],identity[@"birth_sec"],identity[@"birth_usec"],identity[@"wid"]];
                        image.unitRect=CGRectMake((bounds.origin.x-member.rootBounds.origin.x)/member.rootBounds.size.width,(bounds.origin.y-member.rootBounds.origin.y)/member.rootBounds.size.height,bounds.size.width/member.rootBounds.size.width,bounds.size.height/member.rootBounds.size.height);member.image=image;
                        SCStreamConfiguration *config=familyConfiguration(bounds,density,rate);
                        member.samples=familyQueue("org.infinify.native-family-frames");
                        member.stream=[[SCStream alloc]initWithFilter:[[SCContentFilter alloc]initWithDesktopIndependentWindow:window] configuration:config delegate:member];
                        NSError *failure=nil;
                        if(![member.stream addStreamOutput:member type:SCStreamOutputTypeScreen sampleHandlerQueue:member.samples error:&failure]){[member fail:failure.localizedDescription?:@"Family capture output unavailable" code:"output_unavailable" error:failure.code];continue;}
                        [member start];
                    }else if(member.started&&!member.updating&&(member.density!=density||member.rate!=rate)){
                        member.updating=YES;member.density=density;member.rate=rate;NSUInteger revision=++member.configuration;DWReplicaMember *updated=member;
                        familyTrace(member,"configure","none",0);
                        [member.stream updateConfiguration:familyConfiguration(bounds,density,rate) completionHandler:^(NSError *failure){dispatch_async(dispatch_get_main_queue(),^{if(!atomic_load(&updated->alive)||updated.configuration!=revision)return;updated.updating=NO;if(failure)[updated fail:failure.localizedDescription code:"configuration_failed" error:failure.code];});}];
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),dispatch_get_main_queue(),^{if(atomic_load(&updated->alive)&&updated.updating&&updated.configuration==revision)[updated fail:@"Family capture configuration timed out" code:"configuration_timeout" error:0];});
                    }
                    [installed addObject:member];
                }
                // Scheduling priority is not z-order. Publish the exact native
                // observation's sequence (or its existing fallback sequence).
                if(installed.count>1){NSMutableDictionary *byID=[NSMutableDictionary dictionary];for(DWReplicaMember *member in installed)byID[member.identity[@"wid"]]=member;
                    [installed removeAllObjects];for(NSDictionary *plan in wanted){DWReplicaMember *member=byID[plan[@"identity"][@"wid"]];if(member)[installed addObject:member];}}
                for(DWReplicaMember *member in old)if(![installed containsObject:member])[member retire];
                nextMembers[logical]=installed.copy;
                if(![old isEqual:installed]){[owner.drawableAttachments removeObjectForKey:logical];[owner markOrderingChanged];[owner changedWindow:logical];}
                BOOL complete=children&&!error&&[completeRoots containsObject:logical]&&installed.count==wanted.count;
                if(complete&&!installed.count){NSNumber *began=checkedRoots[logical];
                    // Measure from the first validation read, including time
                    // spent waiting on WindowServer and on this queue. A late
                    // result falls back for the whole run; it is not made fresh
                    // by its completion. Birth is still checked at publication.
                    complete=began&&familyProcessMatches(roots[logical][@"identity"]);
                    CFTimeInterval age=began?CACurrentMediaTime()-began.doubleValue:INFINITY;
                    complete=complete&&age>=0&&age<=.1;
                }
                if(complete){NSMutableDictionary *children=[NSMutableDictionary dictionary];
                    for(DWReplicaMember *member in installed){NSString *key=member.image.key;NSNumber *rank=familyRank(ranks,owners,member.identity);
                        if(!key||!rank||children[key]){complete=NO;break;}children[key]=rank;
                    }
                    if(complete){DWReplicaOrder *order=[DWReplicaOrder new];order.root=roots[logical];order.rank=familyRank(ranks,owners,roots[logical][@"identity"]);order.members=installed.copy;order.ranks=children.copy;nextOrdering[logical]=order;}
                }
            }
            // A synchronous capture setup failure invalidates this observation
            // too. No callback sees a partially installed family/order cohort.
            NSDictionary *accepted=owner.epoch==epoch?nextOrdering.copy:@{};
            familyNormalizeOrder(accepted);
            if(!familySameOrder(owner.ordering,accepted))[owner markOrderingChanged];
            owner.members=nextMembers;owner.ordering=accepted;
            owner.orderingEpoch=owner.epoch;owner.orderingObservation=accepted.count?sequence:0;
            [owner replaceDescriptions:owner.epoch==epoch?descriptions.copy:@{}];
            [owner endChanges];
        });});};
        // A fresh empty family needs only retirement of prior children. Do not
        // ask ScreenCaptureKit to enumerate the desktop when no filter can be
        // created, but retain the same epoch/deadline/reconciliation path.
        if(children)[SCShareableContent getShareableContentExcludingDesktopWindows:YES onScreenWindowsOnly:NO completionHandler:reconcile];
        else reconcile(nil,nil);
    });
}
- (void)dealloc {for(NSArray<DWReplicaMember *> *family in _members.allValues)for(DWReplicaMember *member in family)[member retire];}
@end
