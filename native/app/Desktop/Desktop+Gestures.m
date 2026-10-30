// SPDX-License-Identifier: GPL-3.0-or-later
// Desktop trackpad gestures: global trackpad tap, multitouch source, Dock guard, recogniser and magnify.
#import "Desktop+Private.h"
#import "DWDebugTrace.h"
#import "DWDockControl.h"
@implementation Desktop (Gestures)
- (BOOL)globalGesturesEnabled {
    // Called for every tap packet, including pointer motion: no controller,
    // capture, WindowServer observation or AppKit window lookup here.
    return !self.windowed&&!self.cleaning&&!self.sessionInactive&&self.panels.count>0&&(!self.native||!self.native.ended);
}
- (void)configureGlobalTrackpad {
    if(![self globalGesturesEnabled]||self.globalTrackpad)return;
    __weak Desktop *weak=self;
    DWGlobalTrackpadInput *input=[[DWGlobalTrackpadInput alloc]initWithEnabled:^BOOL{return [weak globalGesturesEnabled];}
        admitTouches:^BOOL(DWTrackpadTouchFrame *frame){return [weak admitGlobalTouches:frame];}
        touches:^(DWTrackpadTouchFrame *frame){[weak globalTouches:frame];}
        magnify:^BOOL(NSEvent *event){return [weak globalMagnify:event];}
        ignoreEvent:^BOOL(CGEventRef event){int64_t tag=CGEventGetIntegerValueField(event,kCGEventSourceUserData);return tag&&[weak.postingTags containsObject:@(tag)];}
        cancelled:^{[weak cancelGestures];}];
    // While the touch source delivers, the guard decides Dock control for the bound finger counts only, and per stream: this tap asks it too, so that a Dock-control
    // packet the guard's own tap did not see (or was not installed to see) is still decided, and for every format. Without a source it applies its own rule.
    input.dockDecision=^DWDockControlVerdict(CGEventRef event){Desktop *d=weak;return d.dockGuard?[d.dockGuard decide:event via:"global-tap" at:CACurrentMediaTime()]:DWDockControlUndecided;};
    if([input start]){self.globalTrackpad=input;self.globalTrackpadNoted=NO;return;}
    if(!self.globalTrackpadNoted){self.globalTrackpadNoted=YES;[self say:@"Global trackpad takeover needs existing Accessibility/input access. macOS system gestures remain active until the session tap can start."];}
}
- (BOOL)admitGlobalTouches:(DWTrackpadTouchFrame *)frame { return [self admitContact:frame.fingers]; }
// Whether a touch of `fingers` fingers is the canvas's, asked once per touch by whichever source sees its third finger first: the session tap's events
// or MultitouchSupport's frames. When both report one touch the first answer stands, so the second does not end the gesture the first began.
- (BOOL)admitContact:(NSUInteger)fingers {
    if(self.multitouch.delivering&&self.globalGestureContact)return YES;
    NSString *why=nil;
    if(![self globalGesturesEnabled])why=@"global gestures are off (canvas closed, session away or no panels)";
    else if(self.nativeFillHandoff)why=@"a native fill hand-off is in progress";
    else if(fingers<3)why=@"fewer than three fingers";
    // A native mouse press already owns its drag session, even when its pointer
    // crosses a canvas panel. Extra fingers cannot begin a new camera contact
    // that steals the original source's physical drag and release.
    else if(NSEvent.pressedMouseButtons||self.globalTrackpad.hasNativeMousePress)why=@"a mouse button is down";
    if(why){if(DWDebugTrace()&&fingers>=3)fprintf(stderr,"debug: gestures: touch of %lu fingers refused: %s\n",(unsigned long)fingers,why.UTF8String);return NO;}
    CGPoint at=pointer();BOOL output=NO;
    for(DesktopView *view in self.views){if(view.gesture){if(DWDebugTrace())fprintf(stderr,"debug: gestures: touch of %lu fingers refused: a view holds a gesture\n",(unsigned long)fingers);return NO;}if([view outputAt:at])output=YES;}
    if(!output){if(DWDebugTrace())fprintf(stderr,"debug: gestures: touch of %lu fingers refused: the pointer (%.0f,%.0f) is over no output\n",(unsigned long)fingers,at.x,at.y);return NO;}
    [self.compositor finishGeometryTransitions];if(self.compositor.hasGeometryTransitions){if(DWDebugTrace())fprintf(stderr,"debug: gestures: touch of %lu fingers refused: a geometry transition is running\n",(unsigned long)fingers);return NO;}
    [self cancelGestures];self.globalGestureContact=YES;
    if(DWDebugTrace())fprintf(stderr,"debug: gestures: touch of %lu fingers admitted as the canvas's (path %s)\n",(unsigned long)fingers,self.multitouch.delivering?"multitouch":"global-tap");
    return YES;
}
- (void)globalTouches:(DWTrackpadTouchFrame *)frame {
    if(self.multitouch.delivering||!self.trackpad||![self globalGesturesEnabled])return;
    self.touchPath=@"global-tap";
    for(NSDictionary *touch in frame.touches)[self.trackpad touch:touch[@"identity"] x:[touch[@"x"]doubleValue] y:[touch[@"y"]doubleValue] phase:(DWTouchPhase)[touch[@"phase"]integerValue] time:frame.time];
    [self.trackpad frame:frame.time];self.lastTouches=frame.time;[self armTrackpad];
    if(!frame.fingers)self.globalGestureContact=NO;
}
- (BOOL)globalMagnify:(NSEvent *)event {
    if(![self globalGesturesEnabled])return NO;
    BOOL beginning=!self.magnifying;
    if(beginning){
        if(NSEvent.pressedMouseButtons||self.globalTrackpad.hasNativeMousePress)return NO;
        CGPoint at=pointer();BOOL output=NO;
        for(DesktopView *view in self.views){if(view.gesture)return NO;if([view outputAt:at])output=YES;}
        if(!output)return NO;
        self.nativePinchAccepted=NO;
    }
    self.globalGestureDelivery=YES;
    @try {[self magnify:event];} @finally {self.globalGestureDelivery=NO;}
    if(beginning&&!self.nativePinchAccepted){[self cancelGestures];return NO;}
    return YES;
}
// Desktop mode asks MultitouchSupport for every contact of the pad, wherever the pointer is, and holds the system's Dock-control gestures back for the finger
// counts a [gestures] binding takes. Asked again each time the native input is configured, about every second: a start that failed is tried again every ten
// seconds, and the tap, which needs Accessibility the run may not have yet, each time. INFINIFY_NO_MULTITOUCH=1 leaves the views' own touches in charge.
- (void)configureMultitouch {
    if(![self globalGesturesEnabled]||(getenv("INFINIFY_NO_MULTITOUCH")&&atoi(getenv("INFINIFY_NO_MULTITOUCH"))==1))return;
    if(!self.multitouch){
        if(CACurrentMediaTime()<self.multitouchRetry)return;
        self.multitouchRetry=CACurrentMediaTime()+10;
        __weak Desktop *weak=self;DWDockGuard *guard=[DWDockGuard new];
        DWMultitouchSource *source=[[DWMultitouchSource alloc]initWithGuard:guard frames:^(DWMultitouchFrame *frame){[weak multitouchFrame:frame];}];
        // Whichever path fed the recogniser until now is not the one that does from here (or the reverse): what it was holding is let go.
        source.deliveringChanged=^(BOOL delivering){(void)delivering;[weak cancelGestures];};
        if(![source start])return;
        self.dockGuard=guard;self.multitouch=source;self.dockTap=[[DWDockTap alloc]initWithGuard:guard];
        self.touchFeed=[[DWMultitouchFeed alloc]initWithRecogniser:^DWTrackpadGestures *{return weak.trackpad;} admit:^BOOL(NSUInteger fingers){return [weak admitContact:fingers];}];
        [self refreshGestureFingers];
    }
    // A source that lost its devices (a wake that found none) is started again, as a first start is retried.
    else if(!self.multitouch.running&&CACurrentMediaTime()>=self.multitouchRetry){self.multitouchRetry=CACurrentMediaTime()+10;[self.multitouch start];}
    if(self.multitouch.running&&!self.dockTap.running)[self.dockTap start];
}
// One frame of the pad from MultitouchSupport, in order, on the main thread: the recogniser's calls once the touch is admitted. A frame that comes while the
// canvas is closed or the session is away is nobody's, and ends what a touch had begun.
- (void)multitouchFrame:(DWMultitouchFrame *)frame {
    BOOL empty=!frame.contacts.count;
    if(!self.touchFeed||!self.trackpad||self.cleaning||self.sessionInactive||![self globalGesturesEnabled]){
        [self.touchFeed cancel:frame.time];if(empty)self.globalGestureContact=NO;else [self.dockGuard refuseContact:frame.contact];return;
    }
    self.touchPath=@"multitouch";
    BOOL fed=[self.touchFeed consume:frame];
    // The system keeps a touch the canvas declined; the guard learns it at once.
    if(self.touchFeed.refused)[self.dockGuard refuseContact:frame.contact];
    if(fed){self.lastTouches=frame.time;[self armTrackpad];}
    if(empty)self.globalGestureContact=NO;
}
// The finger counts a [gestures] binding takes, for the Dock guard: after every config load, and when set-trackpad switches gestures off or on.
- (void)refreshGestureFingers {
    if(!self.dockGuard)return;
    NSDictionary *reply=[self call:@{@"op":@"gesture_fingers"}];uint32_t mask=0;
    for(id count in asArray(reply[@"fingers"])){NSUInteger n=[DWTyped(count,NSNumber.class)unsignedIntegerValue];if(n>0&&n<32)mask|=1u<<n;}
    // Five or more fingers are held back too, bound or not: the system's five-finger spread (Show Desktop) and pinch fling every
    // window to the screen's edges under a canvas that draws them elsewhere (owner, 2026-10-30, after the first real-Mac run).
    mask|=~((1u<<5)-1);
    [self.dockGuard setBound:mask];
}
// The recogniser's gesture in progress, for the Dock guard: it holds the system's gestures back for its finger count until it ends.
- (void)noteDockGesture:(NSDictionary *)event {
    NSString *op=event[@"op"];
    // INFINIFY_DEBUG: every gesture the recogniser begins or ends, with the source that fed it and what the guard held at that moment.
    if(DWDebugTrace()&&([op isEqual:@"gesture_begin"]||[op isEqual:@"gesture_end"])){
        DWDockGuardState g=[self.dockGuard state];
        fprintf(stderr,"debug: gestures: %s%s%s fingers=%s path=%s%s guard{live=%d fingers=%u gesture=%u bound=0x%x refused=%d}\n",op.UTF8String,
            [op isEqual:@"gesture_begin"]?" kind=":"",[op isEqual:@"gesture_begin"]?[DWTyped(event[@"kind"],NSString.class)UTF8String]?:"?":"",
            [op isEqual:@"gesture_begin"]?[[DWTyped(event[@"fingers"],NSNumber.class)stringValue]UTF8String]?:"?":"-",self.touchPath.UTF8String?:"?",
            [op isEqual:@"gesture_end"]?([event[@"cancelled"]boolValue]?" cancelled=1":" cancelled=0"):"",
            g.live,g.fingers,g.gesture,g.bound,g.refused);
    }
    if([op isEqual:@"gesture_begin"])[self.dockGuard gesture:[DWTyped(event[@"fingers"],NSNumber.class)unsignedIntegerValue] at:CACurrentMediaTime()];
    else if([op isEqual:@"gesture_end"])[self.dockGuard gesture:0 at:CACurrentMediaTime()];
}
// One libinput-shaped event, from the recogniser or the magnify stream, to the
// controller. gesture_begin gains what only the shell knows: the modifiers held, the
// output and the window-or-canvas context under the pointer, and the pointer itself.
// An update or an end, which may fire an action, says whether a real modifier is down
// as it does, as a hot key's action does. The reply is an action's, with what the
// gesture fired and a note when it is refused (a resize of a screen-pinned window).
- (void)gesture:(NSDictionary *)event owner:(NSInteger)owner {
    NSString *op=event[@"op"];
    // Cancellation receipts still drain the old gesture; no new/update event can
    // move the logical scene while its native owner is unavailable.
    if([self nativeUnavailable]&&(![op isEqual:@"gesture_end"]||![event[@"cancelled"]boolValue]))return;
    BOOL begin=[op isEqual:@"gesture_begin"],end=[op isEqual:@"gesture_end"],held=[DWCycleHold modifiersDown]!=0;NSMutableDictionary *command=[event mutableCopy];
    if(begin){
        [self cancelNativeTitleClick];
        // Upstream: a gesture that begins on top of a held modifier chord makes it a binding prefix, not a tap, whatever becomes of the gesture.
        [self.tapKeys taint];
        // The controller holds one gesture: a pinch that gains a third finger ends before the swipe it became begins.
        if(self.gestureOwner)[self gesture:@{@"op":@"gesture_end",@"cancelled":@YES,@"time_ms":event[@"time_ms"]} owner:self.gestureOwner];
        if(self.cleaning||self.sessionInactive)return;
        // Where a press or a scroll would land: over an output, and not during a button drag.
        CGPoint p=pointer();DesktopView *under=nil;NSNumber *output=nil;
        for(DesktopView *view in self.views){if(view.gesture)return;if(!output&&(output=[view outputAt:p]))under=view;}
        if(!output)return;
        // New input withdraws a native focus request still in flight, as a scroll does. An open cycle whose selection has settled
        // stays open, for a swipe bound to cycle-windows to step. Flights are the controller's to stop: upstream cancels them only for a bound gesture.
        under.lastOutput=output;[self.navigation interrupt];
        // A swipe or pinch of the recogniser's takes the fingers from a scroll they were making. Its later pans are held
        // back (-padBusy:); the rest of it goes here, as at a press: the 50 ms launch still pending, and the pan_end its
        // lift would send. Either launches the momentum the swipe pans with and empties its tracker, and the swipe's own
        // end, or whichever of the two comes second, would then launch nothing. scrollPan stays: macOS's inertia is still
        // swallowed. A two-finger pinch and a hold hold no scroll back, and end none.
        if(owner==1&&self.trackpad.engaged){[self.panLaunch cancel];for(DesktopView *view in self.views)view.scrollPanTime=0;}
        command[@"modifiers"]=modifiersJSON(NSEvent.modifierFlags);command[@"context"]=[[under hit:p output:output]isKindOfClass:NSDictionary.class]?@"window":@"canvas";command[@"output"]=output;command[@"pointer"]=pointJSON(p);
        self.gestureOwner=owner;self.gestureOutput=output;self.gestureWatched=!self.globalGestureContact&&!self.globalGestureDelivery&&[[self outputUnderPointer:p]isEqual:output];self.gestureMove=self.gestureResize=NO;
    }else if(owner!=self.gestureOwner)return;
    else command[@"held"]=held?@YES:@NO;
    if(end)self.gestureOwner=0;
    NSDictionary *reply=[self call:command];
    if(begin&&owner==2){NSString *state=DWTyped(DWTyped(reply[@"gesture"],NSDictionary.class)[@"state"],NSString.class);self.nativePinchAccepted=state&&![state isEqual:@"unbound"];}
    // A refusal is said once and ends the gesture on both sides. That end is a gesture reply too: a size transaction it carries is performed.
    if(!reply){
        NSString *error=self.statusText;if(!begin&&!end)[self consumeSize:[self call:@{@"op":@"gesture_end",@"cancelled":@YES,@"time_ms":event[@"time_ms"]}]];
        self.gestureOwner=0;[self flashStatus:error];[self render];return;
    }
    // A pan that ends cancelled while still moving lost its touches: macOS took them, a button was pressed, the panels went away. (A finger lifting ahead of the others waits out the recogniser's count debounce, too long to launch.) The canvas stops there instead of coasting on as upstream's cancelled swipe does.
    if(end&&[command[@"cancelled"]isEqual:@YES]&&self.gestureOutput&&[DWTyped(DWTyped(reply[@"gesture"],NSDictionary.class)[@"state"],NSString.class)isEqual:@"swipe_pan"])[self call:@{@"op":@"cancel_navigation",@"output":self.gestureOutput}];
    // No gesture in the reply: trackpad gestures are off (set-trackpad), and the rest of this one has nowhere to go.
    if(begin&&!DWTyped(reply[@"gesture"],NSDictionary.class))self.gestureOwner=0;
    if(begin){NSString *state=DWTyped(DWTyped(reply[@"gesture"],NSDictionary.class)[@"state"],NSString.class);self.gestureResize=[state isEqual:@"swipe_resize"];self.gestureMove=self.gestureResize||[state isEqual:@"swipe_move"];}
    NSDictionary *fired=DWTyped(reply[@"fired"],NSDictionary.class);NSString *action=DWTyped(fired[@"action"],NSString.class);
    // An action the gesture fired and the controller ran holds a cycle open, or ends one, as a hot key's does.
    if(action&&!DWTyped(fired[@"error"],NSString.class))[self holdCycle:action held:held];
    NSString *text=DWTyped(reply[@"note"],NSString.class)?:DWTyped(fired[@"error"],NSString.class)?:action?[self actionFeedback:action flight:DWTyped(reply[@"navigation"],NSDictionary.class) output:self.gestureOutput]:nil;
    if(text)[self flashStatus:text];
    [self applyReply:reply];
}
// Resting fingers send no events, so the recogniser's hold delay and finger-count debounce are met by a timer.
- (void)armTrackpad {
    NSTimeInterval deadline=self.cleaning?0:self.trackpad.deadline;if(deadline==self.trackpadDeadline)return;
    [self.trackpadTimer invalidate];self.trackpadTimer=nil;self.trackpadDeadline=deadline;if(!deadline)return;
    __weak Desktop *weak=self;
    self.trackpadTimer=[NSTimer timerWithTimeInterval:MAX(0,deadline-CACurrentMediaTime()) repeats:NO block:^(NSTimer *timer){(void)timer;Desktop *d=weak;d.trackpadTimer=nil;d.trackpadDeadline=0;[d.trackpad advance:CACurrentMediaTime()];[d armTrackpad];}];
    [[NSRunLoop mainRunLoop]addTimer:self.trackpadTimer forMode:NSRunLoopCommonModes];
}
// One frame of raw touches for the recogniser: every touch of the event, in
// millimetres from the pad's top left (a touch is normalised over a pad sized in
// points). A resting touch is left out, which the recogniser reads as a finger gone.
- (void)touches:(NSEvent *)e {
    if(self.globalTrackpad.running||self.multitouch.delivering)return;
    if(!self.trackpad||self.cleaning||self.sessionInactive)return;
    self.touchPath=@"view-touches";
    for(NSTouch *touch in [e touchesMatchingPhase:NSTouchPhaseAny inView:nil]){
        if(touch.type!=NSTouchTypeIndirect||touch.resting)continue;
        NSPoint p=touch.normalizedPosition;NSSize pad=touch.deviceSize;NSTouchPhase phase=touch.phase;
        [self.trackpad touch:touch.identity x:p.x*pad.width*25.4/72 y:(1-p.y)*pad.height*25.4/72 phase:phase&NSTouchPhaseCancelled?DWTouchCancelled:phase&NSTouchPhaseEnded?DWTouchEnded:phase&NSTouchPhaseBegan?DWTouchBegan:DWTouchMoved time:e.timestamp];
    }
    [self.trackpad frame:e.timestamp];self.lastTouches=e.timestamp;[self armTrackpad];
}
// A swipe or pinch of three or more fingers is the recogniser's: a scroll or a
// magnify macOS makes of the same fingers would be that gesture twice. Moving fingers
// keep sending touches, so an event long after the last of them is not theirs, and
// is never held back.
- (BOOL)padBusy:(NSEvent *)e { return self.trackpad.engaged&&e.timestamp-self.lastTouches<.25; }
// AppKit's two-finger pinch as libinput's: the scale is absolute from the gesture's
// start, the running product of each event's 1 + magnification. No rotation, no delta.
- (void)magnify:(NSEvent *)e {
    if(self.nativeFillHandoff)return;
    if(self.globalTrackpad.running&&!self.globalGestureDelivery)return;
    [self.compositor finishGeometryTransitions];
    if(self.compositor.hasGeometryTransitions)return;
    NSEventPhase phase=e.phase;NSNumber *time=DWGestureTime(e.timestamp);BOOL over=(phase&(NSEventPhaseEnded|NSEventPhaseCancelled))!=0;
    if([self padBusy:e]){if(self.magnifying){self.magnifying=NO;[self gesture:@{@"op":@"gesture_end",@"cancelled":@YES,@"time_ms":time} owner:2];}return;}
    if(phase&NSEventPhaseMayBegin)return;
    if(!self.magnifying){if(over)return;self.magnifying=YES;self.magnifyScale=1;[self gesture:@{@"op":@"gesture_begin",@"kind":@"pinch",@"fingers":@2,@"time_ms":time} owner:2];}
    if(e.magnification){self.magnifyScale*=MAX(.01,1+e.magnification);[self gesture:@{@"op":@"gesture_update",@"dx":@0,@"dy":@0,@"scale":@(self.magnifyScale),@"rotation":@0,@"time_ms":time} owner:2];}
    // An event with no phase is a whole gesture.
    if(over||phase==NSEventPhaseNone){self.magnifying=NO;[self gesture:@{@"op":@"gesture_end",@"cancelled":phase&NSEventPhaseCancelled?@YES:@NO,@"time_ms":time} owner:2];}
}
// The touches stop being a gesture's: a press on the pad, or the panels going away.
// The recogniser forgets its fingers, and a gesture the controller holds ends cancelled.
- (void)cancelGestures {
    [self.globalTrackpad cancel];self.globalGestureContact=NO;
    NSTimeInterval now=CACurrentMediaTime();
    [self.trackpadTimer invalidate];self.trackpadTimer=nil;self.trackpadDeadline=0;self.magnifying=NO;[self.trackpad cancel:now];[self.touchFeed cancel:now];
    if(self.gestureOwner)[self gesture:@{@"op":@"gesture_end",@"cancelled":@YES,@"time_ms":DWGestureTime(now)} owner:self.gestureOwner];
}
@end
