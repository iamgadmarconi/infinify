// SPDX-License-Identifier: GPL-3.0-or-later
// Split from native/desktop/main.m at 37b27b1, moved verbatim.
// Desktop navigation and sizing: resize and navigation coordinators, focus, camera frames, edge pan, size transactions.
#import "Desktop+Private.h"
#import "DWDebugTrace.h"
#import "DWNativeFocus.h"
#import "DWNativeFocusDriver.h"
#import "DWNativeFamily.h"
#import "DWGeometryJSON.h"
// Listen-only session observer of physical mouse presses/releases and scrolls:
// classifies clicks on Dock/Spotlight/Menu Bar vs inside the confirmed focused
// window vs outside the canvas, without cancelling focus restoration on typing.
static BOOL DWIsSystemUIOwner(NSString *owner,NSInteger layer,CGPoint point) {
    if(point.y<=32||layer>=20)return YES;
    return [owner isEqual:@"Dock"]||[owner isEqual:@"Spotlight"]||[owner isEqual:@"Apps"]
        ||[owner isEqual:@"SystemUIServer"]||[owner isEqual:@"Control Center"]||[owner isEqual:@"Notification Center"];
}
static CGEventRef navigationInput(CGEventTapProxy proxy,CGEventType type,CGEventRef event,void *context) {
    (void)proxy;Desktop *desktop=(__bridge Desktop *)context;
    if(type==kCGEventTapDisabledByTimeout||type==kCGEventTapDisabledByUserInput){[desktop.navigation interrupt];if(desktop.navigationTap)CGEventTapEnable(desktop.navigationTap,true);return event;}
    int64_t tag=CGEventGetIntegerValueField(event,kCGEventSourceUserData);
    if(tag&&[desktop.postingTags containsObject:@(tag)])return event;
    if(tag)for(LiveSource *source in desktop.sources.allValues)if(source.router.tag==tag)return event;
    [desktop cancelNativeTitleClick];
    if(type==kCGEventKeyDown){[desktop.pressAdmission chromeKeyDown:event];return event;}
    CGPoint point=CGEventGetLocation(event);
    BOOL down=type==kCGEventLeftMouseDown||type==kCGEventRightMouseDown||type==kCGEventOtherMouseDown;
    BOOL up=type==kCGEventLeftMouseUp||type==kCGEventRightMouseUp||type==kCGEventOtherMouseUp;
    if(down||up){
        CGWindowID top=(CGWindowID)[NSWindow windowNumberAtPoint:NSMakePoint(point.x,screenTop()-point.y) belowWindowWithWindowNumber:0];
        NSDictionary *info=top?windowInfo(top):nil;
        pid_t ownerPID=[info[(id)kCGWindowOwnerPID]intValue];
        NSInteger layer=[info[(id)kCGWindowLayer]integerValue];
        NSString *ownerName=DWTyped(info[(id)kCGWindowOwnerName],NSString.class);
        if(ownerPID!=getpid()&&DWIsSystemUIOwner(ownerName,layer,point)){
            [desktop.navigation noteSystemUIIntent];
        }else if(down){
            NSNumber *clicked=[desktop nativeSource:top at:point].logical;
            if(!clicked)for(DesktopView *view in desktop.views)if((CGWindowID)view.window.windowNumber==top){
                NSNumber *output=[view outputAt:point];clicked=output?DWTyped([view hit:point output:output][@"window"],NSNumber.class):nil;break;
            }
            [desktop.navigation noteWindowClick:clicked];
        }
        if(up)return event;
    }
    for(DesktopView *view in desktop.views)if(CGRectContainsPoint(view.globalBounds,point))return event;
    [desktop.navigation interrupt];return event;
}
@implementation Desktop (Navigation)
- (NSDictionary *)sizeTransitionSnapshot {return [self call:@{@"op":@"snapshot"}];}
- (LiveSource *)sizeTransitionSource:(NSNumber *)window {return self.sources[window];}
- (BOOL)sizeTransitionHeld:(NSNumber *)transaction {
    for(DesktopView *view in self.views)if(view.gesture==4&&[view.resizeTransaction isEqual:transaction])return YES;
    return self.gestureOwner&&self.gestureResize;
}
- (BOOL)sizeTransitionRemovalAllowed:(NSNumber *)window allowed:(BOOL *)allowed {
    uint8_t ok=0;if(!self.controller||!driftwm_desktop_resize_removal_allowed(self.controller,window==nil,window.unsignedLongLongValue,&ok))return NO;
    *allowed=ok!=0;return YES;
}
- (BOOL)sizeTransitionCaptureAllowed {return CGPreflightScreenCaptureAccess();}
- (NSDictionary *)sizeTransitionWindowInfo:(CGWindowID)window {return windowInfo(window);}
- (BOOL)sizeTransitionNativeBounds:(CGWindowID)window bounds:(CGRect *)bounds {return DWNativeBounds(window,bounds);}
- (BOOL)sizeTransitionOwner:(DWFocusIdentity)identity bounds:(CGRect *)bounds {return dw_focus_owner(identity,bounds);}
- (NSDictionary *)sizeTransitionFamily:(NSDictionary *)identity why:(NSString *__autoreleasing *)why {return DWNativeWindowFamily(identity,why);}

// native_resize_capability: DriftWM's sizing actions, the IPC resize write, a rule's size and fullscreen reach a native window through
// the resize coordinator, which every normal run has. main() says so before the config is read, since the binding table marks the
// actions that run here and a chord whose action does not is never registered; the coordinator's creation says so again, after the
// scene load, which rebuilds the controller. A size is settled by the native read alone (docs/crates/desktop/NATIVE_RESIZE.md).
- (void)resizeCapability {
    NSString *status=self.statusText;
    if(![self call:@{@"op":@"native_resize_capability",@"enabled":@YES}]){fprintf(stderr,"native_resize_capability: %s\n",self.statusText.UTF8String);self.statusText=status;}
}
// The navigation coordinator's commands. An activation the user made natively may leave fullscreen, as upstream exits before it
// activates another window of that output: the size transaction that takes the window back comes with the focus request and is
// the resize coordinator's to perform, like any other. The coordinator reads "effect" as a focus request, so a size
// transaction's is taken out of what it is handed, as in -applyReply:; no reply of its commands carried one before fullscreen.
- (NSDictionary *)navigationCall:(NSDictionary *)command {
    NSDictionary *reply=[self call:command],*sized=[self.sizeTransition consumeSize:reply];if(!sized||reply[@"effect"]!=sized)return reply;
    NSMutableDictionary *rest=[reply mutableCopy];[rest removeObjectForKey:@"effect"];return rest;
}
// Every normal run: the coordinator ticks camera flights, performs the controller's focus
// requests on native windows and follows native focus the user moved.
- (void)configureNavigation {
    if(self.navigation)return;
    __weak Desktop *weak=self;dispatch_queue_t queue=dispatch_queue_create("org.infinify.navigation",DISPATCH_QUEUE_SERIAL);
    self.navigation=[[DWNavigationCoordinator alloc]initWithCommand:^NSDictionary *(NSDictionary *c){return [weak navigationCall:c];} driver:[DWNativeFocusDriver new] clock:^uint64_t{return (uint64_t)(CACurrentMediaTime()*1e9);} worker:^(DWJob job){dispatch_async(queue,job);} main:^(DWJob job){dispatch_async(dispatch_get_main_queue(),job);}];
    self.navigation.enabled=YES;self.cycleHold=[DWCycleHold new];
    self.navigation.filterUnsolicitedActivations=!self.windowed&&self.managing&&!self.scope;
    self.navigation.arrivalProtection=^BOOL{Desktop *d=weak;return d.navigation.filterUnsolicitedActivations||(d.navigationTap&&d.navigationTapSource&&CGEventTapIsEnabled(d.navigationTap));};
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
        NSMutableArray *roots=[NSMutableArray array];
        // The live sources, each asked for its current controller binding: no whole-scene serialization per observation.
        for(NSNumber *logical in d.sources){NSDictionary *source=[d sourceBinding:logical],*identity=DWTyped(source[@"identity"],NSDictionary.class);LiveSource *live=d.sources[logical];
            if(!live||live.detached||!identity||!boundIdentity(live.identity,identity))continue;
            [roots addObject:@{@"window":logical,@"identity":identity,@"generation":source[@"generation"]}];
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
    if(self.navigation.filterUnsolicitedActivations){
        NSNotificationCenter *ws=NSWorkspace.sharedWorkspace.notificationCenter;
        void (^observeApp)(NSNotification *,BOOL)=^(NSNotification *note,BOOL launched){
            Desktop *d=weak;DWNavigationCoordinator *nav=d.navigation;if(!d||d.cleaning||!nav)return;
            NSRunningApplication *app=note.userInfo[NSWorkspaceApplicationKey];if(!app)return;
            uint64_t at=[nav nowNanoseconds];
            dispatch_async(queue,^{@autoreleasepool{
                pid_t pid=app.processIdentifier;if(pid<=0||pid==getpid())return;
                BOOL regular=app.activationPolicy==NSApplicationActivationPolicyRegular;
                NSString *bundle=app.bundleIdentifier;
                uint64_t s=0,u=0;if(!dw_focus_birth(pid,&s,&u))return;
                NSArray<NSNumber *> *born=@[@(s),@(u)];
                dispatch_async(dispatch_get_main_queue(),^{
                    Desktop *cur=weak;if(!cur||cur.cleaning||cur.navigation!=nav)return;
                    if(launched)[nav noteApplicationLaunched:pid birth:born bundle:bundle at:at];
                    else [nav noteApplicationActivated:pid birth:born bundle:bundle regular:regular at:at];
                });
            }});
        };
        self.navigationLaunchObserver=[ws addObserverForName:NSWorkspaceDidLaunchApplicationNotification object:nil queue:nil usingBlock:^(NSNotification *note){observeApp(note,YES);}];
        self.navigationActivateObserver=[ws addObserverForName:NSWorkspaceDidActivateApplicationNotification object:nil queue:nil usingBlock:^(NSNotification *note){observeApp(note,NO);}];
    }
    [self.navigation frame];
}
// Native focus needs Accessibility, which can be granted while the app runs, and
// --no-native-focus turns it off. Without it focus is logical and navigation still works.
- (void)refreshFocusAccess {
    BOOL trusted=AXIsProcessTrusted();self.navigation.focusAllowed=trusted&&!self.logicalFocus;[self.tapKeys trusted:trusted];
    if(trusted)[self configureNativeInput];
    if(trusted&&!self.logicalFocus&&!self.navigationTap&&self.navigation){
        CGEventMask mask=CGEventMaskBit(kCGEventLeftMouseDown)|CGEventMaskBit(kCGEventLeftMouseUp)|CGEventMaskBit(kCGEventRightMouseDown)|CGEventMaskBit(kCGEventRightMouseUp)|CGEventMaskBit(kCGEventOtherMouseDown)|CGEventMaskBit(kCGEventOtherMouseUp)|CGEventMaskBit(kCGEventScrollWheel);
        if(CGPreflightListenEventAccess())mask|=CGEventMaskBit(kCGEventKeyDown);
        self.navigationTap=CGEventTapCreate(kCGSessionEventTap,kCGHeadInsertEventTap,kCGEventTapOptionListenOnly,mask,navigationInput,(__bridge void *)self);
        if(self.navigationTap){self.navigationTapSource=CFMachPortCreateRunLoopSource(NULL,self.navigationTap,0);if(self.navigationTapSource)CFRunLoopAddSource(CFRunLoopGetMain(),self.navigationTapSource,kCFRunLoopCommonModes);}
    }
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
    NSNotificationCenter *ws=NSWorkspace.sharedWorkspace.notificationCenter;
    if(self.navigationLaunchObserver){[ws removeObserver:self.navigationLaunchObserver];self.navigationLaunchObserver=nil;}
    if(self.navigationActivateObserver){[ws removeObserver:self.navigationActivateObserver];self.navigationActivateObserver=nil;}
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
    if(!click||!source||source.detached||self.cleaning||self.sessionInactive||[self nativeUnavailable]||self.sizeTransition.fillHandoff
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
