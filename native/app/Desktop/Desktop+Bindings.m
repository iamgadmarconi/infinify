// SPDX-License-Identifier: GPL-3.0-or-later
// Split from native/desktop/main.m at 37b27b1, moved verbatim.
// Desktop bindings: the exit key, global hot keys, mouse bindings, hot corners and the binding refresh.
#import "Desktop+Private.h"
#import "DWInputSources.h"
#import "DWDebugTrace.h"
#import "DWNativeFocus.h"
#import "DWWindowEvents.h"
#import "DWGeometryJSON.h"
#import "DesktopPanel.h"
#import "DWChildProcess.h"
static OSStatus exitKey(EventHandlerCallRef next,EventRef event,void *context) { (void)next;EventHotKeyID key={0};GetEventParameter(event,kEventParamDirectObject,typeEventHotKeyID,NULL,sizeof(key),NULL,&key);if(key.signature!='Infi'||key.id!=1)return eventNotHandledErr;[(__bridge Desktop *)context quit:nil];return noErr; }
// ⌃⌥Esc is the shell's own exit chord until a config binding claims it.
static NSNumber *exitChord(void) { return DWChord(53,controlKey|optionKey); }
@implementation Desktop (Bindings)
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
@end
