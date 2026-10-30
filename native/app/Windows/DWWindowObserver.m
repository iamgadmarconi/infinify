// SPDX-License-Identifier: GPL-3.0-or-later
#import "DWWindowObserver.h"
#import "DWNativeFocus.h"
#import "DWNativePresenter.h"
#import "DWNativeFamily.h"
#import "DWAXLookup.h"
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#include <libproc.h>

@interface DWWindowObservation ()
@property(nonatomic,copy,readwrite) NSDictionary *request,*info,*family;
@property(nonatomic,copy,readwrite) NSString *failure,*familyFailure;
@property(nonatomic,copy,readwrite) NSNumber *minimized;
@property(nonatomic,readwrite) DWWindowObservationState state;
@property(nonatomic,readwrite) CGRect bounds;
@property(nonatomic,readwrite) BOOL hasBounds;
@property(nonatomic,readwrite) CFTimeInterval sampledAt;
@end
@implementation DWWindowObservation @end

@interface DWWindowObservationSnapshot ()
@property(nonatomic,readwrite) uint64_t generation;
@property(nonatomic,readwrite) BOOL listSucceeded;
@property(nonatomic,copy,readwrite) NSDictionary<NSNumber *,NSDictionary *> *onScreen;
@property(nonatomic,copy,readwrite) NSArray<NSDictionary *> *orderedOnScreen;
@property(nonatomic,copy,readwrite) NSDictionary<NSNumber *,NSDictionary *> *nativeCandidateBases;
@property(nonatomic,copy,readwrite) NSArray<DWWindowObservation *> *sources;
@property(nonatomic,readwrite) CFTimeInterval startedAt,finishedAt,deliveredAt;
@end
@implementation DWWindowObservationSnapshot @end

static BOOL observedNumber(id value) { return [value isKindOfClass:NSNumber.class]; }
static NSArray<NSNumber *> *observedBirth(pid_t pid,NSMutableDictionary<NSNumber *,id> *births) {
    id found=births[@(pid)];if(found)return found==NSNull.null?nil:found;
    NSArray *birth=nil;uint64_t seconds=0,microseconds=0;
    if(DWProcessBirth(pid,&seconds,&microseconds))birth=@[@(seconds),@(microseconds)];
    births[@(pid)]=birth?:NSNull.null;return birth;
}
static NSDictionary *observedRequest(NSDictionary *source) {
    if(![source isKindOfClass:NSDictionary.class])return nil;
    NSDictionary *identity=source[@"identity"];
    if(![identity isKindOfClass:NSDictionary.class]||!observedNumber(source[@"logical"])||!observedNumber(source[@"generation"]))return nil;
    for(NSString *key in @[@"pid",@"birth_sec",@"birth_usec",@"wid"])if(!observedNumber(identity[key]))return nil;
    if([identity[@"pid"]intValue]<=0||![identity[@"wid"]unsignedIntValue]||[identity[@"birth_sec"]longLongValue]<=0||[identity[@"birth_usec"]intValue]<0||[identity[@"birth_usec"]intValue]>=1000000)return nil;
    NSMutableDictionary *copiedIdentity=[NSMutableDictionary dictionary];
    for(NSString *key in @[@"pid",@"birth_sec",@"birth_usec",@"wid"])copiedIdentity[key]=[identity[key]copy];
    if(identity[@"owner"]){if(!observedNumber(identity[@"owner"]))return nil;copiedIdentity[@"owner"]=[identity[@"owner"]copy];}
    NSMutableDictionary *request=[@{@"logical":[source[@"logical"]copy],@"generation":[source[@"generation"]copy],@"identity":[copiedIdentity copy]}mutableCopy];
    if([source[@"prior_bounds"]isKindOfClass:NSDictionary.class])request[@"prior_bounds"]=[source[@"prior_bounds"]copy];
    if(source[@"native_bounds"]){if(!observedNumber(source[@"native_bounds"]))return nil;request[@"native_bounds"]=@([source[@"native_bounds"]boolValue]);}
    if(source[@"families"]){if(!observedNumber(source[@"families"]))return nil;request[@"families"]=@([source[@"families"]boolValue]);}
    if(source[@"visibility_revision"]){if(!observedNumber(source[@"visibility_revision"]))return nil;request[@"visibility_revision"]=[source[@"visibility_revision"]copy];}
    if([request[@"families"]boolValue]&&![request[@"native_bounds"]boolValue])return nil;
    return [request copy];
}

static DWWindowObservationSnapshot *observeWindows(uint64_t generation,NSArray<NSDictionary *> *requests,NSDictionary<NSNumber *,NSArray<NSNumber *> *> *scope,NSSet<NSNumber *> *nativeExclusions,void (^discovered)(DWWindowObservationSnapshot *)) {
    DWWindowObservationSnapshot *snapshot=[DWWindowObservationSnapshot new];snapshot.generation=generation;snapshot.startedAt=CACurrentMediaTime();
    NSMutableDictionary<NSNumber *,id> *births=[NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber *,NSDictionary *> *onScreen=[NSMutableDictionary dictionary];
    NSMutableArray<NSDictionary *> *orderedOnScreen=[NSMutableArray array];
    CFArrayRef list=CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly|kCGWindowListExcludeDesktopElements,kCGNullWindowID);
    snapshot.listSucceeded=list!=NULL;
    for(NSDictionary *info in (__bridge NSArray *)list){
        NSNumber *pid=info[(id)kCGWindowOwnerPID],*wid=info[(id)kCGWindowNumber];
        if(!observedNumber(pid)||!observedNumber(wid))continue;
        if(scope){NSArray *allowed=scope[pid];if(!allowed||![observedBirth(pid.intValue,births)isEqual:allowed])continue;}
        NSDictionary *copied=[info copy];onScreen[wid]=copied;[orderedOnScreen addObject:copied];
    }
    if(list)CFRelease(list);snapshot.onScreen=[onScreen copy];snapshot.orderedOnScreen=[orderedOnScreen copy];
    NSMutableDictionary *nativeBases=[NSMutableDictionary dictionary],*regular=[NSMutableDictionary dictionary];
    if(nativeExclusions){
        NSMutableSet *known=[nativeExclusions mutableCopy];for(NSDictionary *request in requests)[known addObject:request[@"identity"][@"wid"]];
        for(NSDictionary *row in orderedOnScreen){
            // Reserve delivery/getter headroom inside the consumer's unchanged
            // 100 ms limit. Timely partial bases can advance offered exclusions;
            // never start another multi-getter audit at the acceptance boundary.
            if(CACurrentMediaTime()-snapshot.startedAt>=.08)break;
            NSNumber *wid=row[(id)kCGWindowNumber],*pid=row[(id)kCGWindowOwnerPID];NSInteger level=[row[(id)kCGWindowLayer]integerValue];
            if([known containsObject:wid]||pid.intValue==getpid()||pid.intValue<=1||(level!=0&&level!=3&&!(scope&&level==4)))continue;
            NSNumber *policy=regular[pid];if(!policy)policy=regular[pid]=@([NSRunningApplication runningApplicationWithProcessIdentifier:pid.intValue].activationPolicy==NSApplicationActivationPolicyRegular);if(!policy.boolValue)continue;
            CGRect bounds=CGRectZero;if(!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)row[(id)kCGWindowBounds],&bounds)||bounds.size.width<40||bounds.size.height<40)continue;
            NSArray *born=observedBirth(pid.intValue,births);if(born.count!=2)continue;
            NSDictionary *basis=DWNativeWindowDiscoveryBasis(@{@"pid":pid,@"wid":wid,@"birth_sec":born[0],@"birth_usec":born[1]});if(basis)nativeBases[wid]=basis;
        }
    }
    snapshot.nativeCandidateBases=nativeBases.copy;
    if(discovered){
        DWWindowObservationSnapshot *metadata=[DWWindowObservationSnapshot new];metadata.generation=generation;metadata.listSucceeded=snapshot.listSucceeded;
        metadata.startedAt=snapshot.startedAt;metadata.finishedAt=CACurrentMediaTime();metadata.onScreen=snapshot.onScreen;metadata.orderedOnScreen=snapshot.orderedOnScreen;metadata.nativeCandidateBases=snapshot.nativeCandidateBases;metadata.sources=@[];
        discovered(metadata);
    }
    NSMutableArray<DWWindowObservation *> *sources=[NSMutableArray arrayWithCapacity:requests.count];
    for(NSDictionary *request in requests){
        DWWindowObservation *source=[DWWindowObservation new];source.request=request;source.state=DWWindowObservationReadFailed;
        // Metadata and cached births may have been read before this source's
        // own bounds. Dating it at batch start gives a conservative upper bound
        // on age, including any slow family queries in the same batch.
        source.sampledAt=snapshot.startedAt;
        NSDictionary *identity=request[@"identity"];NSNumber *wid=identity[@"wid"],*pid=identity[@"pid"];NSArray *expected=@[identity[@"birth_sec"],identity[@"birth_usec"]];
        if(scope&&![scope[pid]isEqual:expected])source.failure=@"requested process is outside the observation scope";
        else {
            NSArray *born=observedBirth(pid.intValue,births);
            if(!born)source.failure=@"process identity could not be read";
            else if(![born isEqual:expected]){source.state=DWWindowObservationIdentityChanged;source.failure=@"process instance changed";}
            else {
                NSDictionary *info=onScreen[wid];BOOL read=YES;
                // A bound window may be parked, minimized or otherwise absent
                // from discovery. A worker-only individual read preserves it.
                if(!info){CFArrayRef rows=CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow,wid.unsignedIntValue);read=rows!=NULL;
                    for(NSDictionary *row in (__bridge NSArray *)rows)if([row[(id)kCGWindowNumber]isEqual:wid]){info=[row copy];break;}
                    if(rows)CFRelease(rows);}
                if(!read)source.failure=@"window information could not be read";
                else if(!info){source.state=DWWindowObservationAbsent;source.failure=@"window server has no current window record";}
                else if([info[(id)kCGWindowOwnerPID]intValue]!=pid.intValue){source.state=DWWindowObservationIdentityChanged;source.failure=@"window owner changed";}
                else {source.info=info;CGRect own=CGRectZero;BOOL nativeBounds=[request[@"native_bounds"]boolValue];
                    if(request[@"visibility_revision"]){bool minimized=false;DWFocusIdentity selected={.pid=pid.intValue,.window=wid.unsignedIntValue,.seconds=[identity[@"birth_sec"]unsignedLongLongValue],.microseconds=[identity[@"birth_usec"]unsignedLongLongValue]};
                        if(dw_focus_minimized(selected,&minimized))source.minimized=@(minimized);}
                    NSDictionary *frame=info[(id)kCGWindowBounds];
                    BOOL hasBounds=nativeBounds?DWNativeBounds(wid.unsignedIntValue,&own):([frame isKindOfClass:NSDictionary.class]&&CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)frame,&own));
                    if(hasBounds){
                        source.bounds=own;source.hasBounds=YES;source.state=DWWindowObservationPresent;
                        if([request[@"families"]boolValue]){NSString *why=nil;source.family=DWNativeWindowFamily(identity,&why);if(!source.family)source.familyFailure=why?:@"native family could not be read";}
                    }
                    else source.failure=nativeBounds?@"untransformed native bounds could not be read":@"window record bounds could not be read";}
            }
        }
        [sources addObject:source];
    }
    snapshot.sources=[sources copy];snapshot.finishedAt=CACurrentMediaTime();return snapshot;
}

@implementation DWWindowObserver {
    dispatch_queue_t _queue;
    uint64_t _generation;
    BOOL _inFlight,_cancelled;
}
- (instancetype)init {
    if(!(self=[super init]))return nil;
    _queue=dispatch_queue_create("org.infinify.window-observation",dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,QOS_CLASS_USER_INITIATED,0));return self;
}
- (BOOL)inFlight { return _inFlight; }
- (BOOL)requestSources:(NSArray<NSDictionary *> *)sources scope:(NSDictionary<NSNumber *,NSArray<NSNumber *> *> *)scope nativeDiscoveryExclusions:(NSSet<NSNumber *> *)nativeDiscoveryExclusions discovery:(void (^)(DWWindowObservationSnapshot *))discovery completion:(void (^)(DWWindowObservationSnapshot *))completion {
    if(!NSThread.isMainThread||_cancelled||_inFlight||_generation==UINT64_MAX||!completion||![sources isKindOfClass:NSArray.class]||(scope&&(![scope isKindOfClass:NSDictionary.class]||!scope.count)))return NO;
    NSMutableDictionary *allowed=[NSMutableDictionary dictionaryWithCapacity:scope.count];
    for(NSNumber *pid in scope){NSArray *born=scope[pid];if(!observedNumber(pid)||pid.intValue<=0||![born isKindOfClass:NSArray.class]||born.count!=2||!observedNumber(born[0])||!observedNumber(born[1]))return NO;allowed[[pid copy]]=[born copy];}
    NSMutableArray *requests=[NSMutableArray arrayWithCapacity:sources.count];
    for(NSDictionary *source in sources){NSDictionary *request=observedRequest(source);if(!request)return NO;[requests addObject:request];}
    if(nativeDiscoveryExclusions&&![nativeDiscoveryExclusions isKindOfClass:NSSet.class])return NO;
    for(id wid in nativeDiscoveryExclusions)if(!observedNumber(wid)||![wid unsignedIntValue])return NO;
    NSArray *copied=[requests copy];NSDictionary *scoped=scope?[allowed copy]:nil;NSSet *excluded=nativeDiscoveryExclusions.copy;uint64_t generation=++_generation;_inFlight=YES;__weak DWWindowObserver *weak=self;
    dispatch_async(_queue,^{@autoreleasepool{
        DWWindowObservationSnapshot *snapshot=observeWindows(generation,copied,scoped,excluded,discovery?^(DWWindowObservationSnapshot *metadata){
            dispatch_async(dispatch_get_main_queue(),^{DWWindowObserver *current=weak;if(!current||current->_cancelled||current->_generation!=generation)return;
                metadata.deliveredAt=CACurrentMediaTime();discovery(metadata);});
        }:nil);
        dispatch_async(dispatch_get_main_queue(),^{DWWindowObserver *current=weak;if(!current||current->_cancelled||current->_generation!=generation)return;
            current->_inFlight=NO;snapshot.deliveredAt=CACurrentMediaTime();completion(snapshot);});
    }});return YES;
}
- (void)cancel { if(!NSThread.isMainThread)return;_cancelled=YES;_inFlight=NO; }
@end
