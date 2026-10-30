// SPDX-License-Identifier: GPL-3.0-or-later
#import "DWResizeCoordinator.h"
// A queued worker and the main-thread completion share only this operation's
// gate. Ending it suppresses work that has not started; an AX call already
// running cannot be retracted, and its later completion is still discarded.
@interface DWResizeOperation : NSObject
@property (copy, readonly) NSDictionary *effect;
- (instancetype)initWithEffect:(NSDictionary *)effect;
- (BOOL)begin;
- (BOOL)end;
@end
@implementation DWResizeOperation {
    NSLock *_gate;
    BOOL _started, _ended;
}
- (instancetype)initWithEffect:(NSDictionary *)effect {
    if((self=[super init])){_effect=[effect copy];_gate=[NSLock new];}return self;
}
- (BOOL)begin { [_gate lock];BOOL allowed=!_started&&!_ended;if(allowed)_started=YES;[_gate unlock];return allowed; }
- (BOOL)end { [_gate lock];BOOL first=!_ended;_ended=YES;[_gate unlock];return first; }
@end
@interface DWResizeCoordinator ()
@property (copy) DWCommand command;
@property id<DWResizeDriver> driver;
@property (copy) DWSchedule worker,main;
@property NSMutableDictionary<NSNumber *,DWResizeOperation *> *pending;
@property BOOL stopping;
// The controller's checked effect counter is monotonic for its lifetime, Load
// included. One watermark rejects re-consumed results without keeping every ID.
@property uint64_t lastAdmittedEffectID;
@property (readwrite) NSString *failure;
@property id orphan;
@end
@implementation DWResizeCoordinator
- (instancetype)initWithCommand:(DWCommand)command driver:(id<DWResizeDriver>)driver worker:(DWSchedule)worker main:(DWSchedule)main {
    if((self=[super init])){_command=[command copy];_driver=driver;_worker=[worker copy];_main=[main copy];_pending=[NSMutableDictionary dictionary];
        _delay=^(NSTimeInterval seconds,DWJob job){dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(seconds*NSEC_PER_SEC)),dispatch_get_main_queue(),job);};}return self;
}
- (NSUInteger)obligations{return self.pending.count;}
- (void)notifyChanged { if(self.changed)self.changed(); }
- (void)consume:(NSDictionary *)reply {
    NSAssert(NSThread.isMainThread,@"Rust controller is main-only");
    id e=reply[@"effect"];
    if([e isKindOfClass:NSDictionary.class]&&([e[@"op"]isEqual:@"observe_resize_source"]||[e[@"op"]isEqual:@"resize_native_window"])){
        id transaction=self.command(@{@"op":@"snapshot"})[@"native_resize"];
        if(![transaction isKindOfClass:NSDictionary.class]||![transaction[@"pending_effect"]isEqual:e])return;
        NSNumber *key=e[@"effect_id"];uint64_t effectID=key.unsignedLongLongValue;if(effectID<=self.lastAdmittedEffectID)return;
        self.lastAdmittedEffectID=effectID;
        // Registration precedes dispatch; cancellation can never retract this obligation.
        DWResizeOperation *operation=[[DWResizeOperation alloc]initWithEffect:e];self.pending[key]=operation;
        // An effect answered for while it waited for the worker (the watchdog's answer) is not performed: its setter would ask a size
        // of a window whose transaction is over.
        __weak DWResizeOperation *weakOperation=operation;__weak DWResizeCoordinator *weakSelf=self;
        id<DWResizeDriver> driver=self.driver;DWSchedule main=self.main;
        self.worker(^{DWResizeOperation *work=weakOperation;if(!weakSelf||![work begin])return;
            NSDictionary *result=[driver perform:work.effect];main(^{[weakSelf finish:work result:result];});});
        // The watchdog. The real result, should it still come, finds the obligation gone and is dropped.
        if(self.timeout>0)self.delay(self.timeout,^{DWResizeCoordinator *co=weakSelf;DWResizeOperation *work=weakOperation;
            if(co&&work)[co finish:work result:[co unanswered:work.effect]];});
    }
    [self notifyChanged];
}
// What the adapter reports for a call that never returned: nothing observed, and a setter that may still run.
- (NSDictionary *)unanswered:(NSDictionary *)e {
    BOOL setter=[e[@"requested"]isKindOfClass:NSDictionary.class];NSDictionary *none=@{@"origin":@{@"x":@0,@"y":@0},@"size":@{@"width":@0,@"height":@0}};
    return @{@"outcome":@"timed_out",@"ax_error":@(-25204),@"mutation_attempted":setter?@YES:@NO,@"observed":@NO,@"requested":setter?e[@"requested"]:@{@"width":@0,@"height":@0},@"actual_ax":none,@"actual_cg":none};
}
- (NSDictionary *)report:(NSDictionary *)e result:(NSDictionary *)result { return self.command(@{@"op":@"native_resize_result",@"transaction":e[@"transaction"],@"effect_id":e[@"effect_id"],@"identity":e[@"identity"],@"generation":e[@"generation"],@"result":result}); }
// The one completion of an effect, on the main thread: the driver's result, or the watchdog's.
- (void)finish:(DWResizeOperation *)operation result:(NSDictionary *)result {
    NSAssert(NSThread.isMainThread,@"Rust controller is main-only");
    NSDictionary *e=operation.effect;NSNumber *key=e[@"effect_id"];
    if(self.pending[key]!=operation||![operation end])return;
    if(!result)result=[self unanswered:e];
    NSDictionary *reply=[self report:e result:result];
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
- (NSNumber *)busyWindow { return self.pending.allValues.firstObject.effect[@"window"]; }
- (void)reap {
    if(self.pending.count||[self canRemove:nil]){self.orphan=nil;return;}
    id t=self.command(@{@"op":@"snapshot"})[@"native_resize"],e=[t isKindOfClass:NSDictionary.class]?t[@"pending_effect"]:nil;id mark=[e isKindOfClass:NSDictionary.class]?e:t;
    if([e isKindOfClass:NSDictionary.class]&&self.deferred&&self.deferred(e)){self.orphan=nil;return;}
    if(![e isKindOfClass:NSDictionary.class]&&[t isKindOfClass:NSDictionary.class]&&self.held&&self.held(t[@"transaction"])){self.orphan=nil;return;}
    if(![self.orphan isEqual:mark]){self.orphan=mark;return;}
    self.orphan=nil;
    if([e isKindOfClass:NSDictionary.class]){NSNumber *key=e[@"effect_id"];self.lastAdmittedEffectID=MAX(self.lastAdmittedEffectID,key.unsignedLongLongValue);
        DWResizeOperation *operation=[[DWResizeOperation alloc]initWithEffect:e];self.pending[key]=operation;[self finish:operation result:[self unanswered:e]];}
    else [self cancel];
}
- (void)discardDeferredEffect:(NSDictionary *)effect {
    NSAssert(NSThread.isMainThread,@"Rust controller is main-only");
    if(self.pending.count||![effect[@"op"]isEqual:@"observe_resize_source"]
        ||[effect[@"requested"]isKindOfClass:NSDictionary.class])return;
    NSDictionary *transaction=self.command(@{@"op":@"snapshot"})[@"native_resize"];
    NSNumber *key=effect[@"effect_id"];uint64_t effectID=key.unsignedLongLongValue;
    if(![transaction isKindOfClass:NSDictionary.class]||![transaction[@"pending_effect"]isEqual:effect]
        ||effectID<=self.lastAdmittedEffectID)return;
    self.orphan=nil;self.lastAdmittedEffectID=effectID;
    DWResizeOperation *operation=[[DWResizeOperation alloc]initWithEffect:effect];self.pending[key]=operation;
    [self finish:operation result:[self unanswered:effect]];
}
- (NSDictionary *)request:(NSDictionary *)c {
    if(!self.enabled||self.stopping)return nil;
    NSDictionary *reply=self.command(c);[self consume:reply];return reply;
}
- (void)cancel {
    id t=self.command(@{@"op":@"snapshot"})[@"native_resize"];if(![t isKindOfClass:NSDictionary.class])return;
    [self consume:self.command(@{@"op":@"cancel_native_resize",@"transaction":t[@"transaction"]})];
}
- (void)shutdown {self.stopping=YES;[self cancel];}
- (BOOL)canRemove:(NSNumber *)window {
    id t=self.command(@{@"op":@"snapshot"})[@"native_resize"];if(![t isKindOfClass:NSDictionary.class]||(window&&![t[@"window"]isEqual:window]))return YES;
    return t[@"pending_effect"]==NSNull.null&&![t[@"uncertain_mutation"]boolValue]&&([t[@"phase"]isEqual:@"complete"]||[t[@"phase"]isEqual:@"failed"]);
}
@end
