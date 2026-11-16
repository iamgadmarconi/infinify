// SPDX-License-Identifier: GPL-3.0-or-later
// Split from native/desktop/main.m at 37b27b1, moved verbatim.
// DesktopView as DriftWM's pointer-policy host (DWPointerHover.h): hover, cursor and policy presses.
#import "Desktop+Private.h"
#import "DesktopView.h"
#import "DWNativeFamily.h"
#import "DWGeometryJSON.h"
@implementation DesktopView (Pointer)
// Hover asks once a frame, and what the controller refuses it is not news for the resting status.
- (DWControllerReply *)pointerCommand:(DWControllerReply *(^)(id<DWInputController> controller))operation quiet:(BOOL)quiet {
    Desktop *d=self.desktop;if([d nativeUnavailable])return nil;
    NSString *status=d.statusText;DWControllerReply *reply=operation(d.controller);if(quiet)d.statusText=status;return reply;
}
- (DWResizeBorder *)resizeBorderAt:(CGPoint)point output:(NSNumber *)output quiet:(BOOL)quiet {
    return [self pointerCommand:^DWControllerReply *(id<DWInputController> c){return [c resizeBorderOnOutput:output screen:point];} quiet:quiet].border;
}
- (DWControllerReply *)pointerHoverOnOutput:(NSNumber *)output screen:(CGPoint)point time:(NSNumber *)time quiet:(BOOL)quiet {
    Desktop *d=self.desktop;NSDictionary *childHover=nil,*childBounds=nil;LiveSource *hoverSource=nil;NSNumber *hoverGeneration=nil,*forwardMotion=nil;
    if([d nativeUnavailable])return nil;
    {
        if(d.native.ended||d.sessionInactive)return nil;
        CGWindowID top=(CGWindowID)[NSWindow windowNumberAtPoint:NSMakePoint(point.x,screenTop()-point.y) belowWindowWithWindowNumber:0];
        LiveSource *source=[d nativeSource:top at:point];NSDictionary *replicaMember=nil;
        if(!source&&top==(CGWindowID)self.window.windowNumber){
            if(![d.compositor appliedOrderForOutput:output snapshot:[d presentationSnapshot]])return nil;
            DWHit *hit=[self hit:point output:output];NSDictionary *member=hit.nativeMember;NSNumber *window=hit.window;LiveSource *candidate=window?d.sources[window]:nil;
            if(member&&candidate&&[d.nativeFamilies contains:candidate.logical identity:member[@"identity"] generation:member[@"generation"] bounds:DWRectFromJSON(member[@"native_bounds"])]&&DWNativeWindowBelongsToRoot(member[@"identity"],candidate.identity)){source=candidate;replicaMember=member;}
        }
        if(source){DWSource *binding=[d sourceBinding:source.logical];
            if(!boundIdentity(source.identity,DWNativeIdentity(binding.identity))||!binding.generation)return nil;
            if(replicaMember&&(![replicaMember[@"generation"]isEqual:binding.generation]||![binding.observationKnown boolValue]))return nil;
            if(replicaMember){childBounds=replicaMember[@"native_bounds"];childHover=@{@"window":source.logical,@"output":output,@"generation":binding.generation,@"identity":replicaMember[@"identity"],@"root_identity":source.identity,@"native_member":@YES};}
            hoverSource=source;hoverGeneration=binding.generation;forwardMotion=replicaMember?@YES:nil;
        }else if(top!=(CGWindowID)self.window.windowNumber)return nil;
    }
    NSString *status=d.statusText;DWControllerReply *reply=hoverSource?[d.controller hoverWindow:hoverSource.logical identity:DWControllerIdentity(hoverSource.identity) generation:hoverGeneration output:output screen:point time:time forwardMotion:forwardMotion]:[d.controller hoverOnOutput:output screen:point time:time];DWFocusEffect *effect=reply.primaryFocusEffect;
    if(childHover&&effect.kind==DWEffectFocusNativeWindow){
        // Hover already changed focus in place. A captured child's root must
        // never reach the AX driver: native root focus can dismiss its popup.
        BOOL current=[effect.window isEqual:childHover[@"window"]]&&[effect.generation isEqual:childHover[@"generation"]]
            &&boundIdentity(childHover[@"root_identity"],DWNativeIdentity(effect.identity))&&[d validateInputTarget:childHover]
            &&[d.nativeFamilies contains:childHover[@"window"] identity:childHover[@"identity"] generation:childHover[@"generation"] bounds:DWRectFromJSON(childBounds)];
        BOOL settled=(current?[d.controller focusLogical:effect]:[d.controller focusResult:effect success:NO])!=nil;
        reply=[reply replyWithNullEffectAndForward:!current||!settled?@NO:nil];
    }
    if(quiet)d.statusText=status;return reply;
}
- (void)pointerApply:(DWControllerReply *)reply { [self.desktop applyReply:reply]; }
// As a window that took the focus by itself: the request is the coordinator's, which answers it focus_logical
// under --no-native-focus, and with none only work for a request the controller has dropped is withdrawn.
// The focus is saved on the next poll.
- (void)pointerFocused:(DWFocusEffect *)effect { [self.desktop.navigation perform:[DWControllerReply replyWithFocusEffect:effect]];self.desktop.sceneDirty=YES;[self.desktop render]; }
// Upstream's hover and its pointer delivery stand down under a pointer grab. Here that is whatever has the pointer or
// the pad: a button down anywhere; a press any panel is handling, which is every drag there is (a pan, a window move
// by a bound press or by a pick-mode press, a press in a native window, a policy press); a trackpad gesture the
// recogniser has made of the touches or the controller holds, a move gesture's drag among them, and a magnify stream;
// a native resize that has not drained. The controller refuses the same on its own account (docs/crates/desktop/POINTER.md): this
// only keeps the question from being asked.
- (BOOL)pointerBusy {
    Desktop *desktop=self.desktop;
    if(!desktop||desktop.cleaning||desktop.sessionInactive||NSEvent.pressedMouseButtons||desktop.gestureOwner||desktop.magnifying||desktop.trackpad.engaged||desktop.compositor.hasGeometryTransitions)return YES;
    for(DesktopView *view in desktop.views)if(view.gesture||view.pressedSource)return YES;
    return NO;
}
- (NSNumber *)pointerSample:(CGPoint *)screen { CGPoint p=pointer();NSNumber *output=[self.desktop outputUnderPointer:p];*screen=p;return [self.outputs containsObject:output]?output:nil; }
- (BOOL)pointerFramed { return self.desktop.frameDriver!=nil; }
- (BOOL)pointerHeld { return [DWCycleHold modifiersDown]!=0; }
- (void)refreshCursor {
    Desktop *desktop=self.desktop;
    // Fill owns interaction until the same native root is revealed. There is
    // no canvas cursor to admit against its intermediate snapshot geometry.
    if(desktop.sizeTransition.fillHandoff){[desktop.canvasCursor releaseOwner:self];return;}
    NSPoint location=NSEvent.mouseLocation;CGPoint point=CGPointMake(location.x,screenTop()-location.y);
    NSNumber *output=[self outputAt:point];
    if(desktop.native){
        BOOL grab=NO;for(DesktopView *view in desktop.views)if(view.gesture==1||view.gesture==2||view.gesture==4){grab=YES;break;}
        // Native camera frames move real windows over a stationary pointer.
        // With no custom canvas cursor to claim, withdraw only our override;
        // querying WindowServer just to choose its ordinary arrow would stall
        // every frame. Actual motion/cursor events still take pointerCursor's
        // fresh recipient check, as do render-time pick, border and grab states.
        if(!grab&&(!output||[self pointerBusy]
            ||(!DWPickOutput([desktop visualSnapshot],output)
                &&![self resizeBorderAt:point output:output quiet:YES]))){
            [desktop.canvasCursor releaseOwner:self];return;
        }
    }
    [self pointerCursor:point output:output reply:nil];
}
// Only a canvas panel that would receive a physical click owns an override.
// Real application windows, the menu bar, Dock and chooser keep their cursor.
// This policy never guesses the cursor requested by a captured application.
- (void)pointerCursor:(CGPoint)p output:(NSNumber *)output reply:(DWControllerReply *)reply {
    Desktop *d=self.desktop;
    if(d.sizeTransition.fillHandoff||d.cleaning||d.sessionInactive||!output||![self.outputs containsObject:output]||!self.window.visible||self.window.ignoresMouseEvents||!CGRectContainsPoint(self.globalBounds,p)){
        [d.canvasCursor releaseOwner:self];return;
    }
    DesktopView *grab=nil;
    for(DesktopView *view in d.views)if(view.gesture==1||view.gesture==2||view.gesture==4){grab=view;break;}
    if(!grab&&[self pointerBusy]){[d.canvasCursor releaseOwner:self];return;}
    NSPoint appPoint=NSMakePoint(p.x,screenTop()-p.y);
    if([NSWindow windowNumberAtPoint:appPoint belowWindowWithWindowNumber:0]!=self.window.windowNumber){[d.canvasCursor releaseOwner:self];return;}
    NSCursor *cursor=NSCursor.arrowCursor;
    if(grab.gesture==1||grab.gesture==2)cursor=NSCursor.closedHandCursor;
    else if(grab.gesture==4){
        DWResizeTransaction *resize=d.controller.scene.nativeResize;
        if([resize.transaction isEqual:grab.resizeTransaction])cursor=DWCanvasResizeCursor(resize.edges)?:cursor;
    }else {
        DWHit *hit=reply?reply.hit:[self hit:p output:output];
        BOOL pick=reply?reply.pick.boolValue:hit.pick.boolValue;
        if(pick)cursor=NSCursor.pointingHandCursor;
        else if(!hit.nativeMember){
            DWResizeBorder *border=[self resizeBorderAt:p output:output quiet:YES];
            DWHit *recipient=border?[self hit:p output:output]:nil;
            if(!recipient.nativeMember&&(!recipient||[recipient.window isEqual:border.window]))cursor=DWCanvasResizeCursor(border.edges)?:cursor;
        }
    }
    [d.canvasCursor setCursor:cursor owner:self];
}
// The motion itself, re-addressed like a click: -forward:… validates the source and maps the point into its window.
// Without Accessibility nothing is posted, and at this cadence nothing is said either.
- (void)pointerDeliver:(NSEvent *)motion at:(CGPoint)p output:(NSNumber *)output {
    if(!AXIsProcessTrusted()||self.desktop.compositor.hasGeometryTransitions)return;
    NSString *status=self.desktop.statusText;CGEventRef cg=motion.CGEvent?CGEventCreateCopy(motion.CGEvent):CGEventCreateMouseEvent(NULL,kCGEventMouseMoved,p,kCGMouseButtonLeft);
    [self forward:cg at:p output:output];if(cg)CFRelease(cg);self.desktop.statusText=status;
}
@end
