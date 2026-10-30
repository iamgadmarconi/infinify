// SPDX-License-Identifier: GPL-3.0-or-later
// Split from native/desktop/main.m at 37b27b1, moved verbatim except that execCommand and the stopped flag are renamed DWExecCommand and DWStopSignal.
// Desktop actions: the action family, exec, launch, stand-in keyboard, native window controls, layout and autostart.
#import "Desktop+Private.h"
#import "DWInputSources.h"
#import "DWDebugTrace.h"
#import "DWNativeFocus.h"
#import "DWWindowEvents.h"
#import "DWGeometryJSON.h"
#import "DesktopPanel.h"
#import "DWChildProcess.h"
@implementation Desktop (Actions)
// Hot key target and the IPC active output: the output under the pointer, else the panel
// under it, else the first registered output.
- (NSNumber *)viewOutput {
    CGPoint point=pointer();
    for(DesktopView *view in self.views){NSNumber *output=[view outputAt:point];if(output)return output;}
    for(DesktopView *view in self.views)if(view.outputs.count&&CGRectContainsPoint(view.globalBounds,point))return [view actionOutput];
    for(DesktopView *view in self.views)if(view.outputs.count)return view.outputs[0];
    return nil;
}
- (NSString *)actionFeedback:(NSString *)action flight:(NSDictionary *)flight output:(NSNumber *)output {
    BOOL home=[action isEqual:@"home-toggle"];
    if(home||[action isEqual:@"zoom-to-fit"]){
        if(!flight)return home?@"Already home":@"Nothing to fit";
        // The toggle keeps its return view while away; an armed flight without one is the way back.
        id returns=[self call:@{@"op":@"snapshot"}][@"navigation"][home?@"home_returns":@"overview_returns"];
        if([returns isKindOfClass:NSDictionary.class]&&!returns[output.stringValue])return @"Previous view";
        return home?@"Home":@"Zoom to fit";
    }
    if([action hasPrefix:@"pan-viewport "])return nil;
    if([action hasPrefix:@"set-bookmark "])return [NSString stringWithFormat:@"Bookmark %@ saved",[action substringFromIndex:13]];
    if([action hasPrefix:@"go-to-bookmark "])return [NSString stringWithFormat:@"Bookmark %@",[action substringFromIndex:15]];
    // Every other bound action, exec and nudge-window among them, reports only its errors.
    if(![@[@"zoom-in",@"zoom-out",@"zoom-reset"]containsObject:action])return nil;
    if(!flight)return @"Zoom limit reached";
    double zoom=[flight[@"target_zoom"]doubleValue];return zoom==1?@"Zoom 1:1":[NSString stringWithFormat:@"Zoom %.3g%%",zoom*100];
}
// One exec effect. A command sh cannot find or run says so on the resting status and
// ends the key repeat in progress: a held chord never starts a missing program
// over and over.
- (void)exec:(NSDictionary *)effect {
    NSString *command=effect[@"command"];__weak Desktop *weak=self;
    // Upstream puts WAYLAND_DISPLAY in every child's environment and its msg client derives the
    // socket from it; the served socket path stands for it here. An [env] entry of that name wins.
    NSMutableDictionary *env=[DWTyped(effect[@"env"],NSDictionary.class) mutableCopy]?:[NSMutableDictionary dictionary];
    if(self.ipc&&self.socketPath&&env[@"INFINIFY_SOCKET"]==nil)env[@"INFINIFY_SOCKET"]=self.socketPath;
    NSString *error=DWExecCommand(command,env,^{Desktop *d=weak;if(!d||d.cleaning)return;[d.hotKeys endRepeat];[d flashStatus:[@"sh could not run: " stringByAppendingString:command]];[d render];});
    if(error)[self flashStatus:error];
}
// macOS's selected keyboard input source, for the controller's Layout and State answers.
- (void)reportLayout {
    NSMutableDictionary *command=[DWCurrentLayout()mutableCopy];if(!command)return;
    NSString *status=self.statusText;command[@"op"]=@"layout_changed";
    if(![self call:command]){fprintf(stderr,"layout_changed: %s\n",self.statusText.UTF8String);self.statusText=status;}
    [self publishState];
}
// The launch effect of relaunching a stand-in. The window it opens is found like any
// other and adopted into the stand-in's slot by the controller.
// A stand-in has no native keyboard recipient. Take the existing canvas panel's
// keyboard focus once on that logical transition, without changing its order.
// Later rendering must never steal it back from an application the user chose.
- (void)updateStandInKeyboard:(NSDictionary *)snapshot {
    NSDictionary *standin=DWFocusedStandIn(snapshot);NSNumber *window=standin[@"window"];
    if(self.windowed||self.cleaning||self.sessionInactive)window=nil;
    if([window isEqual:self.standinKeyboardWindow]||(!window&&!self.standinKeyboardWindow))return;
    DesktopPanel *panel=nil;
    if(window)for(NSDictionary *placement in snapshot[@"placements"])if([placement[@"window"]isEqual:window]){
        for(DesktopView *view in self.views)if([view.outputs containsObject:placement[@"output"]]&&[view.window isKindOfClass:DesktopPanel.class]){panel=(DesktopPanel *)view.window;break;}
        if(panel)break;
    }
    if(window&&!panel)return;
    DesktopPanel *old=(DesktopPanel *)self.standinKeyboardPanel;old.standinKeyboard=NO;
    if(old.isKeyWindow)[old resignKeyWindow];
    self.standinKeyboardWindow=window;self.standinKeyboardPanel=panel;self.standinKeyboardSerial++;
    if(panel){panel.standinKeyboard=YES;[NSApp activate];[panel makeKeyWindow];}
}
- (dispatch_block_t)standInEnter {
    if(self.cleaning||self.sessionInactive||[self nativeUnavailable]||!NSApp.active
        ||!self.standinKeyboardPanel.isKeyWindow||NSApp.keyWindow!=self.standinKeyboardPanel
        ||![self.panels containsObject:self.standinKeyboardPanel]||NSEvent.pressedMouseButtons||self.gestureOwner||self.magnifying||self.trackpad.engaged||self.nativeFillHandoff)return nil;
    for(DesktopView *view in self.views)if(view.gesture||view.pressedSource)return nil;
    for(LiveSource *source in self.sources.allValues)if(source.nativeMouseOwnership)return nil;
    NSDictionary *standin=DWFocusedStandIn([self call:@{@"op":@"snapshot"}]);
    if(!standin||![standin[@"window"]isEqual:self.standinKeyboardWindow])return nil;
    NSUInteger serial=self.standinKeyboardSerial;NSNumber *window=standin[@"window"];__weak Desktop *weak=self;
    return ^{Desktop *d=weak;if(!d||d.standinKeyboardSerial!=serial||![d.standinKeyboardWindow isEqual:window]||![d standInEnter])return;
        [d.tapKeys taint];[d applyReply:[d call:@{@"op":@"ipc",@"request":@{@"Relaunch":window}}]];};
}
// A system window-control shortcut belongs to the exact managed native root that
// currently has keyboard focus. The controller's last observation alone cannot
// distinguish a new window in the same app; read only AXFocusedWindow here.
- (NSDictionary *)nativeWindowControlIntent {
    if(!self.native||self.windowed||self.cleaning||self.sessionInactive||[self nativeUnavailable])return nil;
    DWFocusIdentity target={0};if(!dw_focus_frontmost(&target))return nil;
    NSDictionary *observed=@{@"pid":@(target.pid),@"wid":@(target.window),@"birth_sec":@(target.seconds),@"birth_usec":@(target.microseconds)};
    LiveSource *source=nil;
    for(LiveSource *candidate in self.sources.allValues)if(boundIdentity(candidate.identity,observed)){source=candidate;break;}
    if(!source||source.detached||source.nativeVisibilityHeld||!DWInScope(self.scope,source.router.pid))return nil;
    NSNumber *window=source.logical;NSDictionary *snapshot=[self call:@{@"op":@"snapshot"}];
    NSDictionary *binding=nil;
    for(NSDictionary *record in snapshot[@"windows"])if([record[@"window"]isEqual:window]){binding=DWTyped(record[@"source"],NSDictionary.class);break;}
    NSNumber *output=[self.nativeViews desiredOwnerForWindow:window];
    if(!output||[self.nativeViews replica:window output:output]||!DWTyped(binding[@"generation"],NSNumber.class)||!boundIdentity(source.identity,binding[@"identity"]))return nil;
    NSDictionary *identity=source.identity.copy;
    return @{@"window":window,@"identity":identity,@"generation":binding[@"generation"],@"output":output,@"session":@(self.nativeSessionEpoch)};
}
- (dispatch_block_t)nativeWindowControlKey:(DWNativeWindowControl)action {
    NSDictionary *intent=[self nativeWindowControlIntent];if(!intent)return nil;__weak Desktop *weak=self;
    // The physical pair stays owned even if the target or geometry becomes
    // unavailable before dispatch. Never deliver a native fallback mid-pair.
    return ^{Desktop *d=weak;if(!d||![[d nativeWindowControlIntent]isEqual:intent])return;
        LiveSource *source=d.sources[intent[@"window"]];
        NSDictionary *focus=DWTyped([d call:@{@"op":@"snapshot"}][@"focus"],NSDictionary.class);
        if(DWTyped(focus[@"pending_effect"],NSDictionary.class)||d.nativeFillHandoff||source.nativeMouseOwnership||d.nativeOwnershipTransfer||d.nativeHoverTransfer
            ||d.nativeGestureView||d.nativeScrollView||d.nativeMagnifyView||d.pointerGrab.active||d.gestureOwner||d.magnifying
            ||d.trackpad.engaged||d.globalGestureContact||d.globalTrackpad.ownsTouches||d.globalTrackpad.hasNativeMousePress
            ||NSEvent.pressedMouseButtons||[[d.resize busyWindow]isEqual:source.logical])return;
        for(DesktopView *view in d.views)if(view.gesture||view.heldPress||view.pressedSource||view.pressedTablet||view.pressedPointerGrab)return;
        NSString *name=nil;
        switch(action){
            case DWNativeWindowControlToggleFullscreen:name=@"fullscreen";break;
            case DWNativeWindowControlFill:name=@"fill";break;
            case DWNativeWindowControlRestore:name=@"restore";break;
            case DWNativeWindowControlCenter:name=@"center";break;
            case DWNativeWindowControlSuppressTiling:
                [d.tapKeys taint];[d cancelNativeTitleClick];[d flashStatus:@"Use the canvas to arrange windows"];[d render];return;
        }
        if(!name)return;
        NSMutableDictionary *command=[intent mutableCopy];[command removeObjectForKey:@"session"];command[@"op"]=@"native_decoration";command[@"action"]=name;
        [d.tapKeys taint];[d cancelNativeTitleClick];[d applyReply:[d call:command]];
        if(DWDebugTrace())fprintf(stderr,"debug: native window control key action=%s window=#%s\n",name.UTF8String,source.logical.description.UTF8String);
    };
}
- (void)launch:(NSString *)bundle {
    __weak Desktop *weak=self;
    DWLaunchApplication(bundle,^(NSString *reason){Desktop *d=weak;if(!d||d.cleaning)return;NSString *note=[@"Relaunch failed: " stringByAppendingString:reason];[d say:note];[d flashStatus:note];[d render];});
}
// Upstream's autostart: once, a moment after startup, when the socket already
// answers a command that talks to this app: exec: hands every child the served
// socket as INFINIFY_SOCKET, so `Infinify msg` in a command reaches this instance.
- (void)runAutostart {
    if(self.sessionInactive)return; // retain launch effects until the unopened canvas can admit its session
    NSArray *effects=self.autostart;self.autostart=nil;if(!effects.count)return;
    __weak Desktop *weak=self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(.1*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        Desktop *d=weak;if(!d||DWStopSignal)return;
        for(id effect in effects){NSDictionary *e=DWTyped(effect,NSDictionary.class);if([e[@"op"]isEqual:@"exec"]&&DWTyped(e[@"command"],NSString.class))[d exec:e];}
    });
}
// Hold-to-commit, after an action ran, whatever fired it: a held cycle-windows step keeps the session open
// until the hold modifiers are let go; any other action has ended it.
- (void)holdCycle:(NSString *)action held:(BOOL)held {
    BOOL cycle=[action hasPrefix:@"cycle-windows "];
    if(cycle&&held&&self.navigation){__weak Desktop *weak=self;[self.navigation hold:self.cycleModifiers?:optionKey];[self.cycleHold start:^BOOL(uint32_t down){return [weak.navigation poll:down];}];}
    else if(!cycle){[self.navigation hold:0];[self.cycleHold stop];}
}
// A hot key's pointer and modifiers are the physical ones at the moment it fires.
- (void)action:(NSString *)action output:(NSNumber *)output { [self action:action output:output at:pointer() held:[DWCycleHold modifiersDown]!=0]; }
- (void)action:(NSString *)action output:(NSNumber *)output at:(CGPoint)point held:(BOOL)held { [self action:action output:output at:point held:held corner:nil]; }
// Every hot key and hot corner runs an upstream action string. An existing
// flight is deliberately not cancelled first: pan-viewport extends its in-flight target.
// A normal run also says where the pointer is, for focus-center, and whether a real
// modifier is down: upstream then keeps a cycle-windows session open until the hold
// modifiers are let go, and commits a modifier-less step at once.
// A hot corner's action is the controller's to pick and run: `action` is then only what
// the resting status reports and what decides whether a cycle session is held open.
- (void)action:(NSString *)action output:(NSNumber *)output at:(CGPoint)point held:(BOOL)held corner:(NSString *)corner { [self action:action output:output at:point held:held corner:corner tap:nil]; }
// So is a tap binding's, which the controller looks up by the chord: `tap` is the physical modifiers of the chord just completed, as the
// bindings reply gave them. Upstream runs a tap's action as it runs a key's (keyboard.rs: pending_tap_action through execute_action).
- (void)action:(NSString *)action output:(NSNumber *)output at:(CGPoint)point held:(BOOL)held corner:(NSString *)corner tap:(NSDictionary *)tap {
    if(self.sessionInactive||([self nativeUnavailable]&&![action isEqual:@"quit"]))return;
    // An action cancels a resize the pointer began and is dropped while that is unresolved. A sizing action's own transaction is
    // not cancelled and drops nothing: the next action, a held grow-window's repeat among them, is the controller's to answer.
    if(self.cleaning||!output)return;
    // Upstream's go-to-bookmark is silent on an unset name, so the bookmark table is asked first.
    NSString *name=[action hasPrefix:@"go-to-bookmark "]?[action substringFromIndex:15]:nil;
    // The question is an ipc reply like any other: a size transaction the controller began with it, the size a fullscreen exit still owed its window, is performed.
    NSDictionary *known=name?[self call:@{@"op":@"ipc",@"output":output,@"request":@{@"Bookmark":@{@"name":name}}}]:nil;[self consumeSize:known];
    BOOL unset=name&&!DWTyped(known[@"reply"],NSDictionary.class)[@"Ok"];
    NSMutableDictionary *command=[(tap?@{@"op":@"tap",@"modifiers":tap,@"output":output}:corner?@{@"op":@"hot_corner",@"output":output,@"corner":corner}:@{@"op":@"action",@"output":output,@"action":action})mutableCopy];
    command[@"pointer"]=pointJSON(point);command[@"held"]=held?@YES:@NO;
    NSDictionary *reply=[self call:command];
    if(reply)[self holdCycle:action held:held];
    NSString *sets=[self.hotKeys chords:[@"set-bookmark " stringByAppendingString:name?:@""]].firstObject;
    NSString *missing=[NSString stringWithFormat:@"No bookmark %@ yet%@",name,sets?[NSString stringWithFormat:@" — %@ sets it",sets]:@""];
    NSString *text=unset?missing:reply?[self actionFeedback:action flight:DWTyped(reply[@"navigation"],NSDictionary.class) output:output]:self.statusText;
    if(text)[self flashStatus:text];
    [self applyReply:reply];
}
@end
