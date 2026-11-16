// SPDX-License-Identifier: GPL-3.0-or-later
// Extracted from native/desktop/main.m at 37b27b1 and Desktop sizing categories.
#import "DWSizeTransition.h"
#import "DWDesktopSupport.h"
#import "LiveSource.h"
#import "DWDebugTrace.h"
#import "DWNativeFocus.h"
#import "DWNativeFamily.h"
#import "DWGeometryJSON.h"
#import "DWNativeResizePresentation.h"
@interface DWSizeTransition ()
@property (weak) id<DWSizeTransitionHost> desktop;
@property (copy) DWSizeTransitionCapture capture;
@property (weak) DWNativePresenter *acknowledgementPresenter;
@property DWResizeCoordinator *resize;
@property DWNativeResizePresentation *nativeResizePresentation;
@property NSNumber *nativeResizeLiveTransaction;
@property NSNumber *resizeSavedTransaction;
@property NSNumber *sizeTransaction; // the transaction a sizing action's effect last named
@property (readwrite) NSDictionary *fillHandoff;
@property NSDictionary *nativeRestoreDeferred;
@property NSArray *nativeFillBackgroundTrace;
@property NSMutableDictionary<NSNumber *,NSDictionary *> *nativeFillHistory;
@property NSMutableSet<NSNumber *> *nativeFillRefusedTransactions;
@property id<DWSizeTransitionResizeDriver> nativeResizeDriver;
@property DWNativeHiddenRoot *nativeFillRoot;
@property id<DWSizeTransitionCaptureRequest> nativeFillCapture;
@property id<DWSizeTransitionPicture> nativeFillPicture;
@property BOOL nativeFillHiding,nativeFillAnimating,nativeFillAnimated,nativeFillRevealing;
@property CFTimeInterval nativeFillPresentationDeadline;
@property BOOL nativeFillResuming;
@end
@implementation DWSizeTransition
- (instancetype)initWithHost:(id<DWSizeTransitionHost>)host {
    DWSizeTransitionCapture capture=^id<DWSizeTransitionCaptureRequest>(DWNativeHiddenRoot *root,BOOL interactive,BOOL (^valid)(void),void (^completion)(DWSizeTransitionPictureFactory,NSString *)){
        DWNativeTransitionCapture *request=[DWNativeTransitionCapture captureIdentity:root.identity nativeBounds:root.nativeBounds screenRect:root.screenRect validate:valid completion:^(DWNativeTransitionCaptureResult *result,NSString *failure){
            CGRect rect=result.screenRect;
            if(interactive){rect.origin.x=floor(rect.origin.x);rect.origin.y=floor(rect.origin.y);}
            DWSizeTransitionPictureFactory picture=nil;
            if(result)picture=^id<DWSizeTransitionPicture>{return (id)[[DWNativeTransition alloc]initWithImage:result.image screenRect:rect];};
            completion(picture,failure);
        }];
        return (id)request;
    };
    DWNativeResizeDriver *driver=[DWNativeResizeDriver new];
    // The independent native update lease must still balance after the host or
    // transition owner goes away; never route this watchdog through a weak host.
    driver.screenUpdates=^CGError(BOOL enabled){return DWNativeScreenUpdates(enabled);};
    return [self initWithHost:host driver:driver capture:capture];
}
- (instancetype)initWithHost:(id<DWSizeTransitionHost>)host driver:(id<DWSizeTransitionResizeDriver>)driver capture:(DWSizeTransitionCapture)capture {
    if((self=[super init])){_desktop=host;_nativeResizeDriver=driver;_capture=[capture copy];[self configure];}
    return self;
}
// A single subscription owns the presenter's slot. Routing is internal:
// callers never compete to replace a resize callback with a Fill callback.
- (void)observeAcknowledgementsFrom:(DWNativePresenter *)presenter {
    if(self.acknowledgementPresenter==presenter)return;
    self.acknowledgementPresenter.transitionFrameAcknowledged=nil;
    self.acknowledgementPresenter=presenter;
    __weak DWSizeTransition *weak=self;__weak DWNativePresenter *weakPresenter=presenter;
    presenter.transitionFrameAcknowledged=^{
        DWSizeTransition *d=weak;DWNativePresenter *pr=weakPresenter;
        if(!d||d.desktop.cleaning||d.desktop.sessionInactive||d.desktop.native!=pr)return;
        if(d.fillHandoff){[d.desktop render];return;}
        DWNativeResizePresentation *picture=d.nativeResizePresentation;
        if(!picture.active)return;
        [picture update];if(!d.desktop.cleaning){[d.desktop render];[pr submit];}
    };
}
- (NSUInteger)obligations {return self.resize.obligations;}
- (NSString *)failure {return self.resize.failure;}
- (BOOL)canRemove:(NSNumber *)window {return [self.resize canRemove:window];}
- (NSNumber *)busyWindow {return [self.resize busyWindow];}
- (NSDictionary *)request:(NSDictionary *)command {return [self.resize request:command];}
- (void)consume:(NSDictionary *)reply {[self.resize consume:reply];}
- (void)cancel {[self.resize cancel];}
- (void)shutdown {[self.resize shutdown];}
- (void)reap {[self.resize reap];}
- (void)suspendPresentation {
    self.nativeResizePresentation.retired=nil; // never admit the waiting next transaction during teardown
    [self cancelPresentation];
}
- (void)cancelPresentation {[self.nativeResizePresentation cancel];[self clearNativeFillPresentation];}
- (void)observe {[self updateNativeFill];}
- (void)willRender {[self.nativeResizePresentation update];[self updateNativeFill];}
// The AX reply and later WindowServer family audit are separate observations.
// AppKit may settle another native point between them. Use the audited root's
// own frame for presentation; never change the controller's accepted AX size.
// The presenter still validates the complete report, including every identity,
// duplicate, parent and bounds field before granting readiness.
static CGRect DWResizePresentationNativeBounds(NSDictionary *family,NSDictionary *identity,CGRect fallback) {
    if(![family[@"identity"]isEqual:identity]||![family[@"root"]isEqual:identity[@"wid"]]
        ||![family[@"members"]isKindOfClass:NSArray.class])return fallback;
    for(id value in family[@"members"]){
        if(![value isKindOfClass:NSDictionary.class])continue;
        NSDictionary *member=value;
        if([member[@"identity"]isEqual:identity]&&[member[@"parent"]isEqual:@0])
            return DWRectFromJSON(member[@"native_bounds"]);
    }
    return fallback;
}
// All initial interactive effects pass through coordinator admission, including
// DesktopView's direct resize.request path and gesture requests (not consumeSize).
- (void)prepareInteractiveResize:(NSDictionary *)effect ready:(void (^)(BOOL))ready {
    NSDictionary *snapshot=[self.desktop sizeTransitionSnapshot],*transaction=DWTyped(snapshot[@"native_resize"],NSDictionary.class);
    if(!self.desktop.native){ready(YES);return;}
    if(self.nativeResizePresentation.active){
        [self.nativeResizePresentation prepareEffect:effect ready:ready];return;
    }
    if(![DWNativeResizePresentation requiresBridgeForTransaction:transaction]){ready(YES);return;}
    if([self.nativeResizeLiveTransaction isEqual:effect[@"transaction"]]){ready(YES);return;}
    if(self.fillHandoff||self.desktop.cleaning||self.desktop.sessionInactive||self.desktop.native.ended){ready(NO);return;}
    NSNumber *window=effect[@"window"],*output=[self.desktop.nativeViews desiredOwnerForWindow:window];
    NSDictionary *view=nil;for(NSDictionary *row in snapshot[@"outputs"])if([row[@"id"]isEqual:output]){view=row;break;}
    if(!view){ready(NO);return;}
    DWNativePresenter *presenter=self.desktop.native;uint64_t session=self.desktop.nativeSessionEpoch;
    NSDictionary *effectIdentity=DWTyped(effect[@"identity"],NSDictionary.class);
    NSMutableDictionary *nativeIdentity=[NSMutableDictionary dictionary];
    for(NSString *key in @[@"pid",@"birth_sec",@"birth_usec",@"wid"])if(effectIdentity[key])nativeIdentity[key]=effectIdentity[key];
    // Attached families (e.g. Chrome with Find bar or status bubble) and runs
    // without Screen Recording keep the live resize path instead of stalling.
    if(![self.desktop sizeTransitionCaptureAllowed]||(nativeIdentity.count==4&&[presenter hasAttachedChildrenForWindow:nativeIdentity])){
        self.nativeResizeLiveTransaction=effect[@"transaction"];ready(YES);return;
    }
    self.nativeResizeLiveTransaction=nil;
    DWSizeTransitionCapture capture=self.capture;
    DWNativeResizePresentation *owner=[[DWNativeResizePresentation alloc]initWithPresenter:(id)presenter capture:^DWJob(DWNativeHiddenRoot *root,BOOL (^valid)(void),void (^completion)(id<DWNativeResizePicture>,NSString *)){id<DWSizeTransitionCaptureRequest> request=capture(root,YES,valid,^(DWSizeTransitionPictureFactory makePicture,NSString *failure){id<DWSizeTransitionPicture> picture=makePicture?makePicture():nil;completion(picture,failure?:(!picture?@"snapshot panel unavailable":nil));});return ^{[request cancel];};}];
    self.nativeResizePresentation=owner;__weak DWSizeTransition *weak=self;__weak DWNativeResizePresentation *weakOwner=owner;__weak DWNativePresenter *weakPresenter=presenter;
    [self observeAcknowledgementsFrom:presenter];
    owner.state=^DWNativeResizePresentationState{
        DWSizeTransition *d=weak;DWNativeResizePresentation *p=weakOwner;NSDictionary *e=p.effect;
        if(!d||!e)return (DWNativeResizePresentationState){0};
        NSDictionary *now=[d.desktop sizeTransitionSnapshot],*t=DWTyped(now[@"native_resize"],NSDictionary.class),*binding=nil,*outputNow=nil,*placement=nil;
        LiveSource *source=[d.desktop sizeTransitionSource:window];
        for(NSDictionary *row in now[@"windows"])if([row[@"window"]isEqual:window]){binding=DWTyped(row[@"source"],NSDictionary.class);break;}
        for(NSDictionary *row in now[@"outputs"])if([row[@"id"]isEqual:output]){outputNow=row;break;}
        for(NSDictionary *row in [d.desktop presentationSnapshot][@"placements"])if([row[@"window"]isEqual:window]&&[row[@"output"]isEqual:output]){placement=row;break;}
        BOOL valid=!d.desktop.cleaning&&!d.desktop.sessionInactive&&d.desktop.native==presenter&&!presenter.ended&&d.desktop.nativeSessionEpoch==session
            &&source&&!source.detached&&!source.nativeVisibilityWanted&&!source.nativeMinimized&&!source.nativeMouseOwnership
            &&boundIdentity(source.identity,e[@"identity"])&&boundIdentity(binding[@"identity"],e[@"identity"])
            &&[binding[@"generation"]isEqual:e[@"generation"]]
            &&[[d.desktop.nativeViews desiredOwnerForWindow:window]isEqual:output]&&placement
            &&[view[@"camera"]isEqual:outputNow[@"camera"]]&&[view[@"zoom"]isEqual:outputNow[@"zoom"]]
            &&[view[@"screen_bounds"]isEqual:outputNow[@"screen_bounds"]];
        BOOL sameTransaction=[t[@"transaction"]isEqual:e[@"transaction"]];
        BOOL terminal=!sameTransaction||([t[@"pending_effect"]isEqual:NSNull.null]&&![t[@"uncertain_mutation"]boolValue]
            &&([t[@"phase"]isEqual:@"complete"]||[t[@"phase"]isEqual:@"failed"]));
        BOOL recoverable=!d.desktop.cleaning&&!d.desktop.sessionInactive&&d.desktop.native==presenter&&!presenter.ended&&d.desktop.nativeSessionEpoch==session
            &&source&&!source.detached&&boundIdentity(source.identity,e[@"identity"]);
        NSNumber *currentOutput=[d.desktop.nativeViews desiredOwnerForWindow:window];
        BOOL restored=recoverable&&[presenter acknowledgedPlacementForWindow:window identity:source.identity generation:binding[@"generation"] output:currentOutput]!=nil;
        return (DWNativeResizePresentationState){.valid=valid,.finished=terminal,.restored=restored,.recoverable=recoverable,.drained=terminal&&![d.resize hasNativeWorkForTransaction:e[@"transaction"]],
            .screenRect=DWRectFromJSON(placement[@"screen_rect"]),.alpha=placement[@"alpha"]?[placement[@"alpha"]doubleValue]:1};
    };
    owner.retired=^{DWSizeTransition *d=weak;DWNativePresenter *pr=weakPresenter;if(d&&!d.fillHandoff&&d.desktop.native==pr)[d observeAcknowledgementsFrom:nil];[d.resize retryAdmission];};
    owner.render=^{DWSizeTransition *d=weak;DWNativePresenter *pr=weakPresenter;if(d&&!d.desktop.cleaning){[d.desktop render];if(d.desktop.native==pr)[pr submit];}};
    owner.failed=^(NSString *reason){DWSizeTransition *d=weak;if(!d)return;
        NSDictionary *t=DWTyped([d.desktop sizeTransitionSnapshot][@"native_resize"],NSDictionary.class);
        if([t[@"transaction"]isEqual:weakOwner.effect[@"transaction"]])[d.resize cancel];
        d.desktop.statusText=reason;fprintf(stderr,"%s\n",reason.UTF8String);[d.desktop render];};
    [owner prepareEffect:effect ready:ready];
}
- (void)configure {
    if(self.resize)return;
    __weak DWSizeTransition *weak=self;dispatch_queue_t queue=dispatch_queue_create("org.infinify.resize",DISPATCH_QUEUE_SERIAL);
    id<DWSizeTransitionResizeDriver> driver=self.nativeResizeDriver;
    driver.nativeFill=self.desktop.nativeDesktopMode&&self.desktop.native!=nil;
    driver.canPerform=^BOOL(NSDictionary *effect){
        DWSizeTransition *d=weak;LiveSource *source=[d.desktop sizeTransitionSource:effect[@"window"]];
        if(!d||d.desktop.cleaning||d.desktop.sessionInactive||[d.desktop nativeUnavailable])return NO;
        if(!source||source.detached||source.nativeMouseOwnership||!boundIdentity(source.identity,effect[@"identity"]))return NO;
        if([effect[@"op"]isEqual:@"resize_native_window"]&&(source.nativeVisibilityWanted||source.nativeVisibilityWriting||source.nativeMinimized))return NO;
        // A worker may start after a newer handoff replaced its prepared read.
        // Only the controller's still-pending effect can enter native code.
        NSDictionary *transaction=DWTyped([d.desktop sizeTransitionSnapshot][@"native_resize"],NSDictionary.class);
        if([DWNativeResizePresentation requiresBridgeForTransaction:transaction]
            &&![d.nativeResizeLiveTransaction isEqual:effect[@"transaction"]]
            &&![d.nativeResizePresentation allowsEffect:effect])return NO;
        return [transaction[@"pending_effect"]isEqual:effect];
    };
    driver.fillReady=^DWNativeFillReadiness(NSDictionary *effect){
        DWSizeTransition *d=weak;NSDictionary *held=d.fillHandoff;
        if(!held||d.nativeFillResuming||d.desktop.cleaning||d.desktop.sessionInactive||d.desktop.native.ended
            ||![held[@"transaction"]isEqual:effect[@"transaction"]]||![held[@"generation"]isEqual:effect[@"generation"]]
            ||!boundIdentity(held[@"identity"],effect[@"identity"]))return DWNativeFillPending;
        if(![d nativeFillCurrent:held snapshot:[d.desktop sizeTransitionSnapshot]])return DWNativeFillPending;
        if([held[@"bridge_failed"]boolValue])return DWNativeFillUnsupportedGeometry;
        if(d.nativeFillRoot)return [d.desktop.native isTransitionHidden:d.nativeFillRoot]?DWNativeFillReadyForSnapshotFill:DWNativeFillPending;
        if(![d.desktop.native isWindowWithheld:held[@"identity"]])return DWNativeFillPending;
        // Fresh native/displayed geometry separates an aligned source, a
        // translation-only rebase, and unsupported scaling. Missing evidence
        // remains pending rather than authorizing an ordinary resize.
        NSDictionary *who=held[@"identity"];LiveSource *source=[d.desktop sizeTransitionSource:held[@"window"]];
        if(!source||source.detached||!boundIdentity(source.identity,who))return DWNativeFillPending;
        DWFocusIdentity target={.pid=[who[@"pid"]intValue],.window=[who[@"wid"]unsignedIntValue],.seconds=[who[@"birth_sec"]unsignedLongLongValue],.microseconds=[who[@"birth_usec"]unsignedLongLongValue]};
        CGRect native,displayed,after;
        if(![d.desktop sizeTransitionOwner:target bounds:&native])return DWNativeFillPending;
        NSDictionary *row=[d.desktop sizeTransitionWindowInfo:target.window];
        if([row[(id)kCGWindowOwnerPID]intValue]!=target.pid||!row[(id)kCGWindowBounds]
            ||!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)row[(id)kCGWindowBounds],&displayed)
            ||!isfinite(displayed.origin.x)||!isfinite(displayed.origin.y)||!isfinite(displayed.size.width)||!isfinite(displayed.size.height)
            ||displayed.size.width<=0||displayed.size.height<=0||![d.desktop sizeTransitionOwner:target bounds:&after]||!CGRectEqualToRect(native,after))return DWNativeFillPending;
        BOOL aligned=fabs(native.origin.x-displayed.origin.x)<=1&&fabs(native.origin.y-displayed.origin.y)<=1
            &&fabs(native.size.width-displayed.size.width)<=1&&fabs(native.size.height-displayed.size.height)<=1;
        NSMutableDictionary *fresh=[held mutableCopy];fresh[@"native_baseline"]=DWRectJSON(native);fresh[@"displayed_baseline"]=DWRectJSON(displayed);d.fillHandoff=fresh.copy;
        if(DWDebugTrace())fprintf(stderr,"debug: native fill geometry window=#%s native=%g,%g %gx%g displayed=%g,%g %gx%g supported=%d\n",[held[@"window"]description].UTF8String,native.origin.x,native.origin.y,native.size.width,native.size.height,displayed.origin.x,displayed.origin.y,displayed.size.width,displayed.size.height,aligned);
        BOOL sameExtent=fabs(native.size.width-displayed.size.width)<=1&&fabs(native.size.height-displayed.size.height)<=1;
        return aligned?DWNativeFillReady:(sameExtent&&[d.desktop.native canRebaseWindow:who]?DWNativeFillNeedsRebase:DWNativeFillUnsupportedGeometry);
    };
    driver.restoreReady=^DWNativeFillReadiness(NSDictionary *effect){DWSizeTransition *d=weak;NSDictionary *held=d.fillHandoff;
        if([d.nativeFillRefusedTransactions containsObject:effect[@"transaction"]]||[d.nativeRestoreDeferred[@"effect"][@"transaction"]isEqual:effect[@"transaction"]])return DWNativeFillPending;
        if(!held)return DWNativeFillUnsupportedGeometry;
        if(d.nativeFillResuming||d.desktop.cleaning||d.desktop.sessionInactive||d.desktop.native.ended
            ||![held[@"transaction"]isEqual:effect[@"transaction"]]||![held[@"generation"]isEqual:effect[@"generation"]]
            ||!boundIdentity(held[@"identity"],effect[@"identity"]))return DWNativeFillPending;
        if(![d nativeFillCurrent:held snapshot:[d.desktop sizeTransitionSnapshot]])return DWNativeFillPending;
        if([held[@"bridge_failed"]boolValue]||!d.nativeFillRoot)return DWNativeFillUnsupportedGeometry;
        // Keep the root hidden while qualified Restore clears AppKit's Fill
        // state, then corrects the exact saved frame after native settlement.
        // A frame setter alone leaves Fill active across display changes.
        return [d.desktop.native isTransitionHidden:d.nativeFillRoot]?DWNativeFillReady:DWNativeFillPending;
    };
    driver.fillRebase=^DWNativeFillRebase *(NSDictionary *effect){
        DWSizeTransition *d=weak;NSDictionary *held=d.fillHandoff,*who=held[@"identity"];
        BOOL (^valid)(void)=^BOOL{DWSizeTransition *current=weak;NSDictionary *now=current.fillHandoff;LiveSource *source=[current.desktop sizeTransitionSource:effect[@"window"]];
            return current&&!current.desktop.cleaning&&!current.desktop.sessionInactive&&!current.nativeFillResuming&&!current.desktop.native.ended
                &&[now[@"transaction"]isEqual:effect[@"transaction"]]&&[now[@"generation"]isEqual:effect[@"generation"]]
                &&boundIdentity(now[@"identity"],effect[@"identity"])&&source&&!source.detached&&boundIdentity(source.identity,who)
                &&[current nativeFillCurrent:now snapshot:[current.desktop sizeTransitionSnapshot]];};
        BOOL current=valid(),canRebase=current&&[d.desktop.native canRebaseWindow:who];
        if(!current||!canRebase||!held[@"native_baseline"]||!held[@"displayed_baseline"]){
            if(DWDebugTrace())fprintf(stderr,"debug: native fill rebase refused window=#%s current=%d can_rebase=%d baselines=%d\n",[effect[@"window"]description].UTF8String,current,canRebase,held[@"native_baseline"]!=nil&&held[@"displayed_baseline"]!=nil);
            return nil;
        }
        // Re-audit the known root-only scope before taking an update hold.
        NSString *familyWhy=nil;NSDictionary *family=[d.desktop sizeTransitionFamily:who why:&familyWhy];
        if([family[@"members"]count]!=1){
            if(DWDebugTrace())fprintf(stderr,"debug: native fill rebase refused window=#%s family_members=%lu reason=%s\n",[effect[@"window"]description].UTF8String,(unsigned long)[family[@"members"]count],familyWhy.UTF8String?:"family_not_root_only");
            return nil;
        }
        DWNativeFillRebase *plan=[DWNativeFillRebase new];plan.native=DWRectFromJSON(held[@"native_baseline"]);plan.displayed=DWRectFromJSON(held[@"displayed_baseline"]);
        plan.publish=^BOOL(CGRect observed,BOOL (^authorized)(void)){DWSizeTransition *current=weak;if(!valid())return NO;
            NSDictionary *freshFamily=[weak.desktop sizeTransitionFamily:who why:nil];if([freshFamily[@"members"]count]!=1||!authorized())return NO;
            if(![current.desktop.native rebaseWindow:who bounds:observed])return NO;
            [current.desktop sizeTransitionSource:effect[@"window"]].router.bounds=CFBridgingRelease(CGRectCreateDictionaryRepresentation(observed));
            [current.desktop render];return YES;};
        plan.ready=^BOOL{DWSizeTransition *current=weak;if(!valid())return NO;[current.desktop render];
            if(![current.desktop.native isWindowRebased:who])return NO;
            DWFocusIdentity target={.pid=[who[@"pid"]intValue],.window=[who[@"wid"]unsignedIntValue],.seconds=[who[@"birth_sec"]unsignedLongLongValue],.microseconds=[who[@"birth_usec"]unsignedLongLongValue]};
            CGRect native,displayed,after;NSDictionary *row=[current.desktop sizeTransitionWindowInfo:target.window];
            return [current.desktop sizeTransitionOwner:target bounds:&native]&&[row[(id)kCGWindowOwnerPID]intValue]==target.pid&&row[(id)kCGWindowBounds]
                &&CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)row[(id)kCGWindowBounds],&displayed)
                &&[current.desktop sizeTransitionOwner:target bounds:&after]&&CGRectEqualToRect(native,after)
                &&fabs(native.origin.x-displayed.origin.x)<=1&&fabs(native.origin.y-displayed.origin.y)<=1
                &&fabs(native.size.width-displayed.size.width)<=1&&fabs(native.size.height-displayed.size.height)<=1;};
        plan.cancel=^{DWSizeTransition *current=weak;if(valid()){[current.desktop.native cancelRebaseWindow:who];[current.desktop render];}};
        return plan;
    };
    // On the worker queue. The process named is the effect's, which the controller built from a source -attach: bound.
    if(DWDebugTrace())driver.didPerform=^(NSDictionary *e,NSDictionary *r){NSDictionary *i=e[@"identity"],*asked=DWTyped(e[@"requested"],NSDictionary.class),*actual=r[@"actual_ax"][@"size"];
        fprintf(stderr,"debug: native %s pid=%d wid=%u requested=%gx%g outcome=%s observed=%d actual=%gx%g moved=%d ax_error=%d attempted=%d transaction=%llu effect=%llu\n",((NSString *)DWTyped(r[@"method"],NSString.class)).UTF8String?:"size read",[i[@"pid"]intValue],[i[@"wid"]unsignedIntValue],[asked[@"width"]doubleValue],[asked[@"height"]doubleValue],[r[@"outcome"]description].UTF8String,[r[@"observed"]boolValue],[actual[@"width"]doubleValue],[actual[@"height"]doubleValue],[r[@"moved"]boolValue],[r[@"ax_error"]intValue],[r[@"mutation_attempted"]boolValue],[e[@"transaction"]unsignedLongLongValue],[e[@"effect_id"]unsignedLongLongValue]);};
    self.resize=[[DWResizeCoordinator alloc]initWithCommand:^NSDictionary *(NSDictionary *c){return [weak resizeCall:c];} driver:driver worker:^(DWJob job){dispatch_async(queue,job);} main:^(DWJob job){dispatch_async(dispatch_get_main_queue(),job);}];
    self.resize.enabled=YES;
    self.resize.beforeAdmission=^BOOL(NSDictionary *effect){DWSizeTransition *d=weak;DWNativeResizePresentation *owner=d.nativeResizePresentation;
        return !owner.active||[owner.effect[@"transaction"]isEqual:effect[@"transaction"]];};
    self.resize.prepare=^(NSDictionary *effect,void (^ready)(BOOL)){[weak prepareInteractiveResize:effect ready:ready];};
    // Removal checks run at idle on every observation: a scalar read of the live transaction, not a snapshot. A failed query answers NO and canRemove: asks the command path.
    self.resize.removalAllowed=^BOOL(NSNumber *window,BOOL *allowed){return [weak.desktop sizeTransitionRemovalAllowed:window allowed:allowed];};

    // Native readback (docs/crates/desktop/NATIVE_RESIZE.md): the size a window took is read back from it. Interactive
    // top/left native drags independently hold a snapshot until final placement ACK. App-owned Fill separately holds placement/input until
    // its native animation and a fresh helper ACK settle. An effect unanswered after three seconds is reported as timed out, which ends its
    // transaction. When a transaction has ended, the window is looked at as the poll looks at it: its bounds, its stream's size
    // and the controller's observation follow the size it has, or it is found closed. Then the scene is saved, once.
    self.resize.timeout=3;
    // A resize grab whose pointer rests owes no effect and is no orphan: its press, or its swipe, ends it (-released:at:, gesture_end),
    // and a press or swipe whose end is lost is ended by -endLostInput.
    self.resize.deferred=^BOOL(NSDictionary *effect){DWSizeTransition *d=weak;NSDictionary *deferred=d.nativeRestoreDeferred;
        return [deferred[@"effect"]isEqual:effect]&&[d nativeRestoreDeferredCurrent:deferred snapshot:[d.desktop sizeTransitionSnapshot]];};
    self.resize.held=^BOOL(NSNumber *transaction){return [weak.desktop sizeTransitionHeld:transaction];};
    self.resize.changed=^{DWSizeTransition *d=weak;if(d.desktop.cleaning)return;if(d.resize.failure)d.desktop.statusText=d.resize.failure;
        NSDictionary *transaction=DWTyped([d.desktop sizeTransitionSnapshot][@"native_resize"],NSDictionary.class);
        if(transaction&&[d.resize canRemove:nil]&&!d.resize.obligations&&![d.resizeSavedTransaction isEqual:transaction[@"transaction"]]){d.resizeSavedTransaction=transaction[@"transaction"];
            if(DWDebugTrace())fprintf(stderr,"debug: size transaction %s of #%s ended phase=%s\n",[transaction[@"transaction"]description].UTF8String,[transaction[@"window"]description].UTF8String,((NSString *)DWTyped(transaction[@"phase"],NSString.class)).UTF8String?:"?");
            LiveSource *source=[d.desktop sizeTransitionSource:transaction[@"window"]];if(source&&!source.detached)[d.desktop track:source];[d.desktop saveScene];}
        [d updateNativeFill];[d.desktop render];};
    [self.desktop resizeCapability];
}
// Is the resize transaction on record one a sizing action began, and certain? That one is the controller's: an action or an IPC
// request that arrives while it runs reaches the controller, which continues, coalesces or refuses it as upstream does for a
// window that still owes a configure. A resize the pointer began holds the canvas until it settles, as does every uncertain one.
- (BOOL)sizing {
    if(!self.resize||!self.sizeTransaction)return NO;
    NSDictionary *transaction=DWTyped([self.desktop sizeTransitionSnapshot][@"native_resize"],NSDictionary.class);
    return [transaction[@"transaction"]isEqual:self.sizeTransaction]&&![transaction[@"uncertain_mutation"]boolValue];
}
// The resize coordinator's commands. The native result of a sizing action's transaction is answered with that action's
// continuation: upstream's placement, camera and restore point for the size the window took, or why it took none. The reply
// then gets the tail of an action's reply, on a later turn of the main queue, once the coordinator has consumed its next effect.
// A result that ends its transaction, a pointer resize's included, can be answered with the first effect of another one: the size
// transaction of the next window whose rule's size is still owed (docs/crates/desktop/RULES.md), which may be waiting behind a fullscreen's enter or
// exit as behind any other. The coordinator performs it as it performs every effect a result reply carries; here the transaction
// it names becomes the one -sizing knows as the controller's own, like the one an attach reply begins, so that a press or an
// action does not cancel it and a msg request is not turned away for it. The effect that answers one of the controller's own
// results inside the same transaction is the controller's too, and needs nothing: a fullscreen that is left before the window has
// taken the output's size asks for the old size on the transaction it already has (docs/crates/desktop/FULLSCREEN.md), which -sizing still names.
- (NSDictionary *)resizeCall:(NSDictionary *)command {
    NSDictionary *reply=[self.desktop call:command];
    if(!reply||![command[@"op"]isEqual:@"native_resize_result"])return reply;
    NSDictionary *result=DWTyped(command[@"result"],NSDictionary.class);
    if(self.desktop.native&&[result[@"observed"]boolValue]){
        // Tracking skips a held resize grab. Refresh its native transform basis
        // at this accepted completion, before consume: can render or queue another
        // effect. The router and presenter have separate caches; always bind the
        // accepted observation, once per readback, even if the router is current.
        for(NSDictionary *window in [self.desktop sizeTransitionSnapshot][@"windows"]){
            NSDictionary *source=DWTyped(window[@"source"],NSDictionary.class);LiveSource *live=[self.desktop sizeTransitionSource:window[@"window"]];
            if(!live||live.detached||!boundIdentity(live.identity,command[@"identity"])||!boundIdentity(live.identity,source[@"identity"])||![source[@"generation"]isEqual:command[@"generation"]]||![source[@"observation_known"]boolValue])continue;
            CGRect observed=DWRectFromJSON(source[@"observed_rect"]),prior=CGRectZero;
            if(!CGRectEqualToRect(observed,DWRectFromJSON(result[@"actual_ax"])))break;
            if(!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)live.router.bounds,&prior)||!CGRectEqualToRect(prior,observed))live.router.bounds=CFBridgingRelease(CGRectCreateDictionaryRepresentation(observed));
            CGRect native=DWRectFromJSON(result[@"actual_cg"]);
            if(self.desktop.native.familiesNeeded){
                NSDictionary *family=[self.desktop sizeTransitionFamily:live.identity why:nil]?:@{};
                native=DWResizePresentationNativeBounds(family,live.identity,native);
                [self.desktop.native bound:live.identity bounds:native family:family];
            }else [self.desktop.native bound:live.identity bounds:native];
            break;
        }
    }
    [self.nativeResizePresentation update];
    BOOL own=self.sizeTransaction&&[command[@"transaction"]isEqual:self.sizeTransaction];
    NSNumber *next=DWTyped(sizeEffect(reply)[@"transaction"],NSNumber.class);if(next&&![next isEqual:command[@"transaction"]])self.sizeTransaction=next;
    if(!own)return reply;
    NSMutableDictionary *tail=[reply mutableCopy];[tail removeObjectForKey:@"effect"];__weak DWSizeTransition *weak=self;
    dispatch_async(dispatch_get_main_queue(),^{DWSizeTransition *d=weak;if(!d||d.desktop.cleaning)return;NSString *failure=DWTyped(tail[@"failure"],NSString.class);if(failure)[d.desktop flashStatus:[@"Window not resized: " stringByAppendingString:failure]];[d.desktop applyReply:tail];});
    return reply;
}
- (NSDictionary *)consumeSize:(NSDictionary *)reply {
    NSDictionary *sized=sizeEffect(reply);
    if(sized){
        if(self.nativeRestoreDeferred&&![self.nativeRestoreDeferred[@"effect"]isEqual:sized])[self retireDeferredNativeRestore];
        self.sizeTransaction=DWTyped(sized[@"transaction"],NSNumber.class);
        if(![self deferNativeRestore:sized]){[self prepareNativeFill:sized];[self.resize consume:@{@"effect":sized}];}
    }
    return sized;
}
// Restore can accompany a camera flight to a different window. Keep its exact
// initial read unconsumed while that flight runs: no capture, placement hold,
// worker or native watchdog exists yet, even with a slow configured camera.
- (BOOL)deferNativeRestore:(NSDictionary *)effect {
    if(self.nativeRestoreDeferred)return [self.nativeRestoreDeferred[@"effect"]isEqual:effect];
    if(!self.desktop.nativeDesktopMode||!self.desktop.native||self.desktop.native.ended||self.desktop.cleaning||self.desktop.sessionInactive
        ||self.fillHandoff||self.resize.obligations||![effect[@"op"]isEqual:@"observe_resize_source"]
        ||[self.nativeFillRefusedTransactions containsObject:effect[@"transaction"]])return NO;
    NSDictionary *snapshot=[self.desktop sizeTransitionSnapshot],*transaction=DWTyped(snapshot[@"native_resize"],NSDictionary.class);
    if(![transaction[@"pending_effect"]isEqual:effect]||[transaction[@"interactive"]boolValue]
        ||[transaction[@"baseline_observed"]boolValue]||[transaction[@"cancelled"]boolValue]||[transaction[@"uncertain_mutation"]boolValue])return NO;
    for(NSDictionary *view in snapshot[@"outputs"])if([DWTyped(view[@"fullscreen"],NSDictionary.class)[@"window"]isEqual:effect[@"window"]])return NO;
    NSDictionary *prior=self.nativeFillHistory[effect[@"window"]];
    BOOL remembered=boundIdentity(prior[@"identity"],effect[@"identity"])&&[prior[@"generation"]isEqual:effect[@"generation"]];
    if(!remembered&&![self.nativeResizeDriver hasNativeFillForEffect:effect])return NO;
    LiveSource *source=[self.desktop sizeTransitionSource:effect[@"window"]];NSNumber *output=[self.desktop.nativeViews desiredOwnerForWindow:effect[@"window"]];
    NSDictionary *view=nil;for(NSDictionary *row in snapshot[@"outputs"])if([row[@"id"]isEqual:output]){view=row;break;}
    NSDictionary *flight=DWTyped(DWTyped(DWTyped(snapshot[@"navigation"],NSDictionary.class)[@"flights"],NSDictionary.class)[output.stringValue],NSDictionary.class);
    NSDictionary *camera=DWTyped(flight[@"camera_target"],NSDictionary.class);NSNumber *zoom=DWTyped(flight[@"zoom_target"],NSNumber.class);
    if(!source||source.detached||source.nativeMouseOwnership||!view||!flight||!DWTyped(flight[@"generation"],NSNumber.class)
        ||!DWTyped(camera[@"x"],NSNumber.class)||!DWTyped(camera[@"y"],NSNumber.class)||!isfinite([camera[@"x"]doubleValue])||!isfinite([camera[@"y"]doubleValue])
        ||!zoom||!isfinite(zoom.doubleValue)||zoom.doubleValue<=0)return NO;
    // Presenter receipts use the shell's four-field bound identity. The
    // unchanged controller effect additionally serializes owner:null.
    NSDictionary *deferred=@{@"effect":effect.copy,@"identity":source.identity.copy,@"transaction_state":transaction.copy,@"presenter":self.desktop.native,
        @"session":@(self.desktop.nativeSessionEpoch),@"output":output,@"screen_bounds":view[@"screen_bounds"],
        @"flight_generation":flight[@"generation"],@"camera":camera.copy,@"zoom":zoom};
    if(![self nativeRestoreDeferredCurrent:deferred snapshot:snapshot])return NO;
    self.nativeRestoreDeferred=deferred;
    if(DWDebugTrace())fprintf(stderr,"debug: native restore deferred window=#%s transaction=%llu flight=%llu\n",[effect[@"window"]description].UTF8String,[effect[@"transaction"]unsignedLongLongValue],[flight[@"generation"]unsignedLongLongValue]);
    return YES;
}
- (BOOL)nativeRestoreDeferredCurrent:(NSDictionary *)deferred snapshot:(NSDictionary *)snapshot {
    NSDictionary *effect=deferred[@"effect"];LiveSource *source=[self.desktop sizeTransitionSource:effect[@"window"]];
    if(!deferred||self.desktop.cleaning||DWStopSignal||self.desktop.sessionInactive||self.desktop.native.ended||deferred[@"presenter"]!=self.desktop.native
        ||[deferred[@"session"]unsignedLongLongValue]!=self.desktop.nativeSessionEpoch||!source||source.detached||source.nativeMouseOwnership
        ||source.nativeVisibilityWanted||![source.identity isEqual:deferred[@"identity"]]||!boundIdentity(source.identity,effect[@"identity"])
        ||![DWTyped(snapshot[@"native_resize"],NSDictionary.class)isEqual:deferred[@"transaction_state"]])return NO;
    NSDictionary *binding=nil,*view=nil;
    for(NSDictionary *row in snapshot[@"windows"])if([row[@"window"]isEqual:effect[@"window"]]){binding=DWTyped(row[@"source"],NSDictionary.class);break;}
    for(NSDictionary *row in snapshot[@"outputs"])if([row[@"id"]isEqual:deferred[@"output"]]){view=row;break;}
    if(!boundIdentity(binding[@"identity"],effect[@"identity"])||![binding[@"generation"]isEqual:effect[@"generation"]]
        ||![[self.desktop.nativeViews desiredOwnerForWindow:effect[@"window"]]isEqual:deferred[@"output"]]
        ||![view[@"screen_bounds"]isEqual:deferred[@"screen_bounds"]])return NO;
    NSDictionary *flight=DWTyped(DWTyped(DWTyped(snapshot[@"navigation"],NSDictionary.class)[@"flights"],NSDictionary.class)[[deferred[@"output"]description]],NSDictionary.class);
    if(flight)return [flight[@"generation"]isEqual:deferred[@"flight_generation"]];
    return [view[@"camera"]isEqual:deferred[@"camera"]]&&[view[@"zoom"]isEqual:deferred[@"zoom"]]
        &&(!deferred[@"ready_deadline"]||CACurrentMediaTime()<[deferred[@"ready_deadline"]doubleValue]);
}
- (void)retireDeferredNativeRestore {
    NSDictionary *deferred=self.nativeRestoreDeferred;if(!deferred)return;
    self.nativeRestoreDeferred=nil; // finish can synchronously render/notify.
    NSDictionary *effect=deferred[@"effect"];
    if(!self.nativeFillRefusedTransactions)self.nativeFillRefusedTransactions=[NSMutableSet set];
    [self.nativeFillRefusedTransactions addObject:effect[@"transaction"]];
    if(DWDebugTrace())fprintf(stderr,"debug: native restore deferral retired window=#%s transaction=%llu\n",[effect[@"window"]description].UTF8String,[effect[@"transaction"]unsignedLongLongValue]);
    [self.resize discardDeferredEffect:effect];
}
- (void)updateDeferredNativeRestore {
    NSDictionary *deferred=self.nativeRestoreDeferred;if(!deferred)return;
    NSDictionary *snapshot=[self.desktop sizeTransitionSnapshot];
    if(![self nativeRestoreDeferredCurrent:deferred snapshot:snapshot]){[self retireDeferredNativeRestore];return;}
    if(DWTyped(DWTyped(DWTyped(snapshot[@"navigation"],NSDictionary.class)[@"flights"],NSDictionary.class)[[deferred[@"output"]description]],NSDictionary.class))return;
    // Only the existing preparation allowance starts after the valid flight
    // lands. A missing helper ACK cannot keep a dead resize slot indefinitely.
    if(!deferred[@"ready_deadline"]){NSMutableDictionary *waiting=[deferred mutableCopy];waiting[@"ready_deadline"]=@(CACurrentMediaTime()+2.25);self.nativeRestoreDeferred=deferred=waiting.copy;}
    NSDictionary *effect=deferred[@"effect"],*placement=nil;
    for(NSDictionary *item in [self.desktop presentationSnapshot][@"placements"])if([item[@"window"]isEqual:effect[@"window"]]&&[item[@"output"]isEqual:deferred[@"output"]]){placement=item;break;}
    DWNativeAppliedPlacement *receipt=[self.desktop.native acknowledgedPlacementForWindow:effect[@"window"] identity:deferred[@"identity"] generation:effect[@"generation"] output:deferred[@"output"]];
    if(!placement||!receipt||!CGRectEqualToRect(receipt.requestedScreenRect,DWRectFromJSON(placement[@"screen_rect"]))
        ||!CGRectEqualToRect(receipt.requestedClipRect,DWRectFromJSON(placement[@"clip_rect"]))
        ||!CGRectEqualToRect(receipt.requestedViewport,DWRectFromJSON(deferred[@"screen_bounds"]))||![self.desktop.native isAcknowledgedPlacementCurrent:receipt])return;
    // presentationSnapshot may reconcile ownership. Recheck the saved action
    // after that reconciliation, before acquiring any native placement hold.
    if(![self nativeRestoreDeferredCurrent:deferred snapshot:[self.desktop sizeTransitionSnapshot]]){[self retireDeferredNativeRestore];return;}
    // Same main turn: acquire the normal capture/placement handoff, retire the
    // wait, then admit the original baseline once with ordinary deadlines.
    [self prepareNativeFill:effect];
    if(![self.fillHandoff[@"transaction"]isEqual:effect[@"transaction"]])return;
    self.nativeRestoreDeferred=nil;
    if(DWDebugTrace())fprintf(stderr,"debug: native restore deferral ready window=#%s transaction=%llu sequence=%llu\n",[effect[@"window"]description].UTF8String,[effect[@"transaction"]unsignedLongLongValue],(unsigned long long)receipt.sequence);
    [self.resize consume:@{@"effect":effect}];
}
// Withhold before the baseline worker starts: the logical fullscreen commit
// must not first park or jump its physical source. Only this one transaction
// owns the handoff; identity loss, cancellation and quit preserve normal restore.
- (void)clearNativeFillPresentation {
    [self retireDeferredNativeRestore];
    [self.nativeResizeDriver clearPreparedBaseline];
    // A cancelled prepared transaction must not become an unprepared fallback
    // when its already queued worker next consults readiness.
    if(self.fillHandoff&&!self.nativeFillResuming){if(!self.nativeFillRefusedTransactions)self.nativeFillRefusedTransactions=[NSMutableSet set];[self.nativeFillRefusedTransactions addObject:self.fillHandoff[@"transaction"]];}
    // Invalidate the callbacks before cancellation can synchronously complete.
    id<DWSizeTransitionCaptureRequest> capture=self.nativeFillCapture;id<DWSizeTransitionPicture> picture=self.nativeFillPicture;
    if(self.fillHandoff[@"presenter"]==self.acknowledgementPresenter)[self observeAcknowledgementsFrom:nil];
    self.fillHandoff=nil;self.nativeFillCapture=nil;self.nativeFillPicture=nil;self.nativeFillRoot=nil;self.desktop.nativeViewSnapshot=nil;self.nativeFillBackgroundTrace=nil;
    self.nativeFillResuming=NO;self.nativeFillHiding=NO;self.nativeFillAnimating=NO;self.nativeFillAnimated=NO;self.nativeFillRevealing=NO;self.nativeFillPresentationDeadline=0;
    self.nativeResizeDriver.fillPreparationTimeout=.75;self.resize.timeout=3;
    [capture cancel];[picture cancel];
}
- (BOOL)nativeFillCurrent:(NSDictionary *)held snapshot:(NSDictionary *)snapshot {
    LiveSource *source=[self.desktop sizeTransitionSource:held[@"window"]];
    if(!held||self.desktop.cleaning||self.desktop.sessionInactive||self.desktop.native.ended||held[@"presenter"]!=self.desktop.native
        ||[held[@"session"]unsignedLongLongValue]!=self.desktop.nativeSessionEpoch||!source||source.detached||source.nativeVisibilityWanted||!boundIdentity(source.identity,held[@"identity"]))return NO;
    NSDictionary *binding=nil,*view=nil;
    for(NSDictionary *row in snapshot[@"windows"])if([row[@"window"]isEqual:held[@"window"]]){binding=DWTyped(row[@"source"],NSDictionary.class);break;}
    for(NSDictionary *row in snapshot[@"outputs"])if([row[@"id"]isEqual:held[@"output"]]){view=row;break;}
    return boundIdentity(binding[@"identity"],held[@"identity"])&&[binding[@"generation"]isEqual:held[@"generation"]]
        &&[[self.desktop.nativeViews desiredOwnerForWindow:held[@"window"]]isEqual:held[@"output"]]
        &&[view[@"camera"]isEqual:held[@"camera"]]&&[view[@"zoom"]isEqual:held[@"zoom"]]&&[view[@"screen_bounds"]isEqual:held[@"screen_bounds"]];
}
- (void)prepareNativeFill:(NSDictionary *)effect {
    if(!self.desktop.nativeDesktopMode||!self.desktop.native||self.desktop.native.ended||self.desktop.cleaning||self.desktop.sessionInactive||self.fillHandoff)return;
    NSDictionary *snapshot=[self.desktop sizeTransitionSnapshot],*transaction=DWTyped(snapshot[@"native_resize"],NSDictionary.class);
    if(![transaction[@"transaction"]isEqual:effect[@"transaction"]]||[transaction[@"interactive"]boolValue])return;
    BOOL fullscreen=NO;for(NSDictionary *output in snapshot[@"outputs"]){NSDictionary *entry=DWTyped(output[@"fullscreen"],NSDictionary.class);if([entry[@"window"]isEqual:effect[@"window"]])fullscreen=YES;}
    NSDictionary *prior=self.nativeFillHistory[effect[@"window"]];
    BOOL remembered=boundIdentity(prior[@"identity"],effect[@"identity"])&&[prior[@"generation"]isEqual:effect[@"generation"]];
    BOOL restoring=!fullscreen&&([self.nativeResizeDriver hasNativeFillForEffect:effect]||remembered);
    LiveSource *source=[self.desktop sizeTransitionSource:effect[@"window"]];if((!fullscreen&&!restoring)||!source||source.detached||source.nativeVisibilityWanted||source.nativeMinimized||source.nativeMouseOwnership||!boundIdentity(source.identity,effect[@"identity"]))return;
    NSNumber *output=[self.desktop.nativeViews desiredOwnerForWindow:source.logical];NSDictionary *view=nil,*binding=nil;
    for(NSDictionary *row in snapshot[@"outputs"])if([row[@"id"]isEqual:output]){view=row;break;}
    for(NSDictionary *row in snapshot[@"windows"])if([row[@"window"]isEqual:source.logical]){binding=DWTyped(row[@"source"],NSDictionary.class);break;}
    if(!view||!boundIdentity(binding[@"identity"],source.identity)||![binding[@"generation"]isEqual:effect[@"generation"]])return;
    NSDictionary *window=[self.desktop sizeTransitionWindowInfo:source.router.wid];CGRect native=CGRectZero,displayed=CGRectZero;
    BOOL geometry=[self.desktop sizeTransitionNativeBounds:source.router.wid bounds:&native]&&[window[(id)kCGWindowBounds]isKindOfClass:NSDictionary.class]
        &&CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)window[(id)kCGWindowBounds],&displayed);
    // Infinify owns this transition at every zoom. A covered direct resize
    // avoids starting AppKit Fill and later waiting for its Unfill animation.
    // Unsupported families retain the existing withheld native fallback.
    DWNativeHiddenRoot *root=geometry?[self.desktop.native beginTransitionForWindow:source.identity]:nil;
    if(!root&&![self.desktop.native withholdWindow:source.identity])return;
    if(restoring)[self.nativeFillHistory removeObjectForKey:source.logical];
    else if(root){if(!self.nativeFillHistory)self.nativeFillHistory=[NSMutableDictionary dictionary];self.nativeFillHistory[source.logical]=@{@"identity":source.identity.copy,@"generation":effect[@"generation"]};}
    self.nativeFillRoot=root;self.nativeFillHiding=NO;self.nativeFillAnimating=NO;self.nativeFillAnimated=NO;self.nativeFillRevealing=NO;self.nativeFillPresentationDeadline=0;
    self.fillHandoff=@{@"window":effect[@"window"],@"transaction":effect[@"transaction"],@"identity":source.identity.copy,@"generation":effect[@"generation"],@"restoring":@(restoring),@"presenter":self.desktop.native,@"session":@(self.desktop.nativeSessionEpoch),@"output":output,@"camera":view[@"camera"],@"zoom":view[@"zoom"],@"screen_bounds":view[@"screen_bounds"],@"background":root&&!restoring?(self.desktop.nativeOwnerSnapshot?:@{}):@{}};self.nativeFillResuming=NO;
    [self observeAcknowledgementsFrom:self.desktop.native];
    self.nativeResizeDriver.fillPreparationTimeout=root?2.5:.75;self.resize.timeout=root?7:3;
    [self.desktop cancelNativeHoverForWindow:nil];[self.desktop cancelCapturedInputForWindow:nil];self.desktop.nativeViewSnapshot=nil;
    if(DWDebugTrace())fprintf(stderr,"debug: native fill handoff window=#%s native=%g,%g %gx%g displayed=%g,%g %gx%g snapshot=%d restore=%d\n",source.logical.description.UTF8String,native.origin.x,native.origin.y,native.size.width,native.size.height,displayed.origin.x,displayed.origin.y,displayed.size.width,displayed.size.height,root!=nil,restoring);
    if(root){
        __weak DWSizeTransition *weak=self;NSDictionary *held=self.fillHandoff;
        BOOL (^valid)(void)=^BOOL{DWSizeTransition *d=weak;return d&&d.nativeFillRoot==root&&!d.nativeFillResuming
            &&[d.fillHandoff[@"transaction"]isEqual:held[@"transaction"]]
            &&[d nativeFillCurrent:held snapshot:[d.desktop sizeTransitionSnapshot]];};
        // Snapshot preparation can occupy main longer than the ordinary
        // setter admission budget. Only this exact, read-only baseline may
        // wait for it; its effect, session and handoff are checked again then.
        [self.nativeResizeDriver prepareBaseline:effect validate:^BOOL{
            DWSizeTransition *d=weak;if(!valid())return NO;
            NSDictionary *current=DWTyped([d.desktop sizeTransitionSnapshot][@"native_resize"],NSDictionary.class);
            return ![current[@"cancelled"]boolValue]&&[current[@"pending_effect"]isEqual:effect]
                &&![d.nativeFillRefusedTransactions containsObject:effect[@"transaction"]];
        }];
        self.nativeFillCapture=self.capture(root,NO,valid,^(DWSizeTransitionPictureFactory makePicture,NSString *failure){
            DWSizeTransition *d=weak;if(!valid())return;d.nativeFillCapture=nil;
            id<DWSizeTransitionPicture> picture=makePicture?makePicture():nil;
            if(picture&&[picture show]){d.nativeFillPicture=picture;[d updateNativeFill];[d.desktop render];}
            else {NSMutableDictionary *failed=[d.fillHandoff mutableCopy];failed[@"bridge_failed"]=@YES;d.fillHandoff=failed;
                if(DWDebugTrace())fprintf(stderr,"debug: native transition capture refused window=#%s reason=%s\n",[held[@"window"]description].UTF8String,(failure?:@"snapshot panel unavailable").UTF8String);}
        });
    }
}
- (void)interruptFillForVisibility:(LiveSource *)source {
    NSDictionary *held=self.fillHandoff;
    if(!source||![held[@"window"]isEqual:source.logical]||!boundIdentity(held[@"identity"],source.identity))return;
    // Retire temporary hide/reveal phases without ever describing a resumed
    // frame. The same main turn keeps the family omitted and journalled.
    [self clearNativeFillPresentation]; // invalidate asynchronous capture/animation callbacks first
    if(held[@"presenter"]==self.desktop.native&&[held[@"session"]unsignedLongLongValue]==self.desktop.nativeSessionEpoch){
        [self.desktop.native resumeWindow:source.identity];source.nativeVisibilityHeld=[self.desktop.native withholdWindow:source.identity];
    }
}
- (void)updateNativeFill {
    [self updateDeferredNativeRestore];
    NSDictionary *held=self.fillHandoff;if(!held)return;
    LiveSource *visibilitySource=[self.desktop sizeTransitionSource:held[@"window"]];
    if(visibilitySource.nativeVisibilityWanted){[self interruptFillForVisibility:visibilitySource];return;}
    NSDictionary *snapshot=[self.desktop sizeTransitionSnapshot],*transaction=DWTyped(snapshot[@"native_resize"],NSDictionary.class);
    BOOL gone=![self nativeFillCurrent:held snapshot:snapshot];
    BOOL finished=![transaction[@"transaction"]isEqual:held[@"transaction"]]||([self.resize canRemove:held[@"window"]]&&!self.resize.obligations);
    // A canvas transition can need no native setter (the app was already
    // screen-sized). Its resize transaction may finish before capture, but the
    // displayed projection still needs the same snapshot/hide/animate handoff.
    if(!gone&&finished&&self.nativeFillRoot&&self.nativeFillCapture&&!self.nativeFillCapture.completed)return;
    if(!gone&&self.nativeFillRoot&&self.nativeFillPicture&&!self.nativeFillHiding){
        if([self.desktop.native hideTransition:self.nativeFillRoot]){self.nativeFillHiding=YES;if(DWDebugTrace())fprintf(stderr,"debug: native transition hide window=#%s\n",[held[@"window"]description].UTF8String);}
        else if(finished){
            // Capture and omission ACK arrive independently. A no-setter
            // transaction must not cancel its picture merely because the
            // presenter's initial omission is still in flight.
            if(!self.nativeFillPresentationDeadline)self.nativeFillPresentationDeadline=CACurrentMediaTime()+2.5;
            if(CACurrentMediaTime()<self.nativeFillPresentationDeadline)return;
        }
    }
    NSDictionary *finalPlacement=nil;
    if(finished)for(NSDictionary *item in [self.desktop presentationSnapshot][@"placements"])if([item[@"window"]isEqual:held[@"window"]]&&[item[@"output"]isEqual:held[@"output"]]){finalPlacement=item;break;}
    BOOL targetCurrent=!held[@"target"]||(finalPlacement&&CGRectEqualToRect(DWRectFromJSON(finalPlacement[@"screen_rect"]),DWRectFromJSON(held[@"target"])));
    BOOL bridge=finished&&!gone&&targetCurrent&&!self.nativeFillResuming&&self.nativeFillRoot&&self.nativeFillPicture&&self.nativeFillHiding;
    if(bridge){
        if(!self.nativeFillPresentationDeadline)self.nativeFillPresentationDeadline=CACurrentMediaTime()+2.5;
        if(![self.desktop.native isTransitionRevealed:self.nativeFillRoot]&&CACurrentMediaTime()<self.nativeFillPresentationDeadline){
            if(!self.nativeFillAnimating&&[self.desktop.native isTransitionHidden:self.nativeFillRoot]){
                NSDictionary *placement=finalPlacement;CGRect clip=DWRectFromJSON(placement[@"clip_rect"]);
                if(placement&&clip.size.width>0&&clip.size.height>0){
                    CGRect target=DWRectFromJSON(placement[@"screen_rect"]);
                    DWNativeHiddenRoot *root=self.nativeFillRoot;self.nativeFillAnimating=YES;__weak DWSizeTransition *weak=self;
                    NSMutableDictionary *frozen=[self.fillHandoff mutableCopy];frozen[@"target"]=DWRectJSON(target);self.fillHandoff=frozen.copy;
                    void (^reveal)(BOOL)=^(BOOL completed){DWSizeTransition *d=weak;if(!d||d.nativeFillRoot!=root||d.nativeFillResuming)return;
                        NSDictionary *now=[d.desktop sizeTransitionSnapshot];BOOL targetMatches=NO;
                        for(NSDictionary *item in [d.desktop presentationSnapshot][@"placements"])if([item[@"window"]isEqual:held[@"window"]]&&[item[@"output"]isEqual:held[@"output"]]&&CGRectEqualToRect(DWRectFromJSON(item[@"screen_rect"]),target))targetMatches=YES;
                        BOOL current=[d nativeFillCurrent:held snapshot:now];
                        if(!completed||!targetMatches||!current){if(DWDebugTrace())fprintf(stderr,"debug: native transition completion refused window=#%s completed=%d target=%d current=%d\n",[held[@"window"]description].UTF8String,completed,targetMatches,current);d.nativeFillPresentationDeadline=CACurrentMediaTime();return;}
                        d.nativeFillAnimated=YES;d.desktop.nativeViewSnapshot=nil;
                        if(DWDebugTrace())fprintf(stderr,"debug: native transition animated window=#%s\n",[held[@"window"]description].UTF8String);
                        [d.desktop render];};
                    BOOL accepted=[self.nativeFillPicture animateToScreenRect:target completion:reveal];
                    if(DWDebugTrace())fprintf(stderr,"debug: native transition animate window=#%s target=%g,%g %gx%g accepted=%d\n",[held[@"window"]description].UTF8String,target.origin.x,target.origin.y,target.size.width,target.size.height,accepted);
                    if(!accepted)self.nativeFillPresentationDeadline=CACurrentMediaTime();
                }else self.nativeFillPresentationDeadline=0;
            }
            // Animation completion and the helper's global omission ACK can
            // arrive in either order. Keep the completed picture while waiting
            // for the same exact target to become revealable; do not restart
            // animation or extend the bounded presentation deadline.
            if(self.nativeFillAnimated&&!self.nativeFillRevealing&&finalPlacement){
                CGRect target=DWRectFromJSON(finalPlacement[@"screen_rect"]);
                double alpha=finalPlacement[@"opacity"]?[finalPlacement[@"opacity"]doubleValue]:1;
                self.nativeFillRevealing=[self.desktop.native revealTransition:self.nativeFillRoot screen:target alpha:alpha];
                if(self.nativeFillRevealing&&DWDebugTrace())fprintf(stderr,"debug: native transition reveal window=#%s accepted=1\n",[held[@"window"]description].UTF8String);
            }
            if(self.nativeFillPresentationDeadline)return;
        }
    }
    if(!self.nativeFillResuming&&(gone||finished)){
        if(DWDebugTrace())fprintf(stderr,"debug: native transition resume window=#%s gone=%d finished=%d placement=%d hidden=%d animating=%d revealing=%d\n",[held[@"window"]description].UTF8String,gone,finished,finalPlacement!=nil,self.nativeFillHiding,self.nativeFillAnimating,self.nativeFillRevealing);
        [self.nativeFillCapture cancel];self.nativeFillCapture=nil;
        if(held[@"presenter"]==self.desktop.native&&[held[@"session"]unsignedLongLongValue]==self.desktop.nativeSessionEpoch)[self.desktop.native resumeWindow:held[@"identity"]];
        self.nativeFillResuming=YES;self.desktop.nativeViewSnapshot=nil;
    }
    if(gone){if(!self.nativeFillRefusedTransactions)self.nativeFillRefusedTransactions=[NSMutableSet set];[self.nativeFillRefusedTransactions addObject:held[@"transaction"]];[self clearNativeFillPresentation];return;}
    if(self.nativeFillResuming){
        NSNumber *output=[self.desktop.nativeViews desiredOwnerForWindow:held[@"window"]];
        NSNumber *generation=nil;for(NSDictionary *window in snapshot[@"windows"])if([window[@"window"]isEqual:held[@"window"]]&&boundIdentity(window[@"source"][@"identity"],held[@"identity"]))generation=window[@"source"][@"generation"];
        DWNativeAppliedPlacement *placed=[self.desktop.native acknowledgedPlacementForWindow:held[@"window"] identity:held[@"identity"] generation:generation output:output];
        if(placed||!output||!generation){[self clearNativeFillPresentation];
            if(DWDebugTrace())fprintf(stderr,"debug: native fill handoff resumed window=#%s sequence=%llu\n",[held[@"window"]description].UTF8String,(unsigned long long)placed.sequence);}
    }
}
- (NSDictionary *)nativeFillBackground:(NSDictionary *)snapshot {
    NSDictionary *held=self.fillHandoff,*prior=held[@"background"];
    if(!prior.count||!self.nativeFillRoot||self.nativeFillAnimated||self.nativeFillResuming||[held[@"bridge_failed"]boolValue])return snapshot;
    void (^trace)(NSString *,NSDictionary *)=^(NSString *reason,NSDictionary *counts){
        if(!DWDebugTrace())return;NSArray *entry=@[held[@"transaction"],reason,counts];if([self.nativeFillBackgroundTrace isEqual:entry])return;
        self.nativeFillBackgroundTrace=entry;NSData *encoded=[NSJSONSerialization dataWithJSONObject:counts options:0 error:nil];
        fprintf(stderr,"debug: native transition background window=#%s transaction=%llu reason=%s counts=%s time=%.6f\n",[held[@"window"]description].UTF8String,[held[@"transaction"]unsignedLongLongValue],reason.UTF8String,[[NSString alloc]initWithData:encoded encoding:NSUTF8StringEncoding].UTF8String,CACurrentMediaTime());
    };
    if(![self nativeFillCurrent:held snapshot:snapshot]){trace(@"handoff_changed",@{});return snapshot;}
    NSDictionary *oldOutput=nil;for(NSDictionary *row in prior[@"outputs"])if([row[@"id"]isEqual:held[@"output"]]){oldOutput=row;break;}
    // Fullscreen deliberately rounds its parked camera and sets zoom to one.
    // Keep the prior SCREEN placements across that logical change; requiring
    // the old camera/zoom to equal the parked view discarded every scaled hold.
    // nativeFillCurrent above still fences any later parked-view change.
    if(!oldOutput||![oldOutput[@"screen_bounds"]isEqual:held[@"screen_bounds"]]){trace(@"output_changed",@{});return snapshot;}
    NSMutableDictionary *before=[NSMutableDictionary dictionary],*now=[NSMutableDictionary dictionary];
    for(NSDictionary *row in prior[@"windows"])if(row[@"window"])before[row[@"window"]]=row;
    for(NSDictionary *row in snapshot[@"windows"])if(row[@"window"])now[row[@"window"]]=row;
    NSMutableArray *placements=[asArray(snapshot[@"placements"])mutableCopy];NSMutableSet *placed=[NSMutableSet set];
    for(NSDictionary *row in placements)if(row[@"window"])[placed addObject:row[@"window"]];
    NSUInteger excluded=0,changedSource=0,changedWindow=0,retained=0;
    for(NSDictionary *placement in prior[@"placements"]){
        NSNumber *window=placement[@"window"];NSDictionary *old=before[window],*current=now[window],*source=DWTyped(current[@"source"],NSDictionary.class);LiveSource *live=[self.desktop sizeTransitionSource:window];
        if(!window||[window isEqual:held[@"window"]]||[placed containsObject:window]||![placement[@"output"]isEqual:held[@"output"]]){excluded++;continue;}
        if(!old||!current||!live||live.detached||live.nativeMouseOwnership||!boundIdentity(source[@"identity"],live.identity)
            ||![source isEqual:placement[@"source"]]){changedSource++;continue;}
        BOOL pinned=[placement[@"pinned"]boolValue]&&DWTyped(old[@"pinned"],NSDictionary.class);
        BOOL same=YES;for(NSString *key in @[@"source",@"world_rect",@"pinned",@"widget",@"mode",@"kind"]){
            // A pin's world rectangle follows the parked camera; its exact
            // output/screen pin descriptor is the physical projection basis.
            if(pinned&&[key isEqual:@"world_rect"])continue;
            if(![(old[key]?:NSNull.null)isEqual:current[key]?:NSNull.null]){same=NO;break;}
        }
        if(same){[placements addObject:placement];[placed addObject:window];retained++;}else changedWindow++;
    }
    trace(@"projected",@{@"prior":@([prior[@"placements"]count]),@"current":@([snapshot[@"placements"]count]),@"retained":@(retained),@"excluded":@(excluded),@"changed_source":@(changedSource),@"changed_window":@(changedWindow)});
    if(placements.count==[snapshot[@"placements"]count])return snapshot;
    NSMutableDictionary *covered=[snapshot mutableCopy];covered[@"placements"]=placements.copy;return covered.copy;
}
@end
