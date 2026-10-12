// SPDX-License-Identifier: GPL-3.0-or-later
#import "resize-coordinator.h"
@interface DWResizeCoordinator ()
@property (copy) DWCommand command;
@property id<DWResizeDriver> driver;
@property (copy) DWSchedule worker,main;
@property NSMutableDictionary<NSNumber *,NSDictionary *> *pending;
@property BOOL stopping;
@property NSMutableSet<NSNumber *> *seen;
@property (readwrite) NSString *failure;
@property id orphan;
// Effects whose obligation has ended, by id. The one state of the coordinator the worker reads, so it is read and written locked.
@property NSMutableSet<NSNumber *> *discharged;
@end
@implementation DWResizeCoordinator
- (instancetype)initWithCommand:(DWCommand)command driver:(id<DWResizeDriver>)driver worker:(DWSchedule)worker main:(DWSchedule)main {
    if((self=[super init])){_command=[command copy];_driver=driver;_worker=[worker copy];_main=[main copy];_pending=[NSMutableDictionary dictionary];_seen=[NSMutableSet set];_discharged=[NSMutableSet set];
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
        NSNumber *key=e[@"effect_id"];if([self.seen containsObject:key])return;
        [self.seen addObject:key];
        // Registration precedes dispatch; cancellation can never retract this obligation.
        self.pending[key]=e;
        // An effect answered for while it waited for the worker (the watchdog's answer) is not performed: its setter would ask a size
        // of a window whose transaction is over.
        self.worker(^{if([self discharged:key])return;NSDictionary *result=[self.driver perform:e];self.main(^{[self finish:e result:result];});});
        // The watchdog. The real result, should it still come, finds the obligation gone and is dropped.
        if(self.timeout>0)self.delay(self.timeout,^{[self finish:e result:[self unanswered:e]];});
    }
    [self notifyChanged];
}
// What the adapter reports for a call that never returned: nothing observed, and a setter that may still run.
- (NSDictionary *)unanswered:(NSDictionary *)e {
    BOOL setter=[e[@"requested"]isKindOfClass:NSDictionary.class];NSDictionary *none=@{@"origin":@{@"x":@0,@"y":@0},@"size":@{@"width":@0,@"height":@0}};
    return @{@"outcome":@"timed_out",@"ax_error":@(-25204),@"mutation_attempted":setter?@YES:@NO,@"observed":@NO,@"requested":setter?e[@"requested"]:@{@"width":@0,@"height":@0},@"actual_ax":none,@"actual_cg":none};
}
- (BOOL)discharged:(NSNumber *)key { @synchronized(self.discharged){return [self.discharged containsObject:key];} }
- (void)discharge:(NSNumber *)key { [self.pending removeObjectForKey:key];@synchronized(self.discharged){[self.discharged addObject:key];} }
- (NSDictionary *)report:(NSDictionary *)e result:(NSDictionary *)result { return self.command(@{@"op":@"native_resize_result",@"transaction":e[@"transaction"],@"effect_id":e[@"effect_id"],@"identity":e[@"identity"],@"generation":e[@"generation"],@"result":result}); }
// The one completion of an effect, on the main thread: the driver's result, or the watchdog's.
- (void)finish:(NSDictionary *)e result:(NSDictionary *)result {
    NSAssert(NSThread.isMainThread,@"Rust controller is main-only");
    NSNumber *key=e[@"effect_id"];if(![self.pending[key]isEqual:e])return;
    if(!result)result=[self unanswered:e];
    NSDictionary *reply=[self report:e result:result];
    if(!reply){
        // No obligation outlives its effect. A result the controller would not take is replaced once by the unanswered
        // one, which is valid for any effect still pending; refused too, the transaction is no longer this effect's, and it is let go.
        result=[self unanswered:e];reply=[self report:e result:result];
        if(!reply){[self discharge:key];self.failure=@"The size request ended without a result the controller accepted";[self notifyChanged];return;}
    }
    // A failure is said of the effect it happened to, and ends with the next one the controller takes.
    [self discharge:key];self.failure=nil;
    [self consume:reply];
}
- (NSNumber *)busyWindow { return self.pending.allValues.firstObject[@"window"]; }
- (void)reap {
    if(self.pending.count||[self canRemove:nil]){self.orphan=nil;return;}
    id t=self.command(@{@"op":@"snapshot"})[@"native_resize"],e=[t isKindOfClass:NSDictionary.class]?t[@"pending_effect"]:nil;id mark=[e isKindOfClass:NSDictionary.class]?e:t;
    if(![e isKindOfClass:NSDictionary.class]&&[t isKindOfClass:NSDictionary.class]&&self.held&&self.held(t[@"transaction"])){self.orphan=nil;return;}
    if(![self.orphan isEqual:mark]){self.orphan=mark;return;}
    self.orphan=nil;
    if([e isKindOfClass:NSDictionary.class]){[self.seen addObject:e[@"effect_id"]];self.pending[e[@"effect_id"]]=e;[self finish:e result:[self unanswered:e]];}
    else [self cancel];
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
