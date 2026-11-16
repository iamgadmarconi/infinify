// SPDX-License-Identifier: GPL-3.0-or-later
#import "DWNavigationCoordinator.h"
#include <stdio.h>
#include <stdlib.h>
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
@property NSDictionary *nativeClick;
@property NSDictionary *nativeClickPose;
@property BOOL nativeClickReleased,nativeClickCompleted,nativeClickConfirmed;
@property uint64_t nativeClickDeadline;
@property uint64_t nativeClickPoll;
@end
@implementation DWNavigationCoordinator
- (instancetype)initWithCommand:(DWCommand)c driver:(id<DWNavigationDriver>)d clock:(uint64_t (^)(void))clock worker:(DWSchedule)worker main:(DWSchedule)main {
    if((self=[super init])){_command=[c copy];_driver=d;_clock=[clock copy];_worker=[worker copy];_main=[main copy];_lock=[NSLock new];}return self;
}
- (uint64_t)nowNanoseconds { return self.clock?self.clock():0; }
- (BOOL)current:(uint64_t)epoch { [self.lock lock];BOOL valid=!self.closed&&self.epoch==epoch;[self.lock unlock];return valid; }
- (uint64_t)advance { self.work=nil;[self.lock lock];uint64_t epoch=++self.epoch;[self.lock unlock];return epoch; }
- (void)cancelNativeClick { self.nativeClick=nil;self.nativeClickPose=nil;self.nativeClickReleased=self.nativeClickCompleted=self.nativeClickConfirmed=NO; }
- (void)cancelFocus { [self clearBackgroundArrival];[self cancelNativeClick];[self advance];self.held=0;if(!self.closed&&self.enabled)self.command(@{@"op":@"cancel_focus_cycle"}); }
- (void)interrupt { [self cancelBackgroundArrival];if(self.work)[self cancelFocus]; }
- (void)invalidate { [self cancelFocus];if(!self.closed&&self.enabled)for(NSDictionary *o in self.command(@{@"op":@"snapshot"})[@"outputs"])self.command(@{@"op":@"cancel_navigation",@"output":o[@"id"]}); }
- (void)shutdown { [self invalidate];[self.lock lock];self.closed=YES;[self.lock unlock];self.command=nil;self.changed=nil;self.settled=nil;self.output=nil;self.observationBinding=nil;self.nativeClickReleaseReady=nil;self.arrivalProtection=nil; }
- (BOOL)binding:(NSDictionary *)effect snapshot:(NSDictionary *)snapshot {
    for(NSDictionary *window in snapshot[@"windows"])if([window[@"window"]isEqual:effect[@"window"]]){
        id source=window[@"source"];return [source isKindOfClass:NSDictionary.class]&&[source[@"identity"]isEqual:effect[@"identity"]]&&[source[@"generation"]isEqual:effect[@"generation"]];
    }
    return NO;
}
- (void)complete:(NSDictionary *)effect epoch:(uint64_t)epoch success:(BOOL)success {
    [self answer:effect epoch:epoch with:@{@"op":@"focus_result",@"success":success?@YES:@NO}];
}
// The controller's pending request is answered once: the driver's result, or focus_logical when the driver is never asked.
- (void)answer:(NSDictionary *)effect epoch:(uint64_t)epoch with:(NSDictionary *)fields {
    if(![self current:epoch])return;
    self.work=nil;[self policy:@{@"kind":@"answer",@"effect_id":effect[@"effect_id"],@"success":fields[@"success"]?:@YES}];NSDictionary *snapshot=self.command(@{@"op":@"snapshot"});
    if([snapshot[@"focus"][@"pending_effect"]isEqual:effect]&&[self binding:effect snapshot:snapshot]){
        NSMutableDictionary *result=[effect mutableCopy];[result addEntriesFromDictionary:fields];self.command(result);[self advance];
        if([fields[@"success"]boolValue]){NSDictionary *id=effect[@"identity"];[self policy:@{@"kind":@"confirmed",@"identity":id}];}
        if(self.changed)self.changed();
    }
}
- (void)perform:(NSDictionary *)reply {
    if(!self.enabled||self.closed||!reply)return;
    NSDictionary *effect=[focusEffect(reply) copy];
    NSDictionary *decision=[self policy:@{@"kind":@"reply",@"reply":reply,@"protect":@(self.arrivalProtection&&self.arrivalProtection())}];
    if(effect||reply[@"effect"])[self cancelNativeClick];
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
    BOOL isCorrection=[decision[@"correction"]boolValue];
    NSDictionary *arrival=isCorrection&&[decision[@"observed"]isKindOfClass:NSDictionary.class]?decision[@"observed"]:nil;
    pid_t intruderPID=isCorrection?([decision[@"intruder_pid"]intValue]?:[arrival[@"pid"]intValue]):0,targetPID=[effect[@"identity"][@"pid"]intValue];
    uint64_t startedAt=isCorrection?[decision[@"started_at"]unsignedLongLongValue]:0;
    DWGuard authorization=isCorrection&&intruderPID>0&&[self.driver respondsToSelector:@selector(authorization:overridingPID:)]
        ?[self.driver authorization:effect[@"identity"] overridingPID:intruderPID]:[self.driver authorization:effect[@"identity"]];
    self.work=effect;
    self.worker(^{if(![self current:epoch])return;
        // A launch root may have opened its own sheet before this worker ran.
        // Its former root observation never authorizes overriding that child.
        BOOL stillArrival=YES;
        if(arrival)stillArrival=sameIdentity([self.driver observe],arrival);
        else if(intruderPID>0){
            NSDictionary *obs=[self.driver observe];
            if(obs)stillArrival=[obs[@"pid"]intValue]==intruderPID||[obs[@"pid"]intValue]==targetPID;
            else if([self.driver respondsToSelector:@selector(frontmostPID)]){pid_t front=[self.driver frontmostPID];stillArrival=front==intruderPID||front==targetPID;}
        }
        BOOL success=stillArrival&&[self.driver select:effect[@"identity"] guard:^BOOL{return [self current:epoch]&&self.clock()<deadline&&authorization&&authorization();}];
        if(isCorrection&&getenv("INFINIFY_DEBUG")){
            uint64_t doneAt=self.clock();double bounceMs=startedAt&&doneAt>=startedAt?(double)(doneAt-startedAt)/1e6:0;
            fprintf(stderr,"debug: focus restore target_pid=%d target_wid=%u intruder_pid=%d success=%d bounce_ms=%.2f\n",(int)targetPID,[effect[@"identity"][@"wid"]unsignedIntValue],(int)(intruderPID?:[arrival[@"pid"]intValue]),(int)success,bounceMs);
        }
        self.main(^{[self complete:effect epoch:epoch success:success];});
    });
}
- (NSDictionary *)navigate:(NSDictionary *)command {
    if(!self.enabled||self.closed)return nil;
    [self cancelBackgroundArrival];[self cancelNativeClick];[self policy:@{@"kind":@"reset_restores"}];
    NSDictionary *reply=self.command(command);if(!reply)return nil;
    [self perform:reply];if(self.changed)self.changed();return reply;
}
- (void)clearBackgroundArrival { if(!self.closed)[self policy:@{@"kind":@"clear_background"}]; }
- (void)cancelBackgroundArrival {
    if(self.closed)return;
    NSDictionary *decision=[self policy:@{@"kind":@"cancel_background"}];
    if([decision[@"cancel_work"]boolValue]){[self cancelNativeClick];[self advance];self.held=0;}
}
- (NSDictionary *)policy:(NSDictionary *)fact {
    return self.command(@{@"op":@"focus_policy",@"timestamp_ns":@(self.clock()),@"filter":@(self.filterUnsolicitedActivations),@"focus_allowed":@(self.focusAllowed),@"fact":fact});
}
- (void)noteSystemSwitchHeld:(BOOL)held {
    if(self.closed)return;
    [self consumePolicy:[self policy:@{@"kind":@"switch",@"held":@(held)}]];
}
- (void)noteSystemUIIntent {
    if(self.closed)return;
    [self consumePolicy:[self policy:@{@"kind":@"system_ui"}]];
}
- (void)noteLaunchIntentForBundle:(NSString *)bundle {
    if(self.closed||!bundle.length)return;
    [self consumePolicy:[self policy:@{@"kind":@"launch_intent",@"bundle":bundle}]];
}
- (void)noteWindowClick:(NSNumber *)window {
    if(!self.closed)[self consumePolicy:[self policy:@{@"kind":@"window_click",@"window":window?:NSNull.null}]];
}
- (NSDictionary *)attach:(NSDictionary *)command arrived:(BOOL)arrived adopted:(BOOL)adopted utility:(BOOL)utility {
    if(arrived&&adopted&&self.filterUnsolicitedActivations&&!utility){
        NSDictionary *decision=[self policy:@{@"kind":@"window_arrived",@"identity":command[@"identity"],@"bundle":command[@"bundle_id"]}];
        [self consumePolicy:decision];
        NSMutableDictionary *attach=[command mutableCopy];
        // Previously a nil authorizeProcess reply meant NO authorization.
        attach[@"unsolicited"]=decision?decision[@"unsolicited"]:@YES;
        return self.command(attach);
    }
    return self.command(command);
}
- (void)application:(pid_t)pid birth:(NSArray<NSNumber *> *)birth bundle:(NSString *)bundle activated:(BOOL)activated at:(uint64_t)at {
    if(pid<=0||birth.count!=2)return;
    NSDictionary *decision=[self policy:@{@"kind":@"application",@"process":@{@"pid":@(pid),@"birth_sec":birth[0],@"birth_usec":birth[1]},@"bundle":bundle?:NSNull.null,@"event_at":@(at),@"activated":@(activated)}];
    [self consumePolicy:decision];
    if([decision[@"observe"]boolValue])[self observe];
}
- (void)noteApplicationLaunched:(pid_t)pid birth:(NSArray<NSNumber *> *)birth bundle:(NSString *)bundle at:(uint64_t)at {
    if(!self.filterUnsolicitedActivations||!self.enabled||self.closed)return;
    [self application:pid birth:birth bundle:bundle activated:NO at:at];
}
- (void)noteApplicationActivated:(pid_t)pid birth:(NSArray<NSNumber *> *)birth bundle:(NSString *)bundle regular:(BOOL)regular at:(uint64_t)at {
    if(!self.filterUnsolicitedActivations||!self.enabled||self.closed||!regular)return;
    [self application:pid birth:birth bundle:bundle activated:YES at:at];
}
- (void)consumePolicy:(NSDictionary *)decision {
    if([decision[@"cancel_work"]boolValue]){self.held=0;[self cancelNativeClick];[self advance];}
    if([decision[@"advance"]boolValue]){[self cancelNativeClick];[self advance];}
    if([decision[@"reply"]isKindOfClass:NSDictionary.class])[self perform:decision[@"reply"]];
    if([decision[@"changed"]boolValue]&&self.changed)self.changed();
}
- (void)hold:(NSUInteger)modifiers { self.held=modifiers; }
- (BOOL)poll:(NSUInteger)down {
    if(!self.enabled||self.closed||!self.held)return NO;
    if((down&self.held)==self.held)return YES;
    self.held=0;[self releaseCycle];return NO;
}
- (void)releaseCycle { if(self.enabled&&!self.closed)self.command(@{@"op":@"end_focus_cycle"}); }
- (void)beginNativeClick:(NSDictionary *)binding output:(NSNumber *)output {
    [self cancelNativeClick];
    if(!self.enabled||self.closed||!self.focusAllowed||!output)return;
    NSDictionary *snapshot=self.command(@{@"op":@"snapshot"}),*pose=nil;
    for(NSDictionary *view in snapshot[@"outputs"])if([view[@"id"]isEqual:output])pose=@{@"camera":view[@"camera"],@"zoom":view[@"zoom"],@"screen_bounds":view[@"screen_bounds"]};
    if(!pose||![self binding:binding snapshot:snapshot])return;
    [self cancelFocus];
    self.command(@{@"op":@"cancel_navigation",@"output":output});
    NSMutableDictionary *click=[binding mutableCopy];click[@"output"]=output;self.nativeClick=click.copy;
    self.nativeClickPose=pose;self.nativeClickPoll=0;
    [self observe];
}
- (void)endNativeClick:(NSDictionary *)binding completed:(BOOL)completed {
    NSDictionary *click=self.nativeClick;
    if(!click||![click[@"window"]isEqual:binding[@"window"]]||![click[@"generation"]isEqual:binding[@"generation"]]||!sameIdentity(click[@"identity"],binding[@"identity"]))return;
    // Reconciliation can finish the native geometry hold after the real up.
    // It must not overwrite that already classified physical completion.
    if(self.nativeClickReleased)return;
    self.nativeClickReleased=YES;self.nativeClickCompleted=completed;self.nativeClickDeadline=self.clock()+1500000000;
    [self observe];
}
// Runs before duplicate-focus suppression: a click on an already focused root
// still needs its optional release navigation. The observed identity is the
// authority; the press alone never claims focus or calls the native driver.
- (BOOL)observeNativeClick:(NSDictionary *)match snapshot:(NSDictionary *)snapshot {
    NSDictionary *click=self.nativeClick;if(!click)return NO;NSDictionary *output=nil;
    for(NSDictionary *view in snapshot[@"outputs"])if([view[@"id"]isEqual:click[@"output"]])output=view;
    if(!self.focusAllowed||!output||![self binding:click snapshot:snapshot]||(self.nativeClickReleased&&self.clock()>self.nativeClickDeadline)){[self cancelNativeClick];return NO;}
    if(![click[@"window"]isEqual:match[@"window"]]||![click[@"generation"]isEqual:match[@"generation"]]||!sameIdentity(click[@"identity"],match[@"identity"])){
        // The worker can read the formerly focused app before AppKit receives
        // the untouched down. Do not spend this press on that earlier focus.
        return !self.nativeClickConfirmed;
    }
    if(!self.nativeClickConfirmed){
        self.nativeClickConfirmed=YES;[self advance];
        NSMutableDictionary *c=[match mutableCopy];c[@"op"]=@"activate";c[@"cause"]=@"click";c[@"output"]=click[@"output"];
        NSDictionary *reply=self.command(c),*effect=focusEffect(reply);
        if(effect)[self complete:effect epoch:self.epoch success:YES];
        else if(!reply){[c removeObjectsForKeys:@[@"cause",@"output"]];c[@"op"]=@"observe_focus";self.command(c);}
    }
    if(self.nativeClickReleased){
        for(NSString *key in @[@"camera",@"zoom",@"screen_bounds"])if(![output[key]isEqual:self.nativeClickPose[key]])self.nativeClickCompleted=NO;
        if(self.nativeClickCompleted&&self.nativeClickReleaseReady&&!self.nativeClickReleaseReady(click))return YES;
        BOOL completed=self.nativeClickCompleted;[self cancelNativeClick];
        if(completed){NSMutableDictionary *c=[click mutableCopy];c[@"op"]=@"activate";c[@"cause"]=@"click_release";self.command(c);}
    }
    if(self.changed)self.changed();return YES;
}
- (void)observe {
    if(!self.enabled||self.closed)return;
    // A focus event may arrive while a read is under way, and that read may have looked before the change: one more follows it.
    if(self.observing){self.again=YES;return;}
    self.observing=YES;
    uint64_t epoch=self.epoch;
    DWObservedBinding resolve=self.observationBinding?self.observationBinding():nil;
    self.worker(^{NSDictionary *actual=[self.driver observe];uint64_t observedAt=self.clock();NSDictionary *family=actual&&resolve?resolve(actual):nil;self.main(^{
        // After this turn: what this read reports is followed first, so the next read is judged against the focus that leaves.
        self.observing=NO;if(self.again){self.again=NO;self.main(^{[self observe];});}
        if(!actual||![self current:epoch])return;
        // Physical-click geometry is driver work; all ordinary focus and
        // arrival classification stays in the controller, without snapshots.
        if(!family&&self.nativeClick){
            NSDictionary *snapshot=self.command(@{@"op":@"snapshot"}),*match=nil;
            for(NSDictionary *w in snapshot[@"windows"]){id source=w[@"source"];
                if([source isKindOfClass:NSDictionary.class]&&sameIdentity(source[@"identity"],actual)){match=@{@"window":w[@"window"],@"identity":source[@"identity"],@"generation":source[@"generation"]};break;}}
            if(!match){for(NSDictionary *w in snapshot[@"windows"]){id source=w[@"source"];if(![source isKindOfClass:NSDictionary.class])continue;NSMutableDictionary *plain=[source[@"identity"]mutableCopy];[plain removeObjectForKey:@"owner"];if(sameIdentity(plain,actual))return;}}
            if(self.clock()-observedAt>100000000)return;
            if([self observeNativeClick:match snapshot:snapshot])return;
        }
        NSDictionary *decision=[self policy:@{@"kind":@"observation",@"actual":actual,@"family":family?:NSNull.null,@"event_at":@(observedAt),@"output":(self.output?self.output():nil)?:NSNull.null}];
        [self consumePolicy:decision];
    });});
}
- (BOOL)frame {
    if(!self.enabled||self.closed)return NO;
    if(self.nativeClick&&self.nativeClickReleased){
        uint64_t now=self.clock();
        if(now>self.nativeClickDeadline)[self cancelNativeClick];
        else if(!self.observing&&now-self.nativeClickPoll>=50000000&&(!self.nativeClickCompleted||!self.nativeClickReleaseReady||self.nativeClickReleaseReady(self.nativeClick))){self.nativeClickPoll=now;[self observe];}
    }
    NSDictionary *result=self.command(@{@"op":@"tick_navigation",@"timestamp_ns":@(self.clock())});
    if([result[@"changed_outputs"]count]&&self.changed)self.changed();
    BOOL active=[result[@"needs_frames"]boolValue];if(!active&&self.flying&&self.settled)self.settled();self.flying=active;return active;
}
@end
