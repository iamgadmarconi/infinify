// SPDX-License-Identifier: GPL-3.0-or-later
// Desktop input taps: the native input tap, its configuration and cancellation, lost input.
// Split from native/app/Desktop/Desktop+Input.m (0b3f028; native/desktop/main.m at 37b27b1), moved verbatim.
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
#import "DWControllerHit.h"
#import "DWGeometryJSON.h"
// INFINIFY_DEBUG in the environment: one stderr line for each click that goes to a window and each native focus request.
@implementation Desktop (Input)
- (void)configureNativeInput {
    [self configureGlobalTrackpad];[self configureMultitouch];
    // The title session tap must be installed after the global session tap so
    // a later global retry cannot observe its down before title admission.
    if(self.native&&[self globalGesturesEnabled]&&!self.globalTrackpad.running)return;
    if(self.native.ended||self.sessionInactive||!self.panels.count||self.nativeInput)return;
    __weak Desktop *weak=self;
    DWNativeInput *input=[[DWNativeInput alloc]initWithConsume:^BOOL(CGEventType type,CGEventRef event){return [weak nativeInput:type event:event];} earlyConsume:^BOOL(CGEventType type,CGEventRef event){return [weak earlyNativeTitle:type event:event];} ignoreEvent:^BOOL(CGEventRef event){
        int64_t tag=CGEventGetIntegerValueField(event,kCGEventSourceUserData);if(!tag)return NO;
        if([weak.postingTags containsObject:@(tag)])return YES;
        for(LiveSource *source in weak.sources.allValues)if(source.router.tag==tag)return YES;
        return NO;
    } cancelled:^{[weak cancelCapturedInputForWindow:nil];[weak cancelNativeInput];}];
    input.nativeMouseOwnershipChanged=^(CGEventRef event,NSIndexSet *buttons){[weak nativeMouseOwnershipChanged:event buttons:buttons];};
    // INFINIFY_DEBUG: a Dock-control packet that gets as far as this tap was dropped by neither session tap; say so (the line is rate-limited like the others).
    if(DWDebugTrace())input.dockControl=^(CGEventRef event){Desktop *d=weak;char detail[96];snprintf(detail,sizeof detail,"reached the annotated tap undropped; multitouch_delivering=%d dock_tap_running=%d",(int)d.multitouch.delivering,(int)d.dockTap.running);DWDockControlTrace("annotated-tap",event,DWDockControlClassify(event,NULL,NULL),DWDockControlPass,"reached-annotated-tap",detail);};
    if([input start]){self.nativeInput=input;self.nativeInputNoted=NO;return;}
    if(!self.nativeInputNoted){self.nativeInputNoted=YES;[self say:@"Native canvas gestures over windows need existing Accessibility/input access. IPC and gestures on empty canvas remain available."];}
}
- (void)cancelNativeInput {
    [self cancelNativeTitleClick];
    [self.navigation cancelNativeClick];
    [self cancelNativeHoverForWindow:nil];
    self.nativeDecorationPress=nil;
    self.nativeButtonHover=nil;
    DesktopView *view=self.nativeGestureView;self.nativeGestureView=nil;
    if(view.gesture){view.clearsFocus=NO;view.lastDragPan=0;[view released:view.lastPoint at:NSProcessInfo.processInfo.systemUptime];}
    view.nativeTitlePress=nil;
    self.nativeScrollView.scrollPan=nil;self.nativeScrollView.scrollPanTime=0;self.nativeScrollView.lastScrollPan=0;
    self.nativeScrollView=nil;self.nativeScrollTime=0;[self.panLaunch cancel];
    if(self.nativeMagnifyView)[self cancelGestures];self.nativeMagnifyView=nil;self.nativeMagnifySource=nil;
}
- (BOOL)nativeInput:(CGEventType)type event:(CGEventRef)cg {
    int64_t tag=CGEventGetIntegerValueField(cg,kCGEventSourceUserData);
    if(tag&&[self.postingTags containsObject:@(tag)])return NO;
    if(tag)for(LiveSource *source in self.sources.allValues)if(source.router.tag==tag)return NO;
    // Native Fill owns temporary geometry. Consume each refused button's whole
    // pair, including its tail after the handoff ends; never map an intermediate
    // app frame through the controller's already-final camera.
    NSInteger fillButton=CGEventGetIntegerValueField(cg,kCGMouseEventButtonNumber);
    BOOL fillDown=type==kCGEventLeftMouseDown||type==kCGEventRightMouseDown||type==kCGEventOtherMouseDown;
    if(fillDown)[self cancelNativeTitleClick];
    BOOL fillUp=type==kCGEventLeftMouseUp||type==kCGEventRightMouseUp||type==kCGEventOtherMouseUp;
    BOOL fillDrag=type==kCGEventLeftMouseDragged||type==kCGEventRightMouseDragged||type==kCGEventOtherMouseDragged;
    uint64_t fillBit=fillButton>=0&&fillButton<64?UINT64_C(1)<<fillButton:0;
    // A fresh physical down retires a pair whose release was lost, just as
    // DWNativeInput retires its own capture before admitting a new press.
    if(fillDown)self.nativeFillBlockedButtons&=~fillBit;
    if(fillBit&&(self.nativeFillBlockedButtons&fillBit)&&(fillUp||fillDrag)){
        if(fillUp)self.nativeFillBlockedButtons&=~fillBit;return YES;
    }
    NSEvent *fillScroll=type==kCGEventScrollWheel?[NSEvent eventWithCGEvent:cg]:nil;
    BOOL fillScrollPhased=fillScroll.hasPreciseScrollingDeltas&&(fillScroll.phase!=NSEventPhaseNone||fillScroll.momentumPhase!=NSEventPhaseNone);
    BOOL fillScrollBegin=(fillScroll.phase&(NSEventPhaseBegan|NSEventPhaseMayBegin))!=0;
    BOOL fillScrollEnd=((fillScroll.phase|fillScroll.momentumPhase)&NSEventPhaseCancelled)||(fillScroll.momentumPhase&NSEventPhaseEnded);
    if(fillScrollPhased&&fillScrollBegin)self.nativeFillBlockedScroll=NO;
    if(fillScrollPhased&&self.nativeFillBlockedScroll){if(fillScrollEnd)self.nativeFillBlockedScroll=NO;return YES;}
    if(self.nativeFillHandoff&&(fillDown||type==kCGEventScrollWheel)){
        CGWindowID recipient=(CGWindowID)CGEventGetIntegerValueField(cg,kCGMouseEventWindowUnderMousePointerThatCanHandleThisEvent);
        if(!recipient)recipient=(CGWindowID)CGEventGetIntegerValueField(cg,kCGMouseEventWindowUnderMousePointer);
        NSNumber *root=[self.native rootWindowFor:recipient];
        BOOL held=[root isEqual:self.nativeFillHandoff[@"identity"][@"wid"]];
        // Retained background windows are visual coverage only. Their current
        // fullscreen scene has no input site, so consume the complete pair.
        for(NSDictionary *placement in self.nativeFillHandoff[@"background"][@"placements"]){
            LiveSource *live=self.sources[placement[@"window"]];
            if(live&&!live.detached&&[placement[@"output"]isEqual:self.nativeFillHandoff[@"output"]]
                &&boundIdentity(placement[@"source"][@"identity"],live.identity)&&[root isEqual:live.identity[@"wid"]])held=YES;
        }
        for(DesktopView *view in self.views)if((CGWindowID)view.window.windowNumber==recipient)held=YES;
        if(held){if(fillDown)self.nativeFillBlockedButtons|=fillBit;if(fillScrollPhased&&!fillScrollEnd)self.nativeFillBlockedScroll=YES;return YES;}
    }
    if(fillDown||type==kCGEventScrollWheel){
        CGWindowID recipient=(CGWindowID)CGEventGetIntegerValueField(cg,kCGMouseEventWindowUnderMousePointerThatCanHandleThisEvent);
        if(!recipient)recipient=(CGWindowID)CGEventGetIntegerValueField(cg,kCGMouseEventWindowUnderMousePointer);
        NSNumber *root=[self.native rootWindowFor:recipient];
        for(LiveSource *source in self.sources.allValues)if(source.nativeVisibilityHeld&&[root isEqual:source.identity[@"wid"]]){
            if(fillDown)self.nativeFillBlockedButtons|=fillBit;if(fillScrollPhased&&!fillScrollEnd)self.nativeFillBlockedScroll=YES;return YES;
        }
    }
    // A shell-owned decoration/action pair predates any second button that
    // may have reached a captured child. That grab must not consume this up.
    BOOL nativePair=self.nativeGestureView&&!DWNativeTabletEvent(cg)
        &&CGEventGetIntegerValueField(cg,kCGMouseEventButtonNumber)==self.nativeGestureButton
        &&(type==kCGEventLeftMouseDragged||type==kCGEventRightMouseDragged||type==kCGEventOtherMouseDragged
           ||type==kCGEventLeftMouseUp||type==kCGEventRightMouseUp||type==kCGEventOtherMouseUp);
    if(!nativePair&&[self.pointerGrab ownsEvent:cg]){
        NSDictionary *target=self.pointerGrab.target;CGPoint point=CGEventGetLocation(cg);
        [self forwardCapturedPointer:cg screen:point];
        BOOL up=type==kCGEventLeftMouseUp||type==kCGEventRightMouseUp||type==kCGEventOtherMouseUp;
        if(up)for(DesktopView *view in self.views)if(view.pressedPointerGrab&&(!target||sameInputTarget(view.pressedTarget,target))&&view.pressedButton==CGEventGetIntegerValueField(cg,kCGMouseEventButtonNumber)){
            // The adapter owns any other held buttons. End this view's gesture
            // without cancelling those independently paired native presses.
            view.pressedSource=nil;view.pressedTarget=nil;view.pressedPointerGrab=NO;
            [view released:point at:[NSEvent eventWithCGEvent:cg].timestamp];
        }
        return YES;
    }
    if(DWNativeTabletEvent(cg)){
        [self cancelNativeHoverForWindow:nil];
        if(!self.tablet)self.tablet=[DWNativeTabletRouter new];[self.tablet observeEvent:cg];
        if(self.cleaning||self.sessionInactive||self.native.ended){[self.tablet reset];return NO;}
        __weak Desktop *weak=self;
        NSDictionary *retired=[self.tablet retireReplacedToolForEvent:cg validate:^BOOL(NSDictionary *target){return [weak validateInputTarget:target];} post:^BOOL(CGEventRef packet,NSDictionary *target,CGPoint local){return [weak postInput:packet target:target local:local];}];
        NSNumber *device=@(CGEventGetIntegerValueField(cg,DWNativeTabletProximityEvent(cg)?kCGTabletProximityEventDeviceID:kCGTabletEventDeviceID));
        CGPoint point=CGEventGetLocation(cg);
        if(retired)for(DesktopView *view in self.views)if(view.pressedTablet&&[view.pressedTabletDevice isEqual:device]&&sameInputTarget(view.pressedTarget,retired)){
            view.pressedSource=nil;view.pressedTarget=nil;view.pressedTablet=NO;view.pressedTabletDevice=nil;view.clickWindow=nil;
            [view released:point at:[NSEvent eventWithCGEvent:cg].timestamp];
        }
        BOOL owned=[self.tablet ownsEvent:cg];
        NSDictionary *capturedTarget=[self.tablet capturedTargetForEvent:cg];
        BOOL toolOut=DWNativeTabletProximityEvent(cg)&&!CGEventGetIntegerValueField(cg,kCGTabletProximityEventEnterProximity);
        if(owned){
            // Ownership is established by the admitted tool, not today's hit.
            // Overlay and independent native views therefore share the same
            // contact tail even over another source, display or native app.
            [self forwardTabletTail:cg];
            BOOL up=type==kCGEventLeftMouseUp||type==kCGEventRightMouseUp||type==kCGEventOtherMouseUp;
            if(up||toolOut)for(DesktopView *view in self.views)if(view.pressedTablet&&[view.pressedTabletDevice isEqual:device]&&(!capturedTarget||sameInputTarget(view.pressedTarget,capturedTarget))&&(toolOut||view.pressedButton==CGEventGetIntegerValueField(cg,kCGMouseEventButtonNumber))){
                // The router has already paired this release, or closed all
                // buttons on tool-out. Do not synthesize another plain up or
                // cancel additional admitted buttons when the primary lifts.
                view.pressedSource=nil;view.pressedTarget=nil;view.pressedTablet=NO;view.pressedTabletDevice=nil;if(toolOut)view.clickWindow=nil;
                [view released:point at:[NSEvent eventWithCGEvent:cg].timestamp];
            }
            return YES;
        }
        if(toolOut)return NO;
        // Below [zoom] interact_min (default 0.5, DriftWM v0.20.0) a window takes no pointer input, a pen's dedicated packets included
        // (upstream's pointer_focus_under_pick gives a pick target no tablet focus): the pen's mouse-subtype packets are the pick's
        // and its own packets must not reach the application either. Only packets over a pick target are taken; the rest stay as they were.
        if(self.native&&(type==kCGEventTabletPointer||type==kCGEventTabletProximity)){
            CGPoint at=CGEventGetLocation(cg);
            for(DesktopView *view in self.views){NSNumber *output=[view outputAt:at];if(!output)continue;
                if([DWTyped([view hit:at output:output],NSDictionary.class)[@"pick"]isEqual:@YES])return YES;
                break;}
        }
        if(type==kCGEventTabletPointer||type==kCGEventTabletProximity){
            // The overlay's fresh packets still go through AppKit's normal
            // canvas admission. Observing proximity above does not authorize
            // intercepting a pen which is drawing in an unrelated native app.
            if(!self.native)return NO;
            // Dedicated tablet packets may omit mouse-only annotations. Fresh
            // admission still belongs to the actual canvas panel under the pen,
            // never a logical replica covered by another application.
            CGWindowID recipient=(CGWindowID)[NSWindow windowNumberAtPoint:NSMakePoint(point.x,screenTop()-point.y) belowWindowWithWindowNumber:0];
            for(DesktopView *view in self.views){NSNumber *output=[view outputAt:point];if(!output)continue;NSDictionary *hit=[view hit:point output:output];LiveSource *source=self.sources[hit[@"window"]];
                if(recipient!=(CGWindowID)view.window.windowNumber)return NO;
                if(!source||![self.nativeViews replica:source.logical output:output])return NO;
                BOOL old=view.nativePointValid;CGPoint previous=view.nativePoint;view.nativePointValid=YES;view.nativePoint=point;
                BOOL sent=NO;@try{sent=[view forward:cg at:point output:output];}@finally{view.nativePointValid=old;view.nativePoint=previous;}return sent;
            }
            return NO;
        }
    }
    if(type!=kCGEventMouseMoved&&type!=kCGEventScrollWheel&&type!=kCGEventLeftMouseDown&&type!=kCGEventLeftMouseDragged&&type!=kCGEventLeftMouseUp
        &&type!=kCGEventRightMouseDown&&type!=kCGEventRightMouseDragged&&type!=kCGEventRightMouseUp&&type!=kCGEventOtherMouseDown&&type!=kCGEventOtherMouseDragged&&type!=kCGEventOtherMouseUp){
        NSEvent *event=[NSEvent eventWithCGEvent:cg];if(!self.native||event.type!=NSEventTypeMagnify||self.globalTrackpad.running)return NO;
        BOOL over=(event.phase&(NSEventPhaseEnded|NSEventPhaseCancelled))!=0;
        if(event.phase&NSEventPhaseMayBegin)return NO;
        if(self.cleaning||self.sessionInactive||self.native.ended){if(self.nativeMagnifyView)[self cancelNativeInput];return NO;}
        // Magnify is not a CG mouse event: its mouse-specific window/location
        // fields need not be populated. Resolve the real pointer recipient.
        CGPoint point=pointer();DesktopView *view=self.nativeMagnifyView;LiveSource *source=self.nativeMagnifySource;
        if(view&&(source.detached||self.sources[source.logical]!=source||!DWInScope(self.scope,source.router.pid)||![self.views containsObject:view])){[self cancelNativeInput];return NO;}
        if(!view){
            if(over||self.gestureOwner||self.magnifying||NSEvent.pressedMouseButtons)return NO;
            CGWindowID wid=(CGWindowID)[NSWindow windowNumberAtPoint:NSMakePoint(point.x,screenTop()-point.y) belowWindowWithWindowNumber:0];
            source=[self nativeSource:wid at:point];if(!source)return NO;
            for(DesktopView *candidate in self.views)if([candidate outputAt:point]){view=candidate;break;}
            if(!view)return NO;self.nativePinchAccepted=NO;
            [self deliverNative:event type:type view:view at:point];
            if(!self.nativePinchAccepted){[self cancelGestures];return NO;}
            if(!over&&event.phase!=NSEventPhaseNone){self.nativeMagnifyView=view;self.nativeMagnifySource=source;}
            return YES;
        }
        [self deliverNative:event type:type view:view at:point];
        if(over||event.phase==NSEventPhaseNone){self.nativeMagnifyView=nil;self.nativeMagnifySource=nil;}
        return YES;
    }
    if(type==kCGEventMouseMoved){
        CFTimeInterval now=CACurrentMediaTime();if(self.cleaning||self.sessionInactive||self.native.ended)return NO;
        [self queueNativeHover:cg];
        CGWindowID wid=(CGWindowID)CGEventGetIntegerValueField(cg,kCGMouseEventWindowUnderMousePointerThatCanHandleThisEvent);
        if(!wid)wid=(CGWindowID)CGEventGetIntegerValueField(cg,kCGMouseEventWindowUnderMousePointer);
        if(!wid)wid=(CGWindowID)[NSWindow windowNumberAtPoint:NSMakePoint(CGEventGetLocation(cg).x,screenTop()-CGEventGetLocation(cg).y) belowWindowWithWindowNumber:0];
        NSNumber *root=[self.native rootWindowFor:wid];CGPoint point=CGEventGetLocation(cg);
        if(root){NSEvent *motion=[NSEvent eventWithCGEvent:cg];if(motion)for(DesktopView *view in self.views)if([view outputAt:point]){[view.hover nativeMotion:motion];break;}}
        // Below [zoom] interact_min a window takes no pointer input, hover included (docs/crates/desktop/POINTER.md): the canvas has had this motion above, so
        // its own hover, sloppy focus and edge pan go on, and the packet goes no further. The window server has already moved the cursor.
        if(root&&[self pickMotionAt:point window:root])return YES;
        if(now-self.nativeButtonMotion<.1)return NO;self.nativeButtonMotion=now;self.nativeButtonHover=nil;
        for(LiveSource *source in self.sources.allValues)if(!source.detached&&source.router.wid==root.unsignedIntValue){self.nativeButtonHover=source.logical;[self refreshNativeButtons:source];break;}
        if(!self.nativeButtonHover)for(DesktopView *view in self.views)if((CGWindowID)view.window.windowNumber==wid){
            NSNumber *output=[view outputAt:point];NSDictionary *hit=output?[view hit:point output:output]:nil;
            LiveSource *source=self.sources[hit[@"window"]];
            if(source&&!hit[@"native_member"]&&!source.detached&&(!self.native||[self.nativeViews replica:source.logical output:output])){self.nativeButtonHover=source.logical;[self refreshNativeButtons:source];}break;
        }
        return NO;
    }
    BOOL down=type==kCGEventLeftMouseDown||type==kCGEventRightMouseDown||type==kCGEventOtherMouseDown;
    BOOL up=type==kCGEventLeftMouseUp||type==kCGEventRightMouseUp||type==kCGEventOtherMouseUp;
    BOOL drag=type==kCGEventLeftMouseDragged||type==kCGEventRightMouseDragged||type==kCGEventOtherMouseDragged;
    CGPoint point=CGEventGetLocation(cg);NSEvent *event=[NSEvent eventWithCGEvent:cg];if(!event)return NO;
    NSInteger button=CGEventGetIntegerValueField(cg,kCGMouseEventButtonNumber);
    DesktopView *captured=self.nativeGestureView;
    if(down&&captured&&button==self.nativeGestureButton){[self cancelNativeInput];captured=nil;}
    if(captured&&(drag||up)&&button==self.nativeGestureButton){
        if(captured.nativeTitlePress&&![captured nativeTitlePressCurrent]){[self cancelNativeInput];return YES;}
        NSDictionary *press=self.nativeDecorationPress;
        if(press){
            CGPoint started=jsonPoint(press[@"start"]);if(drag&&hypot(point.x-started.x,point.y-started.y)>5)self.nativeDecorationPress=nil;
            if(up){self.nativeDecorationPress=nil;LiveSource *source=self.sources[press[@"window"]];
                BOOL green=[press[@"title"]boolValue]?DWNativeWindowDragHit(source.identity,source.nativeButtons,point):[press[@"replica"]boolValue]?[self replicaGreen:source at:point output:press[@"output"]]:[self nativeGreen:source at:point];
                if([press[@"replica"]boolValue]){
                    NSDictionary *hit=[captured hit:point output:press[@"output"]];
                    CGWindowID top=(CGWindowID)[NSWindow windowNumberAtPoint:NSMakePoint(point.x,screenTop()-point.y) belowWindowWithWindowNumber:0];
                    green&=top==(CGWindowID)captured.window.windowNumber&&[hit[@"window"]isEqual:press[@"window"]]&&!hit[@"native_member"];
                }
                if(!self.cleaning&&!self.sessionInactive&&!self.native.ended&&source&&!source.detached&&[self.views containsObject:captured]&&[captured.outputs containsObject:press[@"output"]]&&boundIdentity(source.identity,press[@"identity"])&&green){
                    NSMutableDictionary *command=[press mutableCopy];[command removeObjectForKey:@"start"];[command removeObjectForKey:@"replica"];[command removeObjectForKey:@"title"];command[@"op"]=@"native_decoration";[self applyReply:[self call:command]];
                }
            }
        }
        if(!self.cleaning&&!self.native.ended&&[self.views containsObject:captured]){
            // An action or a refused grab still owns its button pair, even if it
            // started no drag. Never let its release become an app's lone mouse-up.
            if(captured.gesture)[self deliverNative:event type:type view:captured at:point];
        }else if(captured.gesture){captured.clearsFocus=NO;captured.lastDragPan=0;[captured released:captured.lastPoint at:event.timestamp];}
        if(up){captured.nativeTitlePress=nil;self.nativeGestureView=nil;}
        return YES;
    }
    if(self.cleaning||self.sessionInactive||self.native.ended||(!down&&type!=kCGEventScrollWheel))return NO;
    // Overlay gestures and scrolling stay in AppKit. This tap additionally
    // claims only a positively identified green control and its button pair.
    if(!self.native&&!down)return NO;
    if(type==kCGEventScrollWheel&&self.nativeScrollView){
        BOOL begin=(event.phase&(NSEventPhaseBegan|NSEventPhaseMayBegin))!=0;
        BOOL tail=event.momentumPhase!=NSEventPhaseNone;
        if(!begin&&(tail||event.timestamp-self.nativeScrollTime<.35)&&[self.views containsObject:self.nativeScrollView]){
            DesktopView *view=self.nativeScrollView;self.nativeScrollTime=event.timestamp;
            [self deliverNative:event type:type view:view at:point];
            if(((event.phase|event.momentumPhase)&NSEventPhaseCancelled)||(event.momentumPhase&NSEventPhaseEnded))self.nativeScrollView=nil;
            return YES;
        }
        self.nativeScrollView=nil;
    }
    CGWindowID wid=(CGWindowID)CGEventGetIntegerValueField(cg,kCGMouseEventWindowUnderMousePointerThatCanHandleThisEvent);
    if(!wid)wid=(CGWindowID)CGEventGetIntegerValueField(cg,kCGMouseEventWindowUnderMousePointer);
    if(!wid)wid=(CGWindowID)[NSWindow windowNumberAtPoint:NSMakePoint(point.x,screenTop()-point.y) belowWindowWithWindowNumber:0];
    LiveSource *source=[self nativeSource:wid at:point];BOOL replica=NO;
    if(!source)for(DesktopView *view in self.views)if((CGWindowID)view.window.windowNumber==wid){
        NSNumber *output=[view outputAt:point];NSDictionary *hit=output?[view hit:point output:output]:nil;LiveSource *candidate=self.sources[hit[@"window"]];
        BOOL covered=self.native&&down&&[self.nativeViews requiresPlacementAdmissionForWindow:candidate.logical];
        if(candidate&&(covered||!self.native||[self.nativeViews replica:candidate.logical output:output])
            &&(covered||(candidate.pixels&&!candidate.error))&&!candidate.detached){source=candidate;replica=YES;break;}
    }
    if(!source)return DWNativeTitleRefused(self.routingEarlyNativeTitle,"native_source",nil,wid,point,nil);
    // The session-stage copy may only install a title grab. Coverage refusal
    // and ordinary input policies remain at the annotated destination tap.
    if(self.routingEarlyNativeTitle){
        if(replica)return DWNativeTitleRefused(YES,"replica",source.logical,wid,point,nil);
        if(wid!=source.router.wid)return DWNativeTitleRefused(YES,"child",source.logical,wid,point,@{@"root_wid":@(source.router.wid)});
        if([self.nativeViews requiresPlacementAdmissionForWindow:source.logical])return DWNativeTitleRefused(YES,"placement_coverage",source.logical,wid,point,nil);
    }
    if(self.native&&down&&[self.nativeViews requiresPlacementAdmissionForWindow:source.logical]){
        // Even a cancelled transfer with no eligible recovery token still has
        // coverage. Its physically addressed root/member must get no down.
        pid_t expected=replica?getpid():source.router.pid;
        BOOL addressedCanvas=replica&&CGEventGetIntegerValueField(cg,kCGMouseEventWindowUnderMousePointerThatCanHandleThisEvent)==wid
            &&CGEventGetIntegerValueField(cg,kCGEventTargetUnixProcessID)==getpid();
        // Refusing an already addressed canvas packet grants no input. A later
        // hit mismatch must not send this down into its captured forwarder.
        if(!addressedCanvas){NSDictionary *recipient=DWNativeEventRecipientAtPoint(point);
            if(recipient){
                if([recipient[@"wid"]unsignedIntValue]!=wid||[recipient[@"pid"]intValue]!=expected
                    ||(!replica&&(![recipient[@"birth_sec"]isEqual:source.identity[@"birth_sec"]]
                        ||![recipient[@"birth_usec"]isEqual:source.identity[@"birth_usec"]])))return NO;
            }else if(CGEventGetIntegerValueField(cg,kCGMouseEventWindowUnderMousePointerThatCanHandleThisEvent)!=wid
                ||CGEventGetIntegerValueField(cg,kCGEventTargetUnixProcessID)!=expected)return NO;
        }
        [self cancelNativeHoverForWindow:source.logical];return YES;
    }
    if(self.native&&down&&!replica){
        DWNativeAppliedPlacement *placement=[self.nativeViews admittedPlacementForWindow:source.logical];
        if(placement){DWNativeViewTransfer *transfer=[self.nativeViews currentTransferForWindow:source.logical];
            NSDictionary *recipient=DWNativeEventRecipientAtPoint(point),*identity=nil;
            for(NSDictionary *member in placement.members)if([member[@"identity"][@"wid"]unsignedIntValue]==wid){identity=member[@"identity"];break;}
            const char *refused=NULL;
            if([recipient[@"wid"]unsignedIntValue]!=wid||!boundIdentity(recipient,identity))refused="placement_recipient";
            else if(![self.nativeViews isAdmissionCurrentForTransfer:transfer placement:placement])refused="placement_admission_before";
            else if(!DWNativeValidateAppliedPlacementInput(self.native,placement,recipient,point,NULL))refused="placement_input";
            else if(![self.nativeViews isAdmissionCurrentForTransfer:transfer placement:placement])refused="placement_admission_after";
            if(refused){DWNativeTitleRefused(self.routingEarlyNativeTitle,refused,source.logical,wid,point,@{@"recipient_wid":recipient[@"wid"]?:NSNull.null,@"recipient_pid":recipient[@"pid"]?:NSNull.null});return !self.routingEarlyNativeTitle;}
        }
    }
    for(DesktopView *view in self.views){
        if(!CGRectContainsPoint(view.globalBounds,point))continue;
        NSNumber *output=[view outputAt:point];if(!output)return DWNativeTitleRefused(self.routingEarlyNativeTitle,"output",source.logical,wid,point,nil);
        NSDictionary *hit=DWTyped([view hit:point output:output],NSDictionary.class),*familyHit=nil;
        if(!replica&&wid!=source.router.wid){
            NSDictionary *snapshot=[self call:@{@"op":@"snapshot"}];
            for(NSDictionary *placement in snapshot[@"placements"])if([placement[@"window"]isEqual:source.logical]&&[placement[@"output"]isEqual:output]){
                NSMutableDictionary *context=[@{@"window":source.logical}mutableCopy];for(NSString *flag in @[@"widget",@"pinned"])if([placement[flag]boolValue])context[flag]=@YES;
                familyHit=DWPickHit(context,snapshot,output);hit=familyHit;break;
            }
        }
        if(![hit[@"window"]isEqual:source.logical])return DWNativeTitleRefused(self.routingEarlyNativeTitle,"controller_hit",source.logical,wid,point,@{@"output":output,@"hit_window":hit[@"window"]?:NSNull.null,@"hit_present":@(hit!=nil)});
        BOOL pick=[hit[@"pick"]isEqual:@YES],claimed=pick;
        if(down){
            if(captured||view.gesture)return DWNativeTitleRefused(self.routingEarlyNativeTitle,"existing_gesture",source.logical,wid,point,@{@"captured":@(captured!=nil),@"view_gesture":@(view.gesture)});
            NSArray *triggers=@[@"left",@"right",@"middle",@"back",@"forward"];
            NSDictionary *binding=button>=0&&button<(NSInteger)triggers.count?[self mouseBinding:triggers[button] source:nil flags:event.modifierFlags window:YES under:source.logical pick:pick]:nil;
            if(self.routingEarlyNativeTitle){
                const char *refused=NULL;
                if(pick)refused="pick";else if(replica)refused="replica";else if(binding)refused="binding";
                else if([hit[@"widget"]boolValue])refused="widget";else if(hit[@"native_member"])refused="native_member";
                else if([view resizeBorderForButton:button flags:event.modifierFlags hit:hit at:point output:output])refused="resize_border";
                if(refused)return DWNativeTitleRefused(YES,refused,source.logical,wid,point,@{@"output":output,@"binding_kind":binding[@"kind"]?:NSNull.null});
            }
            if(replica&&[self queuedNativeHoverPress:event source:source hit:hit view:view output:output at:point]){
                [self cancelNativeHoverForWindow:source.logical];return YES;
            }
            NSEventModifierFlags extra=event.modifierFlags&(NSEventModifierFlagCommand|NSEventModifierFlagControl|NSEventModifierFlagShift);
            if(!self.routingEarlyNativeTitle&&button==0&&!extra&&!pick&&!hit[@"native_member"]&&![hit[@"widget"]boolValue]&&(replica?[self replicaGreen:source at:point output:output]:(wid==source.router.wid&&[self nativeGreen:source at:point]))){
                NSDictionary *snapshot=[self call:@{@"op":@"snapshot"}];
                for(NSDictionary *window in snapshot[@"windows"])if([window[@"window"]isEqual:source.logical]){NSDictionary *binding=DWTyped(window[@"source"],NSDictionary.class);
                    if(!boundIdentity(source.identity,binding[@"identity"]))return NO;
                    self.nativeDecorationPress=@{@"window":source.logical,@"output":output,@"identity":binding[@"identity"],@"generation":binding[@"generation"],@"action":(event.modifierFlags&NSEventModifierFlagOption)?@"fit":@"fullscreen",@"start":pointJSON(point),@"replica":@(replica)};
                    self.nativeGestureView=view;self.nativeGestureButton=button;return YES;
                }
            }
            if(!self.routingEarlyNativeTitle)[self refreshNativeButtons:source];
            if(replica)return NO; // Canvas view owns ordinary replica input and bound gestures.
            NSString *kind=DWTyped(binding[@"kind"],NSString.class);
            claimed|=[@[@"pan_viewport",@"move_window",@"move_snapped_windows",@"resize_window",@"resize_window_snapped",@"center_nearest",@"action"]containsObject:kind?:@""];
            if([hit[@"widget"]boolValue]&&([kind hasPrefix:@"move_"]||[kind hasPrefix:@"resize_"]))claimed=NO;
            // AppKit's own resize uses unscaled native coordinates. A transformed
            // root's normal edge press must enter the same pointer-anchored
            // transaction as the canvas, before the app owns its button pair.
            // Family members keep their independent native controls and drags.
            if(!self.routingEarlyNativeTitle&&wid==source.router.wid&&[view resizeBorderForButton:button flags:event.modifierFlags hit:hit at:point output:output])claimed=YES;
            // No late title fallback: annotation follows native chrome tracking.
            BOOL titleCandidate=self.routingEarlyNativeTitle&&!claimed&&!binding&&button==0&&!replica&&wid==source.router.wid&&!pick
                &&![hit[@"widget"]boolValue]&&!hit[@"native_member"]
                &&!(event.modifierFlags&(NSEventModifierFlagCommand|NSEventModifierFlagControl|NSEventModifierFlagOption|NSEventModifierFlagShift));
            BOOL titleHit=titleCandidate&&DWNativeWindowDragHit(source.identity,source.nativeButtons,point);
            if(DWDebugTrace()&&titleCandidate)fprintf(stderr,"debug: native title window=#%s cached=%d age_ms=%.1f region=%d hit=%d reason=%s\n",source.logical.description.UTF8String,source.nativeButtons!=nil,source.nativeButtons?(CACurrentMediaTime()-[source.nativeButtons[@"sampled_at"]doubleValue])*1000:-1,DWTyped(source.nativeButtons[@"title"][@"region"],NSDictionary.class)!=nil,titleHit,((NSString *)DWTyped(source.nativeButtons[@"title_reason"],NSString.class)).UTF8String?:"no_current_report");
            if(titleHit){
                NSDictionary *snapshot=[self call:@{@"op":@"snapshot"}],*current=nil;
                for(NSDictionary *window in snapshot[@"windows"])if([window[@"window"]isEqual:source.logical]){current=DWTyped(window[@"source"],NSDictionary.class);break;}
                // A recognized region is never given back as half an AppKit
                // drag, including a binding which changed before installation.
                self.nativeGestureView=view;self.nativeGestureButton=button;
                if(!boundIdentity(source.identity,current[@"identity"])||!current[@"generation"]
                    ||![[self.nativeViews desiredOwnerForWindow:source.logical]isEqual:output])return YES;
                if(event.clickCount==2){
                    self.nativeDecorationPress=@{@"window":source.logical,@"output":output,@"identity":current[@"identity"],@"generation":current[@"generation"],@"action":@"fullscreen",@"start":pointJSON(point),@"replica":@NO,@"title":@YES};
                    return YES;
                }
                view.nativeTitlePress=@{@"window":source.logical,@"output":output,@"identity":current[@"identity"],@"generation":current[@"generation"]};
                view.nativeTitleMoved=view.nativeTitleReleased=NO;
                claimed=YES;
            }
            if(!claimed)return NO;
            self.nativeGestureView=view;self.nativeGestureButton=button;
        }else{
            NSDictionary *binding=[self mouseBinding:@"scroll" source:event.hasPreciseScrollingDeltas?@"finger":@"wheel" flags:event.modifierFlags window:YES under:source.logical pick:pick];
            NSString *kind=DWTyped(binding[@"kind"],NSString.class);claimed|=[kind isEqual:@"pan_viewport"]||[kind isEqual:@"zoom"];
            if(!event.hasPreciseScrollingDeltas){
                int64_t lines=CGEventGetIntegerValueField(cg,kCGScrollWheelEventDeltaAxis1);
                if(!lines&&(event.modifierFlags&NSEventModifierFlagShift))lines=CGEventGetIntegerValueField(cg,kCGScrollWheelEventDeltaAxis2);
                if(lines)claimed|=[DWTyped([self mouseBinding:lines>0?@"wheel_up":@"wheel_down" source:nil flags:event.modifierFlags window:YES under:source.logical pick:pick][@"kind"],NSString.class)isEqual:@"action"];
            }
            if(!claimed)return NO;
            if(event.hasPreciseScrollingDeltas&&event.phase!=NSEventPhaseNone){self.nativeScrollView=view;self.nativeScrollTime=event.timestamp;}
        }
        [self deliverNative:event type:type view:view at:point familyHit:familyHit];return YES;
    }
    return DWNativeTitleRefused(self.routingEarlyNativeTitle,"view_bounds",source.logical,wid,point,nil);
}
// macOS platform rule: input whose end never arrived. Upstream's grabs end with their release and libinput ends every gesture it begins; here an end
// can be lost, and what it would have ended is then held for good: the controller refuses every flight while it holds a drag, and a window move resting
// in navigation.edge_pan's zone goes on being carried by the pan beneath it, a frame's worth every frame, without bound. Every frame of the frame timer
// and every poll of a normal run therefore look, and what they find lost ends through the path its own end takes:
// - a press whose release never reached its view (the button came up over another application, inside a menu or a drag session of macOS, or while
//   the panels were being rebuilt): macOS says which buttons are down, and a gesture whose own button has been up for 50 ms, with no release of
//   it waiting in the event queue, is released at the pointer (-[DesktopView released:at:]). The queue is asked because the 50 ms are wall time:
//   a poll that takes as long leaves a real release queued behind this reading, and that release ends its press itself, at its own point and time;
// - a trackpad gesture of the recogniser's whose touches stopped coming without an end or a cancel. Touches go to the view under the pointer, so once
//   the gesture's output is no longer what a press there would reach (Mission Control, another window, a menu over the canvas) its touches are not
//   this panel's any more, and the gesture ends cancelled as a touch macOS cancels does (-cancelGestures). And a move gesture, the one that holds a
//   drag, whose fingers have sent nothing at all for thirty seconds is taken for lost. Still fingers send no touches either and nothing tells the
//   two apart, so thirty seconds is also the longest a move can rest in the edge zone without the least movement of a finger, and only the
//   controller's gesture is ended then: the recogniser keeps its fingers and its swipe, whose later updates and end find no owner (-gesture:owner:),
//   so fingers that were only resting cannot begin another gesture until they lift.
- (void)endLostInput {
    if(self.cleaning||self.askingQueue)return;
    [self.nativeInput cancelIdleEarlyMousePress];
    NSUInteger down=NSEvent.pressedMouseButtons;CFTimeInterval now=CACurrentMediaTime();
    for(DesktopView *view in self.views.copy){
        // A chrome down swallowed before session annotation never enters
        // AppKit's combined button state or its release queue. Its tap owns the
        // pair and bounds silent lost input above, retaining cancelled tails.
        if(view.gesture&&view==self.nativeGestureView&&self.nativeInput.hasEarlyMousePress){
            view.liftSeen=0;continue;
        }
        // A taken-over native drag ended the application's own press with a posted release, so the system says the button is up while
        // the finger is down. The tap still owns that physical pair until its release, which ends the gesture; ten minutes bound a lost one.
        if(view.gesture&&view.takenOverAt&&now-view.takenOverAt<600&&[self.nativeInput holdsCapturedButton:(NSUInteger)view.gestureButton]){view.liftSeen=0;continue;}
        // A press the DebugPointer request made has no button behind it: its own request or its timer ends it.
        if(!view.gesture||view.injected||(down&(1UL<<view.gestureButton))){view.liftSeen=0;continue;}
        if(!view.liftSeen){view.liftSeen=now;continue;}
        if(now-view.liftSeen<.05)continue;
        // Looked at, not taken: the release stays for its own turn. The look is a turn of the run loop, in which a frame or a timer may run: a frame
        // that does asks nothing itself (askingQueue), and the press is read again once the look is over.
        NSEventMask up=view.gestureButton==0?NSEventMaskLeftMouseUp:view.gestureButton==1?NSEventMaskRightMouseUp:NSEventMaskOtherMouseUp;
        self.askingQueue=YES;NSEvent *queued=[NSApp nextEventMatchingMask:up untilDate:[NSDate distantPast] inMode:NSDefaultRunLoopMode dequeue:NO];self.askingQueue=NO;
        if(queued||!view.gesture||self.cleaning||![self.views containsObject:view])continue;
        fprintf(stderr,"A button release never arrived: the press it belonged to is ended here.\n");
        [view released:pointer() at:NSProcessInfo.processInfo.systemUptime];[self render];
    }
    if(self.gestureOwner!=1)return;
    BOOL covered=self.gestureWatched&&![[self outputUnderPointer:pointer()]isEqual:self.gestureOutput],silent=self.gestureMove&&now-self.lastTouches>30;
    if(!covered&&!silent)return;
    fprintf(stderr,"A trackpad gesture lost its touches (%s): ended cancelled.\n",covered?"the canvas is no longer under the pointer":"none for thirty seconds during a window move or resize");
    if(covered)[self cancelGestures];else [self gesture:@{@"op":@"gesture_end",@"cancelled":@YES,@"time_ms":DWGestureTime(now)} owner:1];
    [self render];
}
@end
