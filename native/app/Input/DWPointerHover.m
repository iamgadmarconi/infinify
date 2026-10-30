// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from DriftWM, repository https://github.com/malbiruk/driftwm, commit 352333a8fa1b22171492d4b71a54102045c9a19d:
// src/input/mod.rs (dispatch_absolute_motion and on_pointer_motion_relative: every
// real pointer motion is delivered to the surface under it and runs
// maybe_hover_focus), src/input/pointer.rs (try_pick_button, maybe_promote_pick and
// the release tail of on_pointer_button; the MouseAction::CenterNearest arm),
// src/state/navigation.rs (arm_pick, resolve_pick, CLICK_NAVIGATE_SLOP) and
// src/grabs/navigate_grab.rs (NavigateGrab: one center-nearest, on the first motion
// 16 points from the press). Which window a motion focuses, whether it may be
// delivered, what a pick navigates to and which way a swipe points are the
// controller's (crates/desktop/src/pointer_policy.rs). Upstream is handed every
// motion by its backend; a panel that is never key gets them from a tracking area.
#import "DWPointerHover.h"
#import "DWTypedValue.h"
#import <QuartzCore/QuartzCore.h>

static NSDictionary *pointJSON(CGPoint p) { return @{@"x":@(p.x),@"y":@(p.y)}; }
BOOL DWPickOutput(NSDictionary *snapshot,NSNumber *output) {
    for(id listed in DWTyped(snapshot[@"outputs"],NSArray.class)){NSDictionary *entry=DWTyped(listed,NSDictionary.class);if([entry[@"id"]isEqual:output]&&[entry[@"pick"]isEqual:@YES])return YES;}
    return NO;
}
NSDictionary *DWPickHit(NSDictionary *hit,NSDictionary *snapshot,NSNumber *output) {
    if(!DWPickOutput(snapshot,output))return hit;
    NSMutableDictionary *picked=[hit mutableCopy];picked[@"pick"]=@YES;return picked;
}
// A press the policy owns until its button comes up.
typedef NS_ENUM(NSInteger,DWPress) {
    DWPressNone,
    DWPressPick,     // left, in pick mode: a pick on release, a window move past the click slop
    DWPressNearest,  // bound to center-nearest: no direction taken yet
    DWPressSpent,    // nothing left to do but keep the press from the application
};
@implementation DWPointerHover {
    __weak NSView<DWPointerHost> *_host;
    NSTrackingArea *_area;
    NSTrackingArea *_cursorArea;
    NSEvent *_motion;      // the newest motion not yet sent
    NSTimer *_flush;       // the one pending hover, while no frame timer runs
    CFTimeInterval _sent;  // when the last hover went
    DWPress _press;
    NSNumber *_window,*_output; // what the press went down on
    CGPoint _start;
    BOOL _focus; // the nearest press is focus-nearest's
}
- (instancetype)initWithHost:(NSView<DWPointerHost> *)host {
    if((self=[super init])){
        _host=host;_forwarding=YES;
        _area=[[NSTrackingArea alloc]initWithRect:NSZeroRect options:NSTrackingMouseMoved|NSTrackingMouseEnteredAndExited|NSTrackingActiveAlways|NSTrackingInVisibleRect|NSTrackingEnabledDuringMouseDrag owner:self userInfo:nil];
        [host addTrackingArea:_area];host.window.acceptsMouseMovedEvents=YES;
        // AppKit suppresses cursorUpdate: for ActiveAlways, so cursor resets
        // while our application is active use a separate tracking area.
        // https://developer.apple.com/documentation/appkit/nstrackingarea/options-swift.struct/activealways
        _cursorArea=[[NSTrackingArea alloc]initWithRect:NSZeroRect options:NSTrackingCursorUpdate|NSTrackingActiveInActiveApp|NSTrackingInVisibleRect owner:self userInfo:nil];
        [host addTrackingArea:_cursorArea];
    }
    return self;
}
// The tracking area's. Motion arrives as often as the pointer reports it; one hover
// a frame is enough, and it is the newest. A running frame timer of the shell's takes
// it with its next frame; only without one is a timer armed here.
- (void)mouseMoved:(NSEvent *)event {
    if(!_area)return;
    _motion=event;if(_flush||[_host pointerFramed])return;
    __weak DWPointerHover *weak=self;
    _flush=[NSTimer timerWithTimeInterval:MAX(0,_sent+1.0/60-CACurrentMediaTime()) repeats:NO block:^(NSTimer *timer){
        DWPointerHover *hover=weak;if(!hover||hover->_flush!=timer)return;
        hover->_flush=nil;[hover flush];
    }];
    [NSRunLoop.mainRunLoop addTimer:_flush forMode:NSRunLoopCommonModes];
}
- (BOOL)pending { return _motion!=nil; }
- (void)mouseEntered:(NSEvent *)event { [self cursorUpdate:event]; }
- (void)mouseExited:(NSEvent *)event {
    (void)event;[_flush invalidate];_flush=nil;_motion=nil;
    [_host pointerCursor:CGPointZero output:nil reply:nil];
}
- (void)cursorUpdate:(NSEvent *)event {
    (void)event;if(!_area)return;CGPoint point=CGPointZero;NSNumber *output=[_host pointerSample:&point];
    [_host pointerCursor:point output:output reply:nil];
}
- (void)nativeMotion:(NSEvent *)event { [self mouseMoved:event]; }
// This object's own timer. A frame timer that started while it waited has the motion from here on.
- (void)flush {
    NSView<DWPointerHost> *host=_host;if(!_motion||!host||[host pointerFramed])return;
    CGPoint p=CGPointZero;NSNumber *output=[host pointerSample:&p];[self hover:p output:output];
}
- (void)frame:(CGPoint)screen output:(NSNumber *)output { [_flush invalidate];_flush=nil;if(_motion)[self hover:screen output:output]; }
// `p` and `output` are the shell's reading of the pointer, not the event's: the motion is only what is delivered.
// A tracking area reports the pointer inside its view also under a window that covers the panel there (the
// chooser, a menu, in a windowed run another application), which is not on an output.
- (void)hover:(CGPoint)p output:(NSNumber *)output {
    NSEvent *motion=_motion;NSView<DWPointerHost> *host=_host;_motion=nil;_sent=CACurrentMediaTime();
    if(!motion||!host||!_area)return;
    if(!output||[host pointerBusy]){[host pointerCursor:p output:output reply:nil];return;}
    // time_ms is now on the clock events are stamped with, as a timed pan's is its event's: the controller
    // tells from the two whether a scroll that panned is still to launch its coast.
    NSDictionary *reply=[host pointerCommand:@{@"op":@"hover",@"output":output,@"screen":pointJSON(p),@"time_ms":@((uint32_t)(uint64_t)(_sent*1000))} quiet:YES];
    [host pointerCursor:p output:output reply:reply];if(!reply)return;
    // Upstream's order: the motion goes to the window under it, whoever holds the keyboard, then focus follows.
    if(self.forwarding&&[reply[@"forward"]isEqual:@YES])[host pointerDeliver:motion at:p output:output];
    // Sloppy focus moved: only then is there an effect to perform and anything to draw.
    if([reply[@"dirty"]isEqual:@YES])[host pointerFocused:DWTyped(reply[@"effect"],NSDictionary.class)];
}
- (BOOL)pickPress:(NSDictionary *)hit button:(NSInteger)button claimed:(BOOL)claimed at:(CGPoint)screen output:(NSNumber *)output {
    NSNumber *window=DWTyped(hit[@"window"],NSNumber.class);
    if(claimed||!window||!output||![hit[@"pick"]isEqual:@YES])return NO;
    // try_pick_button: any button is swallowed and focuses and raises its target; only the left one arms the pick.
    _press=button?DWPressSpent:DWPressPick;_window=window;_output=output;_start=screen;
    NSView<DWPointerHost> *host=_host;[host pointerApply:[host pointerCommand:@{@"op":@"activate",@"window":window,@"output":output,@"cause":@"click"} quiet:NO]];
    return YES;
}
- (void)nearestPress:(CGPoint)screen output:(NSNumber *)output focus:(BOOL)focus { _press=DWPressNearest;_window=nil;_output=output;_start=screen;_focus=focus; }
// held: whether a real modifier is down as the swipe fires, as every action the shell sends says.
- (NSDictionary *)nearest:(CGPoint)screen { return @{@"op":@"pointer_nearest",@"output":_output?:NSNull.null,@"screen":pointJSON(screen),@"start":pointJSON(_start),@"held":[_host pointerHeld]?@YES:@NO,@"focus":_focus?@YES:@NO}; }
- (BOOL)pressDragged:(CGPoint)screen {
    NSView<DWPointerHost> *host=_host;double dx=_start.x-screen.x,dy=_start.y-screen.y,xx=dx*dx,yy=dy*dy;
    if(_press==DWPressNearest){
        // NavigateGrab fires once, on the first motion out of its dead zone, and ignores the rest of the drag.
        // The controller keeps the same dead zone, so the test is its own: the squared distance against 16².
        if(xx+yy<256)return NO;
        NSDictionary *command=[self nearest:screen];_press=DWPressSpent;[host pointerApply:[host pointerCommand:command quiet:NO]];return NO;
    }
    // maybe_promote_pick: past the click slop, on the output of the press. The pick is dropped first, so a drag
    // out and back never picks as well; a refused move leaves the press spent.
    if(_press!=DWPressPick||xx+yy<=25||![[host outputAt:screen]isEqual:_output])return NO;
    _press=DWPressSpent;
    // begin_drag raises and focuses its window, as the press did, and the focus request in its reply takes the place of the press's:
    // it is carried out the same way, or the controller would wait on a request nobody answers.
    id reply=[host pointerCommand:@{@"op":@"begin_drag",@"window":_window,@"output":_output,@"group":@NO} quiet:NO];if(DWTyped(reply,NSDictionary.class))[host pointerApply:reply];
    return reply!=nil;
}
- (void)pressReleased:(CGPoint)screen {
    NSView<DWPointerHost> *host=_host;DWPress press=_press;NSNumber *window=_window,*output=_output;
    NSDictionary *swipe=press==DWPressNearest?[self nearest:screen]:nil;
    _press=DWPressNone;_window=_output=nil;
    if(swipe)[host pointerApply:[host pointerCommand:swipe quiet:NO]];
    // resolve_pick: the button came up on the output it went down on. Whether that output is still in pick mode is the controller's to check.
    else if(press==DWPressPick&&[[host outputAt:screen]isEqual:output])[host pointerApply:[host pointerCommand:@{@"op":@"pick",@"window":window,@"output":output} quiet:NO]];
}
- (void)stop {
    [_flush invalidate];_flush=nil;_motion=nil;_press=DWPressNone;_window=_output=nil;
    if(_area){[_host removeTrackingArea:_area];_area=nil;}
    if(_cursorArea){[_host removeTrackingArea:_cursorArea];_cursorArea=nil;}
    [_host pointerCursor:CGPointZero output:nil reply:nil];_host=nil;
}
- (void)dealloc { [_flush invalidate]; }
@end
