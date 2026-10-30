// SPDX-License-Identifier: GPL-3.0-or-later
// Split from native/desktop/main.m at 37b27b1, moved verbatim.
// Desktop navigation and sizing: resize and navigation coordinators, focus, camera frames, edge pan, size transactions.
#import "Desktop+Private.h"
#import "DWDebugTrace.h"
#import "DWNativeFocus.h"
#import "DWNativeFocusDriver.h"
#import "DWNativeFamily.h"
#import "DWGeometryJSON.h"
// Optional, and only where Input Monitoring is already granted: a press or scroll outside
// the canvas while a native focus request is in flight withdraws that request. Listen-only,
// and nothing depends on it. A press on the canvas is its view's to handle.
// Key downs cancel only the bounded background-arrival correction; binding
// releases never cancel the normal native focus request they began.
static CGEventRef navigationInput(CGEventTapProxy proxy,CGEventType type,CGEventRef event,void *context) {
    (void)proxy;Desktop *desktop=(__bridge Desktop *)context;
    [desktop cancelNativeTitleClick];
    if(type==kCGEventTapDisabledByTimeout||type==kCGEventTapDisabledByUserInput){[desktop.navigation interrupt];if(desktop.navigationTap)CGEventTapEnable(desktop.navigationTap,true);return event;}
    [desktop.navigation cancelBackgroundArrival];
    if(type==kCGEventKeyDown)return event;
    CGPoint point=CGEventGetLocation(event);for(DesktopView *view in desktop.views)if(CGRectContainsPoint(view.globalBounds,point))return event;
    [desktop.navigation interrupt];return event;
}
@implementation Desktop (Navigation)
- (void)configureResize {
    if(self.resize)return;
    __weak Desktop *weak=self;dispatch_queue_t queue=dispatch_queue_create("org.infinify.resize",DISPATCH_QUEUE_SERIAL);
    DWNativeResizeDriver *driver=[DWNativeResizeDriver new];self.nativeResizeDriver=driver;
    driver.nativeFill=self.nativeDesktopMode&&self.native!=nil;
    driver.canPerform=^BOOL(NSDictionary *effect){
        Desktop *d=weak;LiveSource *source=d.sources[effect[@"window"]];
        if(!source||source.detached||source.nativeMouseOwnership||!boundIdentity(source.identity,effect[@"identity"]))return NO;
        if([effect[@"op"]isEqual:@"resize_native_window"]&&(source.nativeVisibilityWanted||source.nativeVisibilityWriting||source.nativeMinimized))return NO;
        // A worker may start after a newer handoff replaced its prepared read.
        // Only the controller's still-pending effect can enter native code.
        return [DWTyped([d call:@{@"op":@"snapshot"}][@"native_resize"],NSDictionary.class)[@"pending_effect"]isEqual:effect];
    };
    driver.fillReady=^DWNativeFillReadiness(NSDictionary *effect){
        Desktop *d=weak;NSDictionary *held=d.nativeFillHandoff;
        if(!held||d.nativeFillResuming||d.cleaning||d.sessionInactive||d.native.ended
            ||![held[@"transaction"]isEqual:effect[@"transaction"]]||![held[@"generation"]isEqual:effect[@"generation"]]
            ||!boundIdentity(held[@"identity"],effect[@"identity"]))return DWNativeFillPending;
        if(![d nativeFillCurrent:held snapshot:[d call:@{@"op":@"snapshot"}]])return DWNativeFillPending;
        if([held[@"bridge_failed"]boolValue])return DWNativeFillUnsupportedGeometry;
        if(d.nativeFillRoot)return [d.native isTransitionHidden:d.nativeFillRoot]?DWNativeFillReadyForSnapshotFill:DWNativeFillPending;
        if(![d.native isWindowWithheld:held[@"identity"]])return DWNativeFillPending;
        // Fresh native/displayed geometry separates an aligned source, a
        // translation-only rebase, and unsupported scaling. Missing evidence
        // remains pending rather than authorizing an ordinary resize.
        NSDictionary *who=held[@"identity"];LiveSource *source=d.sources[held[@"window"]];
        if(!source||source.detached||!boundIdentity(source.identity,who))return DWNativeFillPending;
        DWFocusIdentity target={.pid=[who[@"pid"]intValue],.window=[who[@"wid"]unsignedIntValue],.seconds=[who[@"birth_sec"]unsignedLongLongValue],.microseconds=[who[@"birth_usec"]unsignedLongLongValue]};
        CGRect native,displayed,after;
        if(!dw_focus_owner(target,&native))return DWNativeFillPending;
        NSDictionary *row=windowInfo(target.window);
        if([row[(id)kCGWindowOwnerPID]intValue]!=target.pid||!row[(id)kCGWindowBounds]
            ||!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)row[(id)kCGWindowBounds],&displayed)
            ||!isfinite(displayed.origin.x)||!isfinite(displayed.origin.y)||!isfinite(displayed.size.width)||!isfinite(displayed.size.height)
            ||displayed.size.width<=0||displayed.size.height<=0||!dw_focus_owner(target,&after)||!CGRectEqualToRect(native,after))return DWNativeFillPending;
        BOOL aligned=fabs(native.origin.x-displayed.origin.x)<=1&&fabs(native.origin.y-displayed.origin.y)<=1
            &&fabs(native.size.width-displayed.size.width)<=1&&fabs(native.size.height-displayed.size.height)<=1;
        NSMutableDictionary *fresh=[held mutableCopy];fresh[@"native_baseline"]=DWRectJSON(native);fresh[@"displayed_baseline"]=DWRectJSON(displayed);d.nativeFillHandoff=fresh.copy;
        if(DWDebugTrace())fprintf(stderr,"debug: native fill geometry window=#%s native=%g,%g %gx%g displayed=%g,%g %gx%g supported=%d\n",[held[@"window"]description].UTF8String,native.origin.x,native.origin.y,native.size.width,native.size.height,displayed.origin.x,displayed.origin.y,displayed.size.width,displayed.size.height,aligned);
        BOOL sameExtent=fabs(native.size.width-displayed.size.width)<=1&&fabs(native.size.height-displayed.size.height)<=1;
        return aligned?DWNativeFillReady:(sameExtent&&[d.native canRebaseWindow:who]?DWNativeFillNeedsRebase:DWNativeFillUnsupportedGeometry);
    };
    driver.restoreReady=^DWNativeFillReadiness(NSDictionary *effect){Desktop *d=weak;NSDictionary *held=d.nativeFillHandoff;
        if([d.nativeFillRefusedTransactions containsObject:effect[@"transaction"]]||[d.nativeRestoreDeferred[@"effect"][@"transaction"]isEqual:effect[@"transaction"]])return DWNativeFillPending;
        if(!held)return DWNativeFillUnsupportedGeometry;
        if(d.nativeFillResuming||d.cleaning||d.sessionInactive||d.native.ended
            ||![held[@"transaction"]isEqual:effect[@"transaction"]]||![held[@"generation"]isEqual:effect[@"generation"]]
            ||!boundIdentity(held[@"identity"],effect[@"identity"]))return DWNativeFillPending;
        if(![d nativeFillCurrent:held snapshot:[d call:@{@"op":@"snapshot"}]])return DWNativeFillPending;
        if([held[@"bridge_failed"]boolValue]||!d.nativeFillRoot)return DWNativeFillUnsupportedGeometry;
        // Keep the root hidden while qualified Restore clears AppKit's Fill
        // state, then corrects the exact saved frame after native settlement.
        // A frame setter alone leaves Fill active across display changes.
        return [d.native isTransitionHidden:d.nativeFillRoot]?DWNativeFillReady:DWNativeFillPending;
    };
    driver.screenUpdates=^CGError(BOOL enabled){return DWNativeScreenUpdates(enabled);};
    driver.fillRebase=^DWNativeFillRebase *(NSDictionary *effect){
        Desktop *d=weak;NSDictionary *held=d.nativeFillHandoff,*who=held[@"identity"];
        BOOL (^valid)(void)=^BOOL{Desktop *current=weak;NSDictionary *now=current.nativeFillHandoff;LiveSource *source=current.sources[effect[@"window"]];
            return current&&!current.cleaning&&!current.sessionInactive&&!current.nativeFillResuming&&!current.native.ended
                &&[now[@"transaction"]isEqual:effect[@"transaction"]]&&[now[@"generation"]isEqual:effect[@"generation"]]
                &&boundIdentity(now[@"identity"],effect[@"identity"])&&source&&!source.detached&&boundIdentity(source.identity,who)
                &&[current nativeFillCurrent:now snapshot:[current call:@{@"op":@"snapshot"}]];};
        BOOL current=valid(),canRebase=current&&[d.native canRebaseWindow:who];
        if(!current||!canRebase||!held[@"native_baseline"]||!held[@"displayed_baseline"]){
            if(DWDebugTrace())fprintf(stderr,"debug: native fill rebase refused window=#%s current=%d can_rebase=%d baselines=%d\n",[effect[@"window"]description].UTF8String,current,canRebase,held[@"native_baseline"]!=nil&&held[@"displayed_baseline"]!=nil);
            return nil;
        }
        // Re-audit the known root-only scope before taking an update hold.
        NSString *familyWhy=nil;NSDictionary *family=DWNativeWindowFamily(who,&familyWhy);
        if([family[@"members"]count]!=1){
            if(DWDebugTrace())fprintf(stderr,"debug: native fill rebase refused window=#%s family_members=%lu reason=%s\n",[effect[@"window"]description].UTF8String,(unsigned long)[family[@"members"]count],familyWhy.UTF8String?:"family_not_root_only");
            return nil;
        }
        DWNativeFillRebase *plan=[DWNativeFillRebase new];plan.native=DWRectFromJSON(held[@"native_baseline"]);plan.displayed=DWRectFromJSON(held[@"displayed_baseline"]);
        plan.publish=^BOOL(CGRect observed,BOOL (^authorized)(void)){Desktop *current=weak;if(!valid())return NO;
            NSDictionary *freshFamily=DWNativeWindowFamily(who,NULL);if([freshFamily[@"members"]count]!=1||!authorized())return NO;
            if(![current.native rebaseWindow:who bounds:observed])return NO;
            current.sources[effect[@"window"]].router.bounds=CFBridgingRelease(CGRectCreateDictionaryRepresentation(observed));
            [current render];return YES;};
        plan.ready=^BOOL{Desktop *current=weak;if(!valid())return NO;[current render];
            if(![current.native isWindowRebased:who])return NO;
            DWFocusIdentity target={.pid=[who[@"pid"]intValue],.window=[who[@"wid"]unsignedIntValue],.seconds=[who[@"birth_sec"]unsignedLongLongValue],.microseconds=[who[@"birth_usec"]unsignedLongLongValue]};
            CGRect native,displayed,after;NSDictionary *row=windowInfo(target.window);
            return dw_focus_owner(target,&native)&&[row[(id)kCGWindowOwnerPID]intValue]==target.pid&&row[(id)kCGWindowBounds]
                &&CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)row[(id)kCGWindowBounds],&displayed)
                &&dw_focus_owner(target,&after)&&CGRectEqualToRect(native,after)
                &&fabs(native.origin.x-displayed.origin.x)<=1&&fabs(native.origin.y-displayed.origin.y)<=1
                &&fabs(native.size.width-displayed.size.width)<=1&&fabs(native.size.height-displayed.size.height)<=1;};
        plan.cancel=^{Desktop *current=weak;if(valid()){[current.native cancelRebaseWindow:who];[current render];}};
        return plan;
    };
    // On the worker queue. The process named is the effect's, which the controller built from a source -attach: bound.
    if(DWDebugTrace())driver.didPerform=^(NSDictionary *e,NSDictionary *r){NSDictionary *i=e[@"identity"],*asked=DWTyped(e[@"requested"],NSDictionary.class),*actual=r[@"actual_ax"][@"size"];
        fprintf(stderr,"debug: native %s pid=%d wid=%u requested=%gx%g outcome=%s observed=%d actual=%gx%g moved=%d ax_error=%d attempted=%d transaction=%llu effect=%llu\n",((NSString *)DWTyped(r[@"method"],NSString.class)).UTF8String?:"size read",[i[@"pid"]intValue],[i[@"wid"]unsignedIntValue],[asked[@"width"]doubleValue],[asked[@"height"]doubleValue],[r[@"outcome"]description].UTF8String,[r[@"observed"]boolValue],[actual[@"width"]doubleValue],[actual[@"height"]doubleValue],[r[@"moved"]boolValue],[r[@"ax_error"]intValue],[r[@"mutation_attempted"]boolValue],[e[@"transaction"]unsignedLongLongValue],[e[@"effect_id"]unsignedLongLongValue]);};
    self.resize=[[DWResizeCoordinator alloc]initWithCommand:^NSDictionary *(NSDictionary *c){return [weak resizeCall:c];} driver:driver worker:^(DWJob job){dispatch_async(queue,job);} main:^(DWJob job){dispatch_async(dispatch_get_main_queue(),job);}];
    self.resize.enabled=YES;

    // Native readback (docs/crates/desktop/NATIVE_RESIZE.md): the size a window took is read back from it, no capture is acknowledged, no
    // picture is cleared. App-owned Fill separately holds placement/input until
    // its native animation and a fresh helper ACK settle. An effect unanswered after three seconds is reported as timed out, which ends its
    // transaction. When a transaction has ended, the window is looked at as the poll looks at it: its bounds, its stream's size
    // and the controller's observation follow the size it has, or it is found closed. Then the scene is saved, once.
    self.resize.timeout=3;
    // A resize grab whose pointer rests owes no effect and is no orphan: its press, or its swipe, ends it (-released:at:, gesture_end),
    // and a press or swipe whose end is lost is ended by -endLostInput.
    self.resize.deferred=^BOOL(NSDictionary *effect){Desktop *d=weak;NSDictionary *deferred=d.nativeRestoreDeferred;
        return [deferred[@"effect"]isEqual:effect]&&[d nativeRestoreDeferredCurrent:deferred snapshot:[d call:@{@"op":@"snapshot"}]];};
    self.resize.held=^BOOL(NSNumber *transaction){Desktop *d=weak;for(DesktopView *view in d.views)if(view.gesture==4&&[view.resizeTransaction isEqual:transaction])return YES;return d.gestureOwner&&d.gestureResize;};
    self.resize.changed=^{Desktop *d=weak;if(d.cleaning)return;if(d.resize.failure)d.statusText=d.resize.failure;
        NSDictionary *transaction=DWTyped([d call:@{@"op":@"snapshot"}][@"native_resize"],NSDictionary.class);
        if(transaction&&[d.resize canRemove:nil]&&!d.resize.obligations&&![d.resizeSavedTransaction isEqual:transaction[@"transaction"]]){d.resizeSavedTransaction=transaction[@"transaction"];
            if(DWDebugTrace())fprintf(stderr,"debug: size transaction %s of #%s ended phase=%s\n",[transaction[@"transaction"]description].UTF8String,[transaction[@"window"]description].UTF8String,((NSString *)DWTyped(transaction[@"phase"],NSString.class)).UTF8String?:"?");
            LiveSource *source=d.sources[transaction[@"window"]];if(source&&!source.detached)[d track:source];[d saveScene];}
        [d updateNativeFill];[d render];};
    [self resizeCapability];
}
// native_resize_capability: DriftWM's sizing actions, the IPC resize write, a rule's size and fullscreen reach a native window through
// the resize coordinator, which every normal run has. main() says so before the config is read, since the binding table marks the
// actions that run here and a chord whose action does not is never registered; the coordinator's creation says so again, after the
// scene load, which rebuilds the controller. A size is settled by the native read alone (docs/crates/desktop/NATIVE_RESIZE.md).
- (void)resizeCapability {
    NSString *status=self.statusText;
    if(![self call:@{@"op":@"native_resize_capability",@"enabled":@YES}]){fprintf(stderr,"native_resize_capability: %s\n",self.statusText.UTF8String);self.statusText=status;}
}
// Is the resize transaction on record one a sizing action began, and certain? That one is the controller's: an action or an IPC
// request that arrives while it runs reaches the controller, which continues, coalesces or refuses it as upstream does for a
// window that still owes a configure. A resize the pointer began holds the canvas until it settles, as does every uncertain one.
- (BOOL)sizing {
    if(!self.resize||!self.sizeTransaction)return NO;
    NSDictionary *transaction=DWTyped([self call:@{@"op":@"snapshot"}][@"native_resize"],NSDictionary.class);
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
    NSDictionary *reply=[self call:command];
    if(!reply||![command[@"op"]isEqual:@"native_resize_result"])return reply;
    NSDictionary *result=DWTyped(command[@"result"],NSDictionary.class);
    if(self.native&&[result[@"observed"]boolValue]){
        // Tracking skips a held resize grab. Refresh its native transform basis
        // at this accepted completion, before consume: can render or queue another
        // effect. The router and presenter have separate caches; always bind the
        // accepted observation, once per readback, even if the router is current.
        for(NSDictionary *window in [self call:@{@"op":@"snapshot"}][@"windows"]){
            NSDictionary *source=DWTyped(window[@"source"],NSDictionary.class);LiveSource *live=self.sources[window[@"window"]];
            if(!live||live.detached||!boundIdentity(live.identity,command[@"identity"])||!boundIdentity(live.identity,source[@"identity"])||![source[@"generation"]isEqual:command[@"generation"]]||![source[@"observation_known"]boolValue])continue;
            CGRect observed=DWRectFromJSON(source[@"observed_rect"]),prior=CGRectZero;
            if(!CGRectEqualToRect(observed,DWRectFromJSON(result[@"actual_ax"])))break;
            if(!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)live.router.bounds,&prior)||!CGRectEqualToRect(prior,observed))live.router.bounds=CFBridgingRelease(CGRectCreateDictionaryRepresentation(observed));
            [self.native bound:live.identity bounds:observed];break;
        }
    }
    BOOL own=self.sizeTransaction&&[command[@"transaction"]isEqual:self.sizeTransaction];
    NSNumber *next=DWTyped(sizeEffect(reply)[@"transaction"],NSNumber.class);if(next&&![next isEqual:command[@"transaction"]])self.sizeTransaction=next;
    if(!own)return reply;
    NSMutableDictionary *tail=[reply mutableCopy];[tail removeObjectForKey:@"effect"];__weak Desktop *weak=self;
    dispatch_async(dispatch_get_main_queue(),^{Desktop *d=weak;if(!d||d.cleaning)return;NSString *failure=DWTyped(tail[@"failure"],NSString.class);if(failure)[d flashStatus:[@"Window not resized: " stringByAppendingString:failure]];[d applyReply:tail];});
    return reply;
}
// The navigation coordinator's commands. An activation the user made natively may leave fullscreen, as upstream exits before it
// activates another window of that output: the size transaction that takes the window back comes with the focus request and is
// the resize coordinator's to perform, like any other. The coordinator reads "effect" as a focus request, so a size
// transaction's is taken out of what it is handed, as in -applyReply:; no reply of its commands carried one before fullscreen.
- (NSDictionary *)navigationCall:(NSDictionary *)command {
    NSDictionary *reply=[self call:command],*sized=[self consumeSize:reply];if(!sized||reply[@"effect"]!=sized)return reply;
    NSMutableDictionary *rest=[reply mutableCopy];[rest removeObjectForKey:@"effect"];return rest;
}
// Every normal run: the coordinator ticks camera flights, performs the controller's focus
// requests on native windows and follows native focus the user moved.
- (void)configureNavigation {
    if(self.navigation)return;
    __weak Desktop *weak=self;dispatch_queue_t queue=dispatch_queue_create("org.infinify.navigation",DISPATCH_QUEUE_SERIAL);
    self.navigation=[[DWNavigationCoordinator alloc]initWithCommand:^NSDictionary *(NSDictionary *c){return [weak navigationCall:c];} driver:[DWNativeFocusDriver new] clock:^uint64_t{return (uint64_t)(CACurrentMediaTime()*1e9);} worker:^(DWJob job){dispatch_async(queue,job);} main:^(DWJob job){dispatch_async(dispatch_get_main_queue(),job);}];
    self.navigation.enabled=YES;self.cycleHold=[DWCycleHold new];
    self.navigation.changed=^{[weak render];[weak ensureFrames];};
    self.navigation.settled=^{[weak saveScene];};
    self.navigation.output=^NSNumber *{return [weak viewOutput];};
    self.navigation.nativeClickReleaseReady=^BOOL(NSDictionary *click){
        Desktop *d=weak;LiveSource *source=d.sources[click[@"window"]];
        if(!d||d.cleaning||d.sessionInactive||d.native.ended||!source||source.detached||source.nativeMouseOwnership
            ||!boundIdentity(source.identity,click[@"identity"])||![[d.nativeViews desiredOwnerForWindow:source.logical]isEqual:click[@"output"]])return NO;
        DWNativeAppliedPlacement *placed=[d.native acknowledgedPlacementForWindow:click[@"window"] identity:click[@"identity"] generation:click[@"generation"] output:click[@"output"]];
        return placed&&[d.native isAcknowledgedPlacementCurrent:placed];
    };
    self.navigation.observationBinding=^DWObservedBinding{
        Desktop *d=weak;if(!d||d.cleaning||d.native.ended||(d.native&&!d.native.familiesNeeded))return nil;
        NSMutableArray *roots=[NSMutableArray array];NSDictionary *snapshot=[d call:@{@"op":@"snapshot"}];
        for(NSDictionary *window in snapshot[@"windows"]){NSDictionary *source=DWTyped(window[@"source"],NSDictionary.class),*identity=DWTyped(source[@"identity"],NSDictionary.class);LiveSource *live=d.sources[window[@"window"]];
            if(!live||live.detached||!identity||!boundIdentity(live.identity,identity))continue;
            [roots addObject:@{@"window":window[@"window"],@"identity":[identity copy],@"generation":source[@"generation"]}];
        }
        NSArray *bindings=roots.copy;
        return ^NSDictionary *(NSDictionary *actual){
            for(NSDictionary *binding in bindings){NSDictionary *root=binding[@"identity"];BOOL same=YES;
                for(NSString *key in @[@"pid",@"birth_sec",@"birth_usec"])if(![actual[key]isEqual:root[key]])same=NO;
                if(same&&![actual[@"wid"]isEqual:root[@"wid"]]&&DWNativeWindowBelongsToRoot(actual,root))return binding;
            }
            return nil;
        };
    };
    [self refreshFocusAccess];
    // Never asked for: the observer exists only where the user has already granted Input Monitoring.
    if(!self.logicalFocus&&CGPreflightListenEventAccess()){
        CGEventMask mask=CGEventMaskBit(kCGEventLeftMouseDown)|CGEventMaskBit(kCGEventRightMouseDown)|CGEventMaskBit(kCGEventOtherMouseDown)|CGEventMaskBit(kCGEventScrollWheel)|CGEventMaskBit(kCGEventKeyDown);
        self.navigationTap=CGEventTapCreate(kCGSessionEventTap,kCGHeadInsertEventTap,kCGEventTapOptionListenOnly,mask,navigationInput,(__bridge void *)self);
        if(self.navigationTap){self.navigationTapSource=CFMachPortCreateRunLoopSource(NULL,self.navigationTap,0);if(self.navigationTapSource)CFRunLoopAddSource(CFRunLoopGetMain(),self.navigationTapSource,kCFRunLoopCommonModes);}
    }
    [self.navigation frame];
}
// Native focus needs Accessibility, which can be granted while the app runs, and
// --no-native-focus turns it off. Without it focus is logical and navigation still works.
- (void)refreshFocusAccess {
    BOOL trusted=AXIsProcessTrusted();self.navigation.focusAllowed=trusted&&!self.logicalFocus;[self.tapKeys trusted:trusted];
    if(trusted)[self configureNativeInput];
    if(trusted||self.logicalFocus||self.focusNoted||!self.navigation)return;
    self.focusNoted=YES;NSString *note=focusAccessNote;
    // Said once, ahead of a notice already up; what a config load left for the resting status returns as the resting status.
    [self say:note];self.statusText=!self.statusText.length?note:[NSString stringWithFormat:@"%@ · %@",note,self.statusText];
}
- (void)cancelNavigation {
    [self cancelNativeTitleClick];
    [self.navigation invalidate];
    // Without the coordinator, pointer intent still stops every view-action flight.
    if(!self.navigation)for(DesktopView *view in self.views)for(NSNumber *output in view.outputs)[self call:@{@"op":@"cancel_navigation",@"output":output}];
}
- (void)stopNavigation {
    [self cancelNativeTitleClick];
    [self.cycleHold stop];self.cycleHold=nil;[self.navigation shutdown];self.navigation=nil;[self.frameDriver invalidate];self.frameDriver=nil;self.frameFlying=NO;self.flying=NO;
    if(self.navigationTapSource){CFRunLoopRemoveSource(CFRunLoopGetMain(),self.navigationTapSource,kCFRunLoopCommonModes);CFRelease(self.navigationTapSource);self.navigationTapSource=NULL;}
    if(self.navigationTap){CFMachPortInvalidate(self.navigationTap);CFRelease(self.navigationTap);self.navigationTap=NULL;}
}
// Where the pointer is: its global point, and the output it is on. It is on an output only
// where a press would reach that output's panel, so a canvas behind another window (the
// chooser, a menu, in a windowed run another application) has no pointer. One reading for
// everything that asks: cursor edge pan's report and hover. The outputs are the last snapshot's, so nothing is asked of the controller.
- (NSNumber *)outputUnderPointer:(CGPoint)p {
    if(!self.pointerOutputs.count)return nil;
    NSInteger top=[NSWindow windowNumberAtPoint:NSMakePoint(p.x,screenTop()-p.y) belowWindowWithWindowNumber:0];
    BOOL native=[self nativeSource:(CGWindowID)top at:p]!=nil;
    for(DesktopView *view in self.views)if(view.window.windowNumber==top||native)for(NSDictionary *o in self.pointerOutputs)if([view.outputs containsObject:o[@"id"]]&&CGRectContainsPoint(DWRectFromJSON(o[@"screen_bounds"]),p))return o[@"id"];
    return nil;
}
// The pointer's part of a frame, before the tick. It is read once, and only when one of its
// two readers wants it, then handed to both in upstream's order for one motion of the
// pointer (maybe_hover_focus, then refresh_cursor_edge_pan):
// - hover: while the frame timer runs, whichever it serves (camera motion, or only an
//   animated background or a window that opens or leaves), the motion a panel's tracking area has waiting goes with the frame,
//   so a moving pointer is one hover a frame and never a timer beside this one. With no
//   frame timer an idle poll's frame carries none: pointer-hover's own timer does, see there.
// - cursor edge pan: while the controller's snapshot asks for it, where the pointer is and
//   which output it is on. The answer is the controller's to use; a refusal leaves the
//   resting status alone. Nothing is reported while a panel holds a button gesture:
//   upstream's refresh stands down under any pointer grab, and the controller knows only
//   its own, not a press forwarded to a native window.
- (void)pointerFrame { [self pointerFrame:NO]; }
// moved: the report is made only if the pointer is not where it was last reported. A frame of the timer that serves no camera
// motion asks so: such frames come at the display's rate for as long as a window's pictures do, the idle poll goes on beside
// them and reports a pointer at rest at its own pace, and a call into the controller per refresh would be for nothing.
- (void)pointerFrame:(BOOL)moved {
    if(self.cleaning||self.sessionInactive||[self nativeUnavailable])return;
    BOOL report=self.pointerWanted,hover=NO;
    for(DesktopView *view in self.views){if(view.gesture)report=NO;if(self.frameDriver&&view.hover.pending)hover=YES;}
    if(!report&&!hover)return;
    CGPoint p=pointer();NSNumber *output=[self outputUnderPointer:p];
    if(hover)for(DesktopView *view in self.views.copy)[view.hover frame:p output:[view.outputs containsObject:output]?output:nil];
    if(!report||(moved&&CGPointEqualToPoint(p,self.pointerReported)))return;self.pointerReported=p;
    NSString *status=self.statusText;NSDictionary *told=[self call:@{@"op":@"pointer",@"output":output?:NSNull.null,@"screen":pointJSON(p)}];self.statusText=status;
    // The pull moved the focus: a hover's effect, performed as a hover's is (-pointerFocused:).
    if([told[@"dirty"]isEqual:@YES]){NSDictionary *effect=DWTyped(told[@"effect"],NSDictionary.class);[self.navigation perform:effect?@{@"effect":effect}:@{}];self.sceneDirty=YES;[self render];}
}
// One frame of camera motion: every armed flight, a coasting pan, an edge pan. The navigation
// coordinator owns the tick when there is one; otherwise the controller is ticked directly on the same clock.
- (BOOL)cameraFrame {
    if(self.cleaning||self.sessionInactive||[self nativeUnavailable])return NO;
    [self pointerFrame];
    if(self.navigation)return [self.navigation frame];
    NSDictionary *result=[self call:@{@"op":@"tick_navigation",@"timestamp_ns":@((uint64_t)(CACurrentMediaTime()*1e9))}];
    if([result[@"changed_outputs"]count])[self render];
    BOOL active=[result[@"needs_frames"]boolValue];if(!active&&self.flying)[self saveScene];self.flying=active;return active;
}
// Something may be in motion: a frame per display refresh from the next one on. Only the
// controller knows what is, so that frame asks it, and the timer stops serving motion when nothing is.
- (void)ensureFrames { if(self.cleaning||self.sessionInactive||[self nativeUnavailable])return;self.frameFlying=YES;[self startFrames]; }
// The end of a burst of timed pans: upstream's launch_momentum_on. The clock is brought
// up to now first, so the coast's first frame spans one frame and not the idle poll's gap.
- (void)panEnd:(NSNumber *)output {
    if(self.cleaning||[self nativeUnavailable]||!output)return;
    if(!self.frameFlying)[self cameraFrame];
    [self call:@{@"op":@"pan_end",@"output":output}];[self ensureFrames];
}
// A reply that began a native size transaction carries its effect: a sizing action's, an IPC resize's, a fullscreen's, or the attach
// of a window whose rule names a size. It is the resize coordinator's to perform, which every run has.
// The transaction the effect names is the one -sizing knows as the controller's own. Returns the effect, or nil.
- (NSDictionary *)consumeSize:(NSDictionary *)reply {
    NSDictionary *sized=sizeEffect(reply);
    if(sized){
        if(self.nativeRestoreDeferred&&![self.nativeRestoreDeferred[@"effect"]isEqual:sized])[self retireDeferredNativeRestore];
        self.sizeTransaction=DWTyped(sized[@"transaction"],NSNumber.class);
        if(![self deferNativeRestore:sized]){[self prepareNativeFill:sized];[self.resize consume:@{@"effect":sized}];}
    }
    return sized;
}
// Adapted from malbiruk/driftwm (https://github.com/malbiruk/driftwm) 352333a8fa1b22171492d4b71a54102045c9a19d, src/input/pointer.rs
// (on_pointer_button's click-to-focus fallback: raise_and_focus, then the press is forwarded)
// and src/state/navigation.rs (arm_click_navigate, resolve_click_navigate, fire_click_navigate).
// Logical focus and raising are done when this returns. The native focus request is only
// handed to the coordinator, which performs it on the freshly validated window on its worker:
// the press is forwarded while that request is in flight, not after it.
- (void)activate:(NSNumber *)window output:(NSNumber *)output { [self applyReply:[self call:@{@"op":@"activate",@"window":window,@"output":output?:NSNull.null,@"cause":@"click"}]]; }
// That press released as a completed click. With auto_navigate_on_click the controller flies
// to a window that still holds focus and is not wholly in view. The reply carries a flight or
// nothing, never a focus request, so the press's request stays the coordinator's.
- (void)clickReleased:(NSNumber *)window output:(NSNumber *)output { if([self nativeUnavailable])return;[self applyReply:[self call:@{@"op":@"activate",@"window":window,@"output":output?:NSNull.null,@"cause":@"click_release"}]]; }
// Pinned upstream pointer.rs title-bar branch and navigation.rs resolve_click_navigate:
// a stationary title grab is still a click; wait past its competing double-click.
- (void)cancelNativeTitleClick { [self.nativeTitleClickTimer invalidate];self.nativeTitleClickTimer=nil;self.nativeTitleClick=nil; }
- (void)deferNativeTitleClick:(NSDictionary *)intent {
    [self cancelNativeTitleClick];NSDictionary *snapshot=[self call:@{@"op":@"snapshot"}],*pose=nil;
    for(NSDictionary *view in snapshot[@"outputs"])if([view[@"id"]isEqual:intent[@"output"]])pose=view;
    if(!pose)return;
    NSMutableDictionary *click=[intent mutableCopy];click[@"pose"]=@{@"camera":pose[@"camera"],@"zoom":pose[@"zoom"],@"screen_bounds":pose[@"screen_bounds"]};click[@"session"]=@(self.nativeSessionEpoch);self.nativeTitleClick=click.copy;
    __weak Desktop *weak=self;
    self.nativeTitleClickTimer=[NSTimer timerWithTimeInterval:MAX(.3,NSEvent.doubleClickInterval) repeats:NO block:^(NSTimer *timer){[weak fireNativeTitleClick:timer];}];
    [NSRunLoop.mainRunLoop addTimer:self.nativeTitleClickTimer forMode:NSRunLoopCommonModes];
}
- (void)fireNativeTitleClick:(NSTimer *)timer {
    if(!timer||timer!=self.nativeTitleClickTimer)return;
    NSDictionary *click=self.nativeTitleClick;[self cancelNativeTitleClick];
    LiveSource *source=self.sources[click[@"window"]];
    if(!click||!source||source.detached||self.cleaning||self.sessionInactive||[self nativeUnavailable]||self.nativeFillHandoff
        ||[click[@"session"]unsignedLongLongValue]!=self.nativeSessionEpoch||!boundIdentity(source.identity,click[@"identity"])
        ||![birth(source.router.pid)isEqual:source.router.processBirth]
        ||![[self.nativeViews desiredOwnerForWindow:source.logical]isEqual:click[@"output"]])return;
    NSDictionary *snapshot=[self call:@{@"op":@"snapshot"}],*binding=nil,*pose=nil,*focus=DWTyped(snapshot[@"focus"],NSDictionary.class);
    for(NSDictionary *window in snapshot[@"windows"])if([window[@"window"]isEqual:click[@"window"]])binding=DWTyped(window[@"source"],NSDictionary.class);
    for(NSDictionary *view in snapshot[@"outputs"])if([view[@"id"]isEqual:click[@"output"]])pose=view;
    if(!pose||![binding[@"generation"]isEqual:click[@"generation"]]||!boundIdentity(binding[@"identity"],click[@"identity"])
        ||![focus[@"intent"]isEqual:click[@"window"]]||DWTyped(focus[@"pending_effect"],NSDictionary.class))return;
    for(NSString *key in @[@"camera",@"zoom",@"screen_bounds"])if(![pose[key]isEqual:click[@"pose"][key]])return;
    if(!self.logicalFocus){NSDictionary *observed=DWTyped(focus[@"observed_native"],NSDictionary.class);
        if(![observed[@"window"]isEqual:click[@"window"]]||![observed[@"generation"]isEqual:click[@"generation"]]
            ||!boundIdentity(observed[@"identity"],click[@"identity"])||NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier!=source.router.pid)return;}
    NSMutableDictionary *command=[click mutableCopy];[command removeObjectsForKeys:@[@"pose",@"session"]];command[@"op"]=@"activate";command[@"cause"]=@"click_release";
    [self applyReply:[self call:command]];
}
// Upstream's raise_and_focus by itself, for a press bound to a resize that begins nothing: the gate is off or the begin was
// turned away (-beginResize:…), or the window is screen-pinned (-press:…).
- (void)raiseFocus:(NSNumber *)window { [self applyReply:[self call:@{@"op":@"focus",@"window":window}]]; }
// The reply to a resize the pointer began, at a handle or by a press bound to resize-window. Upstream raises and focuses the window
// ahead of its resize grab, and the controller does so inside begin_native_resize. That reply's "effect" is the size transaction's,
// which the resize coordinator has consumed, so the focus request is among its "effects", as in a sizing action's reply, and is the
// navigation coordinator's to perform; with none, nothing is read.
- (void)resizeFocus:(NSDictionary *)reply { if(!self.navigation)return;NSMutableDictionary *rest=[reply mutableCopy];[rest removeObjectForKey:@"effect"];[self.navigation perform:rest]; }
// Upstream src/grabs/pan_grab.rs: a press on empty canvas released within 5 points leaves
// no window focused. Logical only: nothing is asked of any native application.
- (void)clearFocus { [self applyReply:[self call:@{@"op":@"clear_focus"}]]; }
@end
