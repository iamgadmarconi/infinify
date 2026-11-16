// SPDX-License-Identifier: GPL-3.0-or-later
#import "DWAXLookup.h"
#import "DWNativeResizeDriver.h"
#import "DWNativeResize.h"
#import "DWGeometryJSON.h"
#include <time.h>
#include <math.h>
static double monotonic(void){return DWMonotonicSeconds();}
@implementation DWNativeFillRebase
@end
// This lease has no dependency on the main run loop or the serial AX worker.
// Once acquisition succeeds, the watchdog balances the hold even when either
// queue stops making progress. The synchronous acquisition itself is not cancellable.
@interface DWNativeUpdateLease : NSObject
@property NSCondition *condition;
@property (copy) CGError (^updates)(BOOL);
@property double deadline;
// 0 not started, 1 acquiring, 2 held, 3 releasing, 4 released, 5 failed.
@property NSInteger state;
@property BOOL expired;
@property CGError acquireError;
@property CGError releaseError;
- (BOOL)begin;
- (BOOL)live;
- (BOOL)finish;
@end
@implementation DWNativeUpdateLease
- (BOOL)begin {
    [self.condition lock];
    if(self.state||self.expired||monotonic()>=self.deadline){[self.condition unlock];return NO;}
    self.state=1;[self.condition unlock];
    CGError error=self.updates(NO);
    [self.condition lock];self.acquireError=error;self.state=error==kCGErrorSuccess?2:5;
    BOOL expired=self.expired||monotonic()>=self.deadline;[self.condition broadcast];[self.condition unlock];
    // Expiry during the synchronous acquisition cannot enable a hold that is
    // not known to exist. A late success balances immediately, before any AX.
    if(error==kCGErrorSuccess&&expired)[self finish];
    return error==kCGErrorSuccess&&!expired&&[self live];
}
- (BOOL)live { [self.condition lock];BOOL live=self.state==2&&!self.expired&&monotonic()<self.deadline;[self.condition unlock];return live; }
- (BOOL)finish {
    [self.condition lock];self.expired=YES;BOOL owner=self.state==2;if(owner)self.state=3;[self.condition unlock];
    if(owner){CGError error=self.updates(YES);[self.condition lock];self.releaseError=error;self.state=4;[self.condition broadcast];[self.condition unlock];}
    [self.condition lock];if(self.state==3)[self.condition waitUntilDate:[NSDate dateWithTimeIntervalSinceNow:.02]];
    BOOL ok=self.state==4&&self.releaseError==kCGErrorSuccess;[self.condition unlock];return ok;
}
@end
// Late queued callbacks must never publish a transform after their lease ended.
static id onMain(double deadline,DWNativeUpdateLease *lease,id (^work)(void)){
    id (^guarded)(void)=^id{if(monotonic()>=deadline||(lease&&![lease live]))return nil;return work();};
    if(NSThread.isMainThread)return guarded();
    dispatch_semaphore_t answered=dispatch_semaphore_create(0);__block id value=nil;
    dispatch_async(dispatch_get_main_queue(),^{value=guarded();dispatch_semaphore_signal(answered);});
    double left=deadline-monotonic();if(left<=0||dispatch_semaphore_wait(answered,dispatch_time(DISPATCH_TIME_NOW,(int64_t)(left*NSEC_PER_SEC))))return nil;
    return value;
}
static DWResizeIdentity identity(DWIdentity *i){return (DWResizeIdentity){i.pid.intValue,i.birthSeconds.unsignedLongLongValue,i.birthMicroseconds.unsignedLongLongValue,i.wid.unsignedIntValue};}
static DWResizeResult withMutation(DWResizeResult result,DWResizeResult previous){
    result.mutation_attempted|=previous.mutation_attempted;result.moved|=previous.moved;
    if(result.mutation_attempted&&result.outcome==DWResizeTimedOut)result.observed=false;
    if(result.mutation_attempted&&(result.outcome==DWResizeUnavailable||result.outcome==DWResizeMissingWindow||result.outcome==DWResizeAmbiguousWindow||result.outcome==DWResizeInvalidRequest||result.outcome==DWResizeUnsupported)){result.outcome=DWResizeReadbackFailed;result.observed=false;}
    return result;
}
@interface DWPreparedBaselineAdmission : NSObject
@property DWSizeEffect *effect;
@property (copy) BOOL (^validate)(void);
@property double deadline;
@property BOOL cancelled;
@end
@implementation DWPreparedBaselineAdmission
@end
typedef NS_ENUM(NSInteger,DWResizeAdmission) {
    DWResizeAdmissionAllowed,
    DWResizeAdmissionOwnerDenied,
    DWResizeAdmissionPreparedCancelled,
    DWResizeAdmissionPreparedRefused,
    DWResizeAdmissionExpired,
};
@interface DWNativeResizeDriver ()
@property NSMutableDictionary<NSNumber *,DWSizeEffect *> *filled;
@property DWPreparedBaselineAdmission *preparedBaseline;
@end
@implementation DWNativeResizeDriver
@synthesize nativeFill=_nativeFill, canPerform=_canPerform, fillPreparationTimeout=_fillPreparationTimeout;
@synthesize fillReady=_fillReady, fillRebase=_fillRebase, restoreReady=_restoreReady;
@synthesize screenUpdates=_screenUpdates, didPerform=_didPerform;
- (void)prepareBaseline:(DWSizeEffect *)effect validate:(BOOL (^)(void))validate {
    NSAssert(NSThread.isMainThread,@"baseline preparation is main-only");
    [self clearPreparedBaseline];
    double deadline=monotonic()+2.5;
    if(!validate||!(effect.kind==DWEffectObserveResizeSource)||(effect.requestedPresence==DWValuePresent))return;
    // Controller effects are immutable decoded values, including their nested
    // identity and geometry. Retaining the value pins the complete effect.
    DWSizeEffect *pinned=[effect copy];
    DWPreparedBaselineAdmission *prepared=[DWPreparedBaselineAdmission new];
    prepared.effect=pinned;prepared.validate=validate;prepared.deadline=deadline;
    @synchronized(self){self.preparedBaseline=prepared;}
}
- (void)clearPreparedBaseline {
    NSAssert(NSThread.isMainThread,@"baseline cancellation is main-only");
    // Keep one revoked ticket: a worker that has not entered perform yet must
    // not fall back to ordinary admission for this same cancelled effect.
    @synchronized(self){self.preparedBaseline.cancelled=YES;self.preparedBaseline.validate=nil;}
}
- (BOOL)hasNativeFillForEffect:(DWSizeEffect *)effect {
    NSNumber *window=effect.window,*generation=effect.generation;DWIdentity *who=effect.identity;
    if(!window||!generation||!who)return NO;
    @synchronized(self){DWSizeEffect *filled=_filled[window];return [filled.generation isEqual:generation]&&[filled.identity isEqual:who];}
}
- (void)forgetFill:(DWSizeEffect *)effect {NSNumber *window=effect.window;if(window)@synchronized(self){[_filled removeObjectForKey:window];}}
- (void)rememberFill:(DWSizeEffect *)effect {
    NSNumber *window=effect.window;if(!window||!effect.generation||!effect.identity)return;
    @synchronized(self){if(!_filled)_filled=[NSMutableDictionary dictionary];_filled[window]=effect;}
}
- (DWNativeFillReadiness)await:(DWSizeEffect *)effect readiness:(DWNativeFillReadiness (^)(DWSizeEffect *))ready deadline:(double)deadline {
    if(!ready)return DWNativeFillPending;
    do {
        NSNumber *answer=onMain(deadline,nil,^id{return @(ready(effect));});
        if(!answer)return DWNativeFillPending;
        DWNativeFillReadiness allowed=answer.integerValue;
        if(allowed!=DWNativeFillPending||NSThread.isMainThread)return allowed;
        [NSThread sleepForTimeInterval:.01];
    } while(monotonic()<deadline);
    return DWNativeFillPending;
}
- (void)traceRebase:(DWSizeEffect *)effect stage:(NSString *)stage preparation:(double)preparation result:(DWResizeResult *)result lease:(DWNativeUpdateLease *)lease {
    if(!self.didPerform)return;
    [lease.condition lock];NSInteger state=lease?lease.state:-1;CGError acquire=lease.acquireError,release=lease.releaseError;BOOL expired=lease.expired;[lease.condition unlock];
    fprintf(stderr,"debug: native fill rebase stage=%s transaction=%llu effect=%llu preparation_left_ms=%.1f lease_state=%ld expired=%d acquire_error=%d release_error=%d outcome=%s ax_error=%d attempted=%d observed=%d moved=%d actual=%g,%g %gx%g\n",stage.UTF8String,[effect.transaction unsignedLongLongValue],[effect.effectID unsignedLongLongValue],(preparation-monotonic())*1000,(long)state,expired,acquire,release,dw_resize_outcome_name(result->outcome),result->ax_error,result->mutation_attempted,result->observed,result->moved,result->actual_cg.origin.x,result->actual_cg.origin.y,result->actual_cg.size.width,result->actual_cg.size.height);
}
- (BOOL)rebase:(DWSizeEffect *)effect plan:(DWNativeFillRebase *)plan deadline:(double)preparation result:(DWResizeResult *)result {
    if(!self.fillRebase||!self.screenUpdates){[self traceRebase:effect stage:@"missing_callbacks" preparation:preparation result:result lease:nil];return NO;}
    if(!plan||!plan.publish||!plan.ready||!plan.cancel){[self traceRebase:effect stage:monotonic()>=preparation?@"plan_deadline":(plan?@"incomplete_plan":@"plan_refused") preparation:preparation result:result lease:nil];return NO;}
    double deadline=fmin(preparation,monotonic()+.65);
    if(deadline-monotonic()<.15){[self traceRebase:effect stage:@"insufficient_preparation_time" preparation:preparation result:result lease:nil];return NO;}
    DWNativeUpdateLease *lease=[DWNativeUpdateLease new];lease.condition=[NSCondition new];lease.updates=self.screenUpdates;lease.deadline=deadline;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)((deadline-monotonic())*NSEC_PER_SEC)),dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE,0),^{[lease finish];});
    BOOL complete=NO,released=NO;NSString *stage=@"update_hold_refused";
    @try {
        if([lease begin]){
            // Leave 100ms for the two helper ACKs. The adapter reserves its own
            // <=50ms setter timeout within this absolute CLOCK_MONOTONIC limit.
            *result=dw_resize_reposition(identity(effect.identity),plan.native,plan.displayed.origin,deadline-.1);
            stage=@"reposition_refused";
            if(result->outcome==DWResizeApplied&&result->observed&&result->ax_error==kAXErrorSuccess&&[lease live]){
                CGRect observed=result->actual_cg;NSNumber *published=onMain(deadline,lease,^id{return @(plan.publish(observed,^{return [lease live];}));});
                stage=published.boolValue?@"placement_ack_pending":@"publish_refused";
                while(published.boolValue&&[lease live]){
                    NSNumber *ready=onMain(deadline,lease,^id{return @(plan.ready());});
                    if(ready.boolValue&&[lease live]){complete=YES;stage=@"ready";break;}
                    [NSThread sleepForTimeInterval:.005];
                }
            }
        }
    } @finally {
        // Reenable before Fill, and on every refusal/exception. A watchdog that
        // already released owns the call; finish never reenables a second time.
        released=[lease finish];
        if(!complete||!released){if(NSThread.isMainThread)plan.cancel();else dispatch_async(dispatch_get_main_queue(),plan.cancel);}
        [self traceRebase:effect stage:!released&&complete?@"update_release_failed":stage preparation:preparation result:result lease:lease];
    }
    return complete&&released;
}

- (DWNativeResult *)perform:(DWSizeEffect *)e {
    // Retain adapter timeout evidence and merge any earlier normalization mutation
    // into a valid controller result, without replacing its saved baseline.
    CGSize size=e.nativeRequestedSize;BOOL setter=e.requestedPresence==DWValuePresent;
    DWResizeResult r;NSString *method=setter?@"resize":@"size read";
    BOOL (^allowed)(DWSizeEffect *)=self.canPerform;
    DWPreparedBaselineAdmission *prepared=nil;
    @synchronized(self){if(!setter&&[self.preparedBaseline.effect isEqual:e])prepared=self.preparedBaseline;}
    double admissionStarted=monotonic();
    double admissionDeadline=prepared?prepared.deadline:admissionStarted+.25;
    NSNumber *permission=(prepared||allowed)?onMain(admissionDeadline,nil,^id{
        if(prepared){
            @synchronized(self){if(self.preparedBaseline!=prepared||prepared.cancelled)return @(DWResizeAdmissionPreparedCancelled);}
            BOOL valid=prepared.validate&&prepared.validate();
            if(monotonic()>=admissionDeadline)return @(DWResizeAdmissionExpired);
            @synchronized(self){if(self.preparedBaseline!=prepared||prepared.cancelled)return @(DWResizeAdmissionPreparedCancelled);}
            if(!valid)return @(DWResizeAdmissionPreparedRefused);
        }
        BOOL permitted=!allowed||allowed(e);
        if(prepared){
            if(monotonic()>=admissionDeadline)return @(DWResizeAdmissionExpired);
            @synchronized(self){if(self.preparedBaseline!=prepared||prepared.cancelled)return @(DWResizeAdmissionPreparedCancelled);}
        }
        return @(permitted?DWResizeAdmissionAllowed:DWResizeAdmissionOwnerDenied);
    }):@(DWResizeAdmissionAllowed);
    DWResizeAdmission admission=permission?permission.integerValue:DWResizeAdmissionExpired;
    if(prepared&&monotonic()>=admissionDeadline)admission=DWResizeAdmissionExpired;
    BOOL timedOut=admission==DWResizeAdmissionExpired;
    const char *admissionName=!permission?"queue_timeout":admission==DWResizeAdmissionAllowed?"allowed":admission==DWResizeAdmissionOwnerDenied?"owner_denied":admission==DWResizeAdmissionPreparedCancelled?"prepared_cancelled":admission==DWResizeAdmissionPreparedRefused?"prepared_refused":"admission_expired";
    if(self.didPerform)fprintf(stderr,"debug: native resize admission transaction=%llu effect=%llu window=%llu result=%s wait_ms=%.3f setter=%d prepared=%d\n",[e.transaction unsignedLongLongValue],[e.effectID unsignedLongLongValue],[e.window unsignedLongLongValue],admissionName,(monotonic()-admissionStarted)*1000,setter,prepared!=nil);
    if(admission!=DWResizeAdmissionAllowed){r=(DWResizeResult){.outcome=timedOut?DWResizeTimedOut:DWResizeUnavailable,.ax_error=timedOut?kAXErrorCannotComplete:kAXErrorSuccess,.requested=setter?size:CGSizeZero};method=timedOut?@"native admission timed out":admission==DWResizeAdmissionOwnerDenied?@"native owner refused":@"prepared baseline refused";}
    else if(!setter)r=dw_resize_observe(identity(e.identity));
    else {


        if(e.nativeOriginPresence==DWValueNull&&self.nativeFill&&[e.nativeAction isEqual:@"fill"]){
            [self forgetFill:e];
            double timeout=self.fillPreparationTimeout;
            timeout=isfinite(timeout)&&timeout>0?fmin(2.5,fmax(.75,timeout)):.75;
            double preparation=monotonic()+timeout;
            __block DWNativeFillRebase *plan=nil;
            DWNativeFillReadiness allowed=[self await:e readiness:^DWNativeFillReadiness(DWSizeEffect *effect){
                // The omission ACK and plan must be inspected in one main
                // turn. An unrelated frame can invalidate that ACK between
                // turns without changing this window's withheld placement.
                DWNativeFillReadiness ready=self.fillReady?self.fillReady(effect):DWNativeFillPending;
                if(ready!=DWNativeFillNeedsRebase)return ready;
                if(!self.fillRebase||!self.screenUpdates)return DWNativeFillPending;
                DWNativeFillRebase *candidate=self.fillRebase(effect);
                if(!candidate||!candidate.publish||!candidate.ready||!candidate.cancel)return DWNativeFillPending;
                plan=candidate;return ready;
            } deadline:fmin(preparation,monotonic()+fmax(.5,timeout-.25))];
            DWResizeResult normalized={.outcome=DWResizeUnavailable,.requested=size};
            if(allowed==DWNativeFillNeedsRebase){
                BOOL ready=[self rebase:e plan:plan deadline:preparation result:&normalized];
                allowed=ready?DWNativeFillReady:DWNativeFillPending;
            }
            method=allowed==DWNativeFillReady?(normalized.mutation_attempted?@"fill rebased":@"fill"):@"fill gate refused";
            if(allowed==DWNativeFillReadyForSnapshotFill){method=@"snapshot fill";r=dw_resize_apply(identity(e.identity),size);}
            else if(allowed==DWNativeFillUnsupportedGeometry){method=@"fill transformed, resize fallback";r=dw_resize_apply(identity(e.identity),size);}
            else r=allowed==DWNativeFillReady?dw_resize_fill(identity(e.identity),size):(DWResizeResult){.outcome=DWResizeUnavailable,.requested=size};
            if(allowed==DWNativeFillReady&&r.observed&&r.mutation_attempted&&r.ax_error==kAXErrorSuccess&&(r.outcome==DWResizeApplied||r.outcome==DWResizeClamped))[self rememberFill:e];
            // Only a positively unsupported, unattempted menu action permits
            // the ordinary size setter. An attempted press is never replayed.
            if(allowed==DWNativeFillReady&&r.outcome==DWResizeUnsupported&&!r.mutation_attempted){method=@"fill unsupported, resize fallback";r=dw_resize_apply(identity(e.identity),size);}
            if(allowed==DWNativeFillPending&&normalized.mutation_attempted){r=normalized;r.requested=size;r.observed=false;if(r.outcome!=DWResizeTimedOut&&r.outcome!=DWResizeStaleIdentity)r.outcome=DWResizeReadbackFailed;method=@"fill rebase failed";}
            r=withMutation(r,normalized);
        }
        else if(e.nativeOriginPresence==DWValueNull)r=dw_resize_apply(identity(e.identity),size);
        else if(e.nativeOriginIsExactPoint){
            CGRect saved={e.nativeOrigin,size};
            BOOL prepared=self.nativeFill&&self.restoreReady;
            BOOL qualified=prepared&&[self hasNativeFillForEffect:e];
            // The shell gives explicit snapshot handoffs a seven-second
            // coordinator budget: 2.25s preparation +2s Unfill +2s correction.
            // An ordinary-size enter can still own a snapshot Restore. Wait
            // for its hidden ACK even though it cannot use the app's Unfill.
            DWNativeFillReadiness allowed=prepared?[self await:e readiness:self.restoreReady deadline:monotonic()+2.25]:DWNativeFillUnsupportedGeometry;
            if(allowed==DWNativeFillReady&&qualified){
                method=@"unfill";r=dw_resize_unfill(identity(e.identity),saved);
                if(r.mutation_attempted)[self forgetFill:e];
                if(r.outcome==DWResizeUnsupported&&!r.mutation_attempted){method=@"unfill unsupported, frame fallback";r=dw_resize_apply_frame(identity(e.identity),saved);[self forgetFill:e];}
                else if(r.mutation_attempted&&r.observed&&r.ax_error==kAXErrorSuccess&&(r.outcome==DWResizeApplied||r.outcome==DWResizeClamped||r.outcome==DWResizeRejected)&&(!CGRectEqualToRect(r.actual_ax,saved)||!CGRectEqualToRect(r.actual_cg,saved))){
                    // The app may restore its rebased starting origin. Animation
                    // completion, including a one-point near match, does not
                    // discharge the controller's exact saved frame.
                    DWResizeResult unfilled=r;method=@"unfill corrected frame";
                    r=withMutation(dw_resize_apply_frame(identity(e.identity),saved),unfilled);
                }
            }else if(allowed==DWNativeFillReady||allowed==DWNativeFillReadyForFrameRestore||allowed==DWNativeFillUnsupportedGeometry){method=allowed==DWNativeFillReadyForFrameRestore?@"snapshot frame restore":@"frame restore";r=dw_resize_apply_frame(identity(e.identity),saved);[self forgetFill:e];}
            else {method=@"restore gate refused";r=(DWResizeResult){.outcome=DWResizeUnavailable,.requested=size};}
        }
        else r=(DWResizeResult){.outcome=DWResizeInvalidRequest,.requested=size};
    }
    DWNativeResult *result=[DWNativeResult resultWithNativeResize:r];
    // Method and movement are native diagnostic facts, never controller payload.
    if(self.didPerform)self.didPerform(e,result,method,r.moved);
    return result;
}
@end
