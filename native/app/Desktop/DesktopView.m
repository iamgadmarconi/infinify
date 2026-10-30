// SPDX-License-Identifier: GPL-3.0-or-later
// A canvas panel's view: pointer, press, scroll and touch handling over one panel's outputs.
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
@implementation DesktopView
- (BOOL)acceptsFirstResponder { return NO; }
// A real AppKit dragging session may ask us to bring its displayed destination
// to this output. The canvas never accepts the data or impersonates the target.
// Once the native site is in place, WindowServer/AppKit must rediscover that
// destination; its ordinary callbacks own types, operations and completion.
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender { return [self draggingUpdated:sender]; }
- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)sender {
    if(sender.draggingDestinationWindow!=self.window||!self.desktop.native)return NSDragOperationNone;
    NSPoint point=[self convertPoint:sender.draggingLocation fromView:nil];
    [self.desktop cancelNativeHoverForWindow:nil];
    [self.desktop requestNativeOwnershipAt:CGPointMake(point.x+self.globalBounds.origin.x,point.y+self.globalBounds.origin.y) view:self];
    return NSDragOperationNone;
}
- (BOOL)wantsPeriodicDraggingUpdates { return YES; }
- (BOOL)prepareForDragOperation:(id<NSDraggingInfo>)sender { (void)sender;return NO; }
- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender { (void)sender;return NO; }
- (CGPoint)screenPoint:(NSEvent *)e { if(self.nativePointValid)return self.nativePoint;CGPoint p=[self convertPoint:e.locationInWindow fromView:nil]; return CGPointMake(p.x+self.globalBounds.origin.x,p.y+self.globalBounds.origin.y); }
- (NSNumber *)outputAt:(CGPoint)p {
    for(NSDictionary *o in [self.desktop call:@{@"op":@"snapshot"}][@"outputs"])if([self.outputs containsObject:o[@"id"]]&&CGRectContainsPoint(DWRectFromJSON(o[@"screen_bounds"]),p))return o[@"id"];
    return nil;
}
- (NSNumber *)actionOutput { return [self.outputs containsObject:self.lastOutput]?self.lastOutput:self.outputs.firstObject; }
// One compositor layer per output draws the background, the outlines of
// the other outputs, the windows and the stand-ins from the snapshot: widgets below,
// screen-pinned windows above at their own size, each at the controller's opacity (a
// rule's, msg opacity's, or [decorations]').
- (void)compose:(NSDictionary *)snapshot {
    DWCanvasRenderer *canvas=[self.desktop canvasRenderer];CGPoint origin=self.globalBounds.origin;[CATransaction begin];[CATransaction setDisableActions:YES];
    CGFloat scale=self.window.backingScaleFactor,largest=scale;for(DesktopView *view in self.desktop.views)largest=MAX(largest,view.window.backingScaleFactor);
    [canvas render:snapshot outputs:self.outputs host:self.layer origin:origin scale:scale decorationScale:(NSInteger)ceil(largest)];
    // New or moved output layers commit their picture with their geometry; the frame timer serves later redraws.
    [canvas flushDescribed];
    [CATransaction commit];
}
- (void)render:(NSDictionary *)snapshot {
    [self compose:snapshot];[self refreshCursor];
}
// A held root press is authorized by its own completed focus request, not by
// the disappearance of any pending request. ObserveFocus may replace op/id while
// retaining the same observed binding, so only the result uses full effect equality.
static BOOL DWCapturedRootFocusCurrent(NSDictionary *intent,NSDictionary *focus,pid_t foreground,BOOL logicalOnly) {
    NSNumber *deadline=DWTyped(intent[@"focus_deadline"],NSNumber.class);double end=deadline.doubleValue;
    if(!deadline||!isfinite(end)||CACurrentMediaTime()>=end)return NO;
    // --no-native-focus deliberately retains the preexisting logical click path.
    if(logicalOnly)return YES;
    focus=DWTyped(focus,NSDictionary.class);
    NSDictionary *effect=DWTyped(intent[@"focus_effect"],NSDictionary.class),*result=DWTyped(focus[@"last_result"],NSDictionary.class),*observed=DWTyped(focus[@"observed_native"],NSDictionary.class);
    if(![effect[@"op"]isEqual:@"focus_native_window"]||!DWTyped(effect[@"effect_id"],NSNumber.class)
        ||![focus[@"intent"]isEqual:intent[@"window"]]
        ||DWTyped(focus[@"pending_effect"],NSDictionary.class)||![DWTyped(result[@"success"],NSNumber.class)isEqual:@YES]
        ||![result[@"effect"]isEqual:effect])return NO;
    for(NSString *key in @[@"window",@"generation"])
        if(![effect[key]isEqual:intent[key]]||![observed[key]isEqual:intent[key]])return NO;
    NSDictionary *identity=intent[@"root_identity"]?:intent[@"identity"];
    return boundIdentity(effect[@"identity"],identity)&&boundIdentity(observed[@"identity"],identity)
        &&foreground==[identity[@"pid"]intValue];
}
// A provisional click recipient, captured before raising/focusing the window.
// It prevents delayed delivery from changing recipients; posting still requires
// the current hit, binding and native ancestry checks in -forwardCaptured:.
- (NSDictionary *)inputIntentForHit:(NSDictionary *)hit output:(NSNumber *)output {
    NSNumber *windowID=liveHit(hit);if(!windowID)return nil;
    LiveSource *source=self.desktop.sources[windowID];if(!DWCapturedInputAvailable(source)||!output)return nil;
    NSDictionary *binding=nil;for(NSDictionary *window in [self.desktop presentationSnapshot][@"windows"])if([window[@"window"]isEqual:source.logical]){binding=DWTyped(window[@"source"],NSDictionary.class);break;}
    if(!binding[@"generation"]||!boundIdentity(source.identity,binding[@"identity"])||![binding[@"observation_known"]boolValue])return nil;
    NSDictionary *member=DWTyped(hit[@"native_member"],NSDictionary.class),*identity=member?DWTyped(member[@"identity"],NSDictionary.class):source.identity;
    if(!identity||(member&&![member[@"generation"]isEqual:binding[@"generation"]]))return nil;
    return DWCapturedInputAvailable(source)?@{@"window":source.logical,@"output":output,@"generation":binding[@"generation"],@"identity":identity,@"root_identity":source.identity,@"native_member":@(member!=nil)}:nil;
}
- (NSDictionary *)hit:(CGPoint)p output:(NSNumber *)output {
    if(self.nativePointValid&&self.nativeFamilyHit)return self.nativeFamilyHit;
    // Controller input intentionally rejects placeholders. Find their geometry only
    // for the explicit dismiss action; this result never authorizes native delivery.
    NSDictionary *snapshot=[self.desktop presentationSnapshot];NSNumber *under=nil;
    BOOL inOutput=NO;for(NSDictionary *item in snapshot[@"outputs"])if([item[@"id"]isEqual:output]&&CGRectContainsPoint(DWRectFromJSON(item[@"screen_bounds"]),p))inOutput=YES;if(!inOutput)return nil;
    NSArray *tokens=[self.desktop.compositor appliedOrderForOutput:output snapshot:snapshot];
    // Stale pixels/layout cannot authorize a differently ordered replica hit.
    if(!tokens){
        if(self.desktop.routingEarlyNativeTitle&&getenv("INFINIFY_DEBUG"))fprintf(stderr,"debug: native title hit refused output=#%s point=%g,%g reason=renderer_order\n",output.description.UTF8String,p.x,p.y);
        return nil;
    }
    NSMutableDictionary *placements=[NSMutableDictionary dictionary];for(NSDictionary *placement in snapshot[@"placements"])if([placement[@"output"]isEqual:output])placements[placement[@"window"]]=placement;
    // Native replicas use exactly the renderer's described root/child order.
    // Placeholders still only authorize canvas actions, never native delivery.
    for(NSDictionary *token in [tokens reverseObjectEnumerator]){
        if(!DWTyped(token[@"window"],NSNumber.class))continue;
        NSDictionary *placement=placements[token[@"window"]];if(!placement||![placement[@"output"]isEqual:output])continue;
        NSString *key=DWTyped(token[@"key"],NSString.class);
        LiveSource *source=self.desktop.sources[placement[@"window"]];CGRect site=DWRectFromJSON(placement[@"screen_rect"]),own=CGRectZero;
        if(source.router.bounds)CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)source.router.bounds,&own);
        if(key&&source.pixels&&!source.error&&!source.detached&&(!self.desktop.native||[self.desktop.nativeViews replica:source.logical output:output])&&site.size.width>0&&site.size.height>0){
            CGPoint local=CGPointMake((p.x-site.origin.x)*own.size.width/site.size.width,(p.y-site.origin.y)*own.size.height/site.size.height);
            NSDictionary *member=key?[self.desktop.nativeFamilies hit:source.logical key:key local:local]:[self.desktop.nativeFamilies hit:source.logical local:local];
            if(member){NSMutableDictionary *context=[@{@"window":source.logical,@"local":pointJSON(local),@"native_member":member,@"generation":member[@"generation"]}mutableCopy];
                for(NSString *flag in @[@"widget",@"pinned"])if([DWTyped(placement[flag],NSNumber.class)boolValue])context[flag]=@YES;
                return context[@"widget"]||context[@"pinned"]||[placement[@"fullscreen"]boolValue]?context:DWPickHit(context,snapshot,output);
            }
        }
        if(key)continue;
        // A family-only projection has no visible root content. Only an exact
        // captured child hit above can authorize a recipient in its clip.
        if([placement[@"family_only"]boolValue]||!CGRectContainsPoint(DWRectFromJSON(placement[@"clip_rect"]),p))continue;
        if(!source){NSMutableDictionary *held=[@{@"window":placement[@"window"],@"placeholder":@YES} mutableCopy];for(NSString *flag in @[@"widget",@"pinned"])if([DWTyped(placement[flag],NSNumber.class)boolValue])held[flag]=@YES;return held[@"widget"]||held[@"pinned"]?held:DWPickHit(held,snapshot,output);}under=placement[@"window"];break;
    }
    if(!under)return nil;
    NSDictionary *reply=[self.desktop call:@{@"op":@"hit",@"output":output,@"screen":pointJSON(p)}];
    return DWControllerHit(reply[@"hit"],YES,under);
}
// A child press may activate its application, but must never raise the root:
// doing so can dismiss an application's popup or take focus from its sheet.
- (BOOL)childPressCurrent:(NSDictionary *)intent {
    if(!DWTyped(intent[@"window"],NSNumber.class)||![intent[@"native_member"]boolValue])return NO;
    Desktop *d=self.desktop;LiveSource *source=d.sources[intent[@"window"]];
    return source&&!source.detached
        &&![intent[@"identity"][@"wid"]isEqual:intent[@"root_identity"][@"wid"]]
        &&[d validateInputTarget:intent]&&DWNativeWindowBelongsToRoot(intent[@"identity"],source.identity);
}
- (BOOL)focusChildIntent:(NSDictionary *)intent {
    if(![self childPressCurrent:intent])return NO;Desktop *d=self.desktop;
    // Set canvas focus and settle the exact request logically before handing
    // any reply to the coordinator. This asserts no native root focus.
    NSDictionary *reply=[d call:@{@"op":@"focus",@"window":intent[@"window"]}],*effect=DWTyped(reply[@"effect"],NSDictionary.class);
    if(![effect[@"op"]isEqual:@"focus_native_window"]||![effect[@"window"]isEqual:intent[@"window"]]
        ||!boundIdentity(intent[@"root_identity"],DWTyped(effect[@"identity"],NSDictionary.class))||![effect[@"generation"]isEqual:intent[@"generation"]])return NO;
    NSMutableDictionary *ack=[effect mutableCopy];ack[@"op"]=@"focus_logical";NSDictionary *settled=[d call:ack];if(!settled)return NO;
    d.sceneDirty=YES;[d applyReply:settled];
    if(d.logicalFocus)return YES;
    LiveSource *source=d.sources[intent[@"window"]];NSRunningApplication *current=NSWorkspace.sharedWorkspace.frontmostApplication;
    if(current.processIdentifier==source.router.pid)return [self childPressCurrent:intent];
    NSRunningApplication *app=[NSRunningApplication runningApplicationWithProcessIdentifier:source.router.pid];
    // Validate process birth, current binding and ancestry immediately before
    // activating only this application's existing native focus/stack policy.
    if(!app||app.terminated||![self childPressCurrent:intent])return NO;
    return [app activateWithOptions:0];
}
// Whether the native focus request a click on `window` made is still unanswered.
- (BOOL)focusPending:(NSNumber *)window intent:(NSDictionary *)intent {
    if([intent[@"native_member"]boolValue]){
        if(self.desktop.logicalFocus)return NO;LiveSource *source=self.desktop.sources[window];
        if(!source||source.detached||!boundIdentity(source.identity,intent[@"root_identity"])||![birth(source.router.pid)isEqual:source.router.processBirth])return NO;
        return NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier!=source.router.pid;
    }
    id pending=[self.desktop call:@{@"op":@"snapshot"}][@"focus"][@"pending_effect"];return DWTyped(intent[@"focus_effect"],NSDictionary.class)&&[pending isEqual:intent[@"focus_effect"]];
}
// Upstream forwards the press of a click-to-focus to a client it has already focused. Here the focus is a request to another
// application that takes some tens of milliseconds, and until it has landed that application is not the active one: an
// event posted to it then is dropped by everything but a control that takes a first click (measured on a WKWebView and an
// Electron window, 2026-10-10: nothing arrived while inactive, every click did once active and key, covered or not). So
// a root press waits at most the focus coordinator's 1.5-second work budget; failure,
// supersession or expiry drops its whole unsent pair. Child activation keeps its
// existing half-second wait. Drags and release wait behind the same original press.
- (void)holdPress:(NSEvent *)e window:(NSNumber *)window intent:(NSDictionary *)intent at:(CGPoint)p output:(NSNumber *)output {
    [self deliverHeld];BOOL pending=[self focusPending:window intent:intent];
    if(!intent){self.clickWindow=nil;return;}
    CFTimeInterval now=CACurrentMediaTime();double wait=[intent[@"native_member"]boolValue]?.5:1.5;
    NSMutableDictionary *held=[intent mutableCopy];held[@"focus_deadline"]=@(now+wait);intent=held.copy;
    if(DWDebugTrace()){LiveSource *s=self.desktop.sources[window];fprintf(stderr,"debug: press #%s pid=%d app=%s frontmost=%s focus_pending=%d\n",window.description.UTF8String,(int)s.router.pid,[NSRunningApplication runningApplicationWithProcessIdentifier:s.router.pid].bundleIdentifier.UTF8String?:"?",NSWorkspace.sharedWorkspace.frontmostApplication.bundleIdentifier.UTF8String?:"?",(int)pending);}
    self.heldPress=e;self.heldWindow=window;self.heldIntent=intent;self.heldNavigate=NO;self.heldPoint=p;self.heldOutput=output;self.heldDrag=self.heldRelease=nil;self.heldReleased=NO;self.heldSince=now;
    if(!pending){[self deliverHeld];return;}
    __weak DesktopView *weak=self;self.heldTimer=[NSTimer timerWithTimeInterval:.005 repeats:YES block:^(NSTimer *timer){DesktopView *view=weak;if(!view){[timer invalidate];return;}
        if(view.heldPress&&(CACurrentMediaTime()>=[view.heldIntent[@"focus_deadline"]doubleValue]||![view focusPending:view.heldWindow intent:view.heldIntent]))[view deliverHeld];}];
    [NSRunLoop.mainRunLoop addTimer:self.heldTimer forMode:NSRunLoopCommonModes];
}
// The held press goes to its window now, then its latest drag, then its release if the button is already up. Nothing held: nothing.
- (void)deliverHeld {
    [self.heldTimer invalidate];self.heldTimer=nil;NSEvent *press=self.heldPress,*drag=self.heldDrag;if(!press)return;
    NSNumber *window=self.heldWindow,*output=self.heldOutput;NSDictionary *intent=self.heldIntent;BOOL released=self.heldReleased,navigate=self.heldNavigate;CGPoint p=self.heldPoint,d=self.heldDragPoint;NSEvent *release=self.heldRelease;
    self.heldPress=self.heldDrag=self.heldRelease=nil;self.heldWindow=self.heldOutput=nil;self.heldIntent=nil;self.heldReleased=self.heldNavigate=NO;
    BOOL child=[intent[@"native_member"]boolValue],ready=child?([self childPressCurrent:intent]&&![self focusPending:window intent:intent])
        :DWCapturedRootFocusCurrent(intent,[self.desktop call:@{@"op":@"snapshot"}][@"focus"],NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier,self.desktop.logicalFocus);
    CGEventRef cg=ready&&press.CGEvent?CGEventCreateCopy(press.CGEvent):NULL;BOOL sent=cg&&intent&&[self forward:cg at:p output:output expected:intent];if(cg)CFRelease(cg);
    if(DWDebugTrace()){LiveSource *s=self.desktop.sources[window];fprintf(stderr,"debug: press #%s delivered after %.0f ms sent=%d frontmost=%s source=%d valid=%d trusted=%d released=%d status=\"%s\"\n",window.description.UTF8String,(CACurrentMediaTime()-self.heldSince)*1000,(int)sent,NSWorkspace.sharedWorkspace.frontmostApplication.bundleIdentifier.UTF8String?:"?",s!=nil,(int)[s.router valid],(int)AXIsProcessTrusted(),(int)released,sent?"":(self.desktop.statusText?:@"").UTF8String);}
    // No initial down means no queued drag/up or completed-click navigation.
    if(!sent){self.clickWindow=nil;return;}
    if(drag){cg=CGEventCreateCopy(drag.CGEvent);[self forward:cg at:d output:output];CFRelease(cg);}
    if(released){if(release){cg=CGEventCreateCopy(release.CGEvent);BOOL posted=[self forward:cg at:[self screenPoint:release] output:output];CFRelease(cg);if(posted){self.pressedSource=nil;self.pressedTarget=nil;self.pressedTablet=NO;self.pressedTabletDevice=nil;self.pressedPointerGrab=NO;}}[self releasePressed];}
    if(released&&navigate&&!child)[self.desktop clickReleased:window output:output];
}
- (BOOL)forward:(CGEventRef)e at:(CGPoint)p output:(NSNumber *)output {
    return [self forward:e at:p output:output expected:nil];
}
- (BOOL)forward:(CGEventRef)e at:(CGPoint)p output:(NSNumber *)output expected:(NSDictionary *)expected {
    if([self.desktop.pointerGrab ownsEvent:e])return (!expected||sameInputTarget(expected,self.desktop.pointerGrab.target))&&[self.desktop forwardCapturedPointer:e screen:p];
    if([self.desktop.tablet ownsEvent:e])return (!expected||sameInputTarget(expected,[self.desktop.tablet capturedTargetForEvent:e]))&&[self.desktop forwardTabletTail:e];
    BOOL sent=[self forwardCaptured:e at:p output:output expected:expected];
    if(!sent&&!expected&&DWNativeTabletEvent(e))sent=[self.desktop forwardTabletTail:e];
    return sent;
}
- (BOOL)forwardCaptured:(CGEventRef)e at:(CGPoint)p output:(NSNumber *)output expected:(NSDictionary *)expected {
    BOOL native=self.desktop.native!=nil;
    if(self.desktop.nativeFillHandoff)return NO;
    if(self.desktop.native.ended||self.desktop.sessionInactive||self.desktop.cleaning)return NO;
    if(!e||!output)return NO;
    if(DWNativeTabletEvent(e)){
        if(!self.desktop.tablet)self.desktop.tablet=[DWNativeTabletRouter new];
        [self.desktop.tablet observeEvent:e];
        if(DWNativeTabletProximityEvent(e)&&!CGEventGetIntegerValueField(e,kCGTabletProximityEventEnterProximity))return !expected&&[self.desktop forwardTabletTail:e];
    }
    if(!AXIsProcessTrusted()){self.desktop.statusText=@"Input requires Accessibility access. Enable it in System Settings, then reopen.";return NO;}
    NSDictionary *hit=[self hit:p output:output];if(![hit isKindOfClass:NSDictionary.class]||[hit[@"pick"]boolValue])return NO;
    if(expected&&!sameInputTarget(expected,[self inputIntentForHit:hit output:output]))return NO;
    LiveSource *source=self.desktop.sources[hit[@"window"]];
    if(!DWCapturedInputAvailable(source))return NO;
    // The actual native placement gets ordinary WindowServer input. Only an
    // extra display's visible, successfully captured copy can use this route.
    if(native&&(![self.desktop.nativeViews replica:source.logical output:output]||!source.pixels||source.error||source.detached||!DWInScope(self.desktop.scope,source.router.pid)||![[self.desktop.native rootWindowFor:source.router.wid]isEqual:@(source.router.wid)]))return NO;
    // The window's frame may have changed since the poll last looked (a size request just made, a native drag): the same
    // window at its new frame is still the one to post to, as -releasePressed takes it. Its process and number are checked.
    BOOL routerCurrent=YES;
    if(!native&&source){routerCurrent=[source.router valid];if(!routerCurrent){NSDictionary *current=windowInfo(source.router.wid);
        if([birth(source.router.pid)isEqual:source.router.processBirth]&&[current[(id)kCGWindowOwnerPID]intValue]==source.router.pid&&current[(id)kCGWindowBounds])source.router.bounds=current[(id)kCGWindowBounds];
        routerCurrent=[source.router valid];}}
    if(!source||!routerCurrent)return NO;
    // Unsupported cross-source pointer capture must never retarget a held drag.
    CGEventType type=CGEventGetType(e);
    BOOL drag=type==kCGEventLeftMouseDragged||type==kCGEventRightMouseDragged||type==kCGEventOtherMouseDragged;
    BOOL up=type==kCGEventLeftMouseUp||type==kCGEventRightMouseUp||type==kCGEventOtherMouseUp;
    if((drag||(up&&self.pressedSource))&&source!=self.pressedSource)return NO;
    NSDictionary *member=DWTyped(hit[@"native_member"],NSDictionary.class);
    NSDictionary *validated=member?hit:[self.desktop call:@{@"op":@"input",@"output":output,@"screen":pointJSON(p),@"identity":source.identity}][@"hit"];
    if(![validated isKindOfClass:NSDictionary.class]||(!native&&![source.router valid]))return NO;
    CGPoint local=jsonPoint(validated[@"local"]);
    CGRect own=CGRectZero;if(!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)source.router.bounds,&own))return NO;
    NSDictionary *binding=nil;for(NSDictionary *window in [self.desktop call:@{@"op":@"snapshot"}][@"windows"])if([window[@"window"]isEqual:source.logical])binding=DWTyped(window[@"source"],NSDictionary.class);
    if(!binding[@"generation"]||!boundIdentity(source.identity,binding[@"identity"])||![binding[@"observation_known"]boolValue])return NO;
    if(member&&(![member[@"generation"]isEqual:binding[@"generation"]]||![self.desktop.nativeFamilies contains:source.logical identity:member[@"identity"] generation:binding[@"generation"] bounds:DWRectFromJSON(member[@"native_bounds"])]))return NO;
    NSMutableDictionary *target=[@{@"window":source.logical,@"output":output,@"generation":binding[@"generation"],@"identity":source.identity,@"root_identity":source.identity,@"native_bounds":DWRectJSON(own)}mutableCopy];
    if(native||member){NSDictionary *placement=nil;for(NSDictionary *item in [self.desktop presentationSnapshot][@"placements"])if([item[@"window"]isEqual:source.logical]&&[item[@"output"]isEqual:output]){placement=item;break;}CGRect site=DWRectFromJSON(placement[@"screen_rect"]);if(site.size.width>0&&site.size.height>0)target[@"motion_scale"]=pointJSON(CGPointMake(own.size.width/site.size.width,own.size.height/site.size.height));}
    if(member){target[@"identity"]=member[@"identity"];target[@"native_bounds"]=member[@"native_bounds"];target[@"native_member"]=@YES;local=jsonPoint(member[@"local"]);}
    if(expected&&!sameInputTarget(expected,target))return NO;
    if(self.pressedTarget&&(drag||up)&&![self.pressedTarget[@"identity"]isEqual:target[@"identity"]])return NO;
    if(!DWCapturedInputAvailable(source))return NO;
    if(expected&&![expected[@"native_member"]boolValue]
        &&!DWCapturedRootFocusCurrent(expected,[self.desktop call:@{@"op":@"snapshot"}][@"focus"],NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier,self.desktop.logicalFocus))return NO;
    BOOL sent;
    if(DWNativeTabletEvent(e)){__weak Desktop *weak=self.desktop;sent=[self.desktop.tablet forwardEvent:e target:target local:local validate:^BOOL(NSDictionary *value){return [weak validateInputTarget:value];} post:^BOOL(CGEventRef packet,NSDictionary *value,CGPoint point){return [weak postInput:packet target:value local:point];}];}
    else if(native||member)sent=[self.desktop validateInputTarget:target]&&[self.desktop postInput:e target:target local:local];
    else sent=[source.router post:e at:local];
    if(sent&&(type==kCGEventLeftMouseDown||type==kCGEventRightMouseDown||type==kCGEventOtherMouseDown)){self.pressedSource=source;self.pressedTarget=target.copy;self.pressedTablet=DWNativeTabletEvent(e);self.pressedTabletDevice=self.pressedTablet?@(CGEventGetIntegerValueField(e,DWNativeTabletProximityEvent(e)?kCGTabletProximityEventDeviceID:kCGTabletEventDeviceID)):nil;self.pressedLocal=local;self.pressedButton=CGEventGetIntegerValueField(e,kCGMouseEventButtonNumber);}
    if(sent&&(native||member)&&!DWNativeTabletEvent(e)&&(type==kCGEventLeftMouseDown||type==kCGEventRightMouseDown||type==kCGEventOtherMouseDown)){
        if(!self.desktop.pointerGrab)self.desktop.pointerGrab=[DWNativePointerGrab new];self.pressedPointerGrab=[self.desktop.pointerGrab admitEvent:e target:target local:local];
    }
    if(sent&&self.pressedSource==source)self.pressedLocal=local;
    return sent;
}
// Upstream's resize grab, begun by a press bound to resize-window or resize-window-snapped, or by a left press on the resize border
// (`edges` is then the border's; nil lets the controller take them from where in the window the press fell, upstream's
// edges_from_position). In a normal run the grab is a native readback size transaction (docs/crates/desktop/NATIVE_RESIZE.md): each size
// the drag asks is asked of the real window, and the canvas shows the size the window then has.
// Upstream raises and focuses the window first (raise_and_focus, then start_compositor_resize). A resize that begins carries that
// focus request in its reply. A begin that is turned away, by the resize path before the controller is asked or by the controller
// (a size transaction still settling, a window with no source), changed nothing: the press is left upstream's first half, the window
// raised and focused, and the refusal is shown in the controller's words.
- (void)beginResize:(NSNumber *)window edges:(NSString *)edges snapped:(BOOL)snapped at:(CGPoint)p output:(NSNumber *)output {
    NSMutableDictionary *command=[@{@"op":@"begin_native_resize",@"window":window,@"output":output,@"start_screen":pointJSON(p),@"group":snapped?@YES:@NO}mutableCopy];if(edges)command[@"edges"]=edges;
    NSString *status=self.desktop.statusText;NSDictionary *reply=[self.desktop.resize request:command];
    if(reply){self.resizeTransaction=reply[@"transaction"];self.gesture=4;[self.desktop resizeFocus:reply];
        if(DWDebugTrace()){NSDictionary *t=DWTyped([self.desktop call:@{@"op":@"snapshot"}][@"native_resize"],NSDictionary.class);fprintf(stderr,"debug: resize grab transaction=%s window=#%s edges=%s group=%d ratio=%d\n",[t[@"transaction"]description].UTF8String,window.description.UTF8String,((NSString *)DWTyped(t[@"edges"],NSString.class)).UTF8String?:"?",[DWTyped(t[@"group"],NSNumber.class)boolValue],DWTyped(t[@"ratio"],NSNumber.class)!=nil);}
        return;}
    NSString *refusal=[self.desktop.statusText isEqual:status]?nil:self.desktop.statusText;self.desktop.statusText=status;
    [self.desktop raiseFocus:window];if(refusal)[self.desktop flashStatus:[@"Window not resized: " stringByAppendingString:refusal]];
}
- (NSDictionary *)resizeBorderForButton:(NSInteger)button flags:(NSEventModifierFlags)flags hit:(NSDictionary *)hit at:(CGPoint)p output:(NSNumber *)output {
    // Admission is shared by canvas presses and physical native-window presses.
    // The controller owns the band and pick/widget/pin/fullscreen policy; a native
    // child recipient and a modified window binding keep their existing input.
    if(button!=0||hit[@"native_member"])return nil;
    NSDictionary *border=DWTyped([self pointerCommand:@{@"op":@"resize_border",@"output":output,@"screen":pointJSON(p)} quiet:YES][@"border"],NSDictionary.class);
    if(!border||(hit&&![hit[@"window"]isEqual:border[@"window"]]))return nil;
    if((flags&(NSEventModifierFlagControl|NSEventModifierFlagOption|NSEventModifierFlagShift|NSEventModifierFlagCommand))&&[self.desktop mouseBinding:@"left" source:nil flags:flags window:YES under:DWTyped(border[@"window"],NSNumber.class) pick:NO])return nil;
    return border;
}
// A title grab cannot be lent to a rebound source or a replacement output.
// Once cancelled, the tap still swallows this physical pair through its release.
- (BOOL)nativeTitlePressCurrent {
    NSDictionary *intent=self.nativeTitlePress;Desktop *d=self.desktop;LiveSource *source=intent?d.sources[intent[@"window"]]:nil;
    if(!intent||!d.native||[d nativeUnavailable]||d.cleaning||d.sessionInactive
        ||![d.views containsObject:self]||![self.outputs containsObject:intent[@"output"]]
        ||![self.dragOutput isEqual:intent[@"output"]]
        ||![[d.nativeViews desiredOwnerForWindow:intent[@"window"]]isEqual:intent[@"output"]]||!source||source.detached
        ||!boundIdentity(source.identity,intent[@"identity"])||!DWInScope(d.scope,source.router.pid)
        ||![birth(source.router.pid)isEqual:source.router.processBirth]
        ||![[d.native rootWindowFor:source.router.wid]isEqual:@(source.router.wid)])return NO;
    NSDictionary *snapshot=[d call:@{@"op":@"snapshot"}],*binding=nil;BOOL output=NO;
    for(NSDictionary *window in snapshot[@"windows"])if([window[@"window"]isEqual:intent[@"window"]]){binding=DWTyped(window[@"source"],NSDictionary.class);break;}
    for(NSDictionary *view in snapshot[@"outputs"])if([view[@"id"]isEqual:intent[@"output"]]){output=YES;break;}
    return output&&boundIdentity(source.identity,binding[@"identity"])&&[binding[@"generation"]isEqual:intent[@"generation"]];
}
// A normal run's press, dispatched as upstream's on_pointer_button does: the binding
// for the held modifiers in the window or canvas context, else the native window
// under the pointer. An unbound press on empty canvas means nothing to upstream either.
- (void)press:(NSEvent *)e button:(NSInteger)button hit:(NSDictionary *)hit at:(CGPoint)p output:(NSNumber *)output {
    if(self.desktop.nativeFillHandoff)return;
    NSArray<NSString *> *triggers=@[@"left",@"right",@"middle",@"back",@"forward"];LiveSource *source=hit?self.desktop.sources[hit[@"window"]]:nil;self.lastScrollPan=0;self.clearsFocus=NO;
    // One lookup says all of it: the binding, or nil for none, for one the window under the pointer claims by its pass_mouse rule, and
    // over a pick target for a button whose modifiers are not held. A pick target claims nothing; a pinned window is never one, and keeps
    // its button claims below [zoom] interact_min (upstream's try_pinned_button, which stands ahead of try_pick_button).
    NSDictionary *binding=button<(NSInteger)triggers.count?[self.desktop mouseBinding:triggers[button] source:nil flags:e.modifierFlags window:hit!=nil under:liveHit(hit) pick:[hit[@"pick"]isEqual:@YES]]:nil;NSString *kind=DWTyped(binding[@"kind"],NSString.class),*action=DWTyped(binding[@"action"],NSString.class);
    BOOL move=[kind isEqual:@"move_window"]||[kind isEqual:@"move_snapped_windows"],resize=[kind isEqual:@"resize_window"]||[kind isEqual:@"resize_window_snapped"];
    // Upstream's resize border ([mouse] resize_on_border): a left press in the band across a window's visible edge raises and focuses that
    // window and resizes it by that edge, with the cluster when decoration_resize_snapped says so, unless a binding whose modifiers are
    // held claims the press on that window (on_pointer_button asks modifier_button_binding first). The controller says where the band is.
    // A press it does not take goes on as the canvas press it is to -hit:, where upstream would still count the band as the window.
    NSDictionary *border=[self resizeBorderForButton:button flags:e.modifierFlags hit:hit at:p output:output];
    if(border){
        if(DWDebugTrace())fprintf(stderr,"debug: pointer down button=%ld trigger=left binding=none border=%s window=#%s\n",(long)button,((NSString *)DWTyped(border[@"edges"],NSString.class)).UTF8String?:"?",[border[@"window"]description].UTF8String);
        [self beginResize:DWTyped(border[@"window"],NSNumber.class) edges:DWTyped(border[@"edges"],NSString.class) snapped:[DWTyped(border[@"snapped"],NSNumber.class)boolValue] at:p output:output];[self.desktop render];return;}
    if(DWDebugTrace())fprintf(stderr,"debug: pointer down button=%ld trigger=%s binding=%s window=%s\n",(long)button,button<(NSInteger)triggers.count?triggers[button].UTF8String:"?",kind.UTF8String?:"none",hit?[NSString stringWithFormat:@"#%@",hit[@"window"]].UTF8String:"none");
    // Upstream try_pick_button, ahead of everything but a binding whose modifiers are held, which is the only kind the
    // lookup answers over a pick target: below [zoom] interact_min a window or placeholder is one target, whatever the
    // button, and the press is never the application's.
    if([self.hover pickPress:hit button:button claimed:binding!=nil at:p output:output]){self.gesture=DWPolicyPress;return;}
    // ⌃⌥-click still dismisses a detached placeholder while no binding claims that press.
    if(!binding&&!button&&hit&&!source&&(e.modifierFlags&NSEventModifierFlagControl)&&(e.modifierFlags&NSEventModifierFlagOption)){[self.desktop call:@{@"op":@"forget",@"window":hit[@"window"]}];[self.desktop render];[self.desktop saveScene];return;}
    // pointer.rs try_suspended_button: modified bindings and pick mode won
    // above; the label relaunches, the bar moves, the body only focuses.
    if(!binding&&!button&&[hit[@"placeholder"]boolValue]){
        NSDictionary *snapshot=[self.desktop presentationSnapshot];
        NSString *part=[self.desktop.compositor standInPart:hit[@"window"] output:output screen:p snapshot:snapshot];
        if([part isEqual:@"close"]){self.gesture=DWPolicyPress;
            [self.desktop applyReply:[self.desktop call:@{@"op":@"ipc",@"output":output,@"request":@{@"Close":hit[@"window"]}}]];return;}
        if([part isEqual:@"label"]){self.gesture=DWPolicyPress;
            [self.desktop applyReply:[self.desktop call:@{@"op":@"focus",@"window":hit[@"window"]}]];
            [self.desktop applyReply:[self.desktop call:@{@"op":@"ipc",@"output":output,@"request":@{@"Relaunch":hit[@"window"]}}]];return;}
        if([part isEqual:@"title"])move=YES;
    }
    if(self.nativeTitlePress){
        // This is an internal, already intercepted native chrome press. A
        // refusal stays swallowed; it must not fall through to app forwarding.
        if(binding||button!=0||[hit[@"pick"]boolValue]||[hit[@"widget"]boolValue]||hit[@"native_member"]
            ||![hit[@"window"]isEqual:self.nativeTitlePress[@"window"]]||![self nativeTitlePressCurrent])return;
        move=YES;
    }
    // A widget ignores drags and resizes, as upstream's does: the bound press starts no gesture and goes to the widget as a plain click (upstream's move and resize arms fall through to click-to-focus and forward it).
    if((move||resize)&&[DWTyped(hit[@"widget"],NSNumber.class)boolValue]){[self.desktop flashStatus:@"A widget stays where its rule puts it: drags and resizes are ignored"];move=resize=NO;}
    // Upstream on_pointer_button: raise_and_focus, then the move grab. The controller does both inside begin_drag, a pinned window's included, and its reply
    // carries the focus request an activate reply carries: the coordinator's to perform on the native window, as a click's is and a move gesture's.
    if(move&&hit){NSDictionary *begun=[self.desktop call:@{@"op":@"begin_drag",@"window":hit[@"window"],@"output":output,@"group":[kind isEqual:@"move_snapped_windows"]?@YES:@NO}];if(begun){self.gesture=2;[self.desktop.navigation perform:DWTyped(begun,NSDictionary.class)];}}
    else if(resize&&hit)[self beginResize:hit[@"window"] edges:nil snapped:[kind isEqual:@"resize_window_snapped"] at:p output:output];
    // Upstream's pan grab remembers that it began on empty canvas: released without a drag, it unfocuses.
    else if([kind isEqual:@"pan_viewport"]){self.gesture=1;self.clearsFocus=!hit;}
    // Upstream's NavigateGrab: the drag, not the press, takes the direction.
    else if([kind isEqual:@"center_nearest"]){self.gesture=DWPolicyPress;[self.hover nearestPress:p output:output focus:[binding[@"focus"]isEqual:@YES]];}
    // Upstream raises and focuses the window under the pointer, stand-ins included, then runs the action on it.
    else if([kind isEqual:@"action"]&&action){if(hit)[self.desktop applyReply:[self.desktop call:@{@"op":@"focus",@"window":hit[@"window"]}]];[self.desktop action:action output:output at:p held:[DWCycleHold modifiersDown]!=0];return;}
    // Unbound, or bound to a gesture with nothing to act on here: click-to-focus, then the press is the native window's,
    // once the window has the focus that was asked for (-holdPress:window:intent:at:output:).
    else if(hit){NSDictionary *intent=[self inputIntentForHit:hit output:output];BOOL child=DWTyped(hit[@"native_member"],NSDictionary.class)!=nil;self.gesture=3;self.clickWindow=child?nil:hit[@"window"];
        if(child){if(![self focusChildIntent:intent])return;}else {
            NSDictionary *reply=[self.desktop call:@{@"op":@"activate",@"window":hit[@"window"],@"output":output?:NSNull.null,@"cause":@"click"}];
            // Pin before applying the reply: completion/rendering must not lend
            // this physical press a later request for the same logical window.
            if(intent){NSMutableDictionary *held=[intent mutableCopy];held[@"focus_effect"]=DWTyped(reply[@"effect"],NSDictionary.class)?:NSNull.null;intent=held.copy;}
            [self.desktop applyReply:reply];
        }
        [self.desktop render];if(![hit[@"placeholder"]boolValue])[self holdPress:e window:hit[@"window"] intent:intent at:p output:output];return;}
    [self.desktop render];
}
- (void)mouseDown:(NSEvent *)e {
    if(self.desktop.sessionInactive||[self.desktop nativeUnavailable])return;
    [self.desktop.compositor finishGeometryTransitions];
    if(self.desktop.compositor.hasGeometryTransitions)return;
    // One gesture at a time: another button waits until the first is released.
    NSInteger button=e.buttonNumber;if(self.gesture&&button!=self.gestureButton){if([self.desktop.pointerGrab ownsEvent:e.CGEvent])[self.desktop forwardCapturedPointer:e.CGEvent screen:[self screenPoint:e]];return;}
    // A press still held for its window's focus goes first, before this one withdraws that request.
    [self deliverHeld];
    // A press is a fresh interaction, as upstream. It ends an open cycle as letting go of its modifiers does, committing a
    // settled selection as upstream's focus_changed commits it. The pad is one device: in a normal run the press then ends
    // a trackpad gesture in progress, cancelled, so that the coast a pan's end launches stops with the rest. Only then is
    // the focus request still in flight withdrawn and every flight and coast stopped, and a scroll pan still waiting to
    // launch never does, at its delay or at the lift of fingers still down.
    self.clickWindow=nil;[self.desktop.navigation releaseCycle];[self.desktop cancelGestures];[self.desktop cancelNavigation];[self.desktop.panLaunch cancel];self.scrollPanTime=0;
    CGPoint p=[self screenPoint:e];NSNumber *output=[self outputAt:p];if(!output)return;
    self.startPoint=self.lastPoint=p;self.dragOutput=self.lastOutput=output;self.gestureButton=button;self.lastDragPan=0;
    NSDictionary *hit=[self hit:p output:output];BOOL isHit=[hit isKindOfClass:NSDictionary.class];
    [self press:e button:button hit:isHit?hit:nil at:p output:output];
}
- (void)rightMouseDown:(NSEvent *)e { [self mouseDown:e]; }
- (void)otherMouseDown:(NSEvent *)e { [self mouseDown:e]; }
- (void)rightMouseDragged:(NSEvent *)e { [self mouseDragged:e]; }
- (void)otherMouseDragged:(NSEvent *)e { [self mouseDragged:e]; }
- (void)rightMouseUp:(NSEvent *)e { [self mouseUp:e]; }
- (void)otherMouseUp:(NSEvent *)e { [self mouseUp:e]; }
- (void)mouseDragged:(NSEvent *)e {
    if([self.desktop nativeUnavailable])return;
    if(e.buttonNumber!=self.gestureButton)return;
    CGPoint p=[self screenPoint:e];
    if(self.nativeTitlePress){
        if(hypot(p.x-self.startPoint.x,p.y-self.startPoint.y)>5)self.nativeTitleMoved=YES;
        // A title click owns the native pair but is not yet a window move.
        // Even a zero delta can magnetically snap and arm edge pan.
        if(!self.nativeTitleMoved){self.lastPoint=p;return;}
    }
    // A pick-mode press dragged past the click slop is a window move from here on, as upstream's grab starts where it is promoted.
    if(self.gesture==DWPolicyPress&&[self.hover pressDragged:p]){self.gesture=2;self.startPoint=p;}
    // Each drag event says where the pointer is; the controller asks one size at a time of the window and keeps only the latest while one
    // is out. A transaction that takes no more motion has ended by itself (its window will not be resized, closed, or stopped answering):
    // nothing more is sent for this press, which stays swallowed until its button lifts, as upstream's grab outlives a dead client.
    if(self.gesture==4){
        if(self.resizeTransaction){NSString *status=self.desktop.statusText;
            if([self.desktop.resize request:@{@"op":@"native_resize_to",@"transaction":self.resizeTransaction,@"screen":pointJSON(p)}]){
                // Success is consumed synchronously: resize.changed has already
                // described the current scene and arranged its frame flush.
                self.lastPoint=p;return;
            }
            self.resizeTransaction=nil;self.desktop.statusText=status;
        }
    }
    else if(self.gesture==1){
        if(hypot(p.x-self.startPoint.x,p.y-self.startPoint.y)>=5)self.clearsFocus=NO;
        // A drag pan is timed, for the coast its release launches.
        [self pan:CGPointMake(self.lastPoint.x-p.x,self.lastPoint.y-p.y) output:self.dragOutput event:e source:@"drag"];self.lastDragPan=e.timestamp;
    }
    // A window drag says where the pointer is: inside navigation.edge_pan's zone
    // the controller pans under the window frame by frame, also while the pointer rests there.
    else if(self.gesture==2){if([[self.desktop call:@{@"op":@"gesture_to",@"screen_delta":pointJSON(CGPointMake(p.x-self.startPoint.x,p.y-self.startPoint.y)),@"pointer":pointJSON(p)}][@"needs_frames"]boolValue])[self.desktop ensureFrames];}
    else if(self.gesture==3&&self.heldPress){self.heldDrag=e;self.heldDragPoint=p;}
    else if(self.gesture==3){CGEventRef cg=CGEventCreateCopy(e.CGEvent);[self forward:cg at:p output:self.dragOutput];CFRelease(cg);}
    self.lastPoint=p;[self.desktop render];
}
- (void)releasePressed {
    if(self.pressedSource){
        if(self.pressedPointerGrab){__weak Desktop *weak=self.desktop;if(sameInputTarget(self.pressedTarget,self.desktop.pointerGrab.target))[self.desktop.pointerGrab cancelWithValidate:^BOOL(NSDictionary *target){return [weak validateInputTarget:target];} post:^BOOL(CGEventRef event,NSDictionary *target,CGPoint local){return [weak postInput:event target:target local:local];}];[self.desktop.relativeMotion reset];self.pressedSource=nil;self.pressedTarget=nil;self.pressedPointerGrab=NO;return;}
        if(self.pressedTablet){NSDictionary *pressed=self.pressedTarget;__weak Desktop *weak=self.desktop;[self.desktop.tablet cancelTargetsMatching:^BOOL(NSDictionary *target){return [target[@"window"]isEqual:pressed[@"window"]]&&[target[@"output"]isEqual:pressed[@"output"]]&&[target[@"generation"]isEqual:pressed[@"generation"]]&&[target[@"identity"]isEqual:pressed[@"identity"]];} validate:^BOOL(NSDictionary *target){return [weak validateInputTarget:target];} post:^BOOL(CGEventRef event,NSDictionary *target,CGPoint local){return [weak postInput:event target:target local:local];}];self.pressedSource=nil;self.pressedTarget=nil;self.pressedTablet=NO;self.pressedTabletDevice=nil;self.pressedPointerGrab=NO;return;}
        Router *router=self.pressedSource.router;
        // A native title drag can move the real source before the polling tick.
        // Refresh only the already-pressed identity before releasing its button.
        NSDictionary *current=windowInfo(router.wid);
        if(!self.desktop.native&&[birth(router.pid)isEqual:router.processBirth]&&[current[(id)kCGWindowOwnerPID]intValue]==router.pid&&current[(id)kCGWindowBounds])router.bounds=current[(id)kCGWindowBounds];
        // The button that went down in the source is the one that comes up.
        CGMouseButton button=(CGMouseButton)self.pressedButton;CGEventType type=button==kCGMouseButtonLeft?kCGEventLeftMouseUp:button==kCGMouseButtonRight?kCGEventRightMouseUp:kCGEventOtherMouseUp;
        sig_atomic_t wasStopped=stopped;stopped=0;CGEventRef up=CGEventCreateMouseEvent(router.eventSource,type,CGPointZero,button);
        if(self.desktop.native||[self.pressedTarget[@"native_member"]boolValue]){if(self.pressedTarget&&[self.desktop validateInputTarget:self.pressedTarget])[self.desktop postInput:up target:self.pressedTarget local:self.pressedLocal];}
        else [router post:up at:self.pressedLocal];
        CFRelease(up);if(wasStopped)stopped=wasStopped;self.pressedSource=nil;self.pressedTarget=nil;self.pressedTablet=NO;self.pressedTabletDevice=nil;self.pressedPointerGrab=NO;}
}
- (void)mouseUp:(NSEvent *)e { if(e.buttonNumber!=self.gestureButton)return;
    self.nativeTitleReleased=self.nativeTitlePress&&e.type==NSEventTypeLeftMouseUp;
    if(self.heldPress)self.heldRelease=e;
    else if(self.pressedSource){CGEventRef packet=CGEventCreateCopy(e.CGEvent);BOOL posted=[self forward:packet at:[self screenPoint:e] output:self.dragOutput];CFRelease(packet);if(posted){self.pressedSource=nil;self.pressedTarget=nil;self.pressedTablet=NO;self.pressedTabletDevice=nil;self.pressedPointerGrab=NO;}}
    [self released:[self screenPoint:e] at:e.timestamp]; }
- (void)tabletPoint:(NSEvent *)event { if(self.desktop.sessionInactive||self.desktop.cleaning)return;CGEventRef packet=event.CGEvent?CGEventCreateCopy(event.CGEvent):NULL;if(packet){CGPoint at=[self screenPoint:event];[self forward:packet at:at output:[self outputAt:at]];CFRelease(packet);} }
- (void)tabletProximity:(NSEvent *)event { [self tabletPoint:event]; }
// The end of a press, whatever it had become: at the global point and the event time of its release, or of the moment a release that never
// arrived was noticed (-[Desktop endLostInput]).
- (void)released:(CGPoint)p at:(NSTimeInterval)time { self.liftSeen=0;self.takenOverAt=0;
    NSDictionary *titleClick=self.nativeTitleReleased&&!self.nativeTitleMoved&&self.gesture==2&&self.gestureButton==0
        &&hypot(p.x-self.startPoint.x,p.y-self.startPoint.y)<=5&&[[self outputAt:p]isEqual:self.dragOutput]
        &&[self nativeTitlePressCurrent]?self.nativeTitlePress:nil;
    self.nativeTitleReleased=NO;
    // Native title movement never reaches AppKit. After crossing click slop,
    // apply the final up through the same pointer-to-world mapping. An up may
    // be the first packet beyond slop; a stationary click must never snap.
    if(self.nativeTitlePress&&self.gesture==2&&(self.nativeTitleMoved||hypot(p.x-self.startPoint.x,p.y-self.startPoint.y)>5)&&[self nativeTitlePressCurrent])
        [self.desktop call:@{@"op":@"gesture_to",@"screen_delta":pointJSON(CGPointMake(p.x-self.startPoint.x,p.y-self.startPoint.y)),@"pointer":pointJSON(p)}];
    self.nativeTitlePress=nil;
    // The release of a resize grab: the last size asked is let through, the window is read once more, and the canvas has the size it has.
    // A transaction that ended by itself meanwhile has nothing to release, and says so to nobody.
    if(self.gesture==4&&self.resizeTransaction){NSString *status=self.desktop.statusText;
        // The release may be farther than the last drag event. Keep its final
        // pointer position before draining the request, through the same grab.
        [self.desktop.resize request:@{@"op":@"native_resize_to",@"transaction":self.resizeTransaction,@"screen":pointJSON(p)}];
        if(![self.desktop.resize request:@{@"op":@"end_native_resize",@"transaction":self.resizeTransaction}])self.desktop.statusText=status;}
    self.resizeTransaction=nil;if(self.heldPress)self.heldReleased=YES;else [self releasePressed];
    // Upstream resolve_click_navigate follows delivery. A click still waiting for
    // native focus cannot move the camera before its original recipient is checked.
    NSNumber *clicked=self.clickWindow;self.clickWindow=nil;
    if(self.gesture==3&&clicked&&hypot(p.x-self.startPoint.x,p.y-self.startPoint.y)<=5&&[[self outputAt:p]isEqual:self.dragOutput]){if(self.heldPress)self.heldNavigate=YES;else [self.desktop clickReleased:clicked output:self.dragOutput];}
    // A policy press let go: a pick, or a center-nearest press that never left its dead zone.
    if(self.gesture==DWPolicyPress)[self.hover pressReleased:p];
    // A pick-mode press that became a move ends here like any other window drag.
    if(self.gesture==2)[self.desktop call:@{@"op":@"end_gesture"}];
    if(titleClick)[self.desktop deferNativeTitleClick:titleClick];
    // A drag pan coasts from its release, as upstream's pan grab launches momentum.
    // A drag that rested first does not: upstream's 50 ms delay has by then launched it into
    // the held grab, where nothing coasts, and the release finds no velocity left. The
    // second launch here is that one.
    if(self.gesture==1&&self.lastDragPan){[self.desktop panEnd:self.dragOutput];if(time-self.lastDragPan>=.05)[self.desktop panEnd:self.dragOutput];}
    if(self.gesture==1&&self.clearsFocus)[self.desktop clearFocus];self.clearsFocus=NO;self.gesture=0;
    for(DesktopView *view in self.desktop.views)[view refreshCursor];[self.desktop saveScene]; }
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
