// SPDX-License-Identifier: GPL-3.0-or-later
#import "DWNavigationCoordinator.h"
#include <stdio.h>
#include <stdlib.h>
// Option 3A: a physical click inside the confirmed focused window up to 0.75 s
// before another application activates or launches counts as owner intent (e.g.
// clicking a link). Set to 0 to disable.
static const uint64_t DWFocusedWindowClickIntentWindowNs = 750000000ULL;
static BOOL DWFocusedWindowClickAuthorizesSwitch(uint64_t clickAt,uint64_t eventAt) {
    return DWFocusedWindowClickIntentWindowNs>0&&clickAt>0&&eventAt>=clickAt&&eventAt-clickAt<=DWFocusedWindowClickIntentWindowNs;
}
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
@property NSDictionary *familyObservation;
@property NSMutableDictionary<NSNumber *,NSDictionary *> *backgroundArrivals;
@property NSDictionary *backgroundTarget,*backgroundCorrection,*backgroundObserved;
@property NSNumber *backgroundOutput;
@property uint64_t backgroundDeadline;
@property pid_t backgroundIntruderPID;
@property uint64_t backgroundRestoreStartedAt;
@property BOOL initialObservationDone,cmdTabHeld;
@property uint64_t systemIntentUntil,focusedWindowClickAt;
@property NSDictionary *confirmedFocusProcess;
@property NSMutableDictionary<NSString *,NSNumber *> *authorizedBundles;
@property NSMutableDictionary<NSNumber *,NSDictionary *> *authorizedProcesses;
@property NSMutableDictionary<NSNumber *,NSDictionary *> *intruderRestores;
@property NSDictionary *nativeClick;
@property NSDictionary *nativeClickPose;
@property BOOL nativeClickReleased,nativeClickCompleted,nativeClickConfirmed;
@property uint64_t nativeClickDeadline;
@property uint64_t nativeClickPoll;
@end
@implementation DWNavigationCoordinator
- (instancetype)initWithCommand:(DWCommand)c driver:(id<DWNavigationDriver>)d clock:(uint64_t (^)(void))clock worker:(DWSchedule)worker main:(DWSchedule)main {
    if((self=[super init])){_command=[c copy];_driver=d;_clock=[clock copy];_worker=[worker copy];_main=[main copy];_lock=[NSLock new];_authorizedBundles=[NSMutableDictionary dictionary];_authorizedProcesses=[NSMutableDictionary dictionary];_intruderRestores=[NSMutableDictionary dictionary];}return self;
}
- (uint64_t)nowNanoseconds { return self.clock?self.clock():0; }
- (BOOL)current:(uint64_t)epoch { [self.lock lock];BOOL valid=!self.closed&&self.epoch==epoch;[self.lock unlock];return valid; }
- (uint64_t)advance { self.work=nil;[self.lock lock];uint64_t epoch=++self.epoch;[self.lock unlock];return epoch; }
- (void)cancelNativeClick { self.nativeClick=nil;self.nativeClickPose=nil;self.nativeClickReleased=self.nativeClickCompleted=self.nativeClickConfirmed=NO; }
- (void)cancelFocus { [self clearBackgroundArrival];[self cancelNativeClick];[self advance];self.held=0;if(!self.closed&&self.enabled)self.command(@{@"op":@"cancel_focus_cycle"}); }
- (void)interrupt { [self cancelBackgroundArrival];if(self.work)[self cancelFocus]; }
- (void)invalidate { [self cancelFocus];if(!self.closed&&self.enabled)for(NSDictionary *o in self.command(@{@"op":@"snapshot"})[@"outputs"])self.command(@{@"op":@"cancel_navigation",@"output":o[@"id"]}); }
- (void)shutdown { [self invalidate];[self.lock lock];self.closed=YES;[self.lock unlock];self.command=nil;self.changed=nil;self.settled=nil;self.output=nil;self.observationBinding=nil;self.familyObservation=nil;self.nativeClickReleaseReady=nil; }
- (BOOL)binding:(NSDictionary *)effect snapshot:(NSDictionary *)snapshot {
    for(NSDictionary *window in snapshot[@"windows"])if([window[@"window"]isEqual:effect[@"window"]]){
        id source=window[@"source"];return [source isKindOfClass:NSDictionary.class]&&[source[@"identity"]isEqual:effect[@"identity"]]&&[source[@"generation"]isEqual:effect[@"generation"]];
    }
    return NO;
}
- (void)complete:(NSDictionary *)effect epoch:(uint64_t)epoch success:(BOOL)success {
    if([self current:epoch]&&[effect isEqual:self.backgroundCorrection]&&!success&&self.backgroundIntruderPID>0){
        self.intruderRestores[@(self.backgroundIntruderPID)]=@{@"count":@2,@"since":@(self.clock()),@"failed":@YES};
    }
    [self answer:effect epoch:epoch with:@{@"op":@"focus_result",@"success":success?@YES:@NO}];
}
// The controller's pending request is answered once: the driver's result, or focus_logical when the driver is never asked.
- (void)answer:(NSDictionary *)effect epoch:(uint64_t)epoch with:(NSDictionary *)fields {
    if(![self current:epoch])return;
    self.work=nil;if([effect isEqual:self.backgroundCorrection])[self clearBackgroundArrival];NSDictionary *snapshot=self.command(@{@"op":@"snapshot"});
    if([snapshot[@"focus"][@"pending_effect"]isEqual:effect]&&[self binding:effect snapshot:snapshot]){
        NSMutableDictionary *result=[effect mutableCopy];[result addEntriesFromDictionary:fields];self.command(result);[self advance];
        if([fields[@"success"]boolValue]){NSDictionary *id=effect[@"identity"];self.confirmedFocusProcess=@{@"pid":id[@"pid"],@"birth_sec":id[@"birth_sec"],@"birth_usec":id[@"birth_usec"]};}
        if(self.changed)self.changed();
    }
}
- (void)perform:(NSDictionary *)reply {
    if(!self.enabled||self.closed||!reply)return;
    NSDictionary *effect=[focusEffect(reply) copy];
    if(effect&&![effect isEqual:self.backgroundCorrection]){[self clearBackgroundArrival];[self.intruderRestores removeAllObjects];}
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
    BOOL isCorrection=[effect isEqual:self.backgroundCorrection];
    NSDictionary *arrival=isCorrection?self.backgroundObserved:nil;
    pid_t intruderPID=isCorrection?(self.backgroundIntruderPID?:[arrival[@"pid"]intValue]):0,targetPID=[effect[@"identity"][@"pid"]intValue];
    uint64_t startedAt=isCorrection?self.backgroundRestoreStartedAt:0;
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
    [self cancelBackgroundArrival];[self cancelNativeClick];[self.intruderRestores removeAllObjects];
    NSDictionary *reply=self.command(command);if(!reply)return nil;
    [self perform:reply];if(self.changed)self.changed();return reply;
}
- (void)clearBackgroundArrival { self.backgroundArrivals=nil;self.backgroundTarget=nil;self.backgroundCorrection=nil;self.backgroundObserved=nil;self.backgroundOutput=nil;self.backgroundIntruderPID=0;self.backgroundRestoreStartedAt=0; }
- (void)cancelBackgroundArrival {
    BOOL correcting=self.backgroundCorrection&&[self.work isEqual:self.backgroundCorrection];
    [self clearBackgroundArrival];if(correcting)[self cancelFocus];
}
- (void)preserveBackgroundArrival:(NSDictionary *)reply {
    BOOL quiet=[reply[@"focus_on_open_suppressed"]boolValue];
    if(!self.enabled||self.closed||!self.focusAllowed||(![reply[@"background"]boolValue]&&!quiet))return;
    NSDictionary *snapshot=self.command(@{@"op":@"snapshot"}),*target=nil,*arrival=nil;NSNumber *output=nil;
    for(NSDictionary *view in snapshot[@"outputs"]){id full=view[@"fullscreen"];
        if([full isKindOfClass:NSDictionary.class]&&[full[@"window"]isEqual:snapshot[@"focus"][@"intent"]]){output=view[@"id"];break;}}
    if(!output&&!quiet)return;
    for(NSDictionary *window in snapshot[@"windows"]){id source=window[@"source"];if(![source isKindOfClass:NSDictionary.class])continue;
        NSDictionary *binding=@{@"window":window[@"window"],@"identity":source[@"identity"],@"generation":source[@"generation"]};
        if([window[@"window"]isEqual:snapshot[@"focus"][@"intent"]])target=binding;
        if([window[@"window"]isEqual:reply[@"window"]])arrival=binding;
    }
    if(!target||!arrival||[target[@"window"]isEqual:arrival[@"window"]])return;
    if(quiet){
        // Preserve a confirmed live focus, never promote an unconfirmed intent
        // or a stand-in into native correction authority.
        NSDictionary *focus=snapshot[@"focus"];id observed=focus[@"observed_native"],pending=focus[@"pending_effect"];
        BOOL sameCorrection=self.backgroundCorrection&&[pending isEqual:self.backgroundCorrection]&&[self.backgroundTarget isEqual:target];
        if(!sameCorrection&&(pending!=NSNull.null||![observed isKindOfClass:NSDictionary.class]||![observed[@"window"]isEqual:target[@"window"]]||![observed[@"generation"]isEqual:target[@"generation"]]||!sameIdentity(observed[@"identity"],target[@"identity"])))return;
    }
    // Changing from Fill-qualified to ordinary quiet protection retires the
    // entire former cohort, so quiet provenance cannot widen its older entries.
    BOOL sameOutput=self.backgroundOutput==output||[self.backgroundOutput isEqual:output];
    if(![self.backgroundTarget isEqual:target]||!sameOutput||self.clock()>self.backgroundDeadline){
        if(!self.backgroundCorrection)[self clearBackgroundArrival];
        if(!self.backgroundArrivals)self.backgroundArrivals=[NSMutableDictionary dictionary];
    }
    if(!self.backgroundArrivals)self.backgroundArrivals=[NSMutableDictionary dictionary];
    self.backgroundTarget=target;self.backgroundOutput=output;self.backgroundDeadline=self.clock()+1500000000;
    self.backgroundArrivals[arrival[@"window"]]=@{@"binding":arrival,@"deadline":@(self.backgroundDeadline)};
}
- (BOOL)observeBackgroundArrival:(NSDictionary *)match snapshot:(NSDictionary *)snapshot {
    if(!self.backgroundTarget)return NO;
    NSDictionary *target=self.backgroundTarget;BOOL fullscreen=self.backgroundOutput==nil;
    for(NSDictionary *view in snapshot[@"outputs"])if([view[@"id"]isEqual:self.backgroundOutput]){
        id full=view[@"fullscreen"];fullscreen=[full isKindOfClass:NSDictionary.class]&&[full[@"window"]isEqual:target[@"window"]];break;}
    if(!self.focusAllowed||self.clock()>self.backgroundDeadline||!fullscreen||![snapshot[@"focus"][@"intent"]isEqual:target[@"window"]]||![self binding:target snapshot:snapshot]){[self clearBackgroundArrival];return NO;}
    NSDictionary *entry=match?self.backgroundArrivals[match[@"window"]]:nil;
    NSDictionary *arrival=entry[@"binding"];
    if(entry&&!self.backgroundCorrection&&self.clock()>[entry[@"deadline"]unsignedLongLongValue]){[self.backgroundArrivals removeObjectForKey:match[@"window"]];return NO;}
    if(!arrival||![arrival isEqual:match]||![self binding:arrival snapshot:snapshot]){
        if(![match isEqual:target])[self clearBackgroundArrival];return NO;
    }
    if(self.backgroundCorrection){
        if([snapshot[@"focus"][@"pending_effect"]isEqual:self.backgroundCorrection])return YES;
        [self clearBackgroundArrival];return NO;
    }
    // Only this launch-time root observation asks for the preserved live focus.
    // Do not answer that different target from the newcomer's focus readback.
    NSDictionary *reply=self.command(@{@"op":@"focus",@"window":target[@"window"]});
    self.backgroundObserved=match[@"identity"];self.backgroundIntruderPID=[match[@"identity"][@"pid"]intValue];self.backgroundRestoreStartedAt=self.clock();
    self.backgroundCorrection=focusEffect(reply);if(!self.backgroundCorrection){[self clearBackgroundArrival];return NO;}
    self.backgroundDeadline=self.clock()+1500000000;[self perform:reply];if(self.changed)self.changed();return YES;
}
- (NSDictionary *)confirmedLiveFocusInSnapshot:(NSDictionary *)snapshot {
    NSDictionary *focus=snapshot[@"focus"];id observed=focus[@"observed_native"],intent=focus[@"intent"],pending=focus[@"pending_effect"];
    if(self.backgroundCorrection&&[pending isEqual:self.backgroundCorrection]&&self.backgroundTarget&&[intent isEqual:self.backgroundTarget[@"window"]]&&[self binding:self.backgroundTarget snapshot:snapshot])return self.backgroundTarget;
    if(pending!=NSNull.null||![observed isKindOfClass:NSDictionary.class]||![observed[@"window"]isEqual:intent])return nil;
    for(NSDictionary *w in snapshot[@"windows"]){id s=w[@"source"];
        if([w[@"window"]isEqual:intent]&&[s isKindOfClass:NSDictionary.class]&&[s[@"generation"]isEqual:observed[@"generation"]]&&sameIdentity(s[@"identity"],observed[@"identity"]))
            return @{@"window":w[@"window"],@"identity":s[@"identity"],@"generation":s[@"generation"]};
    }
    return nil;
}
- (void)pruneIntentsAt:(uint64_t)now {
    for(NSString *bundle in self.authorizedBundles.allKeys)if([self.authorizedBundles[bundle]unsignedLongLongValue]<now)[self.authorizedBundles removeObjectForKey:bundle];
    for(NSNumber *pid in self.authorizedProcesses.allKeys){
        NSDictionary *entry=self.authorizedProcesses[pid];
        if([entry[@"attach_until"]unsignedLongLongValue]<now&&[entry[@"activate_until"]unsignedLongLongValue]<now)[self.authorizedProcesses removeObjectForKey:pid];
    }
    for(NSNumber *pid in self.intruderRestores.allKeys){
        NSDictionary *entry=self.intruderRestores[pid];
        if(now>[entry[@"since"]unsignedLongLongValue]&&now-[entry[@"since"]unsignedLongLongValue]>5000000000ULL)[self.intruderRestores removeObjectForKey:pid];
    }
}
- (void)noteSystemSwitchHeld:(BOOL)held {
    if(self.closed)return;
    uint64_t now=self.clock();
    if(held){[self cancelBackgroundArrival];[self.intruderRestores removeAllObjects];self.cmdTabHeld=YES;self.systemIntentUntil=now+2500000000ULL;}
    else if(self.cmdTabHeld){self.cmdTabHeld=NO;self.systemIntentUntil=now+1500000000ULL;}
}
- (void)noteSystemUIIntent {
    if(self.closed)return;
    [self cancelBackgroundArrival];[self.intruderRestores removeAllObjects];
    self.systemIntentUntil=self.clock()+2000000000ULL;
}
- (void)noteLaunchIntentForBundle:(NSString *)bundle {
    if(self.closed||!bundle.length)return;
    [self cancelBackgroundArrival];[self.intruderRestores removeAllObjects];
    self.authorizedBundles[bundle]=@(self.clock()+30000000000ULL);
}
- (void)noteFocusedWindowClick {
    if(self.closed)return;
    self.focusedWindowClickAt=self.clock();
}
// Any new window or focus change inside the process (same PID and kernel birth)
// that currently holds confirmed live focus is always solicited, with no time
// window — including while an unadopted panel of that same process (such as an
// Open/Save panel) temporarily cleared observed_native via focus_lost.
- (BOOL)isConfirmedFocusedProcess:(pid_t)pid birth:(NSArray<NSNumber *> *)birth snapshot:(NSDictionary *)snapshot {
    if(pid<=0||birth.count!=2)return NO;
    NSDictionary *target=[self confirmedLiveFocusInSnapshot:snapshot];
    if(target){
        NSDictionary *id=target[@"identity"];
        self.confirmedFocusProcess=@{@"pid":id[@"pid"],@"birth_sec":id[@"birth_sec"],@"birth_usec":id[@"birth_usec"]};
        return [id[@"pid"]intValue]==pid&&[id[@"birth_sec"]isEqual:birth[0]]&&[id[@"birth_usec"]isEqual:birth[1]];
    }
    NSDictionary *held=self.confirmedFocusProcess;
    if(!held||[held[@"pid"]intValue]!=pid||![held[@"birth_sec"]isEqual:birth[0]]||![held[@"birth_usec"]isEqual:birth[1]])return NO;
    NSDictionary *focus=snapshot[@"focus"];
    if(focus[@"observed_native"]!=NSNull.null||focus[@"pending_effect"]!=NSNull.null)return NO;
    id intent=focus[@"intent"];
    for(NSDictionary *w in snapshot[@"windows"]){id s=w[@"source"];
        if([w[@"window"]isEqual:intent]&&[s isKindOfClass:NSDictionary.class]){
            NSDictionary *id=s[@"identity"];
            return [id[@"pid"]intValue]==pid&&[id[@"birth_sec"]isEqual:birth[0]]&&[id[@"birth_usec"]isEqual:birth[1]];
        }
    }
    return NO;
}
- (BOOL)authorizeProcess:(pid_t)pid birth:(NSArray<NSNumber *> *)birth bundle:(NSString *)bundle at:(uint64_t)eventAt allowSameApp:(BOOL)allowSameApp forAttach:(BOOL)forAttach {
    if(pid<=0||birth.count!=2)return NO;
    uint64_t now=self.clock();[self pruneIntentsAt:now];
    NSDictionary *snapshot=nil;
    if(allowSameApp){
        snapshot=self.command(@{@"op":@"snapshot"});
        if([self isConfirmedFocusedProcess:pid birth:birth snapshot:snapshot]){
            [self cancelBackgroundArrival];[self.intruderRestores removeObjectForKey:@(pid)];
            return YES;
        }
    }
    NSDictionary *existing=self.authorizedProcesses[@(pid)];
    if(existing&&[existing[@"birth_sec"]isEqual:birth[0]]&&[existing[@"birth_usec"]isEqual:birth[1]]){
        uint64_t limit=[existing[forAttach?@"attach_until":@"activate_until"]unsignedLongLongValue];
        if(eventAt<=limit||now<=limit)return YES;
    }
    BOOL systemIntent=self.cmdTabHeld||eventAt<=self.systemIntentUntil||now<=self.systemIntentUntil;
    BOOL bundleIntent=bundle.length&&([self.authorizedBundles[bundle]unsignedLongLongValue]>=eventAt||[self.authorizedBundles[bundle]unsignedLongLongValue]>=now);
    BOOL clickIntent=NO;
    if(!systemIntent&&!bundleIntent&&DWFocusedWindowClickAuthorizesSwitch(self.focusedWindowClickAt,eventAt)){
        if(!snapshot)snapshot=self.command(@{@"op":@"snapshot"});
        NSDictionary *target=[self confirmedLiveFocusInSnapshot:snapshot];
        if(!target||[target[@"identity"][@"pid"]intValue]!=pid){clickIntent=YES;self.focusedWindowClickAt=0;}
    }
    if(!systemIntent&&!bundleIntent&&!clickIntent)return NO;
    [self cancelBackgroundArrival];[self.intruderRestores removeObjectForKey:@(pid)];
    if(bundleIntent&&bundle.length)[self.authorizedBundles removeObjectForKey:bundle];
    uint64_t base=MAX(now,eventAt);
    self.authorizedProcesses[@(pid)]=@{@"pid":@(pid),@"birth_sec":birth[0],@"birth_usec":birth[1],@"activate_until":@(base+4000000000ULL),@"attach_until":@(base+15000000000ULL)};
    return YES;
}
- (BOOL)consumeAttachIntentForPID:(pid_t)pid birth:(NSArray<NSNumber *> *)birth bundle:(NSString *)bundle {
    if(!self.filterUnsolicitedActivations)return YES;
    uint64_t now=self.clock();
    if(![self authorizeProcess:pid birth:birth bundle:bundle at:now allowSameApp:YES forAttach:YES])return NO;
    NSMutableDictionary *entry=[self.authorizedProcesses[@(pid)]mutableCopy];
    if(entry){
        uint64_t cap=now+1500000000ULL;
        if([entry[@"attach_until"]unsignedLongLongValue]>cap)entry[@"attach_until"]=@(cap);
        self.authorizedProcesses[@(pid)]=entry.copy;
    }
    return YES;
}
- (BOOL)canRestoreAgainstIntruderPID:(pid_t)pid {
    if(pid<=0)return NO;
    uint64_t now=self.clock();[self pruneIntentsAt:now];
    NSDictionary *entry=self.intruderRestores[@(pid)];
    if(!entry)return YES;
    return ![entry[@"failed"]boolValue]&&[entry[@"count"]unsignedIntegerValue]<2;
}
- (BOOL)restoreConfirmedFocus:(NSDictionary *)target againstPID:(pid_t)pid identity:(NSDictionary *)identity startedAt:(uint64_t)startedAt snapshot:(NSDictionary *)snapshot {
    if(!self.focusAllowed||!target||pid<=0||![self canRestoreAgainstIntruderPID:pid])return NO;
    if(self.backgroundCorrection&&[snapshot[@"focus"][@"pending_effect"]isEqual:self.backgroundCorrection]&&[self.backgroundTarget isEqual:target])return YES;
    uint64_t now=self.clock();NSDictionary *prior=self.intruderRestores[@(pid)];
    NSUInteger count=[prior[@"count"]unsignedIntegerValue]+1;
    uint64_t since=prior?[prior[@"since"]unsignedLongLongValue]:now;
    self.intruderRestores[@(pid)]=@{@"count":@(count),@"since":@(since),@"failed":@NO};
    NSDictionary *reply=self.command(@{@"op":@"focus",@"window":target[@"window"]});
    NSDictionary *effect=focusEffect(reply);if(!effect)return NO;
    self.backgroundTarget=target;self.backgroundObserved=identity;self.backgroundIntruderPID=pid;
    self.backgroundRestoreStartedAt=startedAt?:now;self.backgroundCorrection=effect;self.backgroundDeadline=now+1500000000ULL;
    [self perform:reply];if(self.changed)self.changed();return YES;
}
- (void)noteApplicationLaunched:(pid_t)pid birth:(NSArray<NSNumber *> *)birth bundle:(NSString *)bundle at:(uint64_t)at {
    if(!self.filterUnsolicitedActivations||!self.enabled||self.closed)return;
    [self authorizeProcess:pid birth:birth bundle:bundle at:at allowSameApp:NO forAttach:NO];
}
- (void)noteApplicationActivated:(pid_t)pid birth:(NSArray<NSNumber *> *)birth bundle:(NSString *)bundle regular:(BOOL)regular at:(uint64_t)at {
    if(!self.filterUnsolicitedActivations||!self.enabled||self.closed||!regular)return;
    if([self authorizeProcess:pid birth:birth bundle:bundle at:at allowSameApp:YES forAttach:NO]){[self observe];return;}
    NSDictionary *snapshot=self.command(@{@"op":@"snapshot"}),*target=[self confirmedLiveFocusInSnapshot:snapshot];
    if(target&&[target[@"identity"][@"pid"]intValue]!=pid)[self restoreConfirmedFocus:target againstPID:pid identity:nil startedAt:at snapshot:snapshot];
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
        NSDictionary *identity=actual;
        NSDictionary *snapshot=self.command(@{@"op":@"snapshot"}),*match=nil;
        if(family){
            // A child is associated with the binding captured before the worker
            // read, never a replacement of that binding or an aged parent chain.
            if(self.clock()-observedAt>100000000||![self binding:family snapshot:snapshot])return;
            match=family;identity=family[@"identity"];
        }else{
            self.familyObservation=nil;
            for(NSDictionary *w in snapshot[@"windows"]){id s=w[@"source"];if([s isKindOfClass:NSDictionary.class]&&sameIdentity(s[@"identity"],identity)){match=@{@"window":w[@"window"],@"identity":s[@"identity"],@"generation":s[@"generation"]};break;}}
        }
        if(!match){for(NSDictionary *w in snapshot[@"windows"]){id source=w[@"source"];if(![source isKindOfClass:NSDictionary.class])continue;NSMutableDictionary *plain=[source[@"identity"]mutableCopy];[plain removeObjectForKey:@"owner"];if(sameIdentity(plain,identity))return;}}
        if(!family&&(self.nativeClick||self.backgroundTarget)&&self.clock()-observedAt>100000000)return;
        if(!family&&[self observeNativeClick:match snapshot:snapshot])return;
        if(!family&&self.clock()-observedAt<=100000000&&[self observeBackgroundArrival:match snapshot:snapshot])return;
        NSDictionary *focus=snapshot[@"focus"];id pending=focus[@"pending_effect"];
        if(match&&[pending isKindOfClass:NSDictionary.class]&&[pending[@"window"]isEqual:match[@"window"]]&&[pending[@"generation"]isEqual:match[@"generation"]]&&sameIdentity(pending[@"identity"],identity)){
            if(family)[self answer:pending epoch:epoch with:@{@"op":@"focus_logical"}];else [self complete:pending epoch:epoch success:YES];
            return;
        }
        id observed=focus[@"observed_native"];
        if(family&&[self.familyObservation[@"binding"]isEqual:family]&&sameIdentity(self.familyObservation[@"actual"],actual)&&[focus[@"logical"]isEqual:match[@"window"]]&&pending==NSNull.null)return;
        if(!family&&match&&[observed isKindOfClass:NSDictionary.class]&&[observed[@"window"]isEqual:match[@"window"]]&&[observed[@"generation"]isEqual:match[@"generation"]]&&sameIdentity(observed[@"identity"],identity)){
            self.confirmedFocusProcess=@{@"pid":identity[@"pid"],@"birth_sec":identity[@"birth_sec"],@"birth_usec":identity[@"birth_usec"]};
            return;
        }
        if(!match&&observed==NSNull.null&&pending==NSNull.null)return;
        if(self.filterUnsolicitedActivations&&match){
            BOOL first=!self.initialObservationDone;self.initialObservationDone=YES;
            if(!family&&observed==NSNull.null&&pending==NSNull.null&&([focus[@"intent"]isEqual:match[@"window"]]||(first&&focus[@"intent"]==NSNull.null))){
                [self cancelNativeClick];[self advance];
                NSMutableDictionary *c=[match mutableCopy];c[@"op"]=@"observe_focus";self.command(c);
                self.confirmedFocusProcess=@{@"pid":identity[@"pid"],@"birth_sec":identity[@"birth_sec"],@"birth_usec":identity[@"birth_usec"]};
                if(self.changed)self.changed();return;
            }
            pid_t pid=[actual[@"pid"]intValue];NSArray *birth=@[actual[@"birth_sec"],actual[@"birth_usec"]];
            BOOL alreadyIntended=[focus[@"intent"]isEqual:match[@"window"]];
            BOOL solicited=alreadyIntended||[self authorizeProcess:pid birth:birth bundle:nil at:observedAt allowSameApp:YES forAttach:NO];
            if(!solicited){
                NSDictionary *target=[self confirmedLiveFocusInSnapshot:snapshot];
                if(target&&![target[@"window"]isEqual:match[@"window"]]&&[self restoreConfirmedFocus:target againstPID:pid identity:family?nil:actual startedAt:observedAt snapshot:snapshot])return;
                [self cancelNativeClick];[self advance];
                self.confirmedFocusProcess=nil;
                if(observed!=NSNull.null||pending!=NSNull.null){self.command(@{@"op":@"focus_lost"});if(self.changed)self.changed();}
                return;
            }
        }
        [self cancelNativeClick];
        [self advance];
        if(!match){
            if(![actual[@"pid"]isEqual:self.confirmedFocusProcess[@"pid"]]||![actual[@"birth_sec"]isEqual:self.confirmedFocusProcess[@"birth_sec"]]||![actual[@"birth_usec"]isEqual:self.confirmedFocusProcess[@"birth_usec"]])self.confirmedFocusProcess=nil;
            self.command(@{@"op":@"focus_lost"});
        }
        else {
            self.confirmedFocusProcess=@{@"pid":identity[@"pid"],@"birth_sec":identity[@"birth_sec"],@"birth_usec":identity[@"birth_usec"]};
            // The user focused a window of the canvas natively: upstream's activation, so focus, MRU order and by
            // its reveal rule the camera follow. The observation is the focus; a request in the reply is answered
            // from it, never by the driver. Refused (a gesture is active), the focus is still recorded.
            NSMutableDictionary *c=[match mutableCopy];c[@"op"]=@"activate";c[@"cause"]=family?@"native_family":@"native";c[@"output"]=(self.output?self.output():nil)?:NSNull.null;
            NSDictionary *reply=self.command(c),*effect=focusEffect(reply);
            // A focused sheet/popup gives its root canvas focus, but does not
            // prove that the root itself became the native focused window.
            if(effect){if(family)[self answer:effect epoch:self.epoch with:@{@"op":@"focus_logical"}];else [self complete:effect epoch:self.epoch success:YES];}
            else if(!reply&&!family){[c removeObjectsForKeys:@[@"cause",@"output"]];c[@"op"]=@"observe_focus";self.command(c);}
            if(family&&reply)self.familyObservation=@{@"binding":family,@"actual":actual};
        }
        if(self.changed)self.changed();
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
