// SPDX-License-Identifier: GPL-3.0-or-later
// Split from native/desktop/main.m at 37b27b1, moved verbatim.
// DesktopView scroll, wheel zoom, magnify and touch handling: a normal run's pan, timed, and the trackpad and wheel events.
#import "DesktopView.h"
#import "Desktop+Private.h"
#import <signal.h>
#import "DWControllerHit.h"
#import "DWDebugTrace.h"
#import "DWWindowEvents.h"
#import "DWNativeFamily.h"
#import "DWGeometryJSON.h"
// An input event's time as upstream's libinput timestamp: milliseconds, wrapping at 32 bits.
static NSNumber *eventMillis(NSEvent *e) { return @((uint32_t)(uint64_t)(e.timestamp*1000)); }
@implementation DesktopView (Scroll)
// A normal run's pan, timed: the controller scales it by the config speed of its source
// (navigation.trackpad_speed for a scroll, navigation.mouse_speed for a drag), clears the
// output's flight as every pan does, and tracks its velocity for the coast that follows.
- (void)pan:(CGPoint)delta output:(NSNumber *)output event:(NSEvent *)e source:(NSString *)source {
    [self.desktop call:@{@"op":@"pan",@"output":output,@"screen_delta":pointJSON(delta),@"time_ms":eventMillis(e),@"source":source}];
}
// A normal run's wheel zoom: zoom.step, zoom.mouse_speed and the zoom limits are the
// controller's, as upstream's. delta is upstream's vertical axis amount (positive scrolls
// down and zooms out). A wheel zoom is a flight that later notches extend, so no flight is
// cancelled first. A pinch is not sent here: it is a gesture, see -magnifyWithEvent:.
- (void)wheelZoom:(double)delta at:(CGPoint)p output:(NSNumber *)output {
    // A held window move or resize owns the pointer; drop its zoom input quietly.
    if(!isfinite(delta)||!delta||self.gesture==2||self.gesture==4)return;
    NSDictionary *reply=[self.desktop call:@{@"op":@"zoom_by",@"output":output,@"anchor":pointJSON(p),@"delta":@(delta),@"source":@"wheel"}];BOOL frames=[reply[@"needs_frames"]boolValue];
    // A zoom the limit swallows is no input for a focus request in flight either.
    if(DWTyped(reply[@"navigation"],NSDictionary.class))[self.desktop.navigation interrupt];
    [self.desktop render];if(frames)[self.desktop ensureFrames];self.desktop.sceneDirty=YES;
}
// A normal run's scroll, dispatched as upstream's on_pointer_axis does: a bound scroll
// pans or zooms the canvas and never reaches a window, an unbound one goes to the
// native window under it. A pan or zoom ends its output's flight in the controller, which
// keeps the pan's velocity for the coast; the shell only withdraws a native focus request
// still in flight, as for any unrelated input. An open cycle whose selection has settled
// stays open until its modifiers are let go, as upstream's does.
- (void)scroll:(NSEvent *)e {
    BOOL coast=e.momentumPhase!=NSEventPhaseNone,lifted=(e.phase&(NSEventPhaseEnded|NSEventPhaseCancelled))!=0;
    // Upstream: an axis event on top of a held modifier chord makes it a binding prefix, not a tap. libinput has no momentum of its own, so macOS's is none.
    if(!coast)[self.desktop.tapKeys taint];
    // Upstream computes momentum itself from the finger's deltas. Once a trackpad scroll has
    // panned the canvas its lift launches the coast, and the momentum events macOS adds
    // after it are dropped whole, wherever the pointer is by then. A lift that follows a
    // rest comes after the 50 ms delay has launched, and upstream's stop then launches the
    // emptied tracker: what was left of the coast ends. The second launch here is that one.
    // Under a held drag pan neither is sent: see where the scroll pans.
    if(self.scrollPan&&(coast||lifted)){
        if(lifted){[self.desktop.panLaunch end];if(self.scrollPanTime&&e.timestamp-self.scrollPanTime>=.05&&!(self.gesture==1&&[self.scrollPan isEqual:self.dragOutput]))[self.desktop panEnd:self.scrollPan];}
        else if(e.momentumPhase&(NSEventPhaseEnded|NSEventPhaseCancelled))self.scrollPan=nil;
        return;
    }
    if(e.phase&(NSEventPhaseBegan|NSEventPhaseMayBegin))self.scrollPan=nil;
    CGPoint p=[self screenPoint:e];NSNumber *output=[self outputAt:p];if(!output)return;
    self.lastOutput=output;BOOL precise=e.hasPreciseScrollingDeltas;NSString *source=precise?@"finger":@"wheel";
    // A swipe or pinch of three or more fingers is the recogniser's: a scroll macOS makes of the same fingers pans nothing.
    if(precise&&[self.desktop padBusy:e])return;
    // Upstream keeps a finger pan on the canvas for 150 ms, so a window sliding under the pointer cannot take the gesture.
    BOOL panning=self.lastScrollPan&&CACurrentMediaTime()-self.lastScrollPan<.15;NSDictionary *here=precise&&panning?nil:DWTyped([self hit:p output:output],NSDictionary.class);
    // Upstream's wheel-notch site (on_pointer_axis), ahead of the continuous lookup and for a wheel only: a finger has no notches. Its
    // context is the pointer's own, without the 150 ms canvas lock below. A notch bound to an action runs it once per notch, ten at most
    // for one event, and the event is consumed: it reaches no window and neither pans nor zooms. Any other answer (no notch binding, one
    // that is no action, one the window under the pointer claims by pass_mouse, which the lookup returns as none) leaves the event to the
    // continuous lookup, as upstream falls through. A wheel line is a notch here, as it is for the zoom: macOS reports whole lines.
    // While Shift is held AppKit hands a wheel's vertical lines over as horizontal ones (axis 1 is 0, axis 2 has them, sign kept), where
    // upstream's wheel stays vertical under any modifier: the notch is read back from axis 2 then, so a shift-qualified notch binding and
    // its claim are asked. A sideways wheel turned under Shift arrives as the same event and counts as a notch too, which upstream's does not.
    if(!precise&&e.CGEvent){
        int64_t lines=CGEventGetIntegerValueField(e.CGEvent,kCGScrollWheelEventDeltaAxis1);
        if(!lines&&(e.modifierFlags&NSEventModifierFlagShift))lines=CGEventGetIntegerValueField(e.CGEvent,kCGScrollWheelEventDeltaAxis2);
        if(lines){
            NSDictionary *notch=[self.desktop mouseBinding:lines>0?@"wheel_up":@"wheel_down" source:nil flags:e.modifierFlags window:here!=nil under:liveHit(here) pick:[here[@"pick"]isEqual:@YES]];NSString *run=[DWTyped(notch[@"kind"],NSString.class)isEqual:@"action"]?DWTyped(notch[@"action"],NSString.class):nil;
            if(run){int64_t notches=MIN(llabs(lines),10);BOOL held=[DWCycleHold modifiersDown]!=0;for(int64_t i=0;i<notches;i++)[self.desktop action:run output:output at:p held:held];return;}
        }
    }
    NSDictionary *under=panning?nil:here;BOOL window=under!=nil,pick=[under[@"pick"]isEqual:@YES];
    NSDictionary *binding=[self.desktop mouseBinding:@"scroll" source:source flags:e.modifierFlags window:window under:liveHit(under) pick:pick];NSString *kind=DWTyped(binding[@"kind"],NSString.class);
    // Upstream on_pointer_axis below [zoom] interact_min: the controller looks a scroll that finds no binding over a
    // pick target up again as one on empty canvas, so that it pans or zooms through the same paths as any bound
    // scroll, coast and all; with none there either it goes nowhere. It is never the application's: not its
    // end, and not macOS's inertia after it. A pick target claims no scroll either: pass_mouse is off for it.
    if(!binding&&pick)return;
    // A window that takes over a trackpad scroll which panned first takes the rest of it: its end and macOS's inertia are forwarded too.
    if(!binding){if(window){if(e.phase!=NSEventPhaseNone){self.scrollPan=nil;self.scrollPanTime=0;}CGEventRef cg=CGEventCreateCopy(e.CGEvent);[self forward:cg at:p output:output];CFRelease(cg);}return;}
    // Upstream's axis amounts: positive scrolls right and down, finger points as they are, one wheel line as one notch of 15.
    double h=-e.scrollingDeltaX,v=-e.scrollingDeltaY;
    if(!precise&&e.CGEvent){h=-15.0*CGEventGetIntegerValueField(e.CGEvent,kCGScrollWheelEventDeltaAxis2);v=-15.0*CGEventGetIntegerValueField(e.CGEvent,kCGScrollWheelEventDeltaAxis1);}
    if([kind isEqual:@"zoom"])[self wheelZoom:v at:p output:output];
    // A momentum event of macOS never pans the canvas: not the tail of a scroll that began in a window either.
    else if([kind isEqual:@"pan_viewport"]&&!coast&&(h||v)){
        if(precise)self.lastScrollPan=CACurrentMediaTime();
        if(e.phase!=NSEventPhaseNone){self.scrollPan=output;self.scrollPanTime=e.timestamp;}
        // A scroll under a held drag pan launches nothing of its own: upstream's pan grab holds the coast
        // until its release, so the pan counts as the drag's last and the release's pan_end is the launch.
        [self.desktop.navigation interrupt];[self pan:CGPointMake(h,v) output:output event:e source:source];if(self.gesture==1&&[output isEqual:self.dragOutput])self.lastDragPan=e.timestamp;else [self.desktop.panLaunch panned:output];[self.desktop render];self.desktop.sceneDirty=YES;
    }
}
- (void)scrollWheel:(NSEvent *)e {
    if([self.desktop nativeUnavailable])return;
    [self.desktop.compositor finishGeometryTransitions];
    if(self.desktop.compositor.hasGeometryTransitions)return;
    if(self.desktop.sessionInactive)return;
    [self scroll:e];
}
- (void)magnifyWithEvent:(NSEvent *)e {
    if(self.desktop.sessionInactive||[self.desktop nativeUnavailable])return;
    // A pinch is a gesture binding: the [gestures] table decides what it does.
    [self.desktop magnify:e];
}
// Raw trackpad touches reach a view because its panel asks for them (allowedTouchTypes).
- (void)touchesBeganWithEvent:(NSEvent *)e { [self.desktop touches:e]; }
- (void)touchesMovedWithEvent:(NSEvent *)e { [self.desktop touches:e]; }
- (void)touchesEndedWithEvent:(NSEvent *)e { [self.desktop touches:e]; }
// macOS took the touches for a gesture of its own: each arrives cancelled, which ends ours cancelled.
- (void)touchesCancelledWithEvent:(NSEvent *)e { [self.desktop touches:e]; }
@end
