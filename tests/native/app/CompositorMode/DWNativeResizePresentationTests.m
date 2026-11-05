// SPDX-License-Identifier: GPL-3.0-or-later
// Real presentation owner and coordinator; substituted capture, helper and worker.
// No NSApplication, native window, AX setter, capture or input is started.
#import "DWNativeResizePresentation.h"
#import "DWResizeCoordinator.h"
#import "DWGeometryJSON.h"
#include "DWResizePresentationNativeBounds.inc"
static void check(BOOL ok,NSString *why){if(!ok){fprintf(stderr,"FAIL: %s\n",why.UTF8String);exit(2);}}
// The production capture implementation is linked, but never invoked.
NSDictionary *DWNativeWindowFamily(NSDictionary *identity,NSString **why){(void)identity;if(why)*why=@"test refuses capture";return nil;}
@interface TestPicture : NSObject <DWNativeResizePicture>
@property BOOL shown,removed;
@property CGRect rect;
@property NSUInteger frames;
@end
@implementation TestPicture
- (BOOL)show {self.shown=YES;return YES;}
- (BOOL)setScreenRect:(CGRect)rect {self.rect=rect;self.frames++;return !self.removed;}
- (void)finish {self.removed=YES;}
- (void)cancel {self.removed=YES;}
@end
@interface TestPresenter : NSObject <DWNativeResizePresenter>
@property BOOL supported,hidden,revealed,ackLag;
@property NSUInteger hides,reveals,resumes;
@property CGRect target;
@end
@implementation TestPresenter
- (DWNativeHiddenRoot *)beginTransitionForWindow:(NSDictionary *)identity {check(identity.count==4&&!identity[@"owner"],@"presenter identity strips only null owner");return self.supported?(id)[NSObject new]:nil;}
- (BOOL)hideTransition:(DWNativeHiddenRoot *)root {(void)root;self.hides++;return YES;}
- (BOOL)isTransitionHidden:(DWNativeHiddenRoot *)root {(void)root;return self.hidden&&!self.ackLag;}
- (BOOL)isTransitionHideOwned:(DWNativeHiddenRoot *)root {(void)root;return self.hidden;}
- (BOOL)revealTransition:(DWNativeHiddenRoot *)root screen:(CGRect)screen alpha:(double)alpha {(void)root;(void)alpha;self.target=screen;self.reveals++;return YES;}
- (BOOL)isTransitionRevealed:(DWNativeHiddenRoot *)root {(void)root;return self.revealed;}
- (void)resumeWindow:(NSDictionary *)identity {check(identity.count==4&&!identity[@"owner"],@"resume uses same canonical presenter identity");self.resumes++;}
@end
@interface TestDriver : NSObject <DWResizeDriver>
@property NSUInteger calls,setters;
@property TestPresenter *presenter;
@property (copy) void (^during)(NSDictionary *effect);
@end
@implementation TestDriver
- (NSDictionary *)perform:(NSDictionary *)effect {check(!effect[@"requested"]||self.presenter.hidden,@"no native setter before hide ACK");self.calls++;if(effect[@"requested"])self.setters++;if(self.during)self.during(effect);return @{};}
@end
@interface Harness : NSObject
@property DWNativeResizePresentation *owner;
@property DWResizeCoordinator *coordinator;
@property TestPresenter *presenter;
@property TestDriver *driver;
@property TestPicture *picture;
@property NSMutableArray<DWJob> *workers,*timers,*watchdogs;
@property NSDictionary *effect;
@property NSMutableDictionary *transaction;
@property BOOL valid,finished,restored,recoverable,autoDiagnostic;
@property CGRect target;
@property double now;
@property NSUInteger failures,captureCancels,renders;
@property (copy) void (^captureDone)(id<DWNativeResizePicture>,NSString *);
@end
@implementation Harness
- (instancetype)init {
    if((self=[super init])){
        _valid=YES;_recoverable=YES;_target=CGRectMake(100,100,400,300);_workers=[NSMutableArray array];_timers=[NSMutableArray array];_watchdogs=[NSMutableArray array];
        _presenter=[TestPresenter new];_presenter.supported=YES;_driver=[TestDriver new];_driver.presenter=_presenter;_picture=[TestPicture new];
        __weak Harness *weak=self;
        _owner=[[DWNativeResizePresentation alloc]initWithPresenter:_presenter capture:^DWJob(DWNativeHiddenRoot *root,BOOL (^valid)(void),void (^completion)(id<DWNativeResizePicture>,NSString *)){
            (void)root;(void)valid;weak.captureDone=completion;return ^{weak.captureCancels++;};}];
        _owner.clock=^{return weak.now;};_owner.delay=^(NSTimeInterval seconds,DWJob job){(void)seconds;[weak.timers addObject:job];};
        _owner.state=^DWNativeResizePresentationState{Harness *h=weak;return (DWNativeResizePresentationState){.valid=h.valid,.finished=h.finished,.restored=h.restored,.recoverable=h.recoverable,.drained=h.finished&&![h.coordinator hasNativeWorkForTransaction:@1],.screenRect=h.target,.alpha=1};};
        _owner.failed=^(NSString *reason){(void)reason;weak.failures++;};
        _owner.render=^{weak.renders++;[weak.owner update];}; // nested render is harmless
        _coordinator=[[DWResizeCoordinator alloc]initWithCommand:^NSDictionary *(NSDictionary *command){
            Harness *h=weak;if([command[@"op"]isEqual:@"snapshot"])return @{@"native_resize":h.transaction};
            if([command[@"op"]isEqual:@"native_resize_result"]){
                if(h.autoDiagnostic&&[command[@"effect_id"]isEqual:@2]){[h next:NO];NSMutableDictionary *diagnostic=[h.effect mutableCopy];diagnostic[@"effect_id"]=@3;h.effect=diagnostic;h.transaction[@"pending_effect"]=diagnostic;return @{@"effect":diagnostic};}
                h.transaction[@"pending_effect"]=NSNull.null;if(h.autoDiagnostic)h.finished=YES;return @{};}return @{};
        } driver:_driver worker:^(DWJob job){[weak.workers addObject:job];} main:^(DWJob job){job();}];
        _coordinator.enabled=YES;_coordinator.timeout=3;
        _coordinator.delay=^(NSTimeInterval seconds,DWJob job){[weak.timers addObject:job];if(seconds==3)[weak.watchdogs addObject:job];};
        _coordinator.prepare=^(NSDictionary *effect,void (^ready)(BOOL)){[weak.owner prepareEffect:effect ready:ready];};
        [self next:NO];
    }return self;
}
- (void)next:(BOOL)setter {
    NSMutableDictionary *effect=[@{@"op":setter?@"resize_native_window":@"observe_resize_source",@"transaction":@1,@"effect_id":setter?@2:@1,@"window":@7,@"generation":@3,@"identity":@{@"pid":@5,@"wid":@9,@"birth_sec":@1,@"birth_usec":@0,@"owner":NSNull.null}}mutableCopy];
    if(setter)effect[@"requested"]=@{@"width":@450,@"height":@350};self.effect=effect;
    self.transaction=[@{@"transaction":@1,@"window":@7,@"pending_effect":effect,@"phase":@"active"}mutableCopy];
}
- (void)start {[_coordinator consume:@{@"effect":self.effect}];}
- (void)capture {self.captureDone(self.picture,nil);}
- (void)drain {NSArray *jobs=self.workers.copy;[self.workers removeAllObjects];for(DWJob job in jobs)job();}
@end
int main(void){@autoreleasepool{
    NSDictionary *identity=@{@"pid":@5,@"wid":@9,@"birth_sec":@1,@"birth_usec":@0};
    CGRect driver=CGRectMake(300,200,800,462),audited=CGRectMake(300,200,800,463);
    NSDictionary *family=@{@"identity":identity,@"root":@9,@"members":@[@{@"identity":identity,@"parent":@0,@"native_bounds":DWRectJSON(audited)}]};
    check(CGRectEqualToRect(DWResizePresentationNativeBounds(family,identity,driver),audited),@"presentation uses same family observation when AppKit settles after driver readback");
    check(CGRectEqualToRect(DWResizePresentationNativeBounds(@{},identity,driver),driver),@"missing audit retains fallback for presenter to refuse");
    check(CGRectEqualToRect(DWResizePresentationNativeBounds(family,@{@"wid":@10},driver),driver),@"different root identity cannot supply presentation geometry");
    for(NSString *edge in @[@"left",@"top",@"top_left",@"top_right",@"bottom_left"])
        check([DWNativeResizePresentation requiresBridgeForTransaction:@{@"interactive":@YES,@"edges":edge}],@"affected edge requires bridge");
    for(NSString *edge in @[@"right",@"bottom",@"bottom_right"])
        check(![DWNativeResizePresentation requiresBridgeForTransaction:@{@"interactive":@YES,@"edges":edge}],@"unaffected edge preserves permission-free path");
    check(![DWNativeResizePresentation requiresBridgeForTransaction:@{@"interactive":@NO,@"edges":@"left"}],@"ordinary sizing retains existing Fill path");
    Harness *h=[Harness new];[h start];check(h.coordinator.obligations==1&&!h.workers.count,@"preparation owns obligation without dispatch");
    [h capture];check(h.picture.shown&&!h.workers.count&&h.presenter.hides==1,@"picture precedes hide, no dispatch pending ACK");
    h.presenter.hidden=YES;[h.owner update];check(h.workers.count==1,@"hide ACK admits baseline");[h drain];
    h.presenter.ackLag=YES;[h.owner update];
    check(h.failures==0&&[h.owner allowsEffect:h.effect],@"unrelated frame ACK lag does not revoke already-ACKed root hide");
    [h next:YES];[h start];check(h.workers.count==1,@"subsequent setter admitted while hidden even during unrelated ACK lag");
    h.presenter.ackLag=NO;
    // Native extent may change first; the drawn image stays on the last
    // controller commit, then immediately takes its next anchored rectangle.
    check(CGRectGetMaxX(h.picture.rect)==500&&CGRectGetMaxY(h.picture.rect)==400,@"opposite edges before native setter");
    [h drain];check(h.driver.setters==1,@"actual native setter still dispatched");
    check(CGRectGetMaxX(h.picture.rect)==500&&CGRectGetMaxY(h.picture.rect)==400,@"native extent phase does not move picture");
    h.target=CGRectMake(50,50,450,350);[h.owner update];
    check(CGRectEqualToRect(h.picture.rect,h.target)&&CGRectGetMaxX(h.picture.rect)==500&&CGRectGetMaxY(h.picture.rect)==400,@"accepted top/left commit updates picture immediately with fixed opposite edges");
    h.target=CGRectMake(50.25,50.5,450,350);[h.owner update];
    check(CGRectEqualToRect(h.picture.rect,CGRectMake(50,50,450,350)),@"fractional picture origin follows native CG grid, not flipped AppKit rounding");
    h.target=CGRectMake(50,50,450,350);[h.owner update];
    [h.owner update];check(!h.presenter.reveals&&!h.picture.removed,@"held transaction remains covered");
    h.finished=YES;[h.owner update];check(h.presenter.reveals==1&&!h.picture.removed&&CGRectEqualToRect(h.presenter.target,h.target),@"release drains then reveals latest committed frame");
    h.presenter.revealed=YES;[h.owner update];check(!h.owner.active&&h.picture.removed&&h.presenter.resumes==1,@"only reveal ACK removes successful picture");

    h=[Harness new];[h start];void (^late)(id<DWNativeResizePicture>,NSString *)=h.captureDone;
    [h.owner cancel];check(h.coordinator.obligations==0&&!h.workers.count,@"cancel preparation settles unattempted");
    TestPicture *latePicture=[TestPicture new];late(latePicture,nil);check(!h.owner.active&&latePicture.removed&&!h.workers.count,@"late capture cannot resurrect cancelled transaction");
    h=[Harness new];[h start];h.captureDone(nil,@"screen recording preflight refused");check(!h.owner.active&&h.failures==1&&!h.workers.count&&h.presenter.resumes==1,@"capture failure cancels before mutation");
    h=[Harness new];h.presenter.supported=NO;[h start];check(h.owner.active&&!h.workers.count,@"placement ACK pending waits without native work");
    h.presenter.supported=YES;[h.owner update];[h capture];h.presenter.hidden=YES;[h.owner update];check(h.workers.count==1,@"later placement ACK starts capture and admits only after hide ACK");[h.owner cancel];
    h=[Harness new];h.presenter.supported=NO;[h start];h.now=2.6;[h.owner update];check(!h.owner.active&&h.failures==1&&!h.workers.count,@"unsupported families fail closed after bounded preparation");
    h=[Harness new];[h start];[h capture];h.now=2.6;[h.owner update];check(h.failures==1&&h.presenter.resumes==0&&!h.workers.count&&!h.picture.removed,@"hide timeout starts covered ordinary recovery, not setter");
    h.finished=YES;[h.owner update];h.restored=YES;[h.owner update];check(!h.owner.active&&h.picture.removed,@"ordinary placement ACK ends abort recovery");
    h=[Harness new];[h start];[h capture];h.presenter.hidden=YES;[h.owner update];[h drain];h.finished=YES;[h.owner update];
    h.now=2.6;[h.owner update];[h.owner update];check(h.failures==1&&!h.picture.removed&&h.presenter.resumes==1,@"failed reveal is covered during bounded restore");
    h.now=5.2;[h.owner update];check(!h.owner.active&&h.picture.removed,@"hard recovery timeout removes picture and leaves no withheld root");
    h=[Harness new];[h start];[h capture];h.valid=NO;h.recoverable=NO;[h.owner update];[h.owner update];check(h.failures==1&&!h.owner.active&&h.picture.removed&&!h.workers.count,@"generation/close/session/display invalidation retires callbacks and hide");
    h=[Harness new];[h start];[h capture];h.presenter.hidden=YES;[h.owner update];[h drain];
    check([h.owner allowsEffect:h.effect],@"fresh hidden lease allows worker gate");
    h.presenter.hidden=NO;check(![h.owner allowsEffect:h.effect],@"new child/family revocation refuses worker gate immediately");
    [h next:YES];[h start];check(!h.workers.count&&h.failures==1,@"family revocation cannot admit later setter");
    h=[Harness new];[h start];[h capture];h.valid=NO;h.finished=YES;[h.owner update];[h.owner update];
    check(h.owner.active&&!h.picture.removed&&h.presenter.resumes==1,@"camera/output invalidation keeps covered healthy-session restoration");
    h.restored=YES;[h.owner update];check(!h.owner.active&&h.picture.removed,@"new ordinary placement ACK ends invalidation recovery");
    // Setter watchdog may settle its controller effect before the foreign AX
    // call returns. Its queued diagnostic must survive and really run later.
    h=[Harness new];[h start];[h capture];h.presenter.hidden=YES;[h.owner update];[h drain];[h next:YES];[h start];h.autoDiagnostic=YES;
    __weak Harness *blocked=h;
    h.driver.during=^(NSDictionary *effect){if(!effect[@"requested"])return;Harness *b=blocked;
        b.presenter.hidden=NO;[b.owner update];b.restored=YES;b.now=100;[b.owner update];
        check([b.coordinator hasNativeWorkForTransaction:@1]&&b.picture.shown&&!b.picture.removed&&b.presenter.resumes==0,@"abort cannot unhide/remove atop inflight setter even with stale ordinary ACK");
        DWJob setterTimeout=b.watchdogs.lastObject;setterTimeout();
        check(b.workers.count==1&&[b.transaction[@"pending_effect"][@"effect_id"]isEqual:@3],@"recovery admits diagnostic read after timed-out setter");
        DWJob diagnosticTimeout=b.watchdogs.lastObject;diagnosticTimeout();
        check([b.transaction[@"pending_effect"][@"effect_id"]isEqual:@3]&&!b.picture.removed,@"diagnostic watchdog waits behind still-running setter");
    };
    [h drain];check(!h.picture.removed&&h.presenter.resumes==0,@"late actual setter completion still waits for diagnostic");
    [h drain];[h.owner update];check(h.presenter.resumes==1&&!h.picture.removed,@"actual diagnostic drain permits ordinary restoration");
    [h.owner update];check(!h.owner.active&&h.picture.removed,@"restoration ACK only retires after native drain");
    // A separate transaction waits unadmitted, then is reconsidered rather than
    // answered NO by the previous transaction's presentation owner.
    h=[Harness new];blocked=h;h.coordinator.beforeAdmission=^BOOL(NSDictionary *effect){return !blocked.owner.active||[effect[@"transaction"]isEqual:blocked.owner.effect[@"transaction"]];};
    blocked=h;[h start];[h capture];h.presenter.hidden=YES;[h.owner update];[h drain];
    NSMutableDictionary *other=[h.effect mutableCopy];other[@"transaction"]=@2;other[@"effect_id"]=@4;h.transaction[@"transaction"]=@2;h.transaction[@"pending_effect"]=other;
    [h.coordinator consume:@{@"effect":other}];check(h.coordinator.obligations==0&&!h.workers.count,@"unrelated transaction waits without an obligation or preparation watchdog");
    [h.owner cancel];h.coordinator.prepare=^(NSDictionary *effect,void (^ready)(BOOL)){(void)effect;ready(YES);};[h.coordinator retryAdmission];
    check(h.coordinator.obligations==1&&h.workers.count==1,@"retired handoff reconsiders and admits unrelated next transaction");
    h=[Harness new];[h start];NSArray *timers=h.timers.copy;for(DWJob job in timers)job();check(h.coordinator.obligations==0&&!h.workers.count,@"coordinator preparation watchdog never dispatches native work");
    [h.owner cancel];h.presenter.hidden=YES;h.captureDone([TestPicture new],nil);check(!h.workers.count,@"watchdog/cancellation late completion cannot dispatch");
    puts("PASS: interactive native resize presentation/admission lifecycle; substituted capture/helper/driver, no native windows or optical claim");
}return 0;}
