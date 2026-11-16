// SPDX-License-Identifier: GPL-3.0-or-later
#import "DWResizeCoordinator.h"
// A queued worker and the main-thread completion share only this operation's
// gate. Ending it suppresses work that has not started; an AX call already
// running cannot be retracted, and its later completion is still discarded.
@interface DWResizeOperation : NSObject
@property (copy, readonly) DWSizeEffect *effect;
- (instancetype)initWithEffect:(DWSizeEffect *)effect;
- (BOOL)begin;
- (BOOL)end;
- (BOOL)endedBeforeStart;
@end
@implementation DWResizeOperation {
    NSLock *_gate;
    BOOL _started, _ended;
}
- (instancetype)initWithEffect:(DWSizeEffect *)effect {
    if((self=[super init])){_effect=[effect copy];_gate=[NSLock new];}return self;
}
- (BOOL)begin { [_gate lock];BOOL allowed=!_started&&!_ended;if(allowed)_started=YES;[_gate unlock];return allowed; }
- (BOOL)end { [_gate lock];BOOL first=!_ended;_ended=YES;[_gate unlock];return first; }
- (BOOL)endedBeforeStart { [_gate lock];BOOL skipped=_ended&&!_started;[_gate unlock];return skipped; }
@end
@interface DWResizeCoordinator ()
@property id<DWResizeController> controller;
@property id<DWResizeDriver> driver;
@property (copy) DWSchedule worker,main;
@property NSMutableDictionary<NSNumber *,DWResizeOperation *> *pending;
@property BOOL stopping;
@property NSMutableDictionary<NSNumber *,DWResizeOperation *> *dispatched;
@property DWSizeEffect *heldAdmission;
// The controller's checked effect counter is monotonic for its lifetime, Load
// included. One watermark rejects re-consumed results without keeping every ID.
@property uint64_t lastAdmittedEffectID;
@property (readwrite) NSString *failure;
@property id orphan;
@end
@implementation DWResizeCoordinator
- (instancetype)initWithController:(id<DWResizeController>)controller driver:(id<DWResizeDriver>)driver worker:(DWSchedule)worker main:(DWSchedule)main {
    if((self=[super init])){_controller=controller;_driver=driver;_worker=[worker copy];_main=[main copy];_pending=[NSMutableDictionary dictionary];_dispatched=[NSMutableDictionary dictionary];
        _delay=^(NSTimeInterval seconds,DWJob job){dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(seconds*NSEC_PER_SEC)),dispatch_get_main_queue(),job);};}return self;
}
- (NSUInteger)obligations{return self.pending.count;}
- (void)notifyChanged { if(self.changed)self.changed(); }
- (void)consume:(DWControllerReply *)reply {[self consumeEffect:reply.topLevelSizeEffect];}
- (void)consumeEffect:(DWSizeEffect *)e {
    NSAssert(NSThread.isMainThread,@"Rust controller is main-only");
    if(e&&(e.kind==DWEffectObserveResizeSource||e.kind==DWEffectResizeNativeWindow)){
        DWResizeTransaction *transaction=[self.controller resizeTransaction];
        if(!transaction||![transaction.pendingEffect isEqual:e])return;
        if(self.beforeAdmission&&!self.beforeAdmission(e)){self.heldAdmission=e;[self notifyChanged];return;}
        if([self.heldAdmission isEqual:e])self.heldAdmission=nil;
        NSNumber *key=e.effectID;uint64_t effectID=key.unsignedLongLongValue;if(effectID<=self.lastAdmittedEffectID)return;
        self.lastAdmittedEffectID=effectID;
        // Registration precedes dispatch; cancellation can never retract this obligation.
        DWResizeOperation *operation=[[DWResizeOperation alloc]initWithEffect:e];self.pending[key]=operation;
        // An effect answered for while it waited for the worker (the watchdog's answer) is not performed: its setter would ask a size
        // of a window whose transaction is over.
        __weak DWResizeOperation *weakOperation=operation;__weak DWResizeCoordinator *weakSelf=self;
        id<DWResizeDriver> driver=self.driver;DWSchedule main=self.main;
        __block BOOL admitted=NO;
        void (^ready)(BOOL)=^(BOOL allowed){
            DWResizeCoordinator *co=weakSelf;DWResizeOperation *work=weakOperation;
            if(!co||!work||co.pending[key]!=work||admitted)return;
            admitted=YES;
            if(!allowed){DWNativeResult *result=[[co unanswered:e]withMutationAttempted:NO];
                [co finish:work result:result];return;}
            co.dispatched[key]=work;
            co.worker(^{DWResizeOperation *job=weakOperation;if(!weakSelf)return;
                BOOL started=[job begin];if(!started&&![job endedBeforeStart])return;
                DWNativeResult *result=started?[driver perform:job.effect]:nil;
                main(^{DWResizeCoordinator *owner=weakSelf;if(!owner)return;
                    [owner.dispatched removeObjectForKey:key];
                    if(started)[owner finish:job result:result];[owner notifyChanged];});});
            if(co.timeout>0)[co watch:work];
        };
        if(self.prepare){self.prepare(e,ready);if(!admitted)self.delay(2.5,^{ready(NO);});}else ready(YES);
    }
    [self notifyChanged];
}
- (BOOL)hasNativeWorkForTransaction:(NSNumber *)transaction {
    for(DWResizeOperation *work in self.dispatched.allValues)if([work.effect.transaction isEqual:transaction])return YES;
    return NO;
}
- (BOOL)hasEarlierNativeWork:(DWResizeOperation *)operation {
    for(DWResizeOperation *work in self.dispatched.allValues)
        if(![work endedBeforeStart]&&[work.effect.effectID unsignedLongLongValue]<[operation.effect.effectID unsignedLongLongValue])return YES;
    return NO;
}
- (void)watch:(DWResizeOperation *)operation {
    __weak DWResizeCoordinator *weak=self;__weak DWResizeOperation *work=operation;
    self.delay(self.timeout,^{DWResizeCoordinator *owner=weak;DWResizeOperation *job=work;
        if(!owner||!job||owner.pending[job.effect.effectID]!=job)return;
        // A diagnostic queued behind an AX setter must really read AFTER it.
        // Do not let its watchdog retire it before that setter actually returns.
        if(job.effect.requestedPresence!=DWValuePresent&&[owner hasEarlierNativeWork:job]){[owner watch:job];return;}
        [owner finish:job result:[owner unanswered:job.effect]];
    });
}
- (void)retryAdmission {
    DWSizeEffect *effect=self.heldAdmission;if(!effect)return;
    self.heldAdmission=nil;[self consumeEffect:effect];
}
// What the adapter reports for a call that never returned: nothing observed, and a setter that may still run.
- (DWNativeResult *)unanswered:(DWSizeEffect *)e { return [DWNativeResult unansweredForSizeEffect:e]; }
- (DWControllerReply *)report:(DWSizeEffect *)e result:(DWNativeResult *)result { return self.reportResult?self.reportResult(result,e):[self.controller nativeResizeResult:result effect:e]; }
// The one completion of an effect, on the main thread: the driver's result, or the watchdog's.
- (void)finish:(DWResizeOperation *)operation result:(DWNativeResult *)result {
    NSAssert(NSThread.isMainThread,@"Rust controller is main-only");
    DWSizeEffect *e=operation.effect;NSNumber *key=e.effectID;
    if(self.pending[key]!=operation||![operation end])return;
    if(!result)result=[self unanswered:e];
    DWControllerReply *reply=[self report:e result:result];
    if(!reply){
        // No obligation outlives its effect. A result the controller would not take is replaced once by the unanswered
        // one, which is valid for any effect still pending; refused too, the transaction is no longer this effect's, and it is let go.
        result=[self unanswered:e];reply=[self report:e result:result];
        if(!reply){[self.pending removeObjectForKey:key];self.failure=@"The size request ended without a result the controller accepted";[self notifyChanged];return;}
    }
    // A failure is said of the effect it happened to, and ends with the next one the controller takes.
    [self.pending removeObjectForKey:key];self.failure=nil;
    [self consume:reply];
}
- (NSNumber *)busyWindow { return self.pending.allValues.firstObject.effect.window?:self.heldAdmission.window; }
- (void)reap {
    if(self.pending.count||[self canRemove:nil]){self.orphan=nil;return;}
    DWResizeTransaction *t=[self.controller resizeTransaction];DWSizeEffect *e=t.pendingEffect;id mark=e?:t;
    if(e&&([self.heldAdmission isEqual:e]||(self.deferred&&self.deferred(e)))){self.orphan=nil;return;}
    if(!e&&t&&self.held&&self.held(t.transaction)){self.orphan=nil;return;}
    if(![self.orphan isEqual:mark]){self.orphan=mark;return;}
    self.orphan=nil;
    if(e){NSNumber *key=e.effectID;self.lastAdmittedEffectID=MAX(self.lastAdmittedEffectID,key.unsignedLongLongValue);
        DWResizeOperation *operation=[[DWResizeOperation alloc]initWithEffect:e];self.pending[key]=operation;[self finish:operation result:[self unanswered:e]];}
    else [self cancel];
}
- (void)discardDeferredEffect:(DWSizeEffect *)effect {
    NSAssert(NSThread.isMainThread,@"Rust controller is main-only");
    if(self.pending.count||effect.kind!=DWEffectObserveResizeSource
        ||effect.requestedPresence==DWValuePresent)return;
    DWResizeTransaction *transaction=[self.controller resizeTransaction];
    NSNumber *key=effect.effectID;uint64_t effectID=key.unsignedLongLongValue;
    if(!transaction||![transaction.pendingEffect isEqual:effect]
        ||effectID<=self.lastAdmittedEffectID)return;
    self.orphan=nil;self.lastAdmittedEffectID=effectID;
    DWResizeOperation *operation=[[DWResizeOperation alloc]initWithEffect:effect];self.pending[key]=operation;
    [self finish:operation result:[self unanswered:effect]];
}
- (DWControllerReply *)request:(DWResizeRequest)operation {
    if(!self.enabled||self.stopping)return nil;
    DWControllerReply *reply=operation(self.controller);[self consume:reply];return reply;
}
- (void)cancel {
    DWResizeTransaction *t=[self.controller resizeTransaction];if(!t)return;
    [self consume:[self.controller cancelNativeResize:t.transaction]];
}
- (void)shutdown {self.stopping=YES;[self cancel];}
- (BOOL)canRemove:(NSNumber *)window {
    BOOL answer=NO;if(self.removalAllowed&&self.removalAllowed(window,&answer))return answer;
    DWResizeTransaction *t=[self.controller resizeTransaction];if(!t||(window&&![t.window isEqual:window]))return YES;
    return t.pendingEffectPresence==DWValueNull&&![t.uncertainMutation boolValue]&&([t.phase isEqual:@"complete"]||[t.phase isEqual:@"failed"]);
}
@end
