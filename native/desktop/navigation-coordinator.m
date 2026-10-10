// SPDX-License-Identifier: GPL-3.0-or-later
#import "navigation-coordinator.h"
static BOOL sameIdentity(NSDictionary *a,NSDictionary *b) {
    for(NSString *key in @[@"pid",@"birth_sec",@"birth_usec",@"wid"])if(![a[key]isEqual:b[key]])return NO;
    BOOL aOwner=a[@"owner"]&&a[@"owner"]!=NSNull.null,bOwner=b[@"owner"]&&b[@"owner"]!=NSNull.null;
    return aOwner==bOwner&&(!aOwner||[a[@"owner"]isEqual:b[@"owner"]]);
}
// The one focus request a reply can carry: "effect" as focus, navigate_window and activate
// answer, or the focus_native_window entry of an action or IPC reply's "effects".
static NSDictionary *focusEffect(NSDictionary *reply) {
    id effect=reply[@"effect"],effects=reply[@"effects"];if([effect isKindOfClass:NSDictionary.class])return effect;
    if([effects isKindOfClass:NSArray.class])for(id e in [effects reverseObjectEnumerator])if([e isKindOfClass:NSDictionary.class]&&[e[@"op"]isEqual:@"focus_native_window"])return e;
    return nil;
}
@interface DWNavigationCoordinator ()
@property (copy) DWCommand command;
@property id<DWNavigationDriver> driver;
@property (copy) uint64_t (^clock)(void);
@property (copy) DWSchedule worker, main;
@property NSLock *lock;
@property uint64_t epoch;
@property BOOL closed, observing, flying;
@property BOOL again; // native focus was reported to have moved while a read of it was under way
@property NSDictionary *work; // the request handed to the driver and not yet answered
@property NSUInteger held; // modifiers keeping a cycle session open, 0 for none
@end
@implementation DWNavigationCoordinator
- (instancetype)initWithCommand:(DWCommand)c driver:(id<DWNavigationDriver>)d clock:(uint64_t (^)(void))clock worker:(DWSchedule)worker main:(DWSchedule)main {
    if((self=[super init])){_command=[c copy];_driver=d;_clock=[clock copy];_worker=[worker copy];_main=[main copy];_lock=[NSLock new];}return self;
}
- (BOOL)current:(uint64_t)epoch { [self.lock lock];BOOL valid=!self.closed&&self.epoch==epoch;[self.lock unlock];return valid; }
- (uint64_t)advance { self.work=nil;[self.lock lock];uint64_t epoch=++self.epoch;[self.lock unlock];return epoch; }
- (void)cancelFocus { [self advance];self.held=0;if(!self.closed&&self.enabled)self.command(@{@"op":@"cancel_focus_cycle"}); }
- (void)interrupt { if(self.work)[self cancelFocus]; }
- (void)invalidate { [self cancelFocus];if(!self.closed&&self.enabled)for(NSDictionary *o in self.command(@{@"op":@"snapshot"})[@"outputs"])self.command(@{@"op":@"cancel_navigation",@"output":o[@"id"]}); }
- (void)shutdown { [self invalidate];[self.lock lock];self.closed=YES;[self.lock unlock];self.command=nil;self.changed=nil;self.settled=nil;self.output=nil; }
- (BOOL)binding:(NSDictionary *)effect snapshot:(NSDictionary *)snapshot {
    for(NSDictionary *window in snapshot[@"windows"])if([window[@"window"]isEqual:effect[@"window"]]){
        id source=window[@"source"];return [source isKindOfClass:NSDictionary.class]&&[source[@"identity"]isEqual:effect[@"identity"]]&&[source[@"generation"]isEqual:effect[@"generation"]];
    }
    return NO;
}
- (void)complete:(NSDictionary *)effect epoch:(uint64_t)epoch success:(BOOL)success { [self answer:effect epoch:epoch with:@{@"op":@"focus_result",@"success":success?@YES:@NO}]; }
// The controller's pending request is answered once: the driver's result, or focus_logical when the driver is never asked.
- (void)answer:(NSDictionary *)effect epoch:(uint64_t)epoch with:(NSDictionary *)fields {
    if(![self current:epoch])return;
    self.work=nil;NSDictionary *snapshot=self.command(@{@"op":@"snapshot"});
    if(![snapshot[@"focus"][@"pending_effect"]isEqual:effect]||![self binding:effect snapshot:snapshot])return;
    NSMutableDictionary *result=[effect mutableCopy];[result addEntriesFromDictionary:fields];self.command(result);[self advance];
    if(self.changed)self.changed();
}
- (void)perform:(NSDictionary *)reply {
    if(!self.enabled||self.closed||!reply)return;
    NSDictionary *effect=[focusEffect(reply) copy];
    if(!effect){
        // Focus moved to something without a source, or was cleared: the request in flight is no longer the controller's.
        if(reply[@"effect"]||(self.work&&![self.command(@{@"op":@"snapshot"})[@"focus"][@"pending_effect"]isEqual:self.work]))[self advance];
        return;
    }
    uint64_t epoch=[self advance],deadline=self.clock()+1500000000;
    // Logical-only focus is not a failure: it neither cancels a held cycle nor stays out of the most-recently-focused order.
    if(!self.focusAllowed){[self answer:effect epoch:epoch with:@{@"op":@"focus_logical"}];return;}
    if(effect[@"identity"][@"owner"]&&effect[@"identity"][@"owner"]!=NSNull.null){[self complete:effect epoch:epoch success:NO];return;}
    // All captured values are immutable. The guard never enters the controller/main queue.
    DWGuard authorization=[self.driver authorization:effect[@"identity"]];self.work=effect;
    self.worker(^{if(![self current:epoch])return;
        BOOL success=[self.driver select:effect[@"identity"] guard:^BOOL{return [self current:epoch]&&self.clock()<deadline&&authorization&&authorization();}];
        self.main(^{[self complete:effect epoch:epoch success:success];});
    });
}
- (NSDictionary *)navigate:(NSDictionary *)command {
    if(!self.enabled||self.closed)return nil;
    NSDictionary *reply=self.command(command);if(!reply)return nil;
    [self perform:reply];if(self.changed)self.changed();return reply;
}
- (void)hold:(NSUInteger)modifiers { self.held=modifiers; }
- (BOOL)poll:(NSUInteger)down {
    if(!self.enabled||self.closed||!self.held)return NO;
    if((down&self.held)==self.held)return YES;
    self.held=0;[self releaseCycle];return NO;
}
- (void)releaseCycle { if(self.enabled&&!self.closed)self.command(@{@"op":@"end_focus_cycle"}); }
- (void)observe {
    if(!self.enabled||self.closed)return;
    // A focus event may arrive while a read is under way, and that read may have looked before the change: one more follows it.
    if(self.observing){self.again=YES;return;}
    self.observing=YES;
    uint64_t epoch=self.epoch;
    self.worker(^{NSDictionary *identity=[self.driver observe];self.main(^{
        // After this turn: what this read reports is followed first, so the next read is judged against the focus that leaves.
        self.observing=NO;if(self.again){self.again=NO;self.main(^{[self observe];});}
        if(!identity||![self current:epoch])return;
        NSDictionary *snapshot=self.command(@{@"op":@"snapshot"}),*match=nil;
        for(NSDictionary *w in snapshot[@"windows"]){id s=w[@"source"];if([s isKindOfClass:NSDictionary.class]&&sameIdentity(s[@"identity"],identity)){match=@{@"window":w[@"window"],@"identity":s[@"identity"],@"generation":s[@"generation"]};break;}}
        if(!match){for(NSDictionary *w in snapshot[@"windows"]){id source=w[@"source"];if(![source isKindOfClass:NSDictionary.class])continue;NSMutableDictionary *plain=[source[@"identity"]mutableCopy];[plain removeObjectForKey:@"owner"];if(sameIdentity(plain,identity))return;}}
        NSDictionary *focus=snapshot[@"focus"];id pending=focus[@"pending_effect"];
        if(match&&[pending isKindOfClass:NSDictionary.class]&&[pending[@"window"]isEqual:match[@"window"]]&&[pending[@"generation"]isEqual:match[@"generation"]]&&sameIdentity(pending[@"identity"],identity)){[self complete:pending epoch:epoch success:YES];return;}
        id observed=focus[@"observed_native"];
        if(match&&[observed isKindOfClass:NSDictionary.class]&&[observed[@"window"]isEqual:match[@"window"]]&&[observed[@"generation"]isEqual:match[@"generation"]]&&sameIdentity(observed[@"identity"],identity))return;
        if(!match&&observed==NSNull.null&&pending==NSNull.null)return;
        [self advance];
        if(!match)self.command(@{@"op":@"focus_lost"});
        else {
            // The user focused a window of the canvas natively: upstream's activation, so focus, MRU order and by
            // its reveal rule the camera follow. The observation is the focus; a request in the reply is answered
            // from it, never by the driver. Refused (a gesture is active), the focus is still recorded.
            NSMutableDictionary *c=[match mutableCopy];c[@"op"]=@"activate";c[@"cause"]=@"native";c[@"output"]=(self.output?self.output():nil)?:NSNull.null;
            NSDictionary *reply=self.command(c),*effect=focusEffect(reply);
            if(effect)[self complete:effect epoch:self.epoch success:YES];
            else if(!reply){[c removeObjectsForKeys:@[@"cause",@"output"]];c[@"op"]=@"observe_focus";self.command(c);}
        }
        if(self.changed)self.changed();
    });});
}
- (BOOL)frame {
    if(!self.enabled||self.closed)return NO;
    NSDictionary *result=self.command(@{@"op":@"tick_navigation",@"timestamp_ns":@(self.clock())});
    if([result[@"changed_outputs"]count]&&self.changed)self.changed();
    BOOL active=[result[@"needs_frames"]boolValue];if(!active&&self.flying&&self.settled)self.settled();self.flying=active;return active;
}
@end
