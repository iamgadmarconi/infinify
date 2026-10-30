// SPDX-License-Identifier: GPL-3.0-or-later
// Split from native/desktop/main.m at 37b27b1, moved verbatim.
// Desktop native Fill handoff and deferred native restore.
#import "Desktop+Private.h"
#import "DWDebugTrace.h"
#import "DWGeometryJSON.h"
@implementation Desktop (Fill)
// Restore can accompany a camera flight to a different window. Keep its exact
// initial read unconsumed while that flight runs: no capture, placement hold,
// worker or native watchdog exists yet, even with a slow configured camera.
- (BOOL)deferNativeRestore:(NSDictionary *)effect {
    if(self.nativeRestoreDeferred)return [self.nativeRestoreDeferred[@"effect"]isEqual:effect];
    if(!self.nativeDesktopMode||!self.native||self.native.ended||self.cleaning||self.sessionInactive
        ||self.nativeFillHandoff||self.resize.obligations||![effect[@"op"]isEqual:@"observe_resize_source"]
        ||[self.nativeFillRefusedTransactions containsObject:effect[@"transaction"]])return NO;
    NSDictionary *snapshot=[self call:@{@"op":@"snapshot"}],*transaction=DWTyped(snapshot[@"native_resize"],NSDictionary.class);
    if(![transaction[@"pending_effect"]isEqual:effect]||[transaction[@"interactive"]boolValue]
        ||[transaction[@"baseline_observed"]boolValue]||[transaction[@"cancelled"]boolValue]||[transaction[@"uncertain_mutation"]boolValue])return NO;
    for(NSDictionary *view in snapshot[@"outputs"])if([DWTyped(view[@"fullscreen"],NSDictionary.class)[@"window"]isEqual:effect[@"window"]])return NO;
    NSDictionary *prior=self.nativeFillHistory[effect[@"window"]];
    BOOL remembered=boundIdentity(prior[@"identity"],effect[@"identity"])&&[prior[@"generation"]isEqual:effect[@"generation"]];
    if(!remembered&&![self.nativeResizeDriver hasNativeFillForEffect:effect])return NO;
    LiveSource *source=self.sources[effect[@"window"]];NSNumber *output=[self.nativeViews desiredOwnerForWindow:effect[@"window"]];
    NSDictionary *view=nil;for(NSDictionary *row in snapshot[@"outputs"])if([row[@"id"]isEqual:output]){view=row;break;}
    NSDictionary *flight=DWTyped(DWTyped(DWTyped(snapshot[@"navigation"],NSDictionary.class)[@"flights"],NSDictionary.class)[output.stringValue],NSDictionary.class);
    NSDictionary *camera=DWTyped(flight[@"camera_target"],NSDictionary.class);NSNumber *zoom=DWTyped(flight[@"zoom_target"],NSNumber.class);
    if(!source||source.detached||source.nativeMouseOwnership||!view||!flight||!DWTyped(flight[@"generation"],NSNumber.class)
        ||!DWTyped(camera[@"x"],NSNumber.class)||!DWTyped(camera[@"y"],NSNumber.class)||!isfinite([camera[@"x"]doubleValue])||!isfinite([camera[@"y"]doubleValue])
        ||!zoom||!isfinite(zoom.doubleValue)||zoom.doubleValue<=0)return NO;
    // Presenter receipts use the shell's four-field bound identity. The
    // unchanged controller effect additionally serializes owner:null.
    NSDictionary *deferred=@{@"effect":effect.copy,@"identity":source.identity.copy,@"transaction_state":transaction.copy,@"presenter":self.native,
        @"session":@(self.nativeSessionEpoch),@"output":output,@"screen_bounds":view[@"screen_bounds"],
        @"flight_generation":flight[@"generation"],@"camera":camera.copy,@"zoom":zoom};
    if(![self nativeRestoreDeferredCurrent:deferred snapshot:snapshot])return NO;
    self.nativeRestoreDeferred=deferred;
    if(DWDebugTrace())fprintf(stderr,"debug: native restore deferred window=#%s transaction=%llu flight=%llu\n",[effect[@"window"]description].UTF8String,[effect[@"transaction"]unsignedLongLongValue],[flight[@"generation"]unsignedLongLongValue]);
    return YES;
}
- (BOOL)nativeRestoreDeferredCurrent:(NSDictionary *)deferred snapshot:(NSDictionary *)snapshot {
    NSDictionary *effect=deferred[@"effect"];LiveSource *source=self.sources[effect[@"window"]];
    if(!deferred||self.cleaning||DWStopSignal||self.sessionInactive||self.native.ended||deferred[@"presenter"]!=self.native
        ||[deferred[@"session"]unsignedLongLongValue]!=self.nativeSessionEpoch||!source||source.detached||source.nativeMouseOwnership
        ||source.nativeVisibilityWanted||![source.identity isEqual:deferred[@"identity"]]||!boundIdentity(source.identity,effect[@"identity"])
        ||![DWTyped(snapshot[@"native_resize"],NSDictionary.class)isEqual:deferred[@"transaction_state"]])return NO;
    NSDictionary *binding=nil,*view=nil;
    for(NSDictionary *row in snapshot[@"windows"])if([row[@"window"]isEqual:effect[@"window"]]){binding=DWTyped(row[@"source"],NSDictionary.class);break;}
    for(NSDictionary *row in snapshot[@"outputs"])if([row[@"id"]isEqual:deferred[@"output"]]){view=row;break;}
    if(!boundIdentity(binding[@"identity"],effect[@"identity"])||![binding[@"generation"]isEqual:effect[@"generation"]]
        ||![[self.nativeViews desiredOwnerForWindow:effect[@"window"]]isEqual:deferred[@"output"]]
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
    NSDictionary *snapshot=[self call:@{@"op":@"snapshot"}];
    if(![self nativeRestoreDeferredCurrent:deferred snapshot:snapshot]){[self retireDeferredNativeRestore];return;}
    if(DWTyped(DWTyped(DWTyped(snapshot[@"navigation"],NSDictionary.class)[@"flights"],NSDictionary.class)[[deferred[@"output"]description]],NSDictionary.class))return;
    // Only the existing preparation allowance starts after the valid flight
    // lands. A missing helper ACK cannot keep a dead resize slot indefinitely.
    if(!deferred[@"ready_deadline"]){NSMutableDictionary *waiting=[deferred mutableCopy];waiting[@"ready_deadline"]=@(CACurrentMediaTime()+2.25);self.nativeRestoreDeferred=deferred=waiting.copy;}
    NSDictionary *effect=deferred[@"effect"],*placement=nil;
    for(NSDictionary *item in [self presentationSnapshot][@"placements"])if([item[@"window"]isEqual:effect[@"window"]]&&[item[@"output"]isEqual:deferred[@"output"]]){placement=item;break;}
    DWNativeAppliedPlacement *receipt=[self.native acknowledgedPlacementForWindow:effect[@"window"] identity:deferred[@"identity"] generation:effect[@"generation"] output:deferred[@"output"]];
    if(!placement||!receipt||!CGRectEqualToRect(receipt.requestedScreenRect,DWRectFromJSON(placement[@"screen_rect"]))
        ||!CGRectEqualToRect(receipt.requestedClipRect,DWRectFromJSON(placement[@"clip_rect"]))
        ||!CGRectEqualToRect(receipt.requestedViewport,DWRectFromJSON(deferred[@"screen_bounds"]))||![self.native isAcknowledgedPlacementCurrent:receipt])return;
    // presentationSnapshot may reconcile ownership. Recheck the saved action
    // after that reconciliation, before acquiring any native placement hold.
    if(![self nativeRestoreDeferredCurrent:deferred snapshot:[self call:@{@"op":@"snapshot"}]]){[self retireDeferredNativeRestore];return;}
    // Same main turn: acquire the normal capture/placement handoff, retire the
    // wait, then admit the original baseline once with ordinary deadlines.
    [self prepareNativeFill:effect];
    if(![self.nativeFillHandoff[@"transaction"]isEqual:effect[@"transaction"]])return;
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
    if(self.nativeFillHandoff&&!self.nativeFillResuming){if(!self.nativeFillRefusedTransactions)self.nativeFillRefusedTransactions=[NSMutableSet set];[self.nativeFillRefusedTransactions addObject:self.nativeFillHandoff[@"transaction"]];}
    // Invalidate the callbacks before cancellation can synchronously complete.
    DWNativeTransitionCapture *capture=self.nativeFillCapture;DWNativeTransition *picture=self.nativeFillPicture;
    DWNativePresenter *presenter=self.nativeFillHandoff[@"presenter"];presenter.transitionFrameAcknowledged=nil;
    self.nativeFillHandoff=nil;self.nativeFillCapture=nil;self.nativeFillPicture=nil;self.nativeFillRoot=nil;self.nativeViewSnapshot=nil;self.nativeFillBackgroundTrace=nil;
    self.nativeFillResuming=NO;self.nativeFillHiding=NO;self.nativeFillAnimating=NO;self.nativeFillAnimated=NO;self.nativeFillRevealing=NO;self.nativeFillPresentationDeadline=0;
    self.nativeResizeDriver.fillPreparationTimeout=.75;self.resize.timeout=3;
    [capture cancel];[picture cancel];
}
- (BOOL)nativeFillCurrent:(NSDictionary *)held snapshot:(NSDictionary *)snapshot {
    LiveSource *source=self.sources[held[@"window"]];
    if(!held||self.cleaning||self.sessionInactive||self.native.ended||held[@"presenter"]!=self.native
        ||[held[@"session"]unsignedLongLongValue]!=self.nativeSessionEpoch||!source||source.detached||source.nativeVisibilityWanted||!boundIdentity(source.identity,held[@"identity"]))return NO;
    NSDictionary *binding=nil,*view=nil;
    for(NSDictionary *row in snapshot[@"windows"])if([row[@"window"]isEqual:held[@"window"]]){binding=DWTyped(row[@"source"],NSDictionary.class);break;}
    for(NSDictionary *row in snapshot[@"outputs"])if([row[@"id"]isEqual:held[@"output"]]){view=row;break;}
    return boundIdentity(binding[@"identity"],held[@"identity"])&&[binding[@"generation"]isEqual:held[@"generation"]]
        &&[[self.nativeViews desiredOwnerForWindow:held[@"window"]]isEqual:held[@"output"]]
        &&[view[@"camera"]isEqual:held[@"camera"]]&&[view[@"zoom"]isEqual:held[@"zoom"]]&&[view[@"screen_bounds"]isEqual:held[@"screen_bounds"]];
}
- (void)prepareNativeFill:(NSDictionary *)effect {
    if(!self.nativeDesktopMode||!self.native||self.native.ended||self.cleaning||self.sessionInactive||self.nativeFillHandoff)return;
    NSDictionary *snapshot=[self call:@{@"op":@"snapshot"}],*transaction=DWTyped(snapshot[@"native_resize"],NSDictionary.class);
    if(![transaction[@"transaction"]isEqual:effect[@"transaction"]]||[transaction[@"interactive"]boolValue])return;
    BOOL fullscreen=NO;for(NSDictionary *output in snapshot[@"outputs"]){NSDictionary *entry=DWTyped(output[@"fullscreen"],NSDictionary.class);if([entry[@"window"]isEqual:effect[@"window"]])fullscreen=YES;}
    NSDictionary *prior=self.nativeFillHistory[effect[@"window"]];
    BOOL remembered=boundIdentity(prior[@"identity"],effect[@"identity"])&&[prior[@"generation"]isEqual:effect[@"generation"]];
    BOOL restoring=!fullscreen&&([self.nativeResizeDriver hasNativeFillForEffect:effect]||remembered);
    LiveSource *source=self.sources[effect[@"window"]];if((!fullscreen&&!restoring)||!source||source.detached||source.nativeVisibilityWanted||source.nativeMinimized||source.nativeMouseOwnership||!boundIdentity(source.identity,effect[@"identity"]))return;
    NSNumber *output=[self.nativeViews desiredOwnerForWindow:source.logical];NSDictionary *view=nil,*binding=nil;
    for(NSDictionary *row in snapshot[@"outputs"])if([row[@"id"]isEqual:output]){view=row;break;}
    for(NSDictionary *row in snapshot[@"windows"])if([row[@"window"]isEqual:source.logical]){binding=DWTyped(row[@"source"],NSDictionary.class);break;}
    if(!view||!boundIdentity(binding[@"identity"],source.identity)||![binding[@"generation"]isEqual:effect[@"generation"]])return;
    NSDictionary *window=windowInfo(source.router.wid);CGRect native=CGRectZero,displayed=CGRectZero;
    BOOL geometry=DWNativeBounds(source.router.wid,&native)&&[window[(id)kCGWindowBounds]isKindOfClass:NSDictionary.class]
        &&CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)window[(id)kCGWindowBounds],&displayed);
    // Infinify owns this transition at every zoom. A covered direct resize
    // avoids starting AppKit Fill and later waiting for its Unfill animation.
    // Unsupported families retain the existing withheld native fallback.
    DWNativeHiddenRoot *root=geometry?[self.native beginTransitionForWindow:source.identity]:nil;
    if(!root&&![self.native withholdWindow:source.identity])return;
    if(restoring)[self.nativeFillHistory removeObjectForKey:source.logical];
    else if(root){if(!self.nativeFillHistory)self.nativeFillHistory=[NSMutableDictionary dictionary];self.nativeFillHistory[source.logical]=@{@"identity":source.identity.copy,@"generation":effect[@"generation"]};}
    self.nativeFillRoot=root;self.nativeFillHiding=NO;self.nativeFillAnimating=NO;self.nativeFillAnimated=NO;self.nativeFillRevealing=NO;self.nativeFillPresentationDeadline=0;
    self.nativeFillHandoff=@{@"window":effect[@"window"],@"transaction":effect[@"transaction"],@"identity":source.identity.copy,@"generation":effect[@"generation"],@"restoring":@(restoring),@"presenter":self.native,@"session":@(self.nativeSessionEpoch),@"output":output,@"camera":view[@"camera"],@"zoom":view[@"zoom"],@"screen_bounds":view[@"screen_bounds"],@"background":root&&!restoring?(self.nativeOwnerSnapshot?:@{}):@{}};self.nativeFillResuming=NO;
    __weak Desktop *handoffDesktop=self;__weak DWNativePresenter *handoffPresenter=self.native;NSNumber *handoffTransaction=effect[@"transaction"];
    self.native.transitionFrameAcknowledged=^{Desktop *d=handoffDesktop;
        if(!d||d.cleaning||d.sessionInactive||d.native!=handoffPresenter||![d.nativeFillHandoff[@"transaction"]isEqual:handoffTransaction])return;
        [d render];};
    self.nativeResizeDriver.fillPreparationTimeout=root?2.5:.75;self.resize.timeout=root?7:3;
    [self cancelNativeHoverForWindow:nil];[self cancelCapturedInputForWindow:nil];self.nativeViewSnapshot=nil;
    if(DWDebugTrace())fprintf(stderr,"debug: native fill handoff window=#%s native=%g,%g %gx%g displayed=%g,%g %gx%g snapshot=%d restore=%d\n",source.logical.description.UTF8String,native.origin.x,native.origin.y,native.size.width,native.size.height,displayed.origin.x,displayed.origin.y,displayed.size.width,displayed.size.height,root!=nil,restoring);
    if(root){
        __weak Desktop *weak=self;NSDictionary *held=self.nativeFillHandoff;
        BOOL (^valid)(void)=^BOOL{Desktop *d=weak;return d&&d.nativeFillRoot==root&&!d.nativeFillResuming
            &&[d.nativeFillHandoff[@"transaction"]isEqual:held[@"transaction"]]
            &&[d nativeFillCurrent:held snapshot:[d call:@{@"op":@"snapshot"}]];};
        // Snapshot preparation can occupy main longer than the ordinary
        // setter admission budget. Only this exact, read-only baseline may
        // wait for it; its effect, session and handoff are checked again then.
        [self.nativeResizeDriver prepareBaseline:effect validate:^BOOL{
            Desktop *d=weak;if(!valid())return NO;
            NSDictionary *current=DWTyped([d call:@{@"op":@"snapshot"}][@"native_resize"],NSDictionary.class);
            return ![current[@"cancelled"]boolValue]&&[current[@"pending_effect"]isEqual:effect]
                &&![d.nativeFillRefusedTransactions containsObject:effect[@"transaction"]];
        }];
        self.nativeFillCapture=[DWNativeTransitionCapture captureIdentity:root.identity nativeBounds:root.nativeBounds screenRect:root.screenRect validate:valid completion:^(DWNativeTransitionCaptureResult *result,NSString *failure){
            Desktop *d=weak;if(!valid())return;d.nativeFillCapture=nil;
            DWNativeTransition *picture=result?[[DWNativeTransition alloc]initWithImage:result.image screenRect:result.screenRect]:nil;
            if(picture&&[picture show]){d.nativeFillPicture=picture;[d updateNativeFill];[d render];}
            else {NSMutableDictionary *failed=[d.nativeFillHandoff mutableCopy];failed[@"bridge_failed"]=@YES;d.nativeFillHandoff=failed;
                if(DWDebugTrace())fprintf(stderr,"debug: native transition capture refused window=#%s reason=%s\n",[held[@"window"]description].UTF8String,(failure?:@"snapshot panel unavailable").UTF8String);}
        }];
    }
}
- (void)interruptFillForVisibility:(LiveSource *)source {
    NSDictionary *held=self.nativeFillHandoff;
    if(!source||![held[@"window"]isEqual:source.logical]||!boundIdentity(held[@"identity"],source.identity))return;
    // Retire temporary hide/reveal phases without ever describing a resumed
    // frame. The same main turn keeps the family omitted and journalled.
    [self clearNativeFillPresentation]; // invalidate asynchronous capture/animation callbacks first
    if(held[@"presenter"]==self.native&&[held[@"session"]unsignedLongLongValue]==self.nativeSessionEpoch){
        [self.native resumeWindow:source.identity];source.nativeVisibilityHeld=[self.native withholdWindow:source.identity];
    }
}
- (void)updateNativeFill {
    [self updateDeferredNativeRestore];
    NSDictionary *held=self.nativeFillHandoff;if(!held)return;
    LiveSource *visibilitySource=self.sources[held[@"window"]];
    if(visibilitySource.nativeVisibilityWanted){[self interruptFillForVisibility:visibilitySource];return;}
    NSDictionary *snapshot=[self call:@{@"op":@"snapshot"}],*transaction=DWTyped(snapshot[@"native_resize"],NSDictionary.class);
    BOOL gone=![self nativeFillCurrent:held snapshot:snapshot];
    BOOL finished=![transaction[@"transaction"]isEqual:held[@"transaction"]]||([self.resize canRemove:held[@"window"]]&&!self.resize.obligations);
    // A canvas transition can need no native setter (the app was already
    // screen-sized). Its resize transaction may finish before capture, but the
    // displayed projection still needs the same snapshot/hide/animate handoff.
    if(!gone&&finished&&self.nativeFillRoot&&self.nativeFillCapture&&!self.nativeFillCapture.completed)return;
    if(!gone&&self.nativeFillRoot&&self.nativeFillPicture&&!self.nativeFillHiding){
        if([self.native hideTransition:self.nativeFillRoot]){self.nativeFillHiding=YES;if(DWDebugTrace())fprintf(stderr,"debug: native transition hide window=#%s\n",[held[@"window"]description].UTF8String);}
        else if(finished){
            // Capture and omission ACK arrive independently. A no-setter
            // transaction must not cancel its picture merely because the
            // presenter's initial omission is still in flight.
            if(!self.nativeFillPresentationDeadline)self.nativeFillPresentationDeadline=CACurrentMediaTime()+2.5;
            if(CACurrentMediaTime()<self.nativeFillPresentationDeadline)return;
        }
    }
    NSDictionary *finalPlacement=nil;
    if(finished)for(NSDictionary *item in [self presentationSnapshot][@"placements"])if([item[@"window"]isEqual:held[@"window"]]&&[item[@"output"]isEqual:held[@"output"]]){finalPlacement=item;break;}
    BOOL targetCurrent=!held[@"target"]||(finalPlacement&&CGRectEqualToRect(DWRectFromJSON(finalPlacement[@"screen_rect"]),DWRectFromJSON(held[@"target"])));
    BOOL bridge=finished&&!gone&&targetCurrent&&!self.nativeFillResuming&&self.nativeFillRoot&&self.nativeFillPicture&&self.nativeFillHiding;
    if(bridge){
        if(!self.nativeFillPresentationDeadline)self.nativeFillPresentationDeadline=CACurrentMediaTime()+2.5;
        if(![self.native isTransitionRevealed:self.nativeFillRoot]&&CACurrentMediaTime()<self.nativeFillPresentationDeadline){
            if(!self.nativeFillAnimating&&[self.native isTransitionHidden:self.nativeFillRoot]){
                NSDictionary *placement=finalPlacement;CGRect clip=DWRectFromJSON(placement[@"clip_rect"]);
                if(placement&&clip.size.width>0&&clip.size.height>0){
                    CGRect target=DWRectFromJSON(placement[@"screen_rect"]);
                    DWNativeHiddenRoot *root=self.nativeFillRoot;self.nativeFillAnimating=YES;__weak Desktop *weak=self;
                    NSMutableDictionary *frozen=[self.nativeFillHandoff mutableCopy];frozen[@"target"]=DWRectJSON(target);self.nativeFillHandoff=frozen.copy;
                    void (^reveal)(BOOL)=^(BOOL completed){Desktop *d=weak;if(!d||d.nativeFillRoot!=root||d.nativeFillResuming)return;
                        NSDictionary *now=[d call:@{@"op":@"snapshot"}];BOOL targetMatches=NO;
                        for(NSDictionary *item in [d presentationSnapshot][@"placements"])if([item[@"window"]isEqual:held[@"window"]]&&[item[@"output"]isEqual:held[@"output"]]&&CGRectEqualToRect(DWRectFromJSON(item[@"screen_rect"]),target))targetMatches=YES;
                        BOOL current=[d nativeFillCurrent:held snapshot:now];
                        if(!completed||!targetMatches||!current){if(DWDebugTrace())fprintf(stderr,"debug: native transition completion refused window=#%s completed=%d target=%d current=%d\n",[held[@"window"]description].UTF8String,completed,targetMatches,current);d.nativeFillPresentationDeadline=CACurrentMediaTime();return;}
                        d.nativeFillAnimated=YES;d.nativeViewSnapshot=nil;
                        if(DWDebugTrace())fprintf(stderr,"debug: native transition animated window=#%s\n",[held[@"window"]description].UTF8String);
                        [d render];};
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
                self.nativeFillRevealing=[self.native revealTransition:self.nativeFillRoot screen:target alpha:alpha];
                if(self.nativeFillRevealing&&DWDebugTrace())fprintf(stderr,"debug: native transition reveal window=#%s accepted=1\n",[held[@"window"]description].UTF8String);
            }
            if(self.nativeFillPresentationDeadline)return;
        }
    }
    if(!self.nativeFillResuming&&(gone||finished)){
        if(DWDebugTrace())fprintf(stderr,"debug: native transition resume window=#%s gone=%d finished=%d placement=%d hidden=%d animating=%d revealing=%d\n",[held[@"window"]description].UTF8String,gone,finished,finalPlacement!=nil,self.nativeFillHiding,self.nativeFillAnimating,self.nativeFillRevealing);
        [self.nativeFillCapture cancel];self.nativeFillCapture=nil;
        if(held[@"presenter"]==self.native&&[held[@"session"]unsignedLongLongValue]==self.nativeSessionEpoch)[self.native resumeWindow:held[@"identity"]];
        self.nativeFillResuming=YES;self.nativeViewSnapshot=nil;
    }
    if(gone){if(!self.nativeFillRefusedTransactions)self.nativeFillRefusedTransactions=[NSMutableSet set];[self.nativeFillRefusedTransactions addObject:held[@"transaction"]];[self clearNativeFillPresentation];return;}
    if(self.nativeFillResuming){
        NSNumber *output=[self.nativeViews desiredOwnerForWindow:held[@"window"]];
        NSNumber *generation=nil;for(NSDictionary *window in snapshot[@"windows"])if([window[@"window"]isEqual:held[@"window"]]&&boundIdentity(window[@"source"][@"identity"],held[@"identity"]))generation=window[@"source"][@"generation"];
        DWNativeAppliedPlacement *placed=[self.native acknowledgedPlacementForWindow:held[@"window"] identity:held[@"identity"] generation:generation output:output];
        if(placed||!output||!generation){[self clearNativeFillPresentation];
            if(DWDebugTrace())fprintf(stderr,"debug: native fill handoff resumed window=#%s sequence=%llu\n",[held[@"window"]description].UTF8String,(unsigned long long)placed.sequence);}
    }
}
- (NSDictionary *)nativeFillBackground:(NSDictionary *)snapshot {
    NSDictionary *held=self.nativeFillHandoff,*prior=held[@"background"];
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
        NSNumber *window=placement[@"window"];NSDictionary *old=before[window],*current=now[window],*source=DWTyped(current[@"source"],NSDictionary.class);LiveSource *live=self.sources[window];
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
