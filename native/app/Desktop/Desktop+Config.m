// SPDX-License-Identifier: GPL-3.0-or-later
// Split from native/desktop/main.m at 37b27b1, moved verbatim.
// Desktop config: loading, bindings, hot keys and corners, actions, exec, stand-in keyboard, IPC and autostart.
#import "Desktop+Private.h"
#import "DWInputSources.h"
#import "DWDebugTrace.h"
#import "DWNativeFocus.h"
#import "DWWindowEvents.h"
#import "DWGeometryJSON.h"
#import "DesktopPanel.h"
#import "DWChildProcess.h"
// One past the JSON value at p. The input is the controller's own compact output.
static const char *jsonValueEnd(const char *p,const char *end) {
    for(NSInteger depth=0;p<end;p++){
        if(*p=='"'){for(p++;p<end&&*p!='"';p++)if(*p=='\\')p++;if(!depth)return p<end?p+1:end;}
        else if(*p=='{'||*p=='[')depth++;
        else if(*p=='}'||*p==']'){if(!depth)return p;if(!--depth)return p+1;}
        else if(*p==','&&!depth)return p;
    }
    return end;
}
// Raw bytes of one member of a JSON object: the controller's own number formatting
// and key order, which a round trip through NSJSONSerialization would rewrite.
static NSData *jsonMember(NSData *object,const char *key) {
    const char *p=object.bytes,*end=p+object.length;size_t length=strlen(key);
    if(p==end||*p!='{')return nil;
    for(p++;p<end&&*p=='"';){
        const char *name=p+1,*colon=jsonValueEnd(p,end);if(colon>=end||*colon!=':')return nil;
        const char *value=colon+1;p=jsonValueEnd(value,end);
        if((size_t)(colon-1-name)==length&&!memcmp(name,key,length))return [NSData dataWithBytes:value length:(NSUInteger)(p-value)];
        if(p<end&&*p==',')p++;
    }
    return nil;
}
static NSData *ipcError(NSString *message) { return [NSJSONSerialization dataWithJSONObject:@{@"Err":message} options:NSJSONWritingWithoutEscapingSlashes error:nil]; }
static OSStatus exitKey(EventHandlerCallRef next,EventRef event,void *context) { (void)next;EventHotKeyID key={0};GetEventParameter(event,kEventParamDirectObject,typeEventHotKeyID,NULL,sizeof(key),NULL,&key);if(key.signature!='Infi'||key.id!=1)return eventNotHandledErr;[(__bridge Desktop *)context quit:nil];return noErr; }
// ⌃⌥Esc is the shell's own exit chord until a config binding claims it.
static NSNumber *exitChord(void) { return DWChord(53,controlKey|optionKey); }
@implementation Desktop (Config)
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
    NSString *error=execCommand(command,env,^{Desktop *d=weak;if(!d||d.cleaning)return;[d.hotKeys endRepeat];[d flashStatus:[@"sh could not run: " stringByAppendingString:command]];[d render];});
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
// Which corners are bound depends on the outputs registered: read from the bindings
// after every config load, and again whenever panels open.
- (void)armCorners:(NSDictionary *)bindings { if(!self.corners)self.corners=[DWHotCorners new];[self.corners arm:asArray(bindings[@"hot_corners"])]; }
// Is a window fullscreen on this output, by the outputs of the snapshot last drawn (-render)?
- (BOOL)fullscreenOn:(NSNumber *)output { for(NSDictionary *o in self.pointerOutputs)if([o[@"id"]isEqual:output])return DWTyped(o[@"fullscreen"],NSDictionary.class)!=nil;return NO; }
// Upstream checks hot corners on every pointer motion. Here the pointer is read at
// the poll and frame cadence, and only while some corner is bound. A display's
// corners are its panel's, which are the output's and the display's own: the true
// corners, where the pointer comes to rest. The controller picks and runs the action.
// An entry upstream suppresses is not sent at all, under a held button as on an output
// that is fullscreen with disable_when_fullscreen: the resting status then reports no
// action that did not run. The controller's hot_corner applies the fullscreen rule too.
- (void)watchCorners {
    if(self.cleaning||self.sessionInactive||!self.corners.armed)return;
    CGPoint p=pointer();BOOL dragging=NSEvent.pressedMouseButtons!=0;
    for(DesktopView *view in self.views)if(view.gesture||view.pressedSource)dragging=YES;
    for(DesktopView *view in self.views){
        CGRect display=view.globalBounds;if(view.outputs.count!=1||!CGRectContainsPoint(display,p))continue;
        // Upstream's nested backend sees only the motion its own window is sent: an ordinary window
        // covered at the pointer, or left on another Space, has no pointer in its corner. Not asked of
        // the full-screen panels, whose top corners lie under the menu bar.
        if(self.windowed&&[NSWindow windowNumberAtPoint:NSMakePoint(p.x,screenTop()-p.y) belowWindowWithWindowNumber:0]!=view.window.windowNumber)continue;
        NSNumber *output=view.outputs[0];NSString *corner=[self.corners enter:CGPointMake(p.x-display.origin.x,p.y-display.origin.y) size:display.size output:output fullscreen:[self fullscreenOn:output] dragging:dragging];
        if(corner)[self action:[self.corners action:corner output:output] output:output at:p held:[DWCycleHold modifiersDown]!=0 corner:corner];
        return;
    }
    [self.corners leave];
}
// Upstream's broadcast: the controller's state_event returns the State event line
// only when it differs from the last one it returned, and that line goes to every
// subscriber. Without an active output there is no State, which is no news for the resting status.
- (void)broadcastState {
    NSString *status=self.statusText,*line=DWTyped([self call:@{@"op":@"state_event",@"output":[self viewOutput]?:NSNull.null}][@"line"],NSString.class);self.statusText=status;
    if(line)[self.ipc publish:[line dataUsingEncoding:NSUTF8StringEncoding]];
}
// Subscribers get the State after anything that may have changed what it reports:
// asked for by every redraw, broadcast at most once a frame, and on a later turn
// of the main queue so that a request's own reply is written first. Nothing is
// asked of the controller while nobody subscribes.
- (void)publishState {
    if(self.statePush||self.cleaning||!self.ipc.subscribers)return;
    __weak Desktop *weak=self;
    self.statePush=[NSTimer timerWithTimeInterval:MAX(0,self.lastStatePush+1.0/60-CACurrentMediaTime()) repeats:NO block:^(NSTimer *timer){
        Desktop *d=weak;if(!d||d.statePush!=timer)return;
        d.statePush=nil;d.lastStatePush=CACurrentMediaTime();if(!d.cleaning&&d.ipc.subscribers)[d broadcastState];
    }];
    [NSRunLoop.mainRunLoop addTimer:self.statePush forMode:NSRunLoopCommonModes];
}
// Upstream's autostart: once, a moment after startup, when the socket already
// answers a command that talks to this app: exec: hands every child the served
// socket as INFINIFY_SOCKET, so `Infinify msg` in a command reaches this instance.
- (void)runAutostart {
    if(self.sessionInactive)return; // retain launch effects until the unopened canvas can admit its session
    NSArray *effects=self.autostart;self.autostart=nil;if(!effects.count)return;
    __weak Desktop *weak=self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(.1*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        Desktop *d=weak;if(!d||stopped)return;
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
- (void)configureExitKey {
    if(self.hotkeyHandler)return;
    EventTypeSpec type={kEventClassKeyboard,kEventHotKeyPressed};OSStatus handler=InstallApplicationEventHandler(exitKey,1,&type,(__bridge void *)self,&_hotkeyHandler);EventHotKeyID key={'Infi',1};
    if(handler!=noErr||RegisterEventHotKey(53,controlKey|optionKey,key,GetApplicationEventTarget(),0,&_exitHotkey)!=noErr)self.statusText=@"Exit shortcut unavailable; quit with a key bound to quit or with Infinify msg action quit.";
}
- (void)stopExitKey { if(self.exitHotkey){UnregisterEventHotKey(self.exitHotkey);self.exitHotkey=NULL;}if(self.hotkeyHandler){RemoveEventHandler(self.hotkeyHandler);self.hotkeyHandler=NULL;} }
// A normal run's global hot keys: the config's bindings, then the exit chord unless one
// of them claimed it. Windowed mode registers none. Returns the chords macOS refused.
// The config's tap bindings are watched for exactly as long as its keys are registered.
- (NSArray<NSString *> *)startKeys {
    if(self.windowed)return @[];
    NSArray<NSString *> *refused=[self.hotKeys start];if(![self.hotKeys holds:exitChord()])[self configureExitKey];
    [self.tapKeys start];
    return refused;
}
- (void)stopKeys { [self.hotKeys stop];[self.tapKeys stop];[self stopExitKey]; }
// Upstream's binding lookup for one press or scroll: physical modifiers, trigger and
// context in; the bound gesture, or nil for none, out. The binding carries the config's
// pointer speeds.
- (NSDictionary *)mouseBinding:(NSString *)trigger source:(NSString *)source flags:(NSEventModifierFlags)flags window:(BOOL)window { return [self mouseBinding:trigger source:source flags:flags window:window under:nil pick:NO]; }
// The lookup of a real press or scroll also names the window it is over, and says whether that window is a pick target.
// under: upstream's pass_mouse (src/input/pointer.rs: pass_mouse_claims, pass_mouse_claims_notch). Where that window's rule claims the
// trigger the controller answers {"binding": null, "passed": true}, and the trigger is unbound here exactly as it is there: nil, and the
// press or scroll goes on to the window. nil for a placeholder, which has no application to pass anything to.
// pick: that window is a pick target, as its hit says, and the lookup is upstream's below [zoom] interact_min (docs/crates/desktop/POINTER.md); it then
// claims nothing.
- (NSDictionary *)mouseBinding:(NSString *)trigger source:(NSString *)source flags:(NSEventModifierFlags)flags window:(BOOL)window under:(NSNumber *)under pick:(BOOL)pick {
    NSMutableDictionary *command=[@{@"op":@"mouse_binding",@"trigger":trigger,@"source":source?:NSNull.null,@"modifiers":modifiersJSON(flags),@"context":window?@"window":@"canvas",@"pick":pick?@YES:@NO}mutableCopy];if(under)command[@"window"]=under;
    NSDictionary *reply=[self call:command],*binding=DWTyped(reply[@"binding"],NSDictionary.class);
    return binding;
}
// The controller's binding table as hot keys: after every config
// load, and again whenever the keyboard input source changes. Returns what was left out.
- (NSArray<NSString *> *)refreshBindings {
    NSString *status=self.statusText;NSMutableArray<NSString *> *notes=[NSMutableArray array];
    NSDictionary *bindings=[self call:@{@"op":@"bindings"}];if(!bindings)[notes addObject:self.statusText?:@"bindings unavailable"];
    for(id warning in asArray(bindings[@"warnings"]))if(DWTyped(warning,NSString.class))[notes addObject:warning];
    // A key that fires as a binding is a key on top of whatever modifier chord is held: that chord is no tap.
    if(!self.hotKeys){__weak Desktop *weak=self;self.hotKeys=[[DWHotKeys alloc]initWithFire:^(NSString *action){[weak.tapKeys taint];[weak action:action output:[weak viewOutput]];}];self.hotKeys.kept=exitChord();self.hotKeys.standinEnter=^dispatch_block_t{return [weak standInEnter];};self.hotKeys.nativeWindowControl=^dispatch_block_t(DWNativeWindowControl action){return [weak nativeWindowControlKey:action];};self.hotKeys.changed=^{Desktop *d=weak;NSArray<NSString *> *left=[d refreshBindings];for(NSString *line in left)fprintf(stderr,"%s\n",line.UTF8String);if(left.count){d.statusText=summary(@"Bindings",left);[d render];}};}
    // A tap binding's chord, completed, goes back to the controller as it came, to be looked up and run there. The output, the pointer and the modifiers
    // still down are those of the moment, as a hot key's: the release that completes a chord of two leaves one of them held.
    if(!self.tapKeys){__weak Desktop *weak=self;self.tapKeys=[[DWTapKeys alloc]initWithFire:^(NSDictionary *tap){NSDictionary *chord=DWTyped(tap[@"modifiers"],NSDictionary.class);if(chord)[weak action:DWTyped(tap[@"action"],NSString.class) output:[weak viewOutput] at:pointer() held:[DWCycleHold modifiersDown]!=0 corner:nil tap:chord];}];}
    BOOL open=self.panels.count!=0;if(open)[self stopKeys];
    [self.hotKeys setBindings:bindings];[self.tapKeys setBindings:bindings];
    // INFINIFY_DEBUG: which key bindings run here, and so are registered as hot keys in a run that registers any, and which stay with the applications.
    if(DWDebugTrace()){NSMutableArray<NSString *> *run=[NSMutableArray array],*inert=[NSMutableArray array];
        for(id entry in asArray(bindings[@"keys"])){NSDictionary *key=DWTyped(entry,NSDictionary.class);if(DWTyped(key[@"action"],NSString.class))[([DWTyped(key[@"implemented"],NSNumber.class)isEqual:@NO]?inert:run) addObject:[NSString stringWithFormat:@"%@=%@",DWTyped(key[@"combo"],NSString.class)?:@"?",key[@"action"]]];}
        fprintf(stderr,"debug: key bindings that run here: %s\ndebug: key bindings that do not run here: %s\n",[run componentsJoinedByString:@"; "].UTF8String,[inert componentsJoinedByString:@"; "].UTF8String);}
    [notes addObjectsFromArray:self.hotKeys.notes];
    // Upstream's cycle_hold as the controller reports it, else as upstream derives it: the modifiers of the cycle-windows forward binding, Option when it has none.
    NSDictionary *hold=DWTyped(bindings[@"cycle_hold"],NSDictionary.class);UInt32 mask=([hold[@"control"]isEqual:@YES]?controlKey:0)|([hold[@"option"]isEqual:@YES]?optionKey:0)|([hold[@"shift"]isEqual:@YES]?shiftKey:0)|([hold[@"command"]isEqual:@YES]?cmdKey:0);
    if(!mask)for(NSDictionary *key in self.hotKeys.keys)if([key[@"action"]isEqual:@"cycle-windows forward"]){mask=[key[@"chord"]unsignedIntValue]&(controlKey|optionKey|shiftKey|cmdKey);break;}
    self.cycleModifiers=mask?:optionKey;
    [self refreshGestureFingers];
    self.dismissFree=![self mouseBinding:@"left" source:nil flags:NSEventModifierFlagControl|NSEventModifierFlagOption window:YES];
    [self armCorners:bindings];
    self.statusText=status;if(open)[notes addObjectsFromArray:[self startKeys]];
    if(open)[self render];
    // Startup, and every change of the input source, also tell the controller the layout.
    [self reportLayout];
    return notes;
}
// Startup, a change of the config file, the reload-config action, and a canvas reopened
// after Return to desktop. Reload semantics are the controller's, which are upstream's:
// a file that fails to parse leaves the previous config in force and says why.
// What the file itself has wrong, the load's errors and warnings, is shown where upstream shows it and nowhere else: in the
// error bar, which the compositor draws from the controller's own message (snapshot.render.errors). Here those lines go to
// stderr and never to the resting status. The resting status keeps what the bar does not show: a --super chord or a load the
// controller refused (`problems`), and the bindings that were left out.
- (void)loadConfig:(BOOL)platform {
    NSMutableArray<NSString *> *problems=[NSMutableArray array],*file=[NSMutableArray array];
    if(platform&&![self call:@{@"op":@"set_platform",@"super":self.superChord?:@"ctrl+alt"}])[problems addObject:self.statusText?:@"set_platform failed"];
    NSDictionary *loaded=[self call:@{@"op":@"load_config",@"path":self.configPath?:NSNull.null}];if(!loaded)[problems addObject:self.statusText?:@"load_config failed"];
    // A reload can change what is saved (config bookmarks); the launch load precedes the scene and saves nothing.
    if(!platform&&[loaded[@"dirty"]isEqual:@YES])[self saveScene];
    // The launch load's effects are the config's autostart commands: kept for main() to run once. A reload's are never looked at.
    if(platform)self.autostart=asArray(loaded[@"effects"]);
    for(NSString *key in @[@"errors",@"warnings"])for(id message in asArray(loaded[key]))if(DWTyped(message,NSString.class))[file addObject:message];
    // The reply lists a load's warnings in the parser's order, which for a hash-mapped table differs between two loads of one file. They are
    // printed in byte order, the order the controller picks the bar's one line in, so the first line is the one the bar names at every load.
    [file sortUsingComparator:^NSComparisonResult(NSString *a,NSString *b){int order=strcmp(a.UTF8String,b.UTF8String);return order<0?NSOrderedAscending:order>0?NSOrderedDescending:NSOrderedSame;}];
    NSString *path=DWTyped(loaded[@"path"],NSString.class)?:self.configPath;NSArray<NSString *> *left=[self refreshBindings],*all=[problems arrayByAddingObjectsFromArray:left];
    for(NSArray<NSString *> *lines in @[problems,file,left])for(NSString *line in lines)fprintf(stderr,"%s\n",line.UTF8String);
    NSString *note=all.count?summary(problems.count?[@"Config " stringByAppendingString:(path?:@"").stringByAbbreviatingWithTildeInPath]:@"Bindings",all):nil;
    self.configNote=problems.count?note:nil;self.statusText=note?:[self restingStatus];
    if(!self.configWatcher){__weak Desktop *weak=self;self.configWatcher=[[DWConfigWatcher alloc]initWithChanged:^{[weak loadConfig:NO];}];}
    [self.configWatcher watch:path];[self render];
}
// One upstream Request line from a client in, one upstream Reply line out, on the main
// queue. Every refusal is an {"Err":…} line; an answer is the controller's own bytes.
// Before the canvas opens there is no active output and the controller says so itself;
// after Return to desktop the shell is inert, and a failed load must not take changes.
// The controller answers Subscribe with a subscribe effect carrying the current
// State event: the connection is then kept, and that line follows the ack.
- (NSData *)ipcLine:(NSData *)line subscribe:(BOOL *)subscribe event:(NSData *__autoreleasing *)event deferred:(void (^)(NSData *))deferred {
    if(self.cleaning)return ipcError(@"the canvas is closed");
    if(self.startupError)return ipcError(self.startupError);
    // A request that arrives during a sizing action's transaction is the controller's to answer, as an action is.
    id request=[NSJSONSerialization JSONObjectWithData:line options:NSJSONReadingFragmentsAllowed error:nil];
    if([self nativeUnavailable]){
        // Keep inspection/subscription and quitting available, but refuse scene
        // mutations rather than answer success while no native frame can apply.
        NSDictionary *object=DWTyped(request,NSDictionary.class);
        BOOL read=[request isEqual:@"State"]||[request isEqual:@"DebugCounters"]||[request isEqual:@"Subscribe"]||object[@"Layout"];
        BOOL debug=self.debugPointer&&(DWTyped(object[@"DebugNative"],NSDictionary.class)||DWTyped(object[@"DebugCapture"],NSDictionary.class));
        BOOL quit=[object[@"Action"]isEqual:@"quit"];
        if(!read&&!debug&&!quit)return ipcError(@"native presentation is restoring or reconnecting; retry when ready");
    }
    if(self.screenshotBusy&&DWTyped(DWTyped(request,NSDictionary.class)[@"Screenshot"],NSDictionary.class))return ipcError(@"another screenshot is preparing");
    // Without --debug-pointer the line goes on to the controller, which knows no such request and refuses it.
    if(self.debugPointer&&DWTyped(DWTyped(request,NSDictionary.class)[@"DebugPointer"],NSDictionary.class))return [self debugPointer:DWTyped(request,NSDictionary.class)[@"DebugPointer"]];
    if(self.debugPointer&&self.native&&DWTyped(DWTyped(request,NSDictionary.class)[@"DebugDecoration"],NSDictionary.class))return [self debugDecoration:DWTyped(request,NSDictionary.class)[@"DebugDecoration"]];
    // {"DebugNative":{}} with --debug-pointer under native presentation: what was sent to the helper and what the helper says it holds.
    if(self.debugPointer&&self.native&&DWTyped(DWTyped(request,NSDictionary.class)[@"DebugNative"],NSDictionary.class))return [self.native debug:DWTyped(request,NSDictionary.class)[@"DebugNative"]];
    if(self.debugPointer&&DWTyped(DWTyped(request,NSDictionary.class)[@"DebugCapture"],NSDictionary.class))return [self debugCapture:DWTyped(request,NSDictionary.class)[@"DebugCapture"]];
    NSDictionary *command=request?@{@"op":@"ipc",@"output":[self viewOutput]?:NSNull.null,@"request":request,@"pointer":pointJSON(pointer())}:nil;
    if(!command||![NSJSONSerialization isValidJSONObject:command])return ipcError(@"invalid request");
    NSString *status=self.statusText;NSData *raw=nil;NSDictionary *data=[self call:command raw:&raw];
    // Screenshot is answered in two steps: the controller's reply is null and names the
    // capture as an effect, the compositor renders it offscreen and writes the PNG, and
    // what screenshot_result returns for the outcome is the client's reply.
    NSDictionary *capture=nil;if(data&&!DWTyped(data[@"reply"],NSDictionary.class))for(id effect in asArray(data[@"effects"]))if([DWTyped(DWTyped(effect,NSDictionary.class)[@"op"],NSString.class)isEqual:@"screenshot"])capture=effect;
    if(capture){
        self.screenshotBusy=YES;NSDictionary *snapshot=[self call:@{@"op":@"snapshot"}];
        [self prepareScreenshot:capture completed:^(NSString *preparation){
            if(self.cleaning){self.exportSources=nil;self.exportAttachments=nil;self.exportOrdering=nil;self.screenshotBusy=NO;deferred(ipcError(@"screenshot cancelled during shutdown"));return;}
            void (^finish)(NSDictionary *)=^(NSDictionary *rendered){
                self.exportSources=nil;self.exportAttachments=nil;self.exportOrdering=nil;self.screenshotBusy=NO;
                if(self.cleaning){deferred(ipcError(@"screenshot cancelled during shutdown"));return;}
                NSMutableDictionary *result=[rendered mutableCopy];result[@"op"]=@"screenshot_result";
                NSData *response=nil;NSDictionary *answered=[self call:result raw:&response];
                if(!DWTyped(answered[@"reply"],NSDictionary.class)){NSString *error=answered?@"invalid controller reply":self.statusText?:@"controller error";self.statusText=status;deferred(ipcError(error));return;}
                [self applyReply:data];
                deferred(jsonMember(jsonMember(response,"data"),"reply")?:[NSJSONSerialization dataWithJSONObject:answered[@"reply"] options:NSJSONWritingWithoutEscapingSlashes error:nil]);
            };
            DWCanvasRenderer *renderer=[self canvasRenderer];
            if(preparation||!renderer)finish(@{@"error":preparation?:@"no renderer available for capture"});
            else [renderer screenshot:capture snapshot:snapshot completed:finish];
        }];
        return nil;
    }
    // A controller-level refusal still answers the client and leaves the resting status alone.
    if(!DWTyped(data[@"reply"],NSDictionary.class)){NSString *error=data?@"invalid controller reply":self.statusText?:@"controller error";self.statusText=status;return ipcError(error);}
    [self applyReply:data];
    for(id effect in asArray(data[@"effects"])){NSString *first=DWTyped(DWTyped(effect,NSDictionary.class)[@"line"],NSString.class);if([DWTyped(effect,NSDictionary.class)[@"op"]isEqual:@"subscribe"]&&first){*subscribe=YES;*event=[first dataUsingEncoding:NSUTF8StringEncoding];}}
    // That snapshot is the current State. The broadcast is brought up to it before the connection joins:
    // earlier subscribers get a change not yet sent to them, and the new one is not sent its snapshot twice.
    if(*subscribe)[self broadcastState];
    return jsonMember(jsonMember(raw,"data"),"reply")?:[NSJSONSerialization dataWithJSONObject:data[@"reply"] options:NSJSONWritingWithoutEscapingSlashes error:nil];
}
// --debug-pointer, which needs --only-pid: a press, a drag and a release on a managed window, for a test that cannot move the pointer.
// Scoped handler exercise only: the read-only probe returns the actual AX green
// control projected through fresh native bounds. A click calls the native bridge
// directly, posts no event and is not evidence of WindowServer input delivery.
- (NSData *)debugDecoration:(NSDictionary *)request {
    if(!self.scope||self.native.ended)return ipcError(@"DebugDecoration needs a live --native-helper and an explicit --only-pid scope");
    NSString *phase=DWTyped(request[@"phase"],NSString.class),*action=DWTyped(request[@"action"],NSString.class)?:@"fullscreen";
    if(![@[@"probe",@"click"]containsObject:phase]||![@[@"fullscreen",@"fit"]containsObject:action])return ipcError(@"DebugDecoration needs phase probe or click and action fullscreen or fit");
    NSNumber *logical=DWTyped(request[@"window"],NSNumber.class);if(!logical)return ipcError(@"DebugDecoration needs a window id");
    LiveSource *source=self.sources[logical];if(!source||source.detached||!DWInScope(self.scope,source.router.pid))return ipcError(@"DebugDecoration needs an exact bound source in the scope");
    [self refreshNativeButtons:source];
    if(!source.nativeButtons)return [NSJSONSerialization dataWithJSONObject:@{@"Ok":@{@"DebugDecoration":@{@"ready":@NO}}} options:0 error:nil];
    NSDictionary *info=windowInfo(source.router.wid);CGRect displayed=CGRectZero,own=CGRectZero;
    if(!info[(id)kCGWindowBounds]||!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)info[(id)kCGWindowBounds],&displayed)||!DWNativeBounds(source.router.wid,&own))return ipcError(@"DebugDecoration bounds are unavailable");
    NSDictionary *button=[asArray(source.nativeButtons[@"buttons"])firstObject];if(!button)return ipcError(@"this source exposes no enabled native green control");
    CGRect local=DWRectFromJSON(button);CGPoint point=CGPointMake(displayed.origin.x+CGRectGetMidX(local)*displayed.size.width/own.size.width,displayed.origin.y+CGRectGetMidY(local)*displayed.size.height/own.size.height);
    if(![self nativeGreen:source at:point])return [NSJSONSerialization dataWithJSONObject:@{@"Ok":@{@"DebugDecoration":@{@"ready":@NO}}} options:0 error:nil];
    NSNumber *output=nil;NSDictionary *hit=nil;for(DesktopView *view in self.views)if(CGRectContainsPoint(view.globalBounds,point)){output=[view outputAt:point];if(output)hit=[view hit:point output:output];break;}
    BOOL eligible=[hit[@"window"]isEqual:source.logical]&&![hit[@"pick"]boolValue]&&![hit[@"widget"]boolValue]&&[self nativeSource:source.router.wid at:point]==source;
    if(!eligible)return [NSJSONSerialization dataWithJSONObject:@{@"Ok":@{@"DebugDecoration":@{@"ready":@NO,@"screen":@[@(point.x),@(point.y)],@"output":output?:NSNull.null,@"canvas_hit":hit?:NSNull.null}}} options:0 error:nil];
    if([phase isEqual:@"click"]){
        if(self.nativeGestureView||self.nativeScrollView)return ipcError(@"another native input sequence is active");
        CGEventRef down=CGEventCreateMouseEvent(source.router.eventSource,kCGEventLeftMouseDown,point,kCGMouseButtonLeft),up=CGEventCreateMouseEvent(source.router.eventSource,kCGEventLeftMouseUp,point,kCGMouseButtonLeft);
        if(!down||!up){if(down)CFRelease(down);if(up)CFRelease(up);return ipcError(@"DebugDecoration could not create its private handler events");}
        CGEventFlags flags=[action isEqual:@"fit"]?kCGEventFlagMaskAlternate:0;
        for(int i=0;i<2;i++){CGEventRef event=i?up:down;CGEventSetFlags(event,flags);CGEventSetIntegerValueField(event,kCGMouseEventWindowUnderMousePointer,source.router.wid);CGEventSetIntegerValueField(event,kCGMouseEventWindowUnderMousePointerThatCanHandleThisEvent,source.router.wid);}
        BOOL consumed=[self nativeInput:kCGEventLeftMouseDown event:down],taken=consumed&&self.nativeDecorationPress!=nil;
        BOOL released=taken&&[self nativeInput:kCGEventLeftMouseUp event:up];
        NSString *why=nil;if(!taken||!released){NSMutableArray *grabs=[NSMutableArray array];for(DesktopView *view in self.views)[grabs addObject:@(view.gesture)];NSEvent *made=[NSEvent eventWithCGEvent:down];CGPoint after=CGEventGetLocation(down);
            why=[NSString stringWithFormat:@"the native bridge refused the green-control button pair (consumed=%d captured=%d released=%d wid=%lld type=%lu button=%lld flags=%lx point=%g,%g grabs=%@ green=%d source=%d inactive=%d)",consumed,taken,released,(long long)CGEventGetIntegerValueField(down,kCGMouseEventWindowUnderMousePointerThatCanHandleThisEvent),(unsigned long)made.type,(long long)CGEventGetIntegerValueField(down,kCGMouseEventButtonNumber),(unsigned long)made.modifierFlags,after.x,after.y,grabs,[self nativeGreen:source at:after],[self nativeSource:source.router.wid at:after]==source,self.sessionInactive];}
        CFRelease(down);CFRelease(up);if(why){[self cancelNativeInput];return ipcError(why);}
    }
    return [NSJSONSerialization dataWithJSONObject:@{@"Ok":@{@"DebugDecoration":@{@"ready":@YES,@"screen":@[@(point.x),@(point.y)],@"window":source.logical,@"identity":source.identity,@"native_buttons":source.nativeButtons,@"handler_only":@YES}}} options:NSJSONWritingWithoutEscapingSlashes error:nil];
}
// {"DebugPointer":{"phase":"probe"|"down"|"drag"|"up","window":ID,"at":[fx,fy],"offset":[ox,oy],"button":"left"|"right"|"middle",
// "modifiers":["alt","shift","ctrl","super"],"to":[dx,dy]}}.
// down: the point is that fraction of the window's placement on its output, plus `offset` screen points when one is given, which is
// how a point of the resize border just outside the frame is named. `button` (left when absent) and `modifiers` are the event's.
// drag: needs a press that is down; the point is where that press went down plus `to` screen points (a fraction of a tile that is
// changing size names no steady point), and it must be on the canvas panel. up: with `window` and `at`, the release goes to that
// fraction of the window's placement as it is now; without them, to where the press last was, which is how a drag ends and the only
// way to release over a window that has closed.
// Nothing is posted anywhere and the pointer stays where it is: an NSEvent of the matching type is made and handed to the view's own
// -mouseDown:, -mouseDragged: or -mouseUp: (the right and middle buttons' equivalents for those), so everything a person's press,
// drag and release run from there on runs: the binding lookup, the controller's focus request, the hold for native focus, the
// forward to the window, a window drag, a resize grab with every size it asks, the release. Those handlers read the event's button
// number, modifiers, location and time, all of which the made event carries; its CGEvent is read only where a press is forwarded to
// a window. What this does not exercise is the window server delivering a click or a drag to the panel. A point that is clipped,
// off the panel or under another window is refused, never moved. `probe` only answers where the point is and what is under it.
- (void)injected:(DesktopView *)view phase:(int)phase {
    static const NSEventType types[3][3]={{NSEventTypeLeftMouseDown,NSEventTypeRightMouseDown,NSEventTypeOtherMouseDown},{NSEventTypeLeftMouseDragged,NSEventTypeRightMouseDragged,NSEventTypeOtherMouseDragged},{NSEventTypeLeftMouseUp,NSEventTypeRightMouseUp,NSEventTypeOtherMouseUp}};
    NSInteger b=view.injectedButton;CGPoint s=view.injectedPoint;
    NSEvent *e=[NSEvent mouseEventWithType:types[phase][b] location:[view convertPoint:CGPointMake(s.x-view.globalBounds.origin.x,s.y-view.globalBounds.origin.y) toView:nil] modifierFlags:view.injectedFlags timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:view.window.windowNumber context:nil eventNumber:0 clickCount:1 pressure:phase==2?0:1];
    // +mouseEventWithType: has no button parameter and numbers every event it makes 0, a right or middle one too, where the event of a
    // real right or middle button says 1 or 2 and the handlers go by that number. So the event's own Quartz event is copied, given the
    // number its type means, and made an NSEvent again: still posted nowhere, with the same window, location, modifiers and time.
    if(b&&e.buttonNumber!=b){CGEventRef cg=e.CGEvent?CGEventCreateCopy(e.CGEvent):NULL;if(cg){CGEventSetIntegerValueField(cg,kCGMouseEventButtonNumber,b);NSEvent *numbered=[NSEvent eventWithCGEvent:cg];CFRelease(cg);if(numbered)e=numbered;}}
    if(phase==0){if(b==0)[view mouseDown:e];else if(b==1)[view rightMouseDown:e];else [view otherMouseDown:e];}
    else if(phase==1){if(b==0)[view mouseDragged:e];else if(b==1)[view rightMouseDragged:e];else [view otherMouseDragged:e];}
    else{if(b==0)[view mouseUp:e];else if(b==1)[view rightMouseUp:e];else [view otherMouseUp:e];}
}
// A press its test never released is let go where it last was, five seconds after its last event, with the button it went down with.
- (void)armInjected:(DesktopView *)view {
    [view.injectedTimer invalidate];__weak DesktopView *weak=view;__weak Desktop *desktop=self;
    view.injectedTimer=[NSTimer timerWithTimeInterval:5 repeats:NO block:^(NSTimer *timer){(void)timer;DesktopView *v=weak;if(!v.injected)return;v.injected=NO;v.injectedTimer=nil;[desktop injected:v phase:2];}];
    [NSRunLoop.mainRunLoop addTimer:view.injectedTimer forMode:NSRunLoopCommonModes];
}
- (NSData *)debugCapture:(NSDictionary *)request {
    NSNumber *window=DWTyped(request[@"window"],NSNumber.class);if(!window)return ipcError(@"DebugCapture needs a window id");
    LiveSource *source=self.sources[window];NSString *phase=DWTyped(request[@"phase"],NSString.class);
    if(!source||source.detached||!self.scope||!DWInScope(self.scope,source.router.pid)||sourceGone(source,windowInfo(source.router.wid)))return ipcError(@"DebugCapture requires a currently bound capture from --only-pid");
    // A native replica can report its capture lifecycle, but interrupting it
    // would change representation during an ownership transfer. Status is only
    // a diagnostic snapshot, never native placement or input authorization.
    if(self.native&&![phase isEqual:@"status"])return ipcError(@"Native replica DebugCapture is read-only; use phase status");
    if([phase isEqual:@"interrupt"]){
        if(!source.stream)return ipcError(@"that window has no active capture stream");
        [self stopCapture:source];[source captureFailed:[NSError errorWithDomain:SCStreamErrorDomain code:SCStreamErrorSystemStoppedStream userInfo:@{NSLocalizedDescriptionKey:@"Scoped diagnostic interrupted this capture stream"}]];
    }else if(![phase isEqual:@"status"])return ipcError(@"DebugCapture needs phase status or interrupt");
    NSMutableArray *replicas=[NSMutableArray array];for(NSDictionary *output in self.pointerOutputs)if([self.nativeViews replica:source.logical output:output[@"id"]])[replicas addObject:output[@"id"]];
    return [NSJSONSerialization dataWithJSONObject:@{@"Ok":@{@"DebugCapture":@{@"window":source.logical,@"identity":source.identity,@"native_family":source.nativeFamily?:NSNull.null,@"stream":@(source.stream!=nil),@"shareable":@(source.window!=nil),@"pixels":@(source.pixels!=NULL),@"capture_restarted":@(source.restarted),@"captured_frames":@(source.frames),@"session_inactive":@(self.sessionInactive),@"capture_updating":@(source.captureUpdating),@"native_replica":@(source.nativeReplica),@"replica_wanted":@(source.replicaWanted),@"described_replica_outputs":replicas,@"screen_capture_access":@(CGPreflightScreenCaptureAccess()),@"recovering":@(source.captureRecovering),@"failures":@(source.captureFailures),@"accepted":@(source.accepted),@"retry_in":@(MAX(0,source.captureRetryAt-CACurrentMediaTime())),@"reading":@(self.captureRecoveryReading),@"error":source.error?:NSNull.null}}} options:0 error:nil];
}
- (NSData *)debugPointer:(NSDictionary *)request {
    NSString *phase=DWTyped(request[@"phase"],NSString.class),*status=self.statusText;NSNumber *window=DWTyped(request[@"window"],NSNumber.class);NSArray *at=asArray(request[@"at"]),*offset=request[@"offset"]?asArray(request[@"offset"]):nil,*to=asArray(request[@"to"]);
    double fx=at.count==2?[DWTyped(at[0],NSNumber.class)?:@(-1) doubleValue]:-1,fy=at.count==2?[DWTyped(at[1],NSNumber.class)?:@(-1) doubleValue]:-1;
    BOOL up=[phase isEqual:@"up"],drag=[phase isEqual:@"drag"],placed=window&&fx>=0&&fx<=1&&fy>=0&&fy<=1;
    if(![@[@"probe",@"down",@"drag",@"up"]containsObject:phase]||(!drag&&!up&&!placed)||(up&&(window||at.count)&&!placed))return ipcError(@"DebugPointer needs phase probe, down, drag or up; for probe and down a window id and at [fx, fy] within 0 and 1; for drag to [dx, dy]");
    if(drag||(up&&!placed)){
        DesktopView *view=nil;for(DesktopView *v in self.views)if(v.injected)view=v;
        if(!view)return ipcError(@"no DebugPointer press is down");
        if(drag){
            if(to.count!=2||!DWTyped(to[0],NSNumber.class)||!DWTyped(to[1],NSNumber.class))return ipcError(@"DebugPointer drag needs to [dx, dy], screen points from where the press went down");
            CGPoint s=CGPointMake(view.injectedStart.x+[to[0]doubleValue],view.injectedStart.y+[to[1]doubleValue]);
            if(!CGRectContainsPoint(view.globalBounds,s))return ipcError(@"that point is not on the canvas");
            view.injectedPoint=s;[self injected:view phase:1];[self armInjected:view];
        }else{[view.injectedTimer invalidate];view.injectedTimer=nil;view.injected=NO;[self injected:view phase:2];}
        return [NSJSONSerialization dataWithJSONObject:@{@"Ok":@{@"DebugPointer":@{@"screen":@[@(view.injectedPoint.x),@(view.injectedPoint.y)]}}} options:NSJSONWritingWithoutEscapingSlashes error:nil];
    }
    NSString *named=DWTyped(request[@"button"],NSString.class)?:@"left";NSUInteger button=[@[@"left",@"right",@"middle"]indexOfObject:named];NSEventModifierFlags flags=0;
    if(button==NSNotFound||(request[@"button"]&&!DWTyped(request[@"button"],NSString.class)))return ipcError(@"DebugPointer button is left, right or middle");
    for(id name in asArray(request[@"modifiers"])){NSNumber *flag=@{@"alt":@(NSEventModifierFlagOption),@"shift":@(NSEventModifierFlagShift),@"ctrl":@(NSEventModifierFlagControl),@"super":@(NSEventModifierFlagCommand)}[DWTyped(name,NSString.class)?:@""];if(!flag)return ipcError(@"DebugPointer modifiers are alt, shift, ctrl and super");flags|=flag.unsignedIntegerValue;}
    if(offset&&(offset.count!=2||!DWTyped(offset[0],NSNumber.class)||!DWTyped(offset[1],NSNumber.class)))return ipcError(@"DebugPointer offset is [ox, oy], screen points");
    NSDictionary *placement=nil;for(NSDictionary *p in [self call:@{@"op":@"snapshot"}][@"placements"])if([p[@"window"]isEqual:window]){placement=p;break;}
    DesktopView *view=nil;for(DesktopView *v in self.views)if([v.outputs containsObject:placement[@"output"]])view=v;
    if(!placement||!view)return ipcError(@"that window has no placement on an output");
    CGRect rect=DWRectFromJSON(placement[@"screen_rect"]),clip=DWRectFromJSON(placement[@"clip_rect"]);CGPoint s=CGPointMake(rect.origin.x+fx*rect.size.width+(offset?[offset[0]doubleValue]:0),rect.origin.y+fy*rect.size.height+(offset?[offset[1]doubleValue]:0));
    if((!offset&&!CGRectContainsPoint(clip,s))||!CGRectContainsPoint(view.globalBounds,s))return ipcError(@"that point of the window is not on the canvas");
    // A release is not asked what lies under it: it goes to the same fraction of the window's placement as it is now, whatever has come over that point since.
    NSDictionary *hit=up?nil:DWTyped([view hit:s output:placement[@"output"]],NSDictionary.class);
    // A point named by an offset is one of the window's resize border, or of the window itself: the controller says which.
    NSDictionary *border=!up&&offset&&!hit?DWTyped([view pointerCommand:@{@"op":@"resize_border",@"output":placement[@"output"],@"screen":pointJSON(s)} quiet:YES][@"border"],NSDictionary.class):nil;self.statusText=status;
    if(!up&&![hit[@"window"]isEqual:window]&&![border[@"window"]isEqual:window])return ipcError(hit?[NSString stringWithFormat:@"window #%@ is under that point",hit[@"window"]]:border?[NSString stringWithFormat:@"the resize border of window #%@ is under that point",border[@"window"]]:@"no window takes a press at that point");
    NSData *reply=[NSJSONSerialization dataWithJSONObject:@{@"Ok":@{@"DebugPointer":@{@"screen":@[@(s.x),@(s.y)],@"screen_rect":placement[@"screen_rect"],@"clip_rect":placement[@"clip_rect"],@"hit":up||!hit?NSNull.null:hit[@"window"],@"border":border?border[@"edges"]:NSNull.null}}} options:NSJSONWritingWithoutEscapingSlashes error:nil];
    if([phase isEqual:@"probe"])return reply;
    if(up?!view.injected:(view.gesture||view.injected))return ipcError(up?@"no DebugPointer press is down":@"a press is already down");
    [view.injectedTimer invalidate];view.injectedTimer=nil;
    if(up){view.injected=NO;view.injectedPoint=s;[self injected:view phase:2];return reply;}
    view.injected=YES;view.injectedPoint=view.injectedStart=s;view.injectedButton=(NSInteger)button;view.injectedFlags=flags;[self injected:view phase:0];
    [self armInjected:view];
    return reply;
}
// Normal runs only: main() starts the server once and stops it before the final cleanup.
- (BOOL)startIPC:(NSString *)path {
    __weak Desktop *weak=self;NSString *error=nil;
    self.ipc=[DWIPCServer serverAtPath:path asyncHandler:^(NSData *line,DWIPCReply completed){
        Desktop *desktop=weak;if(!desktop){completed(nil,NO,nil);return;}
        BOOL subscribe=NO;NSData *event=nil,*reply=[desktop ipcLine:line subscribe:&subscribe event:&event deferred:^(NSData *response){completed(response,NO,nil);}];
        if(reply)completed(reply,subscribe,event);
    } error:&error];
    if(!self.ipc){fprintf(stderr,"Infinify: cannot start IPC: %s (%s)\n",error.UTF8String,path.fileSystemRepresentation);return NO;}
    self.socketPath=path;return YES;
}
@end
