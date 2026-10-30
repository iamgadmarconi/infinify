// SPDX-License-Identifier: GPL-3.0-or-later
// Desktop native hover and native ownership transfers.
#import "Desktop+Private.h"
#import <unistd.h>
#import "DWWindowEvents.h"
#import "DWNativePlacementValidation.h"
#import "DWGeometryJSON.h"
@implementation Desktop (Hover)
// Hover observes real mouse motion without taking it. Native reads, family
// discovery, rendering and placement requests all happen after the tap returns.
- (BOOL)nativeHoverAllowed {
    if(!self.native||self.nativeFillHandoff||self.native.ended||self.cleaning||self.sessionInactive
        ||NSEvent.pressedMouseButtons||self.globalTrackpad.hasNativeMousePress||self.globalTrackpad.ownsTouches
        ||self.nativeGestureView||self.pointerGrab.active||self.gestureOwner||self.trackpad.engaged
        ||self.globalGestureContact||self.magnifying||self.flying||self.frameFlying||self.compositor.hasGeometryTransitions)return NO;
    for(DesktopView *view in self.views)if(view.gesture||view.heldPress||view.pressedTablet)return NO;
    return YES;
}
- (BOOL)nativeOwnershipReady:(LiveSource *)source {
    return DWCapturedInputAvailable(source)&&self.sources[source.logical]==source&&!source.captureRecovering
        &&!source.restarted&&!source.captureUpdating&&source.stream&&source.pixels&&source.frames
        &&DWInScope(self.scope,source.router.pid)&&[birth(source.router.pid)isEqual:source.router.processBirth]
        &&[windowInfo(source.router.wid)[(id)kCGWindowOwnerPID]intValue]==source.router.pid;
}
- (BOOL)nativeHoverSite:(LiveSource *)source hit:(NSDictionary *)hit view:(DesktopView *)view output:(NSNumber *)output at:(CGPoint)point {
    // A full replica can remain a replica by policy. Do not consume its press
    // for an ownership request that the view plan will refuse.
    // A cooperative singleton first needs the family observation requested by
    // requestNativeOwnershipAt:. Eligibility is checked again after that audit.
    if(source.nativeFamily&&![self.nativeViews canTransferWindow:source.logical output:output])return NO;
    NSDictionary *intent=[view inputIntentForHit:hit output:output],*site=[self.nativeViews placement:source.logical output:output],*drawn=nil,*observed=nil;
    for(NSDictionary *placement in self.renderedPresentation[@"placements"])if([placement[@"window"]isEqual:source.logical]&&[placement[@"output"]isEqual:output]){drawn=placement;break;}
    for(NSDictionary *placement in self.nativeHoverPresentation[@"placements"])if([placement[@"window"]isEqual:source.logical]&&[placement[@"output"]isEqual:output]){observed=placement;break;}
    return intent&&site&&drawn&&observed&&![site[@"family_only"]boolValue]&&![drawn[@"family_only"]boolValue]
        &&boundIdentity(intent[@"identity"],source.identity)&&[drawn[@"source"]isEqual:site[@"source"]]
        &&[observed[@"source"]isEqual:drawn[@"source"]]
        &&CGRectEqualToRect(DWRectFromJSON(observed[@"screen_rect"]),DWRectFromJSON(drawn[@"screen_rect"]))
        &&CGRectEqualToRect(DWRectFromJSON(observed[@"clip_rect"]),DWRectFromJSON(drawn[@"clip_rect"]))
        &&CGRectEqualToRect(DWRectFromJSON(drawn[@"screen_rect"]),DWRectFromJSON(site[@"screen_rect"]))
        &&CGRectEqualToRect(DWRectFromJSON(drawn[@"clip_rect"]),DWRectFromJSON(site[@"clip_rect"]))
        &&CGRectEqualToRect(DWRectFromJSON(site[@"screen_rect"]),DWRectFromJSON(site[@"clip_rect"]))
        &&CGRectContainsPoint(DWRectFromJSON(site[@"clip_rect"]),point);
}
- (void)cancelNativeHoverForWindow:(NSNumber *)window {
    DWNativeViewTransfer *transfer=self.nativeHoverTransfer;
    // A queued packet has no admitted binding yet. A source invalidation must
    // invalidate it too, rather than let deferred work rediscover a replacement.
    if(window&&transfer&&transfer.window!=window.unsignedLongLongValue)return;
    self.nativeHoverEpoch++;self.nativeHoverQueued=NO;self.nativeHoverObservation=nil;self.nativeHoverPresentation=nil;
    self.nativeHoverTransfer=nil;self.nativeHoverView=nil;self.nativeHoverUntil=0;
    DWNativeAppliedPlacement *placed=transfer?[self.nativeViews admittedPlacementForWindow:@(transfer.window)]:nil;
    if(transfer&&![self.nativeViews isAdmissionCurrentForTransfer:transfer placement:placed]
        &&[self.nativeViews isTransferCurrent:transfer]){
        [self.nativeViews cancelTransfer:transfer];
        if(self.nativeOwnershipTransfer==transfer)self.nativeOwnershipTransfer=nil;
    }
    // Completed ownership persists on hover departure. Pending cancellation
    // keeps both copies covered until existing geometry-only recovery settles.
}
- (void)queueNativeHover:(CGEventRef)event {
    NSEvent *motion=[NSEvent eventWithCGEvent:event];CGPoint point=CGEventGetLocation(event);
    int64_t eligible=CGEventGetIntegerValueField(event,kCGMouseEventWindowUnderMousePointerThatCanHandleThisEvent);
    BOOL canvas=NO;for(DesktopView *view in self.views)if(view.window.windowNumber==eligible&&eligible>0){canvas=YES;break;}
    if(!canvas&&!self.nativeHoverObservation&&!self.nativeHoverTransfer)return;
    BOOL plain=self.native&&CGEventGetType(event)==kCGEventMouseMoved&&!DWNativeTabletEvent(event)
        &&motion.subtype==NSEventSubtypeMouseEvent&&CGEventGetIntegerValueField(event,kCGEventSourceUnixProcessID)!=getpid()
        &&!NSEvent.pressedMouseButtons&&isfinite(point.x)&&isfinite(point.y);
    self.nativeHoverObservation=plain?@{@"point":pointJSON(point),@"flags":@(motion.modifierFlags),
        @"eligible_window":@(eligible)}:nil;
    self.nativeHoverPresentation=plain?self.renderedPresentation:nil;
    self.nativeHoverUntil=plain?CACurrentMediaTime()+.75:0;
    if(self.nativeHoverQueued)return;
    self.nativeHoverQueued=YES;uint64_t epoch=self.nativeHoverEpoch;__weak Desktop *weak=self;
    dispatch_async(dispatch_get_main_queue(),^{Desktop *desktop=weak;if(!desktop||desktop.nativeHoverEpoch!=epoch)return;
        desktop.nativeHoverQueued=NO;[desktop updateNativeHover];});
}
- (BOOL)queuedNativeHoverPress:(NSEvent *)event source:(LiveSource *)source hit:(NSDictionary *)hit view:(DesktopView *)view output:(NSNumber *)output at:(CGPoint)point {
    NSDictionary *observation=self.nativeHoverObservation;
    NSArray *triggers=@[@"left",@"right",@"middle",@"back",@"forward"];NSInteger button=event.buttonNumber;
    NSDictionary *binding=button>=0&&button<(NSInteger)triggers.count?[self mouseBinding:triggers[button] source:nil flags:event.modifierFlags window:YES under:source.logical pick:NO]:nil;
    if(!observation||self.nativeHoverTransfer||CACurrentMediaTime()>=self.nativeHoverUntil
        ||![observation[@"eligible_window"]isEqual:@(view.window.windowNumber)]
        ||!CGPointEqualToPoint(point,jsonPoint(observation[@"point"]))||button<0||button>=32
        ||event.subtype!=NSEventSubtypeMouseEvent||[hit[@"pick"]boolValue]||[hit[@"widget"]boolValue]
        ||[hit[@"placeholder"]boolValue]||hit[@"native_member"]||![self nativeOwnershipReady:source]
        ||CGEventGetIntegerValueField(event.CGEvent,kCGEventTargetUnixProcessID)!=getpid()
        ||CGEventGetIntegerValueField(event.CGEvent,kCGMouseEventWindowUnderMousePointerThatCanHandleThisEvent)!=view.window.windowNumber
        ||binding.count||[view resizeBorderForButton:button flags:event.modifierFlags hit:hit at:point output:output]
        ||(button==0&&[self replicaGreen:source at:point output:output]))return NO;
    return [self nativeHoverSite:source hit:hit view:view output:output at:point];
}
- (void)updateNativeHover {
    NSDictionary *observation=self.nativeHoverObservation;CGPoint point=pointer();
    if(!observation||CACurrentMediaTime()>=self.nativeHoverUntil||![self nativeHoverAllowed]
        ||(([observation[@"flags"]unsignedLongLongValue]^NSEvent.modifierFlags)&NSEventModifierFlagDeviceIndependentFlagsMask)
        ||!CGPointEqualToPoint(point,jsonPoint(observation[@"point"]))){[self cancelNativeHoverForWindow:nil];return;}
    [self nativeDescription:[self visualSnapshot]];
    NSDictionary *recipient=DWNativeEventRecipientAtPoint(point);
    DWNativeViewTransfer *held=self.nativeHoverTransfer;
    if(held){
        DWNativeAppliedPlacement *placed=[self.nativeViews admittedPlacementForWindow:@(held.window)];
        if([self.nativeViews isAdmissionCurrentForTransfer:held placement:placed]){[self cancelNativeHoverForWindow:nil];return;}
        LiveSource *source=self.sources[@(held.window)];DesktopView *view=self.nativeHoverView;
        BOOL atCanvas=recipient&&[recipient[@"pid"]intValue]==getpid()&&[recipient[@"wid"]longLongValue]==view.window.windowNumber;
        BOOL atMember=NO;for(NSDictionary *member in held.members)if(boundIdentity(recipient,member[@"identity"]))atMember=YES;
        if(!view||![self.views containsObject:view]||![view.outputs containsObject:@(held.output)]||![self nativeOwnershipReady:source]
            ||![self.nativeViews isTransferCurrent:held]||!boundIdentity(source.identity,held.identity)
            ||!CGRectContainsPoint(held.clipRect,point)||(!atCanvas&&!atMember)){[self cancelNativeHoverForWindow:nil];return;}
        if(atCanvas){NSDictionary *hit=[view hit:point output:@(held.output)];
            if(![hit[@"window"]isEqual:source.logical]||hit[@"native_member"]||[hit[@"pick"]boolValue]){[self cancelNativeHoverForWindow:nil];return;}}
        return;
    }
    DesktopView *view=nil;for(DesktopView *candidate in self.views)if(candidate.window.windowNumber==[recipient[@"wid"]longLongValue]
        &&[recipient[@"pid"]intValue]==getpid()){view=candidate;break;}
    if(!view||![observation[@"eligible_window"]isEqual:@(view.window.windowNumber)]){[self cancelNativeHoverForWindow:nil];return;}
    NSNumber *output=[view outputAt:point];NSDictionary *hit=output?[view hit:point output:output]:nil;
    NSNumber *logical=liveHit(hit);LiveSource *source=logical?self.sources[logical]:nil;NSEventModifierFlags flags=[observation[@"flags"]unsignedLongLongValue];
    if(!output||![self nativeOwnershipReady:source]||![self.nativeViews replica:source.logical output:output]
        ||[hit[@"pick"]boolValue]||[hit[@"widget"]boolValue]||[hit[@"placeholder"]boolValue]||hit[@"native_member"]
        ||self.nativeOwnershipTransfer||[self.nativeViews requiresPlacementAdmissionForWindow:source.logical]
        ||[self mouseBinding:@"left" source:nil flags:flags window:YES under:source.logical pick:NO].count
        ||[view resizeBorderForButton:0 flags:flags hit:hit at:point output:output]
        ||[self replicaGreen:source at:point output:output]){[self cancelNativeHoverForWindow:nil];return;}
    if(![self nativeHoverSite:source hit:hit view:view output:output at:point]){[self cancelNativeHoverForWindow:nil];return;}
    DWNativeViewTransfer *transfer=[self requestNativeOwnershipAt:point view:view];
    if(transfer){self.nativeHoverTransfer=transfer;self.nativeHoverView=view;}
    else if(source.nativeFamily)[self cancelNativeHoverForWindow:nil];
}
// Canonical ownership request for hover and an actual AppKit drag destination.
// No pasteboard access, source activation, synthetic mouse packet or global
// window ordering is involved. Capture, identity and complete-family rules all
// remain applicable to the prospective destination.
- (DWNativeViewTransfer *)requestNativeOwnershipAt:(CGPoint)point view:(DesktopView *)view {
    if(!self.native||self.native.ended||self.cleaning||self.sessionInactive||![self.views containsObject:view])return nil;
    NSNumber *output=[view outputAt:point];if(!output)return nil;
    NSDictionary *hit=[view hit:point output:output];NSNumber *window=liveHit(hit);
    LiveSource *source=window?self.sources[window]:nil;
    if(![self nativeOwnershipReady:source]||[hit[@"pick"]boolValue]
        ||![self.nativeViews replica:window output:output])return nil;
    // Cooperative singleton helpers normally need no family polling. A transfer
    // does; ask the existing bounded observation worker, never invent root-only.
    if(!source.nativeFamily){if(!source.nativeTransferFamilyWanted){source.nativeTransferFamilyWanted=YES;self.windowObservationAgain=YES;[self requestWindowObservation];}
        if(self.nativeHoverObservation){self.nativeTransferUntil=MAX(self.nativeTransferUntil,self.nativeHoverUntil);[self startNativeTransferTimer];}return nil;}
    DWNativeViewTransfer *current=[self.nativeViews currentTransferForWindow:window];
    if(current&&[self.nativeViews isTransferCurrent:current]&&current.output==output.unsignedLongLongValue)return current;
    if(self.nativeOwnershipTransfer&&[self.nativeViews isTransferCurrent:self.nativeOwnershipTransfer])
        [self.nativeViews cancelTransfer:self.nativeOwnershipTransfer];
    DWNativeViewTransfer *transfer=[self.nativeViews requestTransferForWindow:window output:output];
    if(!transfer)return nil;self.nativeOwnershipTransfer=transfer;self.nativeOwnershipDeadline=CACurrentMediaTime()+.75;
    self.nativeTransferUntil=CACurrentMediaTime()+2;self.nativeTransferNextCheck=0;
    [self render];[self captureDemand];
    [self startNativeTransferTimer];return transfer;
}
- (void)startNativeTransferTimer {
    if(!self.nativeTransferTimer){__weak Desktop *weak=self;
        self.nativeTransferTimer=[NSTimer timerWithTimeInterval:.02 repeats:YES block:^(NSTimer *timer){Desktop *desktop=weak;if(!desktop){[timer invalidate];return;}[desktop advanceNativeTransfers];}];
        [NSRunLoop.mainRunLoop addTimer:self.nativeTransferTimer forMode:NSRunLoopCommonModes];}
}
- (void)stopNativeTransferTimer { [self.nativeTransferTimer invalidate];self.nativeTransferTimer=nil; }
- (void)advanceNativeTransfers {
    if(!self.native||self.native.ended||self.cleaning||self.sessionInactive){[self cancelNativeHoverForWindow:nil];[self stopNativeTransferTimer];return;}
    CFTimeInterval now=CACurrentMediaTime();if(now<self.nativeTransferNextCheck)return;
    self.nativeTransferNextCheck=now+.02;
    NSDictionary *snapshot=[self visualSnapshot];[self nativeDescription:snapshot];
    if(self.nativeHoverObservation||self.nativeHoverTransfer)[self updateNativeHover];
    NSArray<DWNativeViewTransfer *> *pending=self.nativeViews.pendingTransfers;
    if(!pending.count){if(!self.nativeHoverObservation)[self stopNativeTransferTimer];self.nativeOwnershipTransfer=nil;return;}
    if(self.nativeOwnershipTransfer&&now>=self.nativeOwnershipDeadline&&[pending containsObject:self.nativeOwnershipTransfer]){
        if(self.nativeOwnershipTransfer==self.nativeHoverTransfer)[self cancelNativeHoverForWindow:nil];
        else [self.nativeViews cancelTransfer:self.nativeOwnershipTransfer];
        self.nativeOwnershipTransfer=nil;[self render];
        pending=self.nativeViews.pendingTransfers;
    }
    // One synchronous geometry check per turn. Unlike camera frames this is a
    // bounded handoff; ordinary idle/primary rendering executes no native reads.
    NSUInteger count=pending.count,start=count?self.nativeTransferCursor%count:0;
    for(NSUInteger index=0;index<count;index++){
        NSUInteger slot=(start+index)%count;DWNativeViewTransfer *transfer=pending[slot];
        DWNativeAppliedPlacement *placement=[self.native acknowledgedPlacementForWindow:@(transfer.window) identity:transfer.identity generation:@(transfer.generation) output:@(transfer.output)];
        if(!placement)continue;self.nativeTransferCursor=slot+1;__weak Desktop *weak=self;
        BOOL complete=[self.nativeViews completeTransfer:transfer placement:placement current:^BOOL(DWNativeAppliedPlacement *receipt){return [weak.native isAcknowledgedPlacementCurrent:receipt];}
            validateGeometry:^BOOL(DWNativeAppliedPlacement *receipt){
                if(!DWNativeValidateAppliedPlacementGeometry(weak.native,receipt,NULL))return NO;
                if(weak.nativeHoverTransfer==transfer){[weak updateNativeHover];return weak.nativeHoverTransfer==transfer;}
                return YES;
            }];
        if(complete){if(self.nativeOwnershipTransfer==transfer)self.nativeOwnershipTransfer=nil;
            if(self.nativeHoverTransfer==transfer)[self cancelNativeHoverForWindow:nil];
            [self render];[self captureDemand];}
        else self.nativeTransferNextCheck=now+.05;
        break;
    }
    // A failed recovery remains visibly covered and is retried at the ordinary
    // reconciliation pace, without an unbounded fast timer or fake admission.
    if(now>=self.nativeTransferUntil||!self.nativeViews.pendingTransfers.count)[self stopNativeTransferTimer];
}
@end
