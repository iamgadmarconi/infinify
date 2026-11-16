// SPDX-License-Identifier: GPL-3.0-or-later
// Desktop input taps: the native input tap, its configuration and cancellation, lost input.
// Split from native/desktop/main.m at 37b27b1, moved verbatim.
#import "Desktop+Private.h"
#import "DWPressNativeAdapter.h"
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
    DWNativeInput *input=[[DWNativeInput alloc]initWithConsume:^BOOL(CGEventType type,CGEventRef event){return [weak.pressAdmission consume:type event:event stage:DWPressAnnotated];} earlyConsume:^BOOL(CGEventType type,CGEventRef event){return [weak.pressAdmission consume:type event:event stage:DWPressSession];} ignoreEvent:^BOOL(CGEventRef event){
        int64_t tag=CGEventGetIntegerValueField(event,kCGEventSourceUserData);if(!tag)return NO;
        if([weak.postingTags containsObject:@(tag)])return YES;
        for(LiveSource *source in weak.sources.allValues)if(source.router.tag==tag)return YES;
        return NO;
    } nativeLookup:[DWPressNativeAdapter new] cancelled:^{[weak cancelCapturedInputForWindow:nil];[weak cancelNativeInput];}];
    input.nativeMouseOwnershipChanged=^(CGEventRef event,NSIndexSet *buttons){[weak nativeMouseOwnershipChanged:event buttons:buttons];};
    // INFINIFY_DEBUG: a Dock-control packet that gets as far as this tap was dropped by neither session tap; say so (the line is rate-limited like the others).
    if(DWDebugTrace())input.dockControl=^(CGEventRef event){Desktop *d=weak;char detail[96];snprintf(detail,sizeof detail,"reached the annotated tap undropped; multitouch_delivering=%d dock_tap_running=%d",(int)d.multitouch.delivering,(int)d.dockTap.running);DWDockControlTrace("annotated-tap",event,DWDockControlClassify(event,NULL,NULL),DWDockControlPass,"reached-annotated-tap",detail);};
    if([input start]){self.nativeInput=input;self.nativeInputNoted=NO;return;}
    if(!self.nativeInputNoted){self.nativeInputNoted=YES;[self say:@"Native canvas gestures over windows need existing Accessibility/input access. IPC and gestures on empty canvas remain available."];}
}
- (void)cancelNativeInput { [self.pressAdmission cancelNativeInput]; }
- (BOOL)nativeInput:(CGEventType)type event:(CGEventRef)cg { return [self.pressAdmission consume:type event:cg stage:DWPressAnnotated]; }
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
        if(view.gesture&&view==self.pressAdmission.gestureView&&self.nativeInput.hasEarlyMousePress){
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
    if(covered)[self cancelGestures];else [self gesture:[DWTrackpadGestureEvent end:YES time:DWGestureTime(now)] owner:1];
    [self render];
}
@end
