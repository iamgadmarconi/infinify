// SPDX-License-Identifier: GPL-3.0-or-later
#import "navigation-coordinator.h"
static BOOL sameIdentity(NSDictionary *a,NSDictionary *b) {
    for(NSString *key in @[@"pid",@"birth_sec",@"birth_usec",@"wid"])if(![a[key]isEqual:b[key]])return NO;
    BOOL aOwner=a[@"owner"]&&a[@"owner"]!=NSNull.null,bOwner=b[@"owner"]&&b[@"owner"]!=NSNull.null;
    return aOwner==bOwner&&(!aOwner||[a[@"owner"]isEqual:b[@"owner"]]);
}
@interface DWNavigationCoordinator ()
@property (copy) DWCommand command;
@property id<DWNavigationDriver> driver;
@property (copy) uint64_t (^clock)(void);
@property (copy) DWSchedule worker, main;
@property NSLock *lock;
@property uint64_t epoch;
@property BOOL closed, observing, flying;
@end
@implementation DWNavigationCoordinator
- (instancetype)initWithCommand:(DWCommand)c driver:(id<DWNavigationDriver>)d clock:(uint64_t (^)(void))clock worker:(DWSchedule)worker main:(DWSchedule)main {
    if((self=[super init])){_command=[c copy];_driver=d;_clock=[clock copy];_worker=[worker copy];_main=[main copy];_lock=[NSLock new];}return self;
}
- (BOOL)current:(uint64_t)epoch { [self.lock lock];BOOL valid=!self.closed&&self.epoch==epoch;[self.lock unlock];return valid; }
- (uint64_t)advance { [self.lock lock];uint64_t epoch=++self.epoch;[self.lock unlock];return epoch; }
- (void)invalidate { [self advance];if(!self.closed&&self.enabled){self.command(@{@"op":@"cancel_focus_cycle"});for(NSDictionary *o in self.command(@{@"op":@"snapshot"})[@"outputs"])self.command(@{@"op":@"cancel_navigation",@"output":o[@"id"]});} }
- (void)shutdown { [self invalidate];[self.lock lock];self.closed=YES;[self.lock unlock];self.command=nil;self.changed=nil;self.settled=nil; }
- (BOOL)binding:(NSDictionary *)effect snapshot:(NSDictionary *)snapshot {
    for(NSDictionary *window in snapshot[@"windows"])if([window[@"window"]isEqual:effect[@"window"]]){
        id source=window[@"source"];return [source isKindOfClass:NSDictionary.class]&&[source[@"identity"]isEqual:effect[@"identity"]]&&[source[@"generation"]isEqual:effect[@"generation"]];
    }
    return NO;
}
- (void)complete:(NSDictionary *)effect epoch:(uint64_t)epoch success:(BOOL)success {
    if(![self current:epoch])return;
    NSDictionary *snapshot=self.command(@{@"op":@"snapshot"});
    if(![snapshot[@"focus"][@"pending_effect"]isEqual:effect]||![self binding:effect snapshot:snapshot])return;
    NSMutableDictionary *result=[effect mutableCopy];result[@"op"]=@"focus_result";result[@"success"]=@(success);self.command(result);[self advance];
    if(self.changed)self.changed();
}
- (void)navigate:(NSDictionary *)command {
    if(!self.enabled||self.closed)return;
    NSDictionary *reply=self.command(command);if(!reply)return;
    uint64_t epoch=[self advance],deadline=self.clock()+1500000000;
    NSDictionary *effect=[reply[@"effect"] copy];
    if(self.changed)self.changed();
    if(![effect isKindOfClass:NSDictionary.class])return;
    if(!self.focusAllowed||(effect[@"identity"][@"owner"]&&effect[@"identity"][@"owner"]!=NSNull.null)){[self complete:effect epoch:epoch success:NO];return;}
    // All captured values are immutable. The guard never enters the controller/main queue.
    DWGuard authorization=[self.driver authorization:effect[@"identity"]];
    self.worker(^{if(![self current:epoch])return;
        BOOL success=[self.driver select:effect[@"identity"] guard:^BOOL{return [self current:epoch]&&self.clock()<deadline&&authorization&&authorization();}];
        self.main(^{[self complete:effect epoch:epoch success:success];});
    });
}
- (void)releaseCycle { if(self.enabled&&!self.closed)self.command(@{@"op":@"end_focus_cycle"}); }
- (void)observe {
    if(!self.enabled||self.closed||self.observing)return;self.observing=YES;
    uint64_t epoch=self.epoch;
    self.worker(^{NSDictionary *identity=[self.driver observe];self.main(^{
        self.observing=NO;if(!identity||![self current:epoch])return;
        NSDictionary *snapshot=self.command(@{@"op":@"snapshot"}),*match=nil;
        for(NSDictionary *w in snapshot[@"windows"]){id s=w[@"source"];if([s isKindOfClass:NSDictionary.class]&&sameIdentity(s[@"identity"],identity)){match=@{@"window":w[@"window"],@"identity":s[@"identity"],@"generation":s[@"generation"]};break;}}
        if(!match){for(NSDictionary *w in snapshot[@"windows"]){id source=w[@"source"];if(![source isKindOfClass:NSDictionary.class])continue;NSMutableDictionary *plain=[source[@"identity"]mutableCopy];[plain removeObjectForKey:@"owner"];if(sameIdentity(plain,identity))return;}}
        NSDictionary *focus=snapshot[@"focus"];id pending=focus[@"pending_effect"];
        if(match&&[pending isKindOfClass:NSDictionary.class]&&[pending[@"window"]isEqual:match[@"window"]]&&[pending[@"generation"]isEqual:match[@"generation"]]&&sameIdentity(pending[@"identity"],identity)){[self complete:pending epoch:epoch success:YES];return;}
        id observed=focus[@"observed_native"];
        if(match&&[observed isKindOfClass:NSDictionary.class]&&[observed[@"window"]isEqual:match[@"window"]]&&[observed[@"generation"]isEqual:match[@"generation"]]&&sameIdentity(observed[@"identity"],identity))return;
        if(!match&&observed==NSNull.null&&pending==NSNull.null)return;
        [self advance];NSMutableDictionary *c=match?[match mutableCopy]:[NSMutableDictionary dictionary];c[@"op"]=match?@"observe_focus":@"focus_lost";self.command(c);if(self.changed)self.changed();
    });});
}
- (BOOL)frame {
    if(!self.enabled||self.closed)return NO;
    NSDictionary *result=self.command(@{@"op":@"tick_navigation",@"timestamp_ns":@(self.clock())});
    if([result[@"changed_outputs"]count]&&self.changed)self.changed();
    BOOL active=[result[@"needs_frames"]boolValue];if(!active&&self.flying&&self.settled)self.settled();self.flying=active;return active;
}
@end
@interface DWNavigationInput ()
@property NSMutableArray<NSDictionary *> *presses;
@property BOOL tab, option, saturated;
@end
@implementation DWNavigationInput
- (instancetype)init {if((self=[super init]))_presses=[NSMutableArray array];return self;}
- (void)cancel {for(NSUInteger i=0;i<self.presses.count;i++)self.presses[i]=@{@"backward":self.presses[i][@"backward"],@"valid":@NO};self.tab=NO;}
- (NSInteger)flagsChanged:(NSUInteger)flags {
    BOOL wasOption=self.option;self.option=(flags&1)!=0;
    if(flags&4){[self cancel];return 1;}
    if(wasOption&&!self.option)return 2;
    if(!wasOption){[self cancel];return 1;}
    return 0;
}
- (BOOL)tabDown:(NSUInteger)flags {
    if(self.saturated)return NO;
    self.option=(flags&1)!=0;
    if(!self.option||(flags&4)){[self cancel];return NO;}
    if(self.presses.count>=128){self.saturated=YES;[self cancel];return NO;}
    self.tab=YES;[self.presses addObject:@{@"backward":@((flags&2)!=0),@"valid":@YES}];return YES;
}
- (BOOL)tabUp {BOOL accepted=self.tab;self.tab=NO;return accepted;}
- (NSNumber *)takeShortcut:(BOOL)backward {
    if(self.saturated)return nil;
    if(!self.presses.count||[self.presses[0][@"backward"]boolValue]!=backward)return nil;
    BOOL valid=[self.presses[0][@"valid"]boolValue];[self.presses removeObjectAtIndex:0];return valid?@(self.option):nil;
}
@end
