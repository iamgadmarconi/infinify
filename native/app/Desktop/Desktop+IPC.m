// SPDX-License-Identifier: GPL-3.0-or-later
// Split from native/desktop/main.m at 37b27b1, moved verbatim.
// Desktop IPC and debug requests: request lines, state broadcast, the debug decoration, capture and pointer probes.
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
@implementation Desktop (IPC)
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
    // {"DebugInput":{}} under INFINIFY_DEBUG: every button state the gesture code could read, and the refusal it would give a new touch right now.
    if(DWDebugTrace()&&DWTyped(DWTyped(request,NSDictionary.class)[@"DebugInput"],NSDictionary.class))return [self debugInput];
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
// Read-only, and served only when INFINIFY_DEBUG is set: the sources of "a mouse button is down", for a test that cannot move a trackpad.
- (NSData *)debugInput {
    return [NSJSONSerialization dataWithJSONObject:@{@"Ok":@{@"DebugInput":@{@"pressed_mouse_buttons":@(NSEvent.pressedMouseButtons),@"hid_buttons":@(DWPhysicalMouseButtons()),
        @"combined_left":@(CGEventSourceButtonState(kCGEventSourceStateCombinedSessionState,kCGMouseButtonLeft)),@"native_press":@(self.globalTrackpad.hasNativeMousePress),
        @"global_tap_running":@(self.globalTrackpad.running),@"refusal":[self buttonRefusal]?:NSNull.null}}} options:NSJSONWritingWithoutEscapingSlashes error:nil];
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
