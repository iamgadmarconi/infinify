// SPDX-License-Identifier: GPL-3.0-or-later
// Desktop native mouse ownership: which native window owns a button press, the takeover of an application's own window drag.
// Split from native/desktop/main.m at 37b27b1, moved verbatim.
#import "Desktop+Private.h"
#import <unistd.h>
#import "DWDebugTrace.h"
#import "DWDockControl.h"
#import "DWNativeFocus.h"
#import "DWWindowEvents.h"
#import "DWNativeDecorations.h"
#import "DWNativePlacementValidation.h"
#import "DWNativeReplicaInput.h"
#import "DWNativeFamily.h"
#import "DWNativeDragTakeover.h"
#import "DWNativeResize.h"
#import "DWAXLookup.h"
#import "DWControllerHit.h"
#import "DWGeometryJSON.h"
// Main thread only: tells the answer of a revert write from one that a later press of the same ownership has made stale.
static uint64_t DWClickRevertToken;
@implementation Desktop (NativeMouse)
- (LiveSource *)nativeSource:(CGWindowID)window at:(CGPoint)point {
    if(!window||!self.native||self.native.ended||self.cleaning)return nil;
    NSNumber *root=[self.native rootWindowFor:window];if(!root)return nil;
    for(LiveSource *source in self.sources.allValues)if(!source.detached&&source.router.wid==root.unsignedIntValue){
        if(!DWInScope(self.scope,source.router.pid)||![birth(source.router.pid)isEqual:source.router.processBirth])return nil;
        NSDictionary *info=windowInfo(window);CGRect bounds=CGRectZero;
        if([info[(id)kCGWindowOwnerPID]intValue]!=source.router.pid||![info[(id)kCGWindowIsOnscreen]boolValue]
            ||[info[(id)kCGWindowAlpha]doubleValue]<=0||!info[(id)kCGWindowBounds]
            ||!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)info[(id)kCGWindowBounds],&bounds)
            ||!CGRectContainsPoint(bounds,point))return nil;
        if(window!=source.router.wid){NSMutableDictionary *member=[source.identity mutableCopy];member[@"wid"]=@(window);[member removeObjectForKey:@"owner"];if(!DWNativeWindowBelongsToRoot(member,source.identity))return nil;}
        return source;
    }
    return nil;
}
- (void)nativeMouseOwnershipChanged:(CGEventRef)event buttons:(NSIndexSet *)buttons {
    LiveSource *source=self.nativeMouseOwner;CFTimeInterval now=CACurrentMediaTime();
    if(source.nativeMouseOwnership){
        NSMutableDictionary *held=source.nativeMouseOwnership;
        if(!event){held[@"click_possible"]=@NO;[self.navigation cancelNativeClick];}
        else {
            CGEventType type=CGEventGetType(event);
            BOOL drag=type==kCGEventLeftMouseDragged||type==kCGEventRightMouseDragged||type==kCGEventOtherMouseDragged;
            CGPoint point=CGEventGetLocation(event),start=jsonPoint(held[@"click_start"]);
            if((drag&&hypot(point.x-start.x,point.y-start.y)>5)||buttons.count>1)held[@"click_possible"]=@NO;
            if(drag&&type==kCGEventLeftMouseDragged&&buttons.count==1&&[self takeOverNativeDrag:source event:event])return;
            if(!buttons.count){
                CGPoint point=CGEventGetLocation(event),start=jsonPoint(held[@"click_start"]);NSDictionary *snapshot=[self call:@{@"op":@"snapshot"}],*binding=nil,*view=nil;
                for(NSDictionary *row in snapshot[@"windows"])if([row[@"window"]isEqual:source.logical])binding=DWTyped(row[@"source"],NSDictionary.class);
                for(NSDictionary *row in snapshot[@"outputs"])if([row[@"id"]isEqual:held[@"output"]])view=row;
                BOOL click=type==kCGEventLeftMouseUp&&[held[@"click_possible"]boolValue]&&!held[@"topology_changed"]
                    &&[held[@"session"]unsignedLongLongValue]==self.nativeSessionEpoch&&hypot(point.x-start.x,point.y-start.y)<=5
                    &&boundIdentity(source.identity,binding[@"identity"])&&[binding[@"generation"]isEqual:held[@"generation"]]
                    &&[view[@"camera"]isEqual:held[@"camera"]]&&[view[@"zoom"]isEqual:held[@"zoom"]]&&[view[@"screen_bounds"]isEqual:held[@"screen_bounds"]]
                    &&CGRectContainsPoint(DWRectFromJSON(view[@"screen_bounds"]),point)&&[[self.nativeViews desiredOwnerForWindow:source.logical]isEqual:held[@"output"]];
                [self.navigation endNativeClick:held[@"click_binding"] completed:click];
                // A press that ends within the click slop with the button released (no takeover, no second button) is a click whatever the
                // canvas's own checks above made of it: the revert in -updateNativeMouseOwners keys on this.
                held[@"click_ended"]=@(type==kCGEventLeftMouseUp&&[held[@"click_possible"]boolValue]&&hypot(point.x-start.x,point.y-start.y)<=5);
            }
        }
        if(buttons.count){held[@"buttons"]=buttons;[held removeObjectForKey:@"released"];held[@"last_packet"]=@(now);}
        else {
            if(event)held[@"released"]=@(now);else [held removeObjectForKey:@"released"];
            held[@"cancelled"]=@(event==NULL);self.nativeMouseOwner=nil;
        }
        return;
    }
    // Any fresh native recipient supersedes an earlier completed click, even
    // when this press belongs to the Dock or another unmanaged window.
    [self.navigation cancelNativeClick];
    [self cancelNativeTitleClick];
    if(!event||buttons.count!=1||![buttons containsIndex:0]||CGEventGetType(event)!=kCGEventLeftMouseDown
        ||self.cleaning||self.sessionInactive||!self.native||self.native.ended||self.nativeFillHandoff)return;
    CGWindowID wid=(CGWindowID)CGEventGetIntegerValueField(event,kCGMouseEventWindowUnderMousePointerThatCanHandleThisEvent);
    if(!wid)wid=(CGWindowID)CGEventGetIntegerValueField(event,kCGMouseEventWindowUnderMousePointer);
    source=[self nativeSource:wid at:CGEventGetLocation(event)];
    // INFINIFY_DEBUG: a native press no managed window owns is left entirely to the application and WindowServer, so say why.
    if(!source){if(DWDebugTrace())fprintf(stderr,"debug: native press unowned wid=%u reason=no_source root=%d\n",wid,[self.native rootWindowFor:wid].intValue);return;}
    if([[self.resize busyWindow]isEqual:source.logical]||[self grabbed:source]
        ||self.nativeOwnershipTransfer||self.nativeHoverTransfer||[self.nativeViews requiresPlacementAdmissionForWindow:source.logical]){
        if(DWDebugTrace())fprintf(stderr,"debug: native press unowned window=#%s reason=busy_or_admission\n",source.logical.description.UTF8String);return;}
    NSDictionary *snapshot=[self call:@{@"op":@"snapshot"}],*record=nil,*view=nil,*planned=nil;NSNumber *output=[self.nativeViews desiredOwnerForWindow:source.logical];
    for(NSDictionary *row in snapshot[@"windows"])if([row[@"window"]isEqual:source.logical]){record=row;break;}
    for(NSDictionary *row in snapshot[@"outputs"])if([row[@"id"]isEqual:output]){view=row;break;}
    for(NSDictionary *row in snapshot[@"placements"])if([row[@"window"]isEqual:source.logical]&&[row[@"output"]isEqual:output]){planned=DWTyped(row[@"screen_rect"],NSDictionary.class);break;}
    NSDictionary *binding=DWTyped(record[@"source"],NSDictionary.class);double zoom=[view[@"zoom"]doubleValue];
    if(source.nativeMouseOwnership){
        NSMutableDictionary *held=source.nativeMouseOwnership;held[@"buttons"]=buttons;[held removeObjectForKey:@"released"];self.nativeMouseOwner=source;
        BOOL root=wid==source.router.wid&&boundIdentity(source.identity,binding[@"identity"])&&[binding[@"generation"]isEqual:held[@"generation"]]
            &&[view[@"camera"]isEqual:held[@"camera"]]&&[view[@"zoom"]isEqual:held[@"zoom"]]&&[view[@"screen_bounds"]isEqual:held[@"screen_bounds"]]
            &&CGRectContainsPoint(DWRectFromJSON(view[@"screen_bounds"]),CGEventGetLocation(event));
        held[@"click_start"]=pointJSON(CGEventGetLocation(event));held[@"click_possible"]=@(root);
        // Each press of a double-click answers for its own displacement: a pending or finished revert belongs to the press before.
        [held removeObjectsForKeys:@[@"click_ended",@"revert",@"revert_token",@"early_tried"]];[self watchNativePress:source];
        if(root)[self.navigation beginNativeClick:held[@"click_binding"] output:output];return;
    }
    CGRect initialNative,initialScreen;NSDictionary *initialRow=windowInfo(source.router.wid);
    if(!DWNativeBounds(source.router.wid,&initialNative)||!initialRow[(id)kCGWindowBounds]
        ||!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)initialRow[(id)kCGWindowBounds],&initialScreen)
        ||!boundIdentity(source.identity,binding[@"identity"])||!binding[@"generation"]||!view||!isfinite(zoom)||zoom<=0
        ||![self.native withholdWindow:source.identity]){if(DWDebugTrace())fprintf(stderr,"debug: native press unowned window=#%s reason=basis_or_withhold\n",source.logical.description.UTF8String);return;}
    source.nativeMouseOwnership=[@{@"identity":source.identity.copy,@"generation":binding[@"generation"],@"output":output,@"session":@(self.nativeSessionEpoch),
        @"camera":view[@"camera"],@"zoom":view[@"zoom"],@"screen_bounds":view[@"screen_bounds"],@"buttons":buttons,@"last_packet":@(now),
        @"initial_native":DWRectJSON(initialNative),@"initial_screen":DWRectJSON(initialScreen)}mutableCopy];
    // Where the controller draws the window. The window list's bounds are not always the drawn rectangle (a Finder window drawn at half
    // size from its own top-left corner read back as its native frame in the guest, so no takeover ever saw a transformed window).
    if(planned)source.nativeMouseOwnership[@"planned_screen"]=planned;
    NSDictionary *clickBinding=@{@"window":source.logical,@"identity":binding[@"identity"],@"generation":binding[@"generation"]};
    BOOL root=wid==source.router.wid&&CGRectContainsPoint(DWRectFromJSON(view[@"screen_bounds"]),CGEventGetLocation(event));
    source.nativeMouseOwnership[@"click_binding"]=clickBinding;source.nativeMouseOwnership[@"click_start"]=pointJSON(CGEventGetLocation(event));source.nativeMouseOwnership[@"click_possible"]=@(root);source.nativeMouseOwnership[@"root"]=@(root);
    if(root)[self.navigation beginNativeClick:clickBinding output:output];
    source.observationToken=++self.observationEpoch;self.nativeMouseOwner=source;[self watchNativePress:source];
    [self cancelNativeHoverForWindow:source.logical];self.nativeViewSnapshot=nil;
    // Omission preserves the current transform; it does not restore or rebase.
    // An already submitted frame can still drain before the omission ACK.
    [self render];
    if(DWDebugTrace())fprintf(stderr,"debug: native mouse owner window=#%s begin buttons=%lu\n",source.logical.description.UTF8String,(unsigned long)buttons.count);
}
// A press that went to a transformed native window and became the application's own window drag. WindowServer moves the native
// frame from where the window is drawn (not from the native frame), keeps or drops the transform as it likes while the button
// is down, and puts the transform back at the release: measured in the guest, the window left the pointer at the first packet
// (it jumped, and at zoom below 1 changed size) and the release adopted a displaced origin; macOS tiling reads the native place.
// The first drag packet that shows the native origin moving with the extent unchanged takes the pair over instead: the application's
// drag is ended with a tagged release, the rest of the physical pair is the canvas's, and the window moves by the pointer from
// the press point exactly as after a recognized title press. Resizes and content drags (the extent or nothing changes) stay native.
- (BOOL)takeOverNativeDrag:(LiveSource *)source event:(CGEventRef)event { return [self takeOverNativeDrag:source at:CGEventGetLocation(event) early:NO]; }
// `early`: the same takeover for a press that has not moved at all (the pointer within 4 points of where it fell) but whose native origin
// has: the application began WindowServer's drag at the mouse down, and the picture sits at scale 1 from then on (measured: 50 to 65 ms
// after the down, for the rest of the press), so it is not worth waiting for pointer motion. The press stays the canvas's own as an
// unmoved title press: a motion past the click slop moves the window by the pointer, a release is the title click (focus) and moves nothing.
- (BOOL)takeOverNativeDrag:(LiveSource *)source at:(CGPoint)point early:(BOOL)early {
    NSMutableDictionary *held=source.nativeMouseOwnership;
    // INFINIFY_DEBUG: why a drag packet of a native press was not taken over, once per reason and press.
    BOOL (^no)(const char *)=^BOOL(const char *reason){
        if(DWDebugTrace()&&held&&![held[@"takeover_refused"]isEqual:@(reason)]){held[@"takeover_refused"]=@(reason);fprintf(stderr,"debug: native takeover declined window=#%s reason=%s\n",source.logical.description.UTF8String,reason);}
        return NO;};
    if(!held)return NO;
    if([held[@"taken"]boolValue]||![held[@"root"]boolValue]||!self.nativeInput||self.cleaning||self.sessionInactive||!self.native||self.native.ended||self.nativeFillHandoff
        ||source.detached||!boundIdentity(source.identity,held[@"identity"])||[held[@"session"]unsignedLongLongValue]!=self.nativeSessionEpoch)return no("state");
    CGPoint start=jsonPoint(held[@"click_start"]);
    CGRect first=DWRectFromJSON(held[@"initial_native"]),drawn=held[@"planned_screen"]?DWRectFromJSON(held[@"planned_screen"]):DWRectFromJSON(held[@"initial_screen"]),native;
    if((hypot(point.x-start.x,point.y-start.y)<=4)==!early||!DWNativeBounds(source.router.wid,&native))return NO;
    if(early?!DWNativeWindowDragBegunInPlace(first,drawn,native,start,point):!DWNativeWindowDragStarted(first,drawn,native,start,point)){
        if(!early&&DWDebugTrace()&&(fabs(native.origin.x-first.origin.x)>1||fabs(native.origin.y-first.origin.y)>1))fprintf(stderr,"debug: native takeover declined window=#%s reason=drag_test first=%g,%g,%g,%g drawn=%g,%g,%g,%g now=%g,%g,%g,%g\n",source.logical.description.UTF8String,first.origin.x,first.origin.y,first.size.width,first.size.height,drawn.origin.x,drawn.origin.y,drawn.size.width,drawn.size.height,native.origin.x,native.origin.y,native.size.width,native.size.height);
        return NO;}
    NSNumber *output=held[@"output"];DesktopView *view=nil;
    for(DesktopView *candidate in self.views)if([[candidate outputAt:start]isEqual:output]){view=candidate;break;}
    if(early)held[@"early_tried"]=@YES;
    if(!view||view.gesture||view.heldPress||view.pressedSource||view.pressedTablet||view.pressedPointerGrab||self.nativeGestureView||self.nativeOwnershipTransfer||self.nativeHoverTransfer
        ||[[self.resize busyWindow]isEqual:source.logical]||![[self.nativeViews desiredOwnerForWindow:source.logical]isEqual:output])return no("view_state");
    NSDictionary *snapshot=[self call:@{@"op":@"snapshot"}],*record=nil,*pose=nil;
    for(NSDictionary *row in snapshot[@"windows"])if([row[@"window"]isEqual:source.logical]){record=row;break;}
    for(NSDictionary *row in snapshot[@"outputs"])if([row[@"id"]isEqual:output]){pose=row;break;}
    NSDictionary *binding=DWTyped(record[@"source"],NSDictionary.class);
    if(!pose||[record[@"mode"]isEqual:@"fullscreen"]||!boundIdentity(source.identity,binding[@"identity"])||![binding[@"generation"]isEqual:held[@"generation"]]
        ||![pose[@"camera"]isEqual:held[@"camera"]]||![pose[@"zoom"]isEqual:held[@"zoom"]]||![pose[@"screen_bounds"]isEqual:held[@"screen_bounds"]])return no("pose");
    NSDictionary *begun=[self call:@{@"op":@"begin_drag",@"window":source.logical,@"output":output,@"group":@NO}];
    if(!begun)return NO;
    // The drag the application started is WindowServer's own (the window follows the pointer whatever the event taps swallow), and
    // it ends when WindowServer sees the button come up. One release is posted at the HID tap for that, from a private event source so
    // that AppKit's combined button state keeps the physical button down: a release that cleared it made -endLostInput end the
    // taken-over gesture 50 ms later as a release that never arrived (measured in the guest). It carries the source's lifetime tag,
    // which both taps let through.
    CGEventSourceRef quiet=CGEventSourceCreate(kCGEventSourceStatePrivate);
    CGEventRef up=quiet?CGEventCreateMouseEvent(quiet,kCGEventLeftMouseUp,point,kCGMouseButtonLeft):NULL;
    if(up){CGEventSetIntegerValueField(up,kCGEventSourceUserData,source.router.tag);CGEventSetIntegerValueField(up,kCGMouseEventClickState,1);CGEventPost(kCGHIDEventTap,up);CFRelease(up);}
    if(quiet)CFRelease(quiet);
    if(!up){[self call:@{@"op":@"end_gesture"}];return NO;}
    held[@"taken"]=@YES;
    [self.nativeInput takeNativeButton:0];
    NSDictionary *intent=@{@"window":source.logical,@"output":output,@"identity":source.identity.copy,@"generation":binding[@"generation"]};
    [self finishNativeMouseOwner:source reason:@"native window drag taken over"];
    // The same initialization as -earlyNativeTitle:event:, for a title press that began at the press point.
    view.clickWindow=nil;[self.navigation releaseCycle];[self cancelGestures];[self cancelNavigation];[self.panLaunch cancel];view.scrollPanTime=0;
    self.nativeGestureView=view;self.nativeGestureButton=0;
    view.startPoint=view.lastPoint=start;view.dragOutput=view.lastOutput=output;view.gestureButton=0;view.lastDragPan=0;view.lastScrollPan=0;view.clearsFocus=NO;
    view.nativeTitlePress=intent;view.nativeTitleMoved=!early;view.nativeTitleReleased=NO;view.takenOverAt=CACurrentMediaTime();
    view.gesture=2;[self.navigation perform:begun];
    // An unmoved press makes no gesture_to: even a zero delta can magnetically snap and arm edge pan (DesktopView -mouseDragged:).
    if(!early&&[[self call:@{@"op":@"gesture_to",@"screen_delta":pointJSON(CGPointMake(point.x-start.x,point.y-start.y)),@"pointer":pointJSON(point)}][@"needs_frames"]boolValue])[self ensureFrames];
    view.lastPoint=point;[self render];
    if(DWDebugTrace())fprintf(stderr,"debug: native window drag taken over%s window=#%s native=%g,%g drawn=%g,%g\n",early?" at the press":"",source.logical.description.UTF8String,native.origin.x,native.origin.y,drawn.origin.x,drawn.origin.y);
    return YES;
}
// A press forwarded to a transformed window can become the application's own window drag without one pointer packet: the application
// calls performWindowDragWithEvent: at the down and WindowServer moves the native frame then. Nothing on the event tap sees that, so the
// press is watched at 4 ms while the button is down, and takes over as soon as the origin moves with the pointer still at rest.
- (void)watchNativePress:(LiveSource *)source {
    NSMutableDictionary *held=source.nativeMouseOwnership;if(!held||[(NSTimer *)held[@"watch"]isValid])return;
    __weak Desktop *weak=self;__weak LiveSource *weakSource=source;
    NSTimer *timer=[NSTimer timerWithTimeInterval:.004 repeats:YES block:^(NSTimer *tick){
        Desktop *desktop=weak;LiveSource *owner=weakSource;NSMutableDictionary *current=owner.nativeMouseOwnership;
        if(!desktop||!owner||current!=held||current[@"watch"]!=tick||[current[@"taken"]boolValue]||[current[@"early_tried"]boolValue]||desktop.nativeMouseOwner!=owner
            ||!CGEventSourceButtonState(kCGEventSourceStateHIDSystemState,kCGMouseButtonLeft)){[tick invalidate];return;}
        CGEventRef here=CGEventCreate(NULL);CGPoint point=here?CGEventGetLocation(here):CGPointZero;if(here)CFRelease(here);
        if([desktop takeOverNativeDrag:owner at:point early:YES])[tick invalidate];
    }];
    held[@"watch"]=timer;[NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
}
- (void)finishNativeMouseOwner:(LiveSource *)source reason:(NSString *)reason {
    NSDictionary *held=source.nativeMouseOwnership;if(!held)return;
    [(NSTimer *)held[@"watch"]invalidate];
    // A lost up can retire geometry after polling, but is never a completed
    // click. An actual up already classified above is left intact.
    [self.navigation endNativeClick:held[@"click_binding"] completed:NO];
    source.nativeMouseOwnership=nil;source.observationToken=++self.observationEpoch;
    if(self.nativeMouseOwner==source)self.nativeMouseOwner=nil;
    [self.native resumeWindow:held[@"identity"]];self.nativeViewSnapshot=nil;
    if(DWDebugTrace())fprintf(stderr,"debug: native mouse owner window=#%s end=%s\n",source.logical.description.UTF8String,reason.UTF8String);
    [self render];
}
- (void)updateNativeMouseOwners {
    if(self.cleaning||self.sessionInactive||!self.native||self.native.ended)return;
    CFTimeInterval now=CACurrentMediaTime();
    for(LiveSource *source in self.sources.allValues.copy){
        NSMutableDictionary *held=source.nativeMouseOwnership;if(!held)continue;
        if([held[@"session"]unsignedLongLongValue]!=self.nativeSessionEpoch){
            [(NSTimer *)held[@"watch"]invalidate];source.nativeMouseOwnership=nil;source.nativeMouseAdopting=NO;source.observationToken=++self.observationEpoch;
            if(self.nativeMouseOwner==source)self.nativeMouseOwner=nil;continue;
        }
        __block BOOL physical=NO;[(NSIndexSet *)held[@"buttons"]enumerateIndexesUsingBlock:^(NSUInteger button,BOOL *stop){(void)stop;if(CGEventSourceButtonState(kCGEventSourceStateHIDSystemState,(CGMouseButton)button))physical=YES;}];
        // Cancellation is not a release. Lost ups settle only after the stored
        // physical buttons are up; an additional button keeps the same owner.
        if(physical){[held removeObjectForKey:@"released"];[held removeObjectForKey:@"stable_since"];continue;}
        if(!held[@"released"]){if(now-[held[@"last_packet"]doubleValue]<.05)continue;held[@"released"]=@(now);if(self.nativeMouseOwner==source)self.nativeMouseOwner=nil;}
        if(source.detached||!boundIdentity(source.identity,held[@"identity"])||![birth(source.router.pid)isEqual:source.router.processBirth]){[self finishNativeMouseOwner:source reason:@"identity changed"];continue;}
        if([[self.resize busyWindow]isEqual:source.logical])continue;
        CGRect native,after,screen;NSDictionary *row=windowInfo(source.router.wid);
        if(!row||![row[(id)kCGWindowIsOnscreen]boolValue]){
            source.nativeMouseAdopting=YES;@try{[self track:source info:row];}@finally{source.nativeMouseAdopting=NO;}
            [self finishNativeMouseOwner:source reason:@"native window closed or hidden"];continue;
        }
        if(now-[held[@"released"]doubleValue]>2){[self finishNativeMouseOwner:source reason:@"final geometry did not settle within two seconds"];continue;}
        if(!DWNativeBounds(source.router.wid,&native)||[row[(id)kCGWindowOwnerPID]intValue]!=source.router.pid||![row[(id)kCGWindowIsOnscreen]boolValue]
            ||!row[(id)kCGWindowBounds]||!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)row[(id)kCGWindowBounds],&screen)
            ||!DWNativeBounds(source.router.wid,&after)||!CGRectEqualToRect(native,after))continue;
        if(!isfinite(screen.origin.x)||!isfinite(screen.origin.y)||!isfinite(screen.size.width)||!isfinite(screen.size.height)||screen.size.width<=0||screen.size.height<=0)continue;
        NSString *revert=held[@"revert"];
        if([revert isEqual:@"pending"])continue;
        if([revert isEqual:@"done"]){[self finishNativeMouseOwner:source reason:@"reverted native click move"];continue;}
        CGRect first=DWRectFromJSON(held[@"initial_native"]);
        DWNativeClickSettle settle=DWNativeClickSettleKind([held[@"click_ended"]boolValue],[held[@"taken"]boolValue],first,native,CGRectEqualToRect(DWRectFromJSON(held[@"initial_screen"]),screen));
        if(settle==DWNativeClickSettleUnchanged){
            [self finishNativeMouseOwner:source reason:@"unchanged native click"];continue;
        }
        if(!held[@"stable_since"]||!CGRectEqualToRect(DWRectFromJSON(held[@"native"]),native)||!CGRectEqualToRect(DWRectFromJSON(held[@"screen"]),screen)){
            held[@"native"]=DWRectJSON(native);held[@"screen"]=DWRectJSON(screen);held[@"stable_since"]=@(now);continue;
        }
        if(now-[held[@"stable_since"]doubleValue]<.15)continue;
        // A click must never move the window. A press the application answered with WindowServer's own window drag (a caption area the shell
        // does not recognise: Chromium's performWindowDragWithEvent:) moves the native frame from where the window is DRAWN, so a plain click,
        // or each press of a double-click, left the frame displaced by the distance between the drawn and the native place (+327 pt per click
        // at zoom 0.5, measured in the guest) and the adoption below turned that into a world move. The click is not a move: the native frame
        // goes back to where it was at the press, through the AX position write the fill rebase uses (dw_resize_reposition), the world
        // rectangle stays, and the transform the shell draws is the one it already had. Only a refused write falls through to adoption,
        // which then keeps the world rectangle and takes the displaced frame as the basis (below).
        if(!revert&&settle==DWNativeClickSettleRevert){
            NSDictionary *who=source.identity;NSNumber *token=@(++DWClickRevertToken);held[@"revert"]=@"pending";held[@"revert_token"]=token;
            DWResizeIdentity target={[who[@"pid"]intValue],[who[@"birth_sec"]unsignedLongLongValue],[who[@"birth_usec"]unsignedLongLongValue],[who[@"wid"]unsignedIntValue]};
            __weak Desktop *weak=self;__weak LiveSource *weakSource=source;CGRect from=native;NSString *logical=source.logical.description;
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{@autoreleasepool{
                DWResizeResult result=dw_resize_reposition(target,from,first.origin,DWMonotonicSeconds()+.4);
                dispatch_async(dispatch_get_main_queue(),^{Desktop *desktop=weak;LiveSource *owner=weakSource;NSMutableDictionary *current=owner.nativeMouseOwnership;
                    if(DWDebugTrace())fprintf(stderr,"debug: native click move revert window=#%s outcome=%s ax_error=%d from=%g,%g to=%g,%g now=%g,%g\n",logical.UTF8String,dw_resize_outcome_name(result.outcome),result.ax_error,from.origin.x,from.origin.y,first.origin.x,first.origin.y,result.actual_cg.origin.x,result.actual_cg.origin.y);
                    if(!desktop||!current||![current[@"revert_token"]isEqual:token])return;
                    BOOL back=result.outcome==DWResizeApplied&&result.observed&&fabs(result.actual_cg.origin.x-first.origin.x)<=1&&fabs(result.actual_cg.origin.y-first.origin.y)<=1;
                    current[@"revert"]=back?@"done":@"failed";if(!back)current[@"revert_outcome"]=[NSString stringWithUTF8String:dw_resize_outcome_name(result.outcome)];});
            }});
            continue;
        }
        source.observationToken=++self.observationEpoch;source.nativeMouseAdopting=YES;
        @try{[self track:source info:row];}@finally{source.nativeMouseAdopting=NO;}
        if([held[@"topology_changed"]boolValue]){[self finishNativeMouseOwner:source reason:@"display topology changed; native basis refreshed"];continue;}
        NSDictionary *snapshot=[self call:@{@"op":@"snapshot"}],*record=nil,*view=nil,*placement=nil;
        for(NSDictionary *item in snapshot[@"windows"])if([item[@"window"]isEqual:source.logical]){record=item;break;}
        for(NSDictionary *item in snapshot[@"outputs"])if([item[@"id"]isEqual:held[@"output"]]){view=item;break;}
        for(NSDictionary *item in snapshot[@"placements"])if([item[@"window"]isEqual:source.logical]&&[item[@"output"]isEqual:held[@"output"]]){placement=item;break;}
        NSDictionary *binding=DWTyped(record[@"source"],NSDictionary.class);double zoom=[view[@"zoom"]doubleValue];
        BOOL current=boundIdentity(source.identity,binding[@"identity"])&&[binding[@"generation"]isEqual:held[@"generation"]]
            &&[[self.nativeViews desiredOwnerForWindow:source.logical]isEqual:held[@"output"]]
            &&[view[@"camera"]isEqual:held[@"camera"]]&&[view[@"zoom"]isEqual:held[@"zoom"]]&&[view[@"screen_bounds"]isEqual:held[@"screen_bounds"]]
            &&placement&&CGRectEqualToRect(DWRectFromJSON(binding[@"observed_rect"]),native)&&![record[@"mode"]isEqual:@"fullscreen"]&&isfinite(zoom)&&zoom>0;
        if(!current){[self finishNativeMouseOwner:source reason:@"adoption basis changed"];continue;}
        CGRect planned=DWRectFromJSON(placement[@"screen_rect"]);BOOL pinned=[placement[@"pinned"]boolValue];
        CGPoint delta=CGPointMake((screen.origin.x-planned.origin.x)/(pinned?1:zoom),(screen.origin.y-planned.origin.y)/(pinned?1:zoom));
        BOOL kept=[revert isEqual:@"failed"];if(kept)delta=CGPointZero;
        NSString *status=self.statusText;NSDictionary *moved=CGPointEqualToPoint(delta,CGPointZero)?@{@"moved":@YES}:[self call:@{@"op":@"relocate_source",@"window":source.logical,@"identity":source.identity,@"generation":binding[@"generation"],@"observed_rect":DWRectJSON(native),@"expected_world_rect":record[@"world_rect"],@"delta":pointJSON(delta)}];self.statusText=status;
        if([moved[@"deferred"]boolValue])continue;
        BOOL extent=fabs(screen.size.width-planned.size.width)<=1&&fabs(screen.size.height-planned.size.height)<=1;
        if([moved[@"moved"]boolValue])self.sceneDirty=YES;
        [self finishNativeMouseOwner:source reason:[moved[@"moved"]boolValue]?(kept?[NSString stringWithFormat:@"native click move kept, revert %@; basis only",held[@"revert_outcome"]]:extent?@"adopted displayed origin":@"adopted origin; displayed extent differs"):@"adoption refused"];
    }
}
@end
