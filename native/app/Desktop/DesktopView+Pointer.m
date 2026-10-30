// SPDX-License-Identifier: GPL-3.0-or-later
// DesktopView as DriftWM's pointer-policy host (pointer-hover.h): hover, cursor and policy presses.
#import "Desktop+Private.h"
#import "DesktopView.h"
#import "DWNativeFamily.h"
#import "DWGeometryJSON.h"
@implementation DesktopView (Pointer)
// Hover asks once a frame, and what the controller refuses it is not news for the resting status.
- (NSDictionary *)pointerCommand:(NSDictionary *)command quiet:(BOOL)quiet {
    Desktop *d=self.desktop;NSDictionary *childHover=nil,*childBounds=nil;
    if([d nativeUnavailable])return nil;
    if([command[@"op"]isEqual:@"hover"]){
        if(d.native.ended||d.sessionInactive)return nil;
        CGPoint point=jsonPoint(command[@"screen"]);CGWindowID top=(CGWindowID)[NSWindow windowNumberAtPoint:NSMakePoint(point.x,screenTop()-point.y) belowWindowWithWindowNumber:0];
        LiveSource *source=[d nativeSource:top at:point];NSDictionary *replicaMember=nil;
        if(!source&&top==(CGWindowID)self.window.windowNumber){
            if(![d.compositor appliedOrderForOutput:command[@"output"] snapshot:[d presentationSnapshot]])return nil;
            NSDictionary *hit=[self hit:point output:command[@"output"]],*member=DWTyped(hit[@"native_member"],NSDictionary.class);NSNumber *window=DWTyped(hit[@"window"],NSNumber.class);LiveSource *candidate=window?d.sources[window]:nil;
            if(member&&candidate&&[d.nativeFamilies contains:candidate.logical identity:member[@"identity"] generation:member[@"generation"] bounds:DWRectFromJSON(member[@"native_bounds"])]&&DWNativeWindowBelongsToRoot(member[@"identity"],candidate.identity)){source=candidate;replicaMember=member;}
        }
        if(source){NSDictionary *binding=nil;for(NSDictionary *window in [d call:@{@"op":@"snapshot"}][@"windows"])if([window[@"window"]isEqual:source.logical])binding=DWTyped(window[@"source"],NSDictionary.class);
            if(!boundIdentity(source.identity,binding[@"identity"])||!binding[@"generation"])return nil;
            if(replicaMember&&(![replicaMember[@"generation"]isEqual:binding[@"generation"]]||![binding[@"observation_known"]boolValue]))return nil;
            if(replicaMember){childBounds=replicaMember[@"native_bounds"];childHover=@{@"window":source.logical,@"output":command[@"output"],@"generation":binding[@"generation"],@"identity":replicaMember[@"identity"],@"root_identity":source.identity,@"native_member":@YES};}
            NSMutableDictionary *native=[command mutableCopy];native[@"op"]=@"hover_source";native[@"window"]=source.logical;native[@"identity"]=source.identity;native[@"generation"]=binding[@"generation"];if(replicaMember)native[@"forward_motion"]=@YES;command=native;
        }else if(top!=(CGWindowID)self.window.windowNumber)return nil;
    }
    NSString *status=d.statusText;NSDictionary *reply=[d call:command],*effect=DWTyped(reply[@"effect"],NSDictionary.class);
    if(childHover&&[effect[@"op"]isEqual:@"focus_native_window"]){
        // Hover already changed focus in place. A captured child's root must
        // never reach the AX driver: native root focus can dismiss its popup.
        BOOL current=[effect[@"window"]isEqual:childHover[@"window"]]&&[effect[@"generation"]isEqual:childHover[@"generation"]]
            &&boundIdentity(childHover[@"root_identity"],DWTyped(effect[@"identity"],NSDictionary.class))&&[d validateInputTarget:childHover]
            &&[d.nativeFamilies contains:childHover[@"window"] identity:childHover[@"identity"] generation:childHover[@"generation"] bounds:DWRectFromJSON(childBounds)];
        NSMutableDictionary *answer=[effect mutableCopy];answer[@"op"]=current?@"focus_logical":@"focus_result";if(!current)answer[@"success"]=@NO;
        BOOL settled=[d call:answer]!=nil;NSMutableDictionary *logical=[reply mutableCopy];logical[@"effect"]=NSNull.null;
        if(!current||!settled)logical[@"forward"]=@NO;reply=logical;
    }
    if(quiet)d.statusText=status;return reply;
}
- (void)pointerApply:(NSDictionary *)reply { [self.desktop applyReply:reply]; }
// As a window that took the focus by itself: the request is the coordinator's, which answers it focus_logical
// under --no-native-focus, and with none only work for a request the controller has dropped is withdrawn.
// The focus is saved on the next poll.
- (void)pointerFocused:(NSDictionary *)effect { [self.desktop.navigation perform:effect?@{@"effect":effect}:@{}];self.desktop.sceneDirty=YES;[self.desktop render]; }
// Upstream's hover and its pointer delivery stand down under a pointer grab. Here that is whatever has the pointer or
// the pad: a button down anywhere; a press any panel is handling, which is every drag there is (a pan, a window move
// by a bound press or by a pick-mode press, a press in a native window, a policy press); a trackpad gesture the
// recogniser has made of the touches or the controller holds, a move gesture's drag among them, and a magnify stream;
// a native resize that has not drained. The controller refuses the same on its own account (POINTER.md): this
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
    if(desktop.nativeFillHandoff){[desktop.canvasCursor releaseOwner:self];return;}
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
                &&!DWTyped([self pointerCommand:@{@"op":@"resize_border",@"output":output,@"screen":pointJSON(point)} quiet:YES][@"border"],NSDictionary.class)))){
            [desktop.canvasCursor releaseOwner:self];return;
        }
    }
    [self pointerCursor:point output:output reply:nil];
}
// Only a canvas panel that would receive a physical click owns an override.
// Real application windows, the menu bar, Dock and chooser keep their cursor.
// This policy never guesses the cursor requested by a captured application.
- (void)pointerCursor:(CGPoint)p output:(NSNumber *)output reply:(NSDictionary *)reply {
    Desktop *d=self.desktop;
    if(d.nativeFillHandoff||d.cleaning||d.sessionInactive||!output||![self.outputs containsObject:output]||!self.window.visible||self.window.ignoresMouseEvents||!CGRectContainsPoint(self.globalBounds,p)){
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
        NSDictionary *resize=DWTyped([d call:@{@"op":@"snapshot"}][@"native_resize"],NSDictionary.class);
        if([resize[@"transaction"]isEqual:grab.resizeTransaction])cursor=DWCanvasResizeCursor(DWTyped(resize[@"edges"],NSString.class))?:cursor;
    }else {
        NSDictionary *hit=reply?DWTyped(reply[@"hit"],NSDictionary.class):[self hit:p output:output];
        BOOL pick=reply?[reply[@"pick"]boolValue]:[hit[@"pick"]boolValue];
        if(pick)cursor=NSCursor.pointingHandCursor;
        else if(!hit[@"native_member"]){
            NSDictionary *border=DWTyped([self pointerCommand:@{@"op":@"resize_border",@"output":output,@"screen":pointJSON(p)} quiet:YES][@"border"],NSDictionary.class);
            NSDictionary *recipient=border?[self hit:p output:output]:nil;
            if(!recipient[@"native_member"]&&(!recipient||[recipient[@"window"]isEqual:border[@"window"]]))cursor=DWCanvasResizeCursor(DWTyped(border[@"edges"],NSString.class))?:cursor;
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
