// SPDX-License-Identifier: GPL-3.0-or-later
#import "DWNavigationCoordinator.h"
#include <stdio.h>
#include <stdlib.h>
// These conversions describe the independently observed native driver's identity
// schema, not controller scene/reply dictionaries. Projections are made on main.
static DWIdentity *observedIdentity(NSDictionary *value) {
    if(!value)return nil;
    id owner=value[@"owner"];if(owner==NSNull.null)owner=nil;
    return [DWIdentity identityWithPID:value[@"pid"] birthSeconds:value[@"birth_sec"] birthMicroseconds:value[@"birth_usec"] windowID:value[@"wid"] owner:owner];
}
static NSDictionary *driverIdentity(DWIdentity *value) {
    if(!value)return nil;
    NSMutableDictionary *native=[@{@"pid":value.pid,@"birth_sec":value.birthSeconds,@"birth_usec":value.birthMicroseconds,@"wid":value.wid}mutableCopy];
    if(value.owner)native[@"owner"]=value.owner;return native.copy;
}
static BOOL sameIdentity(DWIdentity *a,DWIdentity *b) {
    return [a.pid isEqual:b.pid]&&[a.birthSeconds isEqual:b.birthSeconds]&&[a.birthMicroseconds isEqual:b.birthMicroseconds]&&[a.wid isEqual:b.wid]
        &&((!a.owner&&!b.owner)||[a.owner isEqual:b.owner]);
}
static BOOL sameNativeIdentity(NSDictionary *a,NSDictionary *b) {
    for(NSString *key in @[@"pid",@"birth_sec",@"birth_usec",@"wid"])if(![a[key]isEqual:b[key]])return NO;
    BOOL aOwner=a[@"owner"]&&a[@"owner"]!=NSNull.null,bOwner=b[@"owner"]&&b[@"owner"]!=NSNull.null;
    return aOwner==bOwner&&(!aOwner||[a[@"owner"]isEqual:b[@"owner"]]);
}
@interface DWNavigationCoordinator () <DWNavigationExecution>
@property id<DWNavigationController> controller;
@property DWFocusPolicyContext *policyContext;
@property id<DWNavigationDriver> driver;
@property (copy) uint64_t (^clock)(void);
@property (copy) DWSchedule worker, main;
@property NSLock *lock;
@property uint64_t epoch;
@property BOOL closed, observing, flying;
@property BOOL again;
@property DWEffect *work;
@property NSUInteger held;
@property DWSourceBinding *nativeClick;
@property NSNumber *nativeClickOutput;
@property DWOutput *nativeClickPose;
@property BOOL nativeClickReleased,nativeClickCompleted,nativeClickConfirmed;
@property uint64_t nativeClickDeadline,nativeClickPoll;
@end
@implementation DWNavigationCoordinator
- (instancetype)initWithController:(id<DWNavigationController>)controller driver:(id<DWNavigationDriver>)driver clock:(uint64_t (^)(void))clock worker:(DWSchedule)worker main:(DWSchedule)main {
    if((self=[super init])){
        _controller=controller;_driver=driver;_clock=[clock copy];_worker=[worker copy];_main=[main copy];_lock=[NSLock new];
        __weak DWNavigationCoordinator *weak=self;
        _policyContext=[[DWFocusPolicyContext alloc]initWithClock:clock filter:^BOOL{return weak.filterUnsolicitedActivations;} focusAllowed:^BOOL{return weak.focusAllowed;}];
    }return self;
}
- (uint64_t)nowNanoseconds { return self.clock?self.clock():0; }
- (BOOL)current:(uint64_t)epoch { [self.lock lock];BOOL valid=!self.closed&&self.epoch==epoch;[self.lock unlock];return valid; }
- (uint64_t)advance { self.work=nil;[self.lock lock];uint64_t epoch=++self.epoch;[self.lock unlock];return epoch; }
- (void)cancelNativeClick { self.nativeClick=nil;self.nativeClickOutput=nil;self.nativeClickPose=nil;self.nativeClickReleased=self.nativeClickCompleted=self.nativeClickConfirmed=NO; }
- (void)cancelFocus {
    [self clearBackgroundArrival];[self cancelNativeClick];[self advance];self.held=0;
    if(!self.closed&&self.enabled)[self.controller navigationCancelFocusCycle];
}
- (void)interrupt { [self cancelBackgroundArrival];if(self.work)[self cancelFocus]; }
- (void)invalidate {
    [self cancelFocus];if(!self.closed&&self.enabled)for(DWOutput *output in [self.controller navigationScene].outputs)[self.controller navigationCancelOnOutput:output.identifier];
}
- (void)shutdown {
    [self invalidate];if(!self.closed)[self.controller resetFocusPolicyWithContext:self.policyContext];
    [self.lock lock];self.closed=YES;[self.lock unlock];self.controller=nil;self.changed=nil;self.settled=nil;self.output=nil;self.observationBinding=nil;self.nativeClickReleaseReady=nil;self.arrivalProtection=nil;
}
- (BOOL)binding:(DWEffect *)effect snapshot:(DWScene *)snapshot {
    DWWindow *window=[snapshot windowWithID:effect.window];DWSource *source=window.source;
    return source&&[source.identity isEqual:effect.identity]&&[source.generation isEqual:effect.generation];
}
- (void)complete:(DWEffect *)effect epoch:(uint64_t)epoch success:(BOOL)success {
    [self answer:effect epoch:epoch logical:NO success:success];
}
// The policy answer fact, snapshot validation, result, advance and confirmation
// are separate synchronous calls, matching the old command path exactly.
- (void)answer:(DWEffect *)effect epoch:(uint64_t)epoch logical:(BOOL)logical success:(BOOL)success {
    if(![self current:epoch])return;
    self.work=nil;[self.controller focusAnswerBegan:effect success:logical?YES:success context:self.policyContext];
    DWScene *snapshot=[self.controller navigationScene];
    if([snapshot.focus.pendingEffect isEqual:effect]&&[self binding:effect snapshot:snapshot]){
        [self.controller navigationAnswerFocus:effect logical:logical success:success];[self advance];
        if(success&&!logical)[self.controller focusConfirmed:effect.identity context:self.policyContext];
        if(self.changed)self.changed();
    }
}
- (void)perform:(DWControllerReply *)reply {
    if(!self.enabled||self.closed||!reply)return;
    if(![self.controller navigationEffectForReply:reply]&&![reply.background boolValue]&&![reply.focusOnOpenSuppressed boolValue]){
        [self perform:reply decision:nil];return;
    }
    DWFocusCorrection *decision=[self.controller prepareFocusReply:reply protect:self.arrivalProtection&&self.arrivalProtection() context:self.policyContext];
    [self perform:reply decision:decision];
}
- (void)perform:(DWControllerReply *)reply decision:(DWFocusCorrection *)decision {
    if(!self.enabled||self.closed||!reply)return;
    DWEffect *effect=[[self.controller navigationEffectForReply:reply]copy];
    BOOL hasEffect=reply.effectPresence!=DWValueAbsent;
    if(effect||hasEffect)[self cancelNativeClick];
    if(!effect){
        if(hasEffect||(self.work&&![[self.controller navigationScene].focus.pendingEffect isEqual:self.work]))[self advance];
        return;
    }
    uint64_t epoch=[self advance],deadline=self.clock()+1500000000;
    if(!self.focusAllowed){[self answer:effect epoch:epoch logical:YES success:NO];return;}
    if(effect.identity.ownerPresence!=DWValueAbsent&&effect.identity.ownerPresence!=DWValueNull){[self complete:effect epoch:epoch success:NO];return;}
    BOOL isCorrection=[decision.correction boolValue];
    DWIdentity *arrivalIdentity=isCorrection?decision.observed:nil;
    NSDictionary *arrival=driverIdentity(arrivalIdentity),*target=driverIdentity(effect.identity);
    pid_t intruderPID=isCorrection?([decision.intruderPID intValue]?:[arrivalIdentity.pid intValue]):0,targetPID=[effect.identity.pid intValue];
    uint64_t startedAt=isCorrection?[decision.startedAt unsignedLongLongValue]:0;
    DWGuard authorization=isCorrection&&intruderPID>0&&[self.driver respondsToSelector:@selector(authorization:overridingPID:)]
        ?[self.driver authorization:target overridingPID:intruderPID]:[self.driver authorization:target];
    self.work=effect;
    self.worker(^{if(![self current:epoch])return;
        BOOL stillArrival=YES;
        if(arrival)stillArrival=sameNativeIdentity([self.driver observe],arrival);
        else if(intruderPID>0){
            NSDictionary *obs=[self.driver observe];
            if(obs)stillArrival=[obs[@"pid"]intValue]==intruderPID||[obs[@"pid"]intValue]==targetPID;
            else if([self.driver respondsToSelector:@selector(frontmostPID)]){pid_t front=[self.driver frontmostPID];stillArrival=front==intruderPID||front==targetPID;}
        }
        BOOL success=stillArrival&&[self.driver select:target guard:^BOOL{return [self current:epoch]&&self.clock()<deadline&&authorization&&authorization();}];
        if(isCorrection&&getenv("INFINIFY_DEBUG")){
            uint64_t doneAt=self.clock();double bounceMs=startedAt&&doneAt>=startedAt?(double)(doneAt-startedAt)/1e6:0;
            fprintf(stderr,"debug: focus restore target_pid=%d target_wid=%u intruder_pid=%d success=%d bounce_ms=%.2f\n",(int)targetPID,[target[@"wid"]unsignedIntValue],(int)(intruderPID?:[arrival[@"pid"]intValue]),(int)success,bounceMs);
        }
        self.main(^{[self complete:effect epoch:epoch success:success];});
    });
}
- (DWControllerReply *)navigate:(DWControllerReply *(^)(void))command {
    if(!self.enabled||self.closed)return nil;
    [self cancelBackgroundArrival];[self cancelNativeClick];[self.controller resetFocusRestoresWithContext:self.policyContext];
    DWControllerReply *reply=[self.controller navigationExecute:command];if(!reply)return nil;
    [self perform:reply];if(self.changed)self.changed();return reply;
}
- (void)clearBackgroundArrival { if(!self.closed)[self.controller clearBackgroundArrivalWithContext:self.policyContext]; }
- (void)cancelBackgroundArrival {
    if(self.closed)return;
    [self.controller cancelBackgroundArrivalWithContext:self.policyContext execution:self];
}
- (void)noteSystemSwitchHeld:(BOOL)held {
    if(self.closed)return;
    [self.controller systemSwitchHeld:held context:self.policyContext execution:self];
}
- (void)noteSystemUIIntent {
    if(self.closed)return;
    [self.controller systemUIIntentWithContext:self.policyContext execution:self];
}
- (void)noteLaunchIntentForBundle:(NSString *)bundle {
    if(self.closed||!bundle.length)return;
    [self.controller launchIntentForBundle:bundle context:self.policyContext execution:self];
}
- (void)noteWindowClick:(NSNumber *)window {
    if(!self.closed)[self.controller windowClicked:window context:self.policyContext execution:self];
}
- (DWControllerReply *)attach:(DWAttachRequest *)request arrived:(BOOL)arrived adopted:(BOOL)adopted utility:(BOOL)utility {
    return [self.controller attach:request arrived:arrived adopted:adopted utility:utility context:self.policyContext execution:self];
}
- (void)application:(pid_t)pid birth:(NSArray<NSNumber *> *)birth bundle:(NSString *)bundle activated:(BOOL)activated at:(uint64_t)at {
    if(pid<=0||birth.count!=2)return;
    if([self.controller applicationPID:pid birthSeconds:birth[0] microseconds:birth[1] bundle:bundle activated:activated eventAt:at context:self.policyContext execution:self])[self observe];
}
- (void)noteApplicationLaunched:(pid_t)pid birth:(NSArray<NSNumber *> *)birth bundle:(NSString *)bundle at:(uint64_t)at {
    if(!self.filterUnsolicitedActivations||!self.enabled||self.closed)return;
    [self application:pid birth:birth bundle:bundle activated:NO at:at];
}
- (void)noteApplicationActivated:(pid_t)pid birth:(NSArray<NSNumber *> *)birth bundle:(NSString *)bundle regular:(BOOL)regular at:(uint64_t)at {
    if(!self.filterUnsolicitedActivations||!self.enabled||self.closed||!regular)return;
    [self application:pid birth:birth bundle:bundle activated:YES at:at];
}
// Five synchronous actions. The controller alone interprets policy steps.
- (uint64_t)currentEpoch { return self.epoch; }
- (void)navigationCancelNativeClick { [self cancelNativeClick]; }
- (void)navigationAdvanceReleasingHold:(BOOL)releaseHold { [self advance];if(releaseHold)self.held=0; }
- (void)navigationAnswerEffect:(DWEffect *)effect logical:(BOOL)logical epoch:(uint64_t)epoch {
    if(logical)[self answer:effect epoch:epoch logical:YES success:NO];else [self complete:effect epoch:epoch success:YES];
}
- (void)navigationPerformReply:(DWControllerReply *)reply correction:(DWFocusCorrection *)correction prepared:(BOOL)prepared {
    if(prepared)[self perform:reply decision:correction];else [self perform:reply];
}
- (void)navigationChanged { if(self.changed)self.changed(); }
- (void)hold:(NSUInteger)modifiers { self.held=modifiers; }
- (BOOL)poll:(NSUInteger)down {
    if(!self.enabled||self.closed||!self.held)return NO;
    if((down&self.held)==self.held)return YES;
    self.held=0;[self releaseCycle];return NO;
}
- (void)releaseCycle { if(self.enabled&&!self.closed)[self.controller navigationEndFocusCycle]; }
- (void)beginNativeClick:(DWSourceBinding *)binding output:(NSNumber *)output {
    [self cancelNativeClick];
    if(!self.enabled||self.closed||!self.focusAllowed||!output)return;
    DWScene *snapshot=[self.controller navigationScene];DWOutput *pose=[snapshot outputWithID:output];
    DWWindow *window=[snapshot windowWithID:binding.window];DWSource *source=window.source;
    if(!pose||!source||![source.identity isEqual:binding.identity]||![source.generation isEqual:binding.generation])return;
    [self cancelFocus];[self.controller navigationCancelOnOutput:output];
    self.nativeClick=binding;self.nativeClickOutput=output;self.nativeClickPose=pose;self.nativeClickPoll=0;
    [self observe];
}
- (void)endNativeClick:(DWSourceBinding *)binding completed:(BOOL)completed {
    DWSourceBinding *click=self.nativeClick;
    if(!click||![click.window isEqual:binding.window]||![click.generation isEqual:binding.generation]||!sameIdentity(click.identity,binding.identity))return;
    if(self.nativeClickReleased)return;
    self.nativeClickReleased=YES;self.nativeClickCompleted=completed;self.nativeClickDeadline=self.clock()+1500000000;
    [self observe];
}
- (BOOL)observeNativeClick:(DWSourceBinding *)match snapshot:(DWScene *)snapshot {
    DWSourceBinding *click=self.nativeClick;if(!click)return NO;NSNumber *clickOutput=self.nativeClickOutput;
    DWOutput *output=[snapshot outputWithID:clickOutput];
    DWSource *source=[snapshot windowWithID:click.window].source;
    if(!self.focusAllowed||!output||!source||![source.identity isEqual:click.identity]||![source.generation isEqual:click.generation]||(self.nativeClickReleased&&self.clock()>self.nativeClickDeadline)){[self cancelNativeClick];return NO;}
    if(![click.window isEqual:match.window]||![click.generation isEqual:match.generation]||!sameIdentity(click.identity,match.identity))return !self.nativeClickConfirmed;
    if(!self.nativeClickConfirmed){
        self.nativeClickConfirmed=YES;[self advance];
        DWControllerReply *reply=[self.controller navigationActivateBinding:match cause:DWNavigationActivationClick output:clickOutput];
        DWEffect *effect=[self.controller navigationEffectForReply:reply];
        if(effect)[self complete:effect epoch:self.epoch success:YES];
        else if(!reply)[self.controller navigationObserveBinding:match];
    }
    if(self.nativeClickReleased){
        if(![output hasSamePoseAsOutput:self.nativeClickPose])self.nativeClickCompleted=NO;
        if(self.nativeClickCompleted&&self.nativeClickReleaseReady&&!self.nativeClickReleaseReady(click,clickOutput))return YES;
        BOOL completed=self.nativeClickCompleted;[self cancelNativeClick];
        if(completed)[self.controller navigationActivateBinding:click cause:DWNavigationActivationClickRelease output:clickOutput];
    }
    if(self.changed)self.changed();return YES;
}
- (void)observe {
    if(!self.enabled||self.closed)return;
    if(self.observing){self.again=YES;return;}
    self.observing=YES;
    uint64_t epoch=self.epoch;
    DWObservedBinding resolve=self.observationBinding?self.observationBinding():nil;
    self.worker(^{NSDictionary *nativeActual=[self.driver observe];uint64_t observedAt=self.clock();DWSourceBinding *family=nativeActual&&resolve?resolve(nativeActual):nil;self.main(^{
        self.observing=NO;if(self.again){self.again=NO;self.main(^{[self observe];});}
        if(!nativeActual||![self current:epoch])return;
        DWIdentity *actual=observedIdentity(nativeActual);
        if(!family&&self.nativeClick){
            DWScene *snapshot=[self.controller navigationScene];DWSourceBinding *match=nil;
            for(DWWindow *window in snapshot.windows){DWSource *source=window.source;
                if(source&&sameIdentity(source.identity,actual)){match=[DWSourceBinding bindingWithWindow:window.window identity:source.identity generation:source.generation];break;}}
            if(!match){for(DWWindow *window in snapshot.windows){DWSource *source=window.source;if(!source)continue;
                DWIdentity *identity=source.identity;
                if([identity.pid isEqual:actual.pid]&&[identity.birthSeconds isEqual:actual.birthSeconds]&&[identity.birthMicroseconds isEqual:actual.birthMicroseconds]&&[identity.wid isEqual:actual.wid]&&!actual.owner)return;}}
            if(self.clock()-observedAt>100000000)return;
            if([self observeNativeClick:match snapshot:snapshot])return;
        }
        [self.controller observeIdentity:actual familyBinding:family eventAt:observedAt output:self.output?self.output():nil capturedEpoch:epoch context:self.policyContext execution:self];
    });});
}
- (BOOL)frame {
    if(!self.enabled||self.closed)return NO;
    if(self.nativeClick&&self.nativeClickReleased){
        uint64_t now=self.clock();
        if(now>self.nativeClickDeadline)[self cancelNativeClick];
        else if(!self.observing&&now-self.nativeClickPoll>=50000000&&(!self.nativeClickCompleted||!self.nativeClickReleaseReady||self.nativeClickReleaseReady(self.nativeClick,self.nativeClickOutput))){self.nativeClickPoll=now;[self observe];}
    }
    DWControllerReply *result=[self.controller navigationTickAt:self.clock()];
    if(result.changedOutputs.count&&self.changed)self.changed();
    BOOL active=[result.needsFrames boolValue];if(!active&&self.flying&&self.settled)self.settled();self.flying=active;return active;
}
@end
