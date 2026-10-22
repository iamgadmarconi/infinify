// SPDX-License-Identifier: GPL-3.0-or-later
// No NSApplication, AX, capture stream, input tap, or native window is started.
#import "resize-coordinator.h"
#import "resize-driver.h"
#import "../resize/resize.h"
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <CoreVideo/CoreVideo.h>
#include "driftwm_desktop.h"
#include <math.h>
static void check(BOOL ok,NSString *why){if(!ok){fprintf(stderr,"FAIL: %s\n",why.UTF8String);exit(2);}}
static NSDictionary *rect(double x,double y,double w,double h){return @{ @"origin":@{@"x":@(x),@"y":@(y)},@"size":@{@"width":@(w),@"height":@(h)}};}
static NSDictionary *identity(void){return @{@"pid":@123,@"birth_sec":@1800000000,@"birth_usec":@5,@"wid":@1};}
// Actual native driver with substituted adapter functions. These counters prove
// dispatch/fallback policy only; no Accessibility or application call is made.
static NSUInteger nativeReads,nativeSizes,nativeFrames,nativeFills,nativeUnfills;
static DWResizeResult nativeFillResult,nativeUnfillResult,nativeRepositionResult;
static BOOL nativeFrameRefused;
static NSUInteger nativePositions;
static double nativeRepositionDelay;
static BOOL nativeSizePreflightTimeout;
static NSMutableArray *nativeEvents;
static void nativeEvent(NSString *event){@synchronized(nativeEvents){[nativeEvents addObject:event];}}
DWResizeResult dw_resize_reposition(DWResizeIdentity target,CGRect before,CGPoint origin,double deadline){
    (void)target;(void)deadline;nativePositions++;nativeEvent(@"position");
    if(nativeRepositionDelay)[NSThread sleepForTimeInterval:nativeRepositionDelay];
    DWResizeResult r=nativeRepositionResult;r.actual_ax=(CGRect){origin,before.size};r.actual_cg=r.actual_ax;return r;
}
DWResizeResult dw_resize_observe(DWResizeIdentity target){(void)target;nativeReads++;return (DWResizeResult){.outcome=DWResizeObserved};}
DWResizeResult dw_resize_apply(DWResizeIdentity target,CGSize size){(void)target;nativeSizes++;if(nativeSizePreflightTimeout)return (DWResizeResult){.outcome=DWResizeTimedOut,.ax_error=kAXErrorCannotComplete,.requested=size,.observed=true};return (DWResizeResult){.outcome=DWResizeApplied,.requested=size,.mutation_attempted=true};}
DWResizeResult dw_resize_apply_frame(DWResizeIdentity target,CGRect frame){(void)target;nativeFrames++;nativeEvent(@"frame");return nativeFrameRefused?(DWResizeResult){.outcome=DWResizeUnavailable,.requested=frame.size}:(DWResizeResult){.outcome=DWResizeApplied,.requested=frame.size,.mutation_attempted=true,.observed=true,.actual_ax=frame,.actual_cg=frame};}
DWResizeResult dw_resize_fill(DWResizeIdentity target,CGSize size){(void)target;nativeFills++;nativeEvent(@"fill");DWResizeResult result=nativeFillResult;result.requested=size;return result;}
DWResizeResult dw_resize_unfill(DWResizeIdentity target,CGRect saved){(void)target;nativeUnfills++;nativeEvent(@"unfill");DWResizeResult result=nativeUnfillResult;result.requested=saved.size;return result;}
const char *dw_resize_outcome_name(DWResizeOutcome value){const char *names[]={"observed","applied","clamped","rejected","invalid_request","stale_identity","unavailable","missing_window","ambiguous_window","unsupported","readback_failed","timed_out"};return names[value];}
static void nativeFillDispatch(void){
    DWNativeResizeDriver *driver=[DWNativeResizeDriver new];
    NSMutableDictionary *effect=[@{@"identity":identity(),@"requested":@{@"width":@1000,@"height":@770},@"native_origin":NSNull.null,@"native_action":@"fill"}mutableCopy];
    [driver perform:effect];check(nativeSizes==1&&!nativeFills,@"Fill metadata cannot opt an ordinary shell into app actions");
    driver.nativeFill=YES;driver.fillReady=^DWNativeFillReadiness(NSDictionary *e){(void)e;return DWNativeFillReady;};
    nativeFillResult=(DWResizeResult){.outcome=DWResizeApplied,.mutation_attempted=true};[driver perform:effect];
    check(nativeFills==1&&nativeSizes==1,@"native shell performs one Fill and no size setter");
    nativeFillResult=(DWResizeResult){.outcome=DWResizeUnsupported};[driver perform:effect];
    check(nativeFills==2&&nativeSizes==2,@"positively unsupported unattempted Fill has one ordinary fallback");
    for(NSNumber *outcome in @[@(DWResizeTimedOut),@(DWResizeUnavailable),@(DWResizeReadbackFailed),@(DWResizeUnsupported)]){
        nativeFillResult=(DWResizeResult){.outcome=outcome.intValue,.mutation_attempted=true};[driver perform:effect];
        check(nativeSizes==2,@"an attempted Fill never falls back, even if its error says unsupported");
    }
    nativeFillResult=(DWResizeResult){.outcome=DWResizeUnavailable};[driver perform:effect];
    check(nativeSizes==2,@"unattempted identity or focus refusal cannot resize a background app");
    NSUInteger fills=nativeFills;driver.fillReady=^DWNativeFillReadiness(NSDictionary *e){(void)e;return DWNativeFillPending;};NSDictionary *refused=[driver perform:effect];
    check(nativeFills==fills&&nativeSizes==2&&![refused[@"mutation_attempted"]boolValue]&&[refused[@"outcome"]isEqual:@"unavailable"],@"missing helper handoff ACK refuses both native mutation paths");
    driver.fillReady=^DWNativeFillReadiness(NSDictionary *e){(void)e;return DWNativeFillUnsupportedGeometry;};[driver perform:effect];
    check(nativeFills==fills&&nativeSizes==3,@"known transformed geometry uses one ordinary size setter before any app Fill action");
    effect[@"native_origin"]=@{@"x":@20,@"y":@30};[driver perform:effect];
    check(nativeFrames==1&&nativeFills==fills,@"exact frame restoration ignores Fill metadata and gate");
    effect[@"requested"]=NSNull.null;[driver perform:effect];check(nativeReads==1&&nativeFills==fills,@"baseline and final reads never press Fill");
}
// The real driver, substituted adapter and update callbacks. No native calls.
static void nativeFillRebase(void){
    DWNativeResizeDriver *driver=[DWNativeResizeDriver new];driver.nativeFill=YES;
    NSDictionary *effect=@{@"identity":identity(),@"requested":@{@"width":@1000,@"height":@770},@"native_origin":NSNull.null,@"native_action":@"fill"};
    driver.fillReady=^DWNativeFillReadiness(NSDictionary *e){(void)e;return DWNativeFillNeedsRebase;};
    __block BOOL published=YES,acknowledged=YES,refuseHold=NO;__block double holdDelay=0;
    driver.screenUpdates=^CGError(BOOL enabled){nativeEvent(enabled?@"release":@"hold");if(!enabled&&holdDelay)[NSThread sleepForTimeInterval:holdDelay];return !enabled&&refuseHold?kCGErrorFailure:kCGErrorSuccess;};
    driver.fillRebase=^DWNativeFillRebase *(NSDictionary *e){(void)e;DWNativeFillRebase *plan=[DWNativeFillRebase new];
        plan.native=CGRectMake(434,259,586,488);plan.displayed=CGRectMake(816,382,586,488);
        plan.publish=^BOOL(CGRect observed,BOOL (^authorized)(void)){check(CGRectEqualToRect(observed,CGRectMake(816,382,586,488)),@"neutral transform uses observed normalized frame");nativeEvent(@"neutral");return authorized()&&published;};
        plan.ready=^BOOL{if(acknowledged)nativeEvent(@"ack");return acknowledged;};plan.cancel=^{nativeEvent(@"cancel");};return plan;};
    nativeEvents=[NSMutableArray array];nativeRepositionResult=(DWResizeResult){.outcome=DWResizeApplied,.observed=true,.mutation_attempted=true,.moved=true};
    nativeFillResult=(DWResizeResult){.outcome=DWResizeApplied,.observed=true};
    NSDictionary *result=[driver perform:effect];
    check([nativeEvents isEqual:@[@"hold",@"position",@"neutral",@"ack",@"release",@"fill"]],@"rebase order releases updates before exactly one Fill");
    check([result[@"mutation_attempted"]boolValue],@"normalization mutation is retained even when Fill itself reports no attempt");
    nativeSizePreflightTimeout=YES;nativeFillResult=(DWResizeResult){.outcome=DWResizeUnsupported,.observed=true};result=[driver perform:effect];nativeSizePreflightTimeout=NO;
    check([result[@"outcome"]isEqual:@"timed_out"]&&[result[@"mutation_attempted"]boolValue]&&![result[@"observed"]boolValue],@"pre-setter fallback timeout retains normalization debt in a valid controller result");
    nativeFillResult=(DWResizeResult){.outcome=DWResizeApplied,.observed=true};
    NSUInteger fills=nativeFills,positions=nativePositions;nativeEvents=[NSMutableArray array];refuseHold=YES;result=[driver perform:effect];
    check(nativePositions==positions&&nativeFills==fills&&[nativeEvents isEqual:@[@"hold",@"cancel"]]&&! [result[@"mutation_attempted"]boolValue],@"failed acquisition does not enable a hold that never existed");
    refuseHold=NO;nativeEvents=[NSMutableArray array];published=NO;result=[driver perform:effect];
    check(nativeFills==fills&&[result[@"mutation_attempted"]boolValue]&&![result[@"observed"]boolValue]&&[nativeEvents isEqual:@[@"hold",@"position",@"neutral",@"release",@"cancel"]],@"failed neutral submission releases hold and preserves restoration debt");
    published=YES;nativeEvents=[NSMutableArray array];nativeRepositionResult.ax_error=kAXErrorCannotComplete;result=[driver perform:effect];
    check(nativeFills==fills&&[result[@"ax_error"]intValue]==kAXErrorCannotComplete&&[result[@"mutation_attempted"]boolValue]&&[nativeEvents isEqual:@[@"hold",@"position",@"release",@"cancel"]],@"setter timeout cannot start Fill despite exact later readback");
    nativeRepositionResult.ax_error=0;nativeEvents=[NSMutableArray array];acknowledged=NO;result=[driver perform:effect];
    check(nativeFills==fills&&[result[@"mutation_attempted"]boolValue]&&[nativeEvents isEqual:@[@"hold",@"position",@"neutral",@"release",@"cancel"]],@"missing neutral or omission ACK expires without Fill");
    nativeEvents=[NSMutableArray array];acknowledged=YES;nativeRepositionDelay=.8;result=[driver perform:effect];nativeRepositionDelay=0;
    check(nativeFills==fills&&[nativeEvents isEqual:@[@"hold",@"position",@"release",@"cancel"]],@"independent watchdog releases while the worker is blocked and no late neutral or Fill runs");
    nativeEvents=[NSMutableArray array];positions=nativePositions;holdDelay=.8;result=[driver perform:effect];holdDelay=0;
    check(nativePositions==positions&&nativeFills==fills&&[nativeEvents isEqual:@[@"hold",@"release",@"cancel"]]&&! [result[@"mutation_attempted"]boolValue],@"late successful acquisition balances after return and never reaches native mutation");
    nativeEvents=nil;
}
// A queued unrelated frame invalidates the omission ACK immediately after the
// readiness callback. Plan admission must share that callback, not a later turn.
static void nativeFillAtomicPreparation(void){
    DWNativeResizeDriver *driver=[DWNativeResizeDriver new];driver.nativeFill=YES;
    NSDictionary *effect=@{@"identity":identity(),@"requested":@{@"width":@1000,@"height":@770},@"native_origin":NSNull.null,@"native_action":@"fill"};
    __block BOOL omissionACK=YES,invalidated=NO,done=NO;__block NSDictionary *result=nil;
    NSLock *completion=[NSLock new];nativeEvents=[NSMutableArray array];
    NSUInteger positions=nativePositions,fills=nativeFills,sizes=nativeSizes;
    nativeRepositionResult=(DWResizeResult){.outcome=DWResizeApplied,.observed=true,.mutation_attempted=true};
    nativeFillResult=(DWResizeResult){.outcome=DWResizeApplied,.observed=true,.mutation_attempted=true};
    driver.fillReady=^DWNativeFillReadiness(NSDictionary *e){(void)e;check(NSThread.isMainThread,@"readiness runs on main");nativeEvent(@"ready");
        dispatch_async(dispatch_get_main_queue(),^{omissionACK=NO;invalidated=YES;nativeEvent(@"unrelated frame");});return DWNativeFillNeedsRebase;};
    driver.fillRebase=^DWNativeFillRebase *(NSDictionary *e){(void)e;check(NSThread.isMainThread,@"plan runs on main");nativeEvent(@"plan");if(!omissionACK)return nil;
        DWNativeFillRebase *plan=[DWNativeFillRebase new];plan.native=CGRectMake(700,421,656,422);plan.displayed=CGRectMake(700,429,656,422);
        plan.publish=^BOOL(CGRect frame,BOOL (^authorized)(void)){(void)frame;return authorized();};plan.ready=^BOOL{return YES;};plan.cancel=^{};return plan;};
    driver.screenUpdates=^CGError(BOOL enabled){(void)enabled;return kCGErrorSuccess;};
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{NSDictionary *answer=[driver perform:effect];[completion lock];result=answer;done=YES;[completion unlock];});
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:3];BOOL finished=NO;
    do{[NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];[completion lock];finished=done;[completion unlock];}while(!finished&&deadline.timeIntervalSinceNow>0);
    check(finished,@"worker preparation completes within its bound");
    check(invalidated&&[result[@"outcome"]isEqual:@"applied"]&&nativePositions==positions+1&&nativeFills==fills+1&&nativeSizes==sizes,@"unrelated queued ACK invalidation cannot split readiness from plan or replay native mutations");
    check(nativeEvents.count>=3&&[nativeEvents[0]isEqual:@"ready"]&&[nativeEvents[1]isEqual:@"plan"],@"readiness and plan precede the next main-queue turn");nativeEvents=nil;
}
static void nativeRestoreDispatch(void){
    DWNativeResizeDriver *driver=[DWNativeResizeDriver new];driver.nativeFill=YES;
    driver.fillReady=^DWNativeFillReadiness(NSDictionary *e){(void)e;return DWNativeFillReady;};
    driver.restoreReady=^DWNativeFillReadiness(NSDictionary *e){(void)e;return DWNativeFillReady;};
    NSDictionary *enter=@{@"window":@1,@"generation":@7,@"identity":identity(),@"requested":@{@"width":@1000,@"height":@770},@"native_origin":NSNull.null,@"native_action":@"fill"};
    NSDictionary *exit=@{@"window":@1,@"generation":@7,@"identity":identity(),@"requested":@{@"width":@400,@"height":@300},@"native_origin":@{@"x":@180,@"y":@210}};
    CGRect saved=CGRectMake(180,210,400,300),rebased=CGRectMake(500,330,400,300);
    nativeFillResult=(DWResizeResult){.outcome=DWResizeApplied,.observed=true,.mutation_attempted=true};
    nativeUnfillResult=(DWResizeResult){.outcome=DWResizeClamped,.observed=true,.mutation_attempted=true,.actual_ax=rebased,.actual_cg=rebased};
    NSUInteger unfilled=nativeUnfills,frames=nativeFrames;nativeEvents=[NSMutableArray array];
    driver.restoreReady=^DWNativeFillReadiness(NSDictionary *e){(void)e;nativeEvent(@"gate pending");return DWNativeFillPending;};
    NSDictionary *refused=[driver perform:exit];
    check([nativeEvents isEqual:@[@"gate pending"]]&&nativeFrames==frames&&nativeUnfills==unfilled&&[refused[@"outcome"]isEqual:@"unavailable"]&&![refused[@"mutation_attempted"]boolValue],@"snapshot Restore without prior native Fill still refuses mutation until the hidden ACK");
    nativeEvents=[NSMutableArray array];driver.restoreReady=^DWNativeFillReadiness(NSDictionary *e){(void)e;nativeEvent(@"gate ready");return DWNativeFillReady;};[driver perform:exit];
    check([nativeEvents isEqual:@[@"gate ready",@"frame"]]&&nativeUnfills==unfilled,@"snapshot Restore without prior native Fill applies the exact frame only after readiness");
    nativeEvents=[NSMutableArray array];driver.restoreReady=^DWNativeFillReadiness(NSDictionary *e){(void)e;nativeEvent(@"gate unsupported");return DWNativeFillUnsupportedGeometry;};[driver perform:exit];
    check([nativeEvents isEqual:@[@"gate unsupported",@"frame"]]&&nativeUnfills==unfilled,@"unprepared Restore without prior native Fill keeps ordinary exact-frame restoration");
    [driver perform:enter];nativeEvents=[NSMutableArray array];
    driver.restoreReady=^DWNativeFillReadiness(NSDictionary *e){(void)e;nativeEvent(@"gate hidden");return DWNativeFillReadyForFrameRestore;};
    NSDictionary *hidden=[driver perform:exit];
    check([nativeEvents isEqual:@[@"gate hidden",@"frame"]]&&nativeUnfills==unfilled&&![driver hasNativeFillForEffect:exit]&&[hidden[@"actual_ax"]isEqual:rect(saved.origin.x,saved.origin.y,saved.size.width,saved.size.height)],@"hidden snapshot Restore skips native Unfill despite successful native Fill and restores the exact frame after ACK");
    nativeEvents=[NSMutableArray array];[driver perform:exit];
    check([nativeEvents isEqual:@[@"gate hidden",@"frame"]]&&nativeUnfills==unfilled,@"hidden snapshot Restore without native Fill uses the same direct exact-frame path");
    driver.restoreReady=^DWNativeFillReadiness(NSDictionary *e){(void)e;return DWNativeFillReady;};
    [driver perform:enter];check([driver hasNativeFillForEffect:exit],@"only successful actual Fill qualifies the exact identity and generation");
    nativeEvents=[NSMutableArray array];NSDictionary *result=[driver perform:exit];
    check([nativeEvents isEqual:@[@"unfill",@"frame"]]&&[result[@"outcome"]isEqual:@"applied"]&&[result[@"actual_ax"]isEqual:rect(saved.origin.x,saved.origin.y,saved.size.width,saved.size.height)]&&![driver hasNativeFillForEffect:exit],@"native Restore animation at a rebased origin is followed by exact-frame correction and consumes eligibility");
    CGRect nearSaved=CGRectMake(saved.origin.x-1,saved.origin.y,saved.size.width+1,saved.size.height+1);
    [driver perform:enter];nativeEvents=[NSMutableArray array];nativeUnfillResult=(DWResizeResult){.outcome=DWResizeApplied,.observed=true,.mutation_attempted=true,.actual_ax=nearSaved,.actual_cg=nearSaved};result=[driver perform:exit];
    check([nativeEvents isEqual:@[@"unfill",@"frame"]]&&[result[@"actual_ax"]isEqual:rect(saved.origin.x,saved.origin.y,saved.size.width,saved.size.height)]&&[result[@"actual_cg"]isEqual:result[@"actual_ax"]],@"an applied Unfill one point from the saved origin and extent still requires exact-frame correction");
    [driver perform:enter];nativeEvents=[NSMutableArray array];nativeUnfillResult.actual_ax=saved;nativeUnfillResult.actual_cg=saved;[driver perform:exit];
    check([nativeEvents isEqual:@[@"unfill"]],@"an exactly restored Unfill does not issue a redundant frame setter");
    nativeUnfillResult.actual_ax=nearSaved;nativeUnfillResult.actual_cg=nearSaved;
    [driver perform:enter];nativeEvents=[NSMutableArray array];nativeUnfillResult.ax_error=kAXErrorCannotComplete;result=[driver perform:exit];
    check([nativeEvents isEqual:@[@"unfill"]]&&[result[@"ax_error"]intValue]==kAXErrorCannotComplete&&[result[@"mutation_attempted"]boolValue],@"even a settled native Restore with a timeout never triggers correction or replay");
    [driver perform:enter];nativeEvents=[NSMutableArray array];nativeUnfillResult=(DWResizeResult){.outcome=DWResizeUnsupported,.observed=true};result=[driver perform:exit];
    check([nativeEvents isEqual:@[@"unfill",@"frame"]]&&[result[@"outcome"]isEqual:@"applied"],@"only unsupported unattempted native Restore permits ordinary frame fallback");
    [driver perform:enter];nativeEvents=[NSMutableArray array];nativeUnfillResult=(DWResizeResult){.outcome=DWResizeClamped,.observed=true,.mutation_attempted=true,.actual_ax=rebased,.actual_cg=rebased};nativeFrameRefused=YES;result=[driver perform:exit];nativeFrameRefused=NO;
    check([result[@"outcome"]isEqual:@"readback_failed"]&&[result[@"mutation_attempted"]boolValue]&&![result[@"observed"]boolValue]&&[nativeEvents isEqual:@[@"unfill",@"frame"]],@"failed exact correction retains the native Restore action debt in a valid controller result");
    [driver perform:enter];nativeEvents=[NSMutableArray array];NSMutableDictionary *other=[exit mutableCopy];other[@"generation"]=@8;[driver perform:other];
    check([nativeEvents isEqual:@[@"frame"]],@"another generation cannot inherit native Restore eligibility");
    [driver perform:enter];nativeEvents=[NSMutableArray array];driver.restoreReady=nil;[driver perform:exit];
    check([nativeEvents isEqual:@[@"frame"]],@"cleanup without explicit snapshot readiness retains ordinary exact-frame restoration");
    nativeEvents=nil;
}
static NSDictionary *call(DriftDesktop *c,NSDictionary *command){NSData *data=[NSJSONSerialization dataWithJSONObject:@{@"version":@1,@"command":command}options:0 error:nil];char *r=driftwm_desktop_request(c,data.bytes,data.length);check(r!=NULL,@"C ABI response");NSDictionary *reply=[NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:r length:strlen(r)]options:0 error:nil];driftwm_desktop_response_free(r);return [reply[@"ok"]boolValue]?reply[@"data"]:nil;}
@interface Driver : NSObject <DWResizeDriver>
@property CGRect bounds;
@property double skew; // how far right of the Accessibility rectangle, `bounds`, the WindowServer's lies
@property BOOL timeout;
@property BOOL silent,garbled; // readback cases: no result at all, and one that breaks the result contract
@property NSString *outcome;
@property NSUInteger setters;
@property NSUInteger performed;
@property BOOL moveBeforeGrowth;
@end
@implementation Driver
- (NSDictionary *)perform:(NSDictionary *)e{
    BOOL setter=[e[@"requested"]isKindOfClass:NSDictionary.class];if(setter)self.setters++;self.performed++;
    if(self.silent)return nil;
    if(self.garbled)return @{@"outcome":@"observed",@"ax_error":@0,@"mutation_attempted":@YES,@"observed":@YES,@"requested":@{@"width":@1,@"height":@1},@"actual_ax":rect(0,0,5,5),@"actual_cg":rect(90,90,5,5)};
    NSDictionary *requested=setter?e[@"requested"]:@{@"width":@0,@"height":@0};
    if(setter&&!self.timeout&&![self.outcome isEqual:@"rejected"]){
        CGSize size=CGSizeMake([requested[@"width"]doubleValue],[requested[@"height"]doubleValue]);if([self.outcome isEqual:@"clamped"])size.width=210;
        CGPoint origin=self.bounds.origin;
        if(self.moveBeforeGrowth&&(size.width>self.bounds.size.width||size.height>self.bounds.size.height))origin=CGPointMake(0,30);
        if([e[@"native_origin"]isKindOfClass:NSDictionary.class])origin=CGPointMake([e[@"native_origin"][@"x"]doubleValue],[e[@"native_origin"][@"y"]doubleValue]);
        self.bounds=(CGRect){origin,size};
    }
    BOOL observed=!(setter&&self.timeout);NSDictionary *r=observed?rect(self.bounds.origin.x+self.skew,self.bounds.origin.y,self.bounds.size.width,self.bounds.size.height):rect(0,0,0,0),*ax=observed&&r?rect(self.bounds.origin.x,self.bounds.origin.y,self.bounds.size.width,self.bounds.size.height):r;
    return @{@"outcome":setter?(self.timeout?@"timed_out":self.outcome?:@"applied"):@"observed",@"ax_error":setter&&self.timeout?@(-25204):@0,@"mutation_attempted":@(setter),@"observed":@(observed),@"requested":requested,@"actual_ax":ax,@"actual_cg":r};
}
@end
static CMSampleBufferRef sample(CGRect native,NSDictionary *overrides){
    CVPixelBufferRef pixels=NULL;check(CVPixelBufferCreate(NULL,480,360,kCVPixelFormatType_32BGRA,NULL,&pixels)==kCVReturnSuccess,@"pixel buffer");
    CMVideoFormatDescriptionRef format=NULL;check(CMVideoFormatDescriptionCreateForImageBuffer(NULL,pixels,&format)==noErr,@"format");
    CMSampleTimingInfo timing={kCMTimeInvalid,CMTimeMake(1,30),kCMTimeInvalid};CMSampleBufferRef s=NULL;check(CMSampleBufferCreateReadyWithImageBuffer(NULL,pixels,format,&timing,&s)==noErr,@"sample");CFRelease(format);CFRelease(pixels);
    CFArrayRef a=CMSampleBufferGetSampleAttachmentsArray(s,YES);NSMutableDictionary *m=(__bridge NSMutableDictionary *)CFArrayGetValueAtIndex(a,0);
    m[SCStreamFrameInfoStatus]=@(SCFrameStatusComplete);m[SCStreamFrameInfoDisplayTime]=@200;m[SCStreamFrameInfoScaleFactor]=@2;m[SCStreamFrameInfoContentScale]=@1;
    m[SCStreamFrameInfoContentRect]=CFBridgingRelease(CGRectCreateDictionaryRepresentation(CGRectMake(10,10,native.size.width,native.size.height)));m[SCStreamFrameInfoScreenRect]=CFBridgingRelease(CGRectCreateDictionaryRepresentation(native));
    for(id key in overrides){if(overrides[key]==NSNull.null)[m removeObjectForKey:key];else m[key]=overrides[key];}return s;
}
static void drain(NSMutableArray *workers,NSMutableArray *mains){NSUInteger n=0;while(workers.count||mains.count){check(++n<30,@"bounded drain");if(workers.count){DWJob job=workers[0];[workers removeObjectAtIndex:0];job();}if(mains.count){DWJob job=mains[0];[mains removeObjectAtIndex:0];job();}}}
static NSDictionary *snap(DriftDesktop *c){return call(c,@{@"op":@"snapshot"});}
// Real coordinator and Rust C ABI, with a synthetic driver relocating its
// frame as the adapter's preparation does. No native calls or input are made.
static void fullscreenFrameRestore(void){
    DriftDesktop *c=driftwm_desktop_create();Driver *driver=[Driver new];
    CGRect original=CGRectMake(183.5,211.25,400.5,300.25);driver.bounds=original;driver.moveBeforeGrowth=YES;
    NSMutableArray *workers=[NSMutableArray array],*mains=[NSMutableArray array];
    DWResizeCoordinator *co=[[DWResizeCoordinator alloc]initWithCommand:^NSDictionary *(NSDictionary *command){return call(c,command);}driver:driver worker:^(DWJob job){[workers addObject:[job copy]];}main:^(DWJob job){[mains addObject:[job copy]];}];co.enabled=YES;
    call(c,@{@"op":@"native_resize_capability",@"enabled":@YES});
    call(c,@{@"op":@"register_output",@"stable_id":@"one",@"screen_bounds":rect(0,0,1000,800),@"usable_rect_local":rect(0,30,1000,770)});
    call(c,@{@"op":@"attach",@"identity":identity(),@"bundle_id":@"test",@"title":@"source",@"buffer":@{@"width":@400,@"height":@300},@"source_rect":rect(original.origin.x,original.origin.y,original.size.width,original.size.height),@"world_rect":rect(100.5,100.25,original.size.width,original.size.height)});
    call(c,@{@"op":@"focus",@"window":@1});
    NSDictionary *before=snap(c),*world=before[@"windows"][0][@"world_rect"],*camera=before[@"outputs"][0][@"camera"];
    NSDictionary *toggle=@{@"op":@"action",@"output":@1,@"action":@"toggle-fullscreen"};
    [co request:toggle];drain(workers,mains);check(driver.bounds.origin.y==30,@"fullscreen mock moved native origin");
    [co request:toggle];drain(workers,mains);
    check(CGRectEqualToRect(driver.bounds,original)&&co.obligations==0,@"coordinator restores the exact native frame on exit");
    check([snap(c)[@"windows"][0][@"world_rect"]isEqual:world]&&[snap(c)[@"outputs"][0][@"camera"]isEqual:camera],@"native origin restoration preserves world and camera");
    [co request:toggle];
    {DWJob job=workers[0];[workers removeObjectAtIndex:0];job();job=mains[0];[mains removeObjectAtIndex:0];job();}
    check(co.obligations==1&&workers.count==1,@"fullscreen setter is queued before cancellation");
    [co cancel];drain(workers,mains);
    check(CGRectEqualToRect(driver.bounds,original)&&co.obligations==0&&[snap(c)[@"outputs"][0][@"fullscreen"]isEqual:NSNull.null],@"cancelled setter drains and dispatches native restoration without another command");
    check([snap(c)[@"windows"][0][@"world_rect"]isEqual:world]&&[snap(c)[@"outputs"][0][@"camera"]isEqual:camera],@"cancelled fullscreen preserves exact world and camera");
    [co shutdown];driftwm_desktop_destroy(c);
}
// Native readback: no result invalidates a capture, an effect nobody
// answers is discharged by the watchdog, and a result the controller refuses leaves no obligation. After every step the window is
// settled and takes input.
static void readback(void){
    DriftDesktop *c=driftwm_desktop_create();Driver *driver=[Driver new];driver.bounds=CGRectMake(10,20,200,150);
    NSMutableArray *workers=[NSMutableArray array],*mains=[NSMutableArray array],*delays=[NSMutableArray array],*ops=[NSMutableArray array];__block BOOL deaf=NO;__block DWJob lateResult=nil;
    DWResizeCoordinator *co=[[DWResizeCoordinator alloc]initWithCommand:^NSDictionary *(NSDictionary *command){[ops addObject:command[@"op"]];if([command[@"op"]isEqual:@"native_resize_result"]){if(deaf)return nil;if(lateResult){DWJob job=lateResult;lateResult=nil;job();}}return call(c,command);}driver:driver worker:^(DWJob job){[workers addObject:[job copy]];}main:^(DWJob job){[mains addObject:[job copy]];}];
    co.enabled=YES;co.timeout=3;co.delay=^(NSTimeInterval seconds,DWJob job){check(seconds==3,@"the watchdog waits the timeout");[delays addObject:[job copy]];};
    void (^expire)(void)=^{NSArray *due=[delays copy];[delays removeAllObjects];for(DWJob job in due)job();};
    void (^usable)(NSString *)=^(NSString *when){NSDictionary *source=snap(c)[@"windows"][0][@"source"];
        check([source[@"observation_known"]boolValue],[@"readback: settled " stringByAppendingString:when]);
        check(call(c,@{@"op":@"input",@"output":@1,@"screen":@{@"x":@120,@"y":@120},@"identity":identity()})!=nil,[@"readback: input taken " stringByAppendingString:when]);};
    NSDictionary *(^resize)(int)=^NSDictionary *(int width){NSDictionary *reply=call(c,@{@"op":@"ipc",@"output":@1,@"request":@{@"Resize":@{@"window":@1,@"to":@[@(width),@200]}}});check([reply[@"effect"]isKindOfClass:NSDictionary.class],@"readback: a size request begins a transaction");[co consume:@{@"effect":reply[@"effect"]}];return reply;};
    check(call(c,@{@"op":@"native_resize_capability",@"enabled":@YES})!=nil,@"capability");
    call(c,@{@"op":@"register_output",@"stable_id":@"one",@"screen_bounds":rect(0,0,1000,800)});
    call(c,@{@"op":@"attach",@"identity":identity(),@"bundle_id":@"test",@"title":@"source",@"buffer":@{@"width":@400,@"height":@300},@"source_rect":rect(10,20,200,150),@"world_rect":rect(100,100,200,150)});
    // An answered transaction: nothing is invalidated, the size is the window's, and the watchdogs find nothing left to do.
    NSDictionary *first=resize(300);[co consume:first];check(workers.count==1&&co.obligations==1,@"readback: duplicate consume dispatches one worker");
    check([[co busyWindow]isEqual:@1],@"readback: the window is busy while its effect is owed");usable(@"while the baseline is owed");
    {DWJob job=workers[0];[workers removeObjectAtIndex:0];job();job();check(mains.count==1&&driver.performed==1,@"readback: a worker operation can start once");
        job=mains[0];[mains removeObjectAtIndex:0];job();NSUInteger owed=workers.count;job();check(workers.count==owed&&co.obligations==1,@"readback: duplicate result cannot consume the next effect");}
    drain(workers,mains);check(co.obligations==0&&[co canRemove:@1]&&[co busyWindow]==nil,@"readback: answered transaction ends");
    [co consume:first];check(workers.count==0&&co.obligations==0,@"readback: a completed effect is not dispatched again");
    check(![ops containsObject:@"invalidate_native_capture"],@"readback: no result invalidates a capture");
    check([snap(c)[@"windows"][0][@"world_rect"][@"size"]isEqual:@{@"width":@300,@"height":@200}]&&[snap(c)[@"native_resize"][@"phase"]isEqual:@"complete"],@"readback: the size the window took is committed");usable(@"after an applied size");
    NSDictionary *ended=snap(c);expire();check([ended isEqual:snap(c)]&&co.obligations==0,@"readback: a watchdog after the result changes nothing");
    // A baseline read nobody answers: the watchdog ends the transaction, and the late result is dropped.
    resize(320);expire();check(co.obligations==0&&[co canRemove:@1]&&[snap(c)[@"native_resize"][@"phase"]isEqual:@"failed"],@"readback: the watchdog discharges an unanswered read");usable(@"after an unanswered read");
    ended=snap(c);driver.performed=0;drain(workers,mains);check([ended isEqual:snap(c)]&&co.obligations==0,@"readback: a late result is dropped");
    check(driver.performed==0,@"readback: an effect the watchdog answered for is not performed afterwards");
    // A setter nobody answers: one diagnostic read, unanswered too, and the transaction is over.
    resize(340);{DWJob job=workers[0];[workers removeObjectAtIndex:0];job();job=mains[0];[mains removeObjectAtIndex:0];job();}
    check(co.obligations==1&&[snap(c)[@"native_resize"][@"pending_effect"][@"op"]isEqual:@"resize_native_window"],@"readback: the setter is owed");[delays removeObjectAtIndex:0];
    expire();check(co.obligations==1&&[snap(c)[@"native_resize"][@"pending_effect"][@"op"]isEqual:@"observe_resize_source"]&&![co canRemove:@1],@"readback: an unanswered setter is followed by one read");usable(@"while the diagnostic read is owed");
    expire();check(co.obligations==0&&[co canRemove:@1]&&![snap(c)[@"native_resize"][@"uncertain_mutation"]boolValue],@"readback: the watchdog ends an unanswered setter's transaction");usable(@"after an unanswered setter");
    [workers removeAllObjects];[mains removeAllObjects];driver.bounds=CGRectMake(10,20,300,200);
    // A driver that returns nothing is answered for at once.
    driver.silent=YES;resize(360);drain(workers,mains);driver.silent=NO;check(co.obligations==0&&[co canRemove:@1],@"readback: no result is an unanswered effect");usable(@"after a driver without a result");[delays removeAllObjects];
    // A result the controller refuses is replaced by the unanswered one; when that is refused too the obligation is dropped.
    driver.garbled=YES;resize(380);drain(workers,mains);driver.garbled=NO;check(co.obligations==0&&[co canRemove:@1],@"readback: a refused result leaves no obligation");usable(@"after a refused result");[delays removeAllObjects];
    NSDictionary *orphan=resize(400);{DWJob job=workers[0];[workers removeObjectAtIndex:0];job();}
    check(mains.count==1,@"readback: the old driver's completion is delayed");deaf=YES;expire();deaf=NO;check(co.obligations==0&&co.failure.length,@"readback: a result refused twice leaves no obligation");
    [co consume:orphan];check(workers.count==0&&co.obligations==0,@"readback: an orphaned same-ID effect is never performed twice");
    // That transaction is still live in the controller with nobody performing its effect: seen twice a second apart, it is ended.
    check(![co canRemove:@1]&&[co busyWindow]==nil,@"readback: an orphaned transaction is live");[co reap];check(![co canRemove:@1],@"readback: an orphan is given one look");
    lateResult=mains[0];[mains removeObjectAtIndex:0];[ops removeAllObjects];[co reap];
    check([[ops filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF == %@",@"native_resize_result"]]count]==1,@"readback: an old callback cannot answer the same-ID orphan recovery");
    check(co.obligations==0&&[co canRemove:@1],@"readback: an orphaned transaction is reaped");usable(@"after an orphan");
    check(co.failure==nil,@"readback: a failure ends with the next result the controller takes");
    // Navigation may retain an exact initial read before any worker/watchdog.
    // The separate effect hook does not change resting pointer/orphan policy.
    NSDictionary *waiting=call(c,@{@"op":@"ipc",@"output":@1,@"request":@{@"Resize":@{@"window":@1,@"to":@[@410,@200]}}});
    __block NSDictionary *deferred=waiting[@"effect"];co.deferred=^BOOL(NSDictionary *e){return [e isEqual:deferred];};
    [delays removeAllObjects];NSUInteger performed=driver.performed;
    for(int i=0;i<5;i++)[co reap];
    check(![co canRemove:@1]&&co.obligations==0&&workers.count==0&&delays.count==0&&driver.performed==performed,@"readback: deferred baseline survives reaping without worker or watchdog");
    deferred=nil;[co consume:waiting];[co consume:waiting];
    check(co.obligations==1&&workers.count==1&&delays.count==1,@"readback: released baseline is admitted once with its ordinary watchdog");
    drain(workers,mains);check([co canRemove:@1]&&driver.performed>performed,@"readback: deferred transaction resumes normally");[delays removeAllObjects];
    waiting=call(c,@{@"op":@"ipc",@"output":@1,@"request":@{@"Resize":@{@"window":@1,@"to":@[@420,@200]}}});
    deferred=waiting[@"effect"];[co reap];performed=driver.performed;deferred=nil;
    [co discardDeferredEffect:waiting[@"effect"]];[co consume:waiting];
    check([co canRemove:@1]&&co.obligations==0&&workers.count==0&&delays.count==0&&driver.performed==performed,@"readback: cancelled deferred baseline retires without native work and cannot execute late");
    NSDictionary *newWaiting=call(c,@{@"op":@"ipc",@"output":@1,@"request":@{@"Resize":@{@"window":@1,@"to":@[@430,@200]}}});
    [co discardDeferredEffect:waiting[@"effect"]];[co consume:waiting];
    check([snap(c)[@"native_resize"][@"pending_effect"]isEqual:newWaiting[@"effect"]]&&workers.count==0,@"readback: an old deferred binding cannot retire or execute a replacement");
    [co reap];check(![co canRemove:@1],@"readback: an unheld baseline remains an ordinary first-look orphan");[co reap];
    check([co canRemove:@1]&&workers.count==0&&driver.performed==performed,@"readback: unheld baseline still reaps without worker");co.deferred=nil;
    // A resize grab. Its first read checks the window's own extent, and at
    // rest it owes no effect: it is no orphan while the input that holds it is down, and is reaped like one when that input is gone.
    driver.skew=1;NSDictionary *grab=[co request:@{@"op":@"begin_native_resize",@"window":@1,@"output":@1,@"edges":@"right",@"start_screen":@{@"x":@50,@"y":@50}}];driver.skew=0;
    check(grab!=nil,@"readback: a grab begins on a window whose extent is not the one observed");drain(workers,mains);
    check(co.obligations==0&&![co canRemove:@1]&&[snap(c)[@"native_resize"][@"phase"]isEqual:@"dragging"],@"readback: a grab at rest owes nothing and is live");usable(@"during a grab at rest");
    __block BOOL down=YES;co.held=^BOOL(NSNumber *transaction){return down&&[transaction isEqual:grab[@"transaction"]];};
    [co reap];[co reap];[co reap];check(![co canRemove:@1]&&[snap(c)[@"native_resize"][@"phase"]isEqual:@"dragging"],@"readback: a held grab at rest is not reaped");
    down=NO;[co reap];check(![co canRemove:@1],@"readback: a grab nobody holds is given one look");[co reap];drain(workers,mains);
    check(co.obligations==0&&[co canRemove:@1],@"readback: a grab nobody holds is reaped");usable(@"after a reaped grab");[delays removeAllObjects];
    // Completed operation objects disappear while their watchdog jobs are still
    // queued. The admission watermark remains one scalar across a long session.
    for(int i=0;i<512;i++){
        __weak id completed=nil;
        @autoreleasepool{
            resize(500+i%7);completed=[[co valueForKey:@"pending"]allValues].firstObject;
            check(completed!=nil,@"readback: the pending operation is owned");drain(workers,mains);
            check(co.obligations==0&&[co canRemove:@1],@"readback: a long sequence completes each transaction");[ops removeAllObjects];
        }
        check(completed==nil,@"readback: completed operation not retained by queued watchdogs");
    }
    ended=snap(c);expire();check([ended isEqual:snap(c)]&&co.obligations==0,@"readback: old watchdogs cannot affect the last completed transaction");
    [co shutdown];driftwm_desktop_destroy(c);
}
static void abandonedCoordinator(void){
    DriftDesktop *c=driftwm_desktop_create();Driver *driver=[Driver new];driver.bounds=CGRectMake(10,20,200,150);
    NSMutableArray *workers=[NSMutableArray array],*mains=[NSMutableArray array],*delays=[NSMutableArray array];
    __weak DWResizeCoordinator *abandoned=nil;__weak id operation=nil;
    @autoreleasepool{
        DWResizeCoordinator *co=[[DWResizeCoordinator alloc]initWithCommand:^NSDictionary *(NSDictionary *command){return call(c,command);}driver:driver worker:^(DWJob job){[workers addObject:[job copy]];}main:^(DWJob job){[mains addObject:[job copy]];}];
        co.enabled=YES;co.timeout=3;co.delay=^(NSTimeInterval seconds,DWJob job){check(seconds==3,@"abandoned watchdog timeout");[delays addObject:[job copy]];};
        call(c,@{@"op":@"native_resize_capability",@"enabled":@YES});call(c,@{@"op":@"register_output",@"stable_id":@"one",@"screen_bounds":rect(0,0,1000,800)});
        call(c,@{@"op":@"attach",@"identity":identity(),@"bundle_id":@"test",@"title":@"source",@"buffer":@{@"width":@400,@"height":@300},@"source_rect":rect(10,20,200,150),@"world_rect":rect(100,100,200,150)});
        [co request:@{@"op":@"ipc",@"output":@1,@"request":@{@"Resize":@{@"window":@1,@"to":@[@300,@200]}}}];
        abandoned=co;operation=[[co valueForKey:@"pending"]allValues].firstObject;
        check(co.obligations==1&&operation!=nil,@"abandoned coordinator starts with a queued obligation");
    }
    check(abandoned==nil&&operation==nil,@"queued workers and watchdogs do not extend coordinator or operation lifetime");
    for(DWJob job in delays)job();drain(workers,mains);check(driver.performed==0,@"a queued operation outliving its owner is never performed");
    driftwm_desktop_destroy(c);
}
static BOOL number(id x) { return [x isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)x)!=CFBooleanGetTypeID() && isfinite([x doubleValue]); }
static NSString *text(CGRect r) { return [NSString stringWithFormat:@"{%g,%g,%g,%g}",r.origin.x,r.origin.y,r.size.width,r.size.height]; }
// Standalone ScreenCaptureKit frame metadata oracle retained from the retired capture gate.
// This test-only validator establishes no live resize or capture authority.
static NSDictionary *refused(NSString *__autoreleasing *why,NSString *reason) { if(why)*why=reason;return nil; }
static NSDictionary *captureDescription(CMSampleBufferRef sample,uint64_t cutoff,CGRect nativeRect,NSString *__autoreleasing *why) {
    CGSize extent=nativeRect.size;
    if(!sample||!CMSampleBufferIsValid(sample))return refused(why,@"the sample is not valid");
    CVPixelBufferRef pixels=CMSampleBufferGetImageBuffer(sample);if(!pixels)return refused(why,@"the sample has no pixel buffer");
    CFArrayRef attachments=CMSampleBufferGetSampleAttachmentsArray(sample,NO);
    if(!attachments||CFArrayGetCount(attachments)!=1)return refused(why,[NSString stringWithFormat:@"the sample has %ld frame descriptions, not one",attachments?(long)CFArrayGetCount(attachments):0L]);
    id value=(__bridge id)CFArrayGetValueAtIndex(attachments,0);if(![value isKindOfClass:NSDictionary.class])return refused(why,@"the frame description is not a dictionary");
    NSDictionary *m=value;id status=m[SCStreamFrameInfoStatus],time=m[SCStreamFrameInfoDisplayTime],scale=m[SCStreamFrameInfoScaleFactor],content=m[SCStreamFrameInfoContentScale];
    if(!number(status)||[status doubleValue]!=SCFrameStatusComplete||!number(time)||[time doubleValue]<=0||floor([time doubleValue])!=[time doubleValue]||[time doubleValue]>=18446744073709551616.0||[time unsignedLongLongValue]<=cutoff||!number(scale)||!number(content)||[scale doubleValue]<=0||[content doubleValue]<=0)
        return refused(why,[NSString stringWithFormat:@"frame status %@ (a complete frame is %ld), display time %@ against cutoff %llu, scale factor %@, content scale %@",status?:@"missing",(long)SCFrameStatusComplete,time?:@"missing",cutoff,scale?:@"missing",content?:@"missing"]);
    id screen=m[SCStreamFrameInfoScreenRect];CGRect screenRect=CGRectZero;
    if(![screen isKindOfClass:NSDictionary.class]||!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)screen,&screenRect))return refused(why,@"the frame names no screen rectangle");
    if(!CGRectEqualToRect(screenRect,nativeRect))return refused(why,[NSString stringWithFormat:@"the frame's screen rectangle %@ is not the window extent %@",text(screenRect),text(nativeRect)]);
    id r=m[SCStreamFrameInfoContentRect];CGRect rect=CGRectZero;
    if(![r isKindOfClass:NSDictionary.class]||!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)r,&rect))return refused(why,@"the frame names no content rectangle");
    if(!isfinite(extent.width)||!isfinite(extent.height)||extent.width<=0||extent.height<=0||!isfinite(rect.origin.x)||!isfinite(rect.origin.y)||!isfinite(rect.size.width)||!isfinite(rect.size.height)||rect.size.width<=0||rect.size.height<=0)
        return refused(why,[NSString stringWithFormat:@"content rectangle %@ or window extent %@ is empty or not finite",text(rect),text(nativeRect)]);
    if(fabs(rect.size.width/[content doubleValue]-extent.width)>1||fabs(rect.size.height/[content doubleValue]-extent.height)>1)
        return refused(why,[NSString stringWithFormat:@"content %gx%g at content scale %@ is not the window extent's %gx%g within a point",rect.size.width,rect.size.height,content,extent.width,extent.height]);
    CGFloat s=[scale doubleValue];CGRect crop=CGRectMake(rect.origin.x*s,rect.origin.y*s,rect.size.width*s,rect.size.height*s);
    size_t width=CVPixelBufferGetWidth(pixels),height=CVPixelBufferGetHeight(pixels);
    if(!width||!height||!isfinite(CGRectGetMaxX(crop))||!isfinite(CGRectGetMaxY(crop))||crop.origin.x<0||crop.origin.y<0||CGRectGetMaxX(crop)>width||CGRectGetMaxY(crop)>height)
        return refused(why,[NSString stringWithFormat:@"content rectangle %@ at scale factor %@ lies outside the %zux%zu buffer",text(rect),scale,width,height]);
    return @{ @"buffer":@{@"width":@(width),@"height":@(height)},@"content_rect":@{@"origin":@{@"x":@(crop.origin.x),@"y":@(crop.origin.y)},@"size":@{@"width":@(crop.size.width),@"height":@(crop.size.height)}} };
}
static NSDictionary *captureMetadata(CMSampleBufferRef sample,uint64_t cutoff,CGRect nativeRect) { return captureDescription(sample,cutoff,nativeRect,NULL); }
int main(void){@autoreleasepool{
    CGRect native=CGRectMake(10,20,200,150);CMSampleBufferRef s=sample(native,@{});NSDictionary *m=captureMetadata(s,100,native);check([m[@"buffer"][@"width"]intValue]==480&&[m[@"content_rect"][@"origin"][@"x"]intValue]==20,@"actual padded crop");CFRelease(s);
    NSArray *invalid=@[@{SCStreamFrameInfoDisplayTime:NSNull.null},@{SCStreamFrameInfoDisplayTime:@100},@{SCStreamFrameInfoDisplayTime:@(-1)},@{SCStreamFrameInfoDisplayTime:@100.5},@{SCStreamFrameInfoDisplayTime:@1e30},@{SCStreamFrameInfoStatus:NSNull.null},@{SCStreamFrameInfoStatus:@.5},@{SCStreamFrameInfoContentScale:@0},@{SCStreamFrameInfoScreenRect:NSNull.null},@{SCStreamFrameInfoContentRect:CFBridgingRelease(CGRectCreateDictionaryRepresentation(CGRectMake(100,100,200,150)))}];
    for(NSDictionary *override in invalid){s=sample(native,override);NSString *why=nil;check(captureMetadata(s,100,native)==nil,@"invalid metadata rejected");check(captureDescription(s,100,native,&why)==nil&&why.length,@"and every rejection says why");CFRelease(s);}
    readback();abandonedCoordinator();fullscreenFrameRestore();nativeFillDispatch();nativeFillRebase();nativeFillAtomicPreparation();nativeRestoreDispatch();
    puts("PASS: native readback coordinator + Rust C ABI; standalone synthetic CV/CMSampleBuffer metadata oracle; no native app/window/AX/capture started");return 0;
}}
