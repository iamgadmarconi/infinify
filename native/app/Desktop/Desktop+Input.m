// SPDX-License-Identifier: GPL-3.0-or-later
// Desktop input taps: native input, native buttons and titles, captured-input forwarding, native drag takeover, lost input.
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
// Fresh session-stage title admission only. These diagnostics use values already
// read by admission; they do not repeat native queries or change pair ownership.
static BOOL DWNativeTitleRefused(BOOL early,const char *reason,NSNumber *window,CGWindowID wid,CGPoint point,NSDictionary *detail) {
    if(early&&DWDebugTrace()){
        NSData *data=detail?[NSJSONSerialization dataWithJSONObject:detail options:0 error:nil]:nil;
        NSString *json=data?[[NSString alloc]initWithData:data encoding:NSUTF8StringEncoding]:nil;
        fprintf(stderr,"debug: native title admission refused window=#%s wid=%u point=%g,%g reason=%s detail=%s\n",window.description.UTF8String?:"?",wid,point.x,point.y,reason,json.UTF8String?:"{}");
    }
    return NO;
}
// This authorizes only our own chrome gesture, never forwarding content. The
// physical root must already be where the controller expects it, including the
// pin's unit scale; a stale capture/renderer receipt is immaterial to that fact.
static BOOL DWNativeChromeFrameMatches(CGRect own,CGRect displayed,NSDictionary *placement,NSDictionary *output,CGPoint point) {
    CGRect wanted=DWRectFromJSON(placement[@"screen_rect"]),clip=DWRectFromJSON(output[@"screen_bounds"]);
    double scale=[placement[@"pinned"]boolValue]?1:[output[@"zoom"]doubleValue];
    if(!isfinite(scale)||scale<=0||!isfinite(own.size.width)||!isfinite(own.size.height)||own.size.width<=0||own.size.height<=0
        ||!isfinite(displayed.origin.x)||!isfinite(displayed.origin.y)||!isfinite(displayed.size.width)||!isfinite(displayed.size.height)
        ||displayed.size.width<=0||displayed.size.height<=0||[placement[@"family_only"]boolValue]
        ||!CGRectContainsPoint(clip,point))return NO;
    return fabs(wanted.size.width-own.size.width*scale)<=1.01&&fabs(wanted.size.height-own.size.height*scale)<=1.01
        &&fabs(CGRectGetMinX(wanted)-CGRectGetMinX(displayed))<=1.01&&fabs(CGRectGetMaxX(wanted)-CGRectGetMaxX(displayed))<=1.01
        &&fabs(CGRectGetMinY(wanted)-CGRectGetMinY(displayed))<=1.01&&fabs(CGRectGetMaxY(wanted)-CGRectGetMaxY(displayed))<=1.01;
}
// Failed AX refresh is not a new chrome observation. Only a still-public map
// can survive it, under its original title-hit age and exact native geometry.
// A returned report (including a negative title result) always supersedes it.
static NSDictionary *DWNativeButtonsAfterRefresh(NSDictionary *report,NSDictionary *current,NSDictionary *identity,
    CFTimeInterval now,BOOL nativeCurrent,CGRect native) {
    if(report)return now-[report[@"sampled_at"]doubleValue]<=.1?report:nil;
    double sampled=[current[@"sampled_at"]doubleValue],age=now-sampled;
    if(!current||!nativeCurrent||![current[@"identity"]isEqual:identity]||!isfinite(sampled)||sampled<=0
        ||!isfinite(age)||age<0||age>.5||!isfinite(native.origin.x)||!isfinite(native.origin.y)
        ||!isfinite(native.size.width)||!isfinite(native.size.height)||native.size.width<=0||native.size.height<=0
        ||!CGRectEqualToRect(DWRectFromJSON(current[@"native_bounds"]),native))return nil;
    return current;
}

@implementation Desktop (Input)
- (LiveSource *)nativeSource:(CGWindowID)window at:(CGPoint)point {
    if(!window||!self.native||self.native.ended||self.cleaning)return nil;
    NSNumber *root=[self.native rootWindowFor:window];if(!root)return nil;
    for(LiveSource *source in self.sources.allValues)if(!source.detached&&source.router.wid==root.unsignedIntValue){
        if(!DWInScope(self.scope,source.router.pid)||![birth(source.router.pid)isEqual:source.router.processBirth])return nil;
        NSDictionary *info=windowInfo(window);CGRect bounds=CGRectZero;
        if([info[(id)kCGWindowOwnerPID]intValue]!=source.router.pid||![info[(id)kCGWindowIsOnscreen]boolValue]
            ||[info[(id)kCGWindowAlpha]doubleValue]<=0||!info[(id)kCGWindowBounds]
            ||!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)info[(id)kCGWindowBounds],&bounds)
            ||!CGRectContainsPoint(bounds,point))return nil;
        if(window!=source.router.wid){NSMutableDictionary *member=[source.identity mutableCopy];member[@"wid"]=@(window);[member removeObjectForKey:@"owner"];if(!DWNativeWindowBelongsToRoot(member,source.identity))return nil;}
        return source;
    }
    return nil;
}
- (void)nativeMouseOwnershipChanged:(CGEventRef)event buttons:(NSIndexSet *)buttons {
    LiveSource *source=self.nativeMouseOwner;CFTimeInterval now=CACurrentMediaTime();
    if(source.nativeMouseOwnership){
        NSMutableDictionary *held=source.nativeMouseOwnership;
        if(!event){held[@"click_possible"]=@NO;[self.navigation cancelNativeClick];}
        else {
            CGEventType type=CGEventGetType(event);
            BOOL drag=type==kCGEventLeftMouseDragged||type==kCGEventRightMouseDragged||type==kCGEventOtherMouseDragged;
            CGPoint point=CGEventGetLocation(event),start=jsonPoint(held[@"click_start"]);
            if((drag&&hypot(point.x-start.x,point.y-start.y)>5)||buttons.count>1)held[@"click_possible"]=@NO;
            if(drag&&type==kCGEventLeftMouseDragged&&buttons.count==1&&[self takeOverNativeDrag:source event:event])return;
            if(!buttons.count){
                CGPoint point=CGEventGetLocation(event),start=jsonPoint(held[@"click_start"]);NSDictionary *snapshot=[self call:@{@"op":@"snapshot"}],*binding=nil,*view=nil;
                for(NSDictionary *row in snapshot[@"windows"])if([row[@"window"]isEqual:source.logical])binding=DWTyped(row[@"source"],NSDictionary.class);
                for(NSDictionary *row in snapshot[@"outputs"])if([row[@"id"]isEqual:held[@"output"]])view=row;
                BOOL click=type==kCGEventLeftMouseUp&&[held[@"click_possible"]boolValue]&&!held[@"topology_changed"]
                    &&[held[@"session"]unsignedLongLongValue]==self.nativeSessionEpoch&&hypot(point.x-start.x,point.y-start.y)<=5
                    &&boundIdentity(source.identity,binding[@"identity"])&&[binding[@"generation"]isEqual:held[@"generation"]]
                    &&[view[@"camera"]isEqual:held[@"camera"]]&&[view[@"zoom"]isEqual:held[@"zoom"]]&&[view[@"screen_bounds"]isEqual:held[@"screen_bounds"]]
                    &&CGRectContainsPoint(DWRectFromJSON(view[@"screen_bounds"]),point)&&[[self.nativeViews desiredOwnerForWindow:source.logical]isEqual:held[@"output"]];
                [self.navigation endNativeClick:held[@"click_binding"] completed:click];
            }
        }
        if(buttons.count){held[@"buttons"]=buttons;[held removeObjectForKey:@"released"];held[@"last_packet"]=@(now);}
        else {
            if(event)held[@"released"]=@(now);else [held removeObjectForKey:@"released"];
            held[@"cancelled"]=@(event==NULL);self.nativeMouseOwner=nil;
        }
        return;
    }
    // Any fresh native recipient supersedes an earlier completed click, even
    // when this press belongs to the Dock or another unmanaged window.
    [self.navigation cancelNativeClick];
    [self cancelNativeTitleClick];
    if(!event||buttons.count!=1||![buttons containsIndex:0]||CGEventGetType(event)!=kCGEventLeftMouseDown
        ||self.cleaning||self.sessionInactive||!self.native||self.native.ended||self.nativeFillHandoff)return;
    CGWindowID wid=(CGWindowID)CGEventGetIntegerValueField(event,kCGMouseEventWindowUnderMousePointerThatCanHandleThisEvent);
    if(!wid)wid=(CGWindowID)CGEventGetIntegerValueField(event,kCGMouseEventWindowUnderMousePointer);
    source=[self nativeSource:wid at:CGEventGetLocation(event)];
    if(!source||[[self.resize busyWindow]isEqual:source.logical]||[self grabbed:source]
        ||self.nativeOwnershipTransfer||self.nativeHoverTransfer||[self.nativeViews requiresPlacementAdmissionForWindow:source.logical])return;
    NSDictionary *snapshot=[self call:@{@"op":@"snapshot"}],*record=nil,*view=nil;NSNumber *output=[self.nativeViews desiredOwnerForWindow:source.logical];
    for(NSDictionary *row in snapshot[@"windows"])if([row[@"window"]isEqual:source.logical]){record=row;break;}
    for(NSDictionary *row in snapshot[@"outputs"])if([row[@"id"]isEqual:output]){view=row;break;}
    NSDictionary *binding=DWTyped(record[@"source"],NSDictionary.class);double zoom=[view[@"zoom"]doubleValue];
    if(source.nativeMouseOwnership){
        NSMutableDictionary *held=source.nativeMouseOwnership;held[@"buttons"]=buttons;[held removeObjectForKey:@"released"];self.nativeMouseOwner=source;
        BOOL root=wid==source.router.wid&&boundIdentity(source.identity,binding[@"identity"])&&[binding[@"generation"]isEqual:held[@"generation"]]
            &&[view[@"camera"]isEqual:held[@"camera"]]&&[view[@"zoom"]isEqual:held[@"zoom"]]&&[view[@"screen_bounds"]isEqual:held[@"screen_bounds"]]
            &&CGRectContainsPoint(DWRectFromJSON(view[@"screen_bounds"]),CGEventGetLocation(event));
        held[@"click_start"]=pointJSON(CGEventGetLocation(event));held[@"click_possible"]=@(root);
        if(root)[self.navigation beginNativeClick:held[@"click_binding"] output:output];return;
    }
    CGRect initialNative,initialScreen;NSDictionary *initialRow=windowInfo(source.router.wid);
    if(!DWNativeBounds(source.router.wid,&initialNative)||!initialRow[(id)kCGWindowBounds]
        ||!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)initialRow[(id)kCGWindowBounds],&initialScreen)
        ||!boundIdentity(source.identity,binding[@"identity"])||!binding[@"generation"]||!view||!isfinite(zoom)||zoom<=0
        ||![self.native withholdWindow:source.identity])return;
    source.nativeMouseOwnership=[@{@"identity":source.identity.copy,@"generation":binding[@"generation"],@"output":output,@"session":@(self.nativeSessionEpoch),
        @"camera":view[@"camera"],@"zoom":view[@"zoom"],@"screen_bounds":view[@"screen_bounds"],@"buttons":buttons,@"last_packet":@(now),
        @"initial_native":DWRectJSON(initialNative),@"initial_screen":DWRectJSON(initialScreen)}mutableCopy];
    NSDictionary *clickBinding=@{@"window":source.logical,@"identity":binding[@"identity"],@"generation":binding[@"generation"]};
    BOOL root=wid==source.router.wid&&CGRectContainsPoint(DWRectFromJSON(view[@"screen_bounds"]),CGEventGetLocation(event));
    source.nativeMouseOwnership[@"click_binding"]=clickBinding;source.nativeMouseOwnership[@"click_start"]=pointJSON(CGEventGetLocation(event));source.nativeMouseOwnership[@"click_possible"]=@(root);source.nativeMouseOwnership[@"root"]=@(root);
    if(root)[self.navigation beginNativeClick:clickBinding output:output];
    source.observationToken=++self.observationEpoch;self.nativeMouseOwner=source;
    [self cancelNativeHoverForWindow:source.logical];self.nativeViewSnapshot=nil;
    // Omission preserves the current transform; it does not restore or rebase.
    // An already submitted frame can still drain before the omission ACK.
    [self render];
    if(DWDebugTrace())fprintf(stderr,"debug: native mouse owner window=#%s begin buttons=%lu\n",source.logical.description.UTF8String,(unsigned long)buttons.count);
}
// A press that went to a transformed native window and became the application's own window drag. WindowServer moves the native
// frame from where the window is drawn (not from the native frame), keeps or drops the transform as it likes while the button
// is down, and puts the transform back at the release: measured in the guest, the window left the pointer at the first packet
// (it jumped, and at zoom below 1 changed size) and the release adopted a displaced origin; macOS tiling reads the native place.
// The first drag packet that shows the native origin moving with the extent unchanged takes the pair over instead: the application's
// drag is ended with a tagged release, the rest of the physical pair is the canvas's, and the window moves by the pointer from
// the press point exactly as after a recognized title press. Resizes and content drags (the extent or nothing changes) stay native.
- (BOOL)takeOverNativeDrag:(LiveSource *)source event:(CGEventRef)event {
    NSMutableDictionary *held=source.nativeMouseOwnership;
    if(!held||[held[@"taken"]boolValue]||![held[@"root"]boolValue]||!self.nativeInput||self.cleaning||self.sessionInactive||!self.native||self.native.ended||self.nativeFillHandoff
        ||source.detached||!boundIdentity(source.identity,held[@"identity"])||[held[@"session"]unsignedLongLongValue]!=self.nativeSessionEpoch)return NO;
    CGPoint point=CGEventGetLocation(event),start=jsonPoint(held[@"click_start"]);
    CGRect first=DWRectFromJSON(held[@"initial_native"]),drawn=DWRectFromJSON(held[@"initial_screen"]),native;
    if(hypot(point.x-start.x,point.y-start.y)<=4||!DWNativeBounds(source.router.wid,&native)||!DWNativeWindowDragStarted(first,drawn,native,start,point))return NO;
    NSNumber *output=held[@"output"];DesktopView *view=nil;
    for(DesktopView *candidate in self.views)if([[candidate outputAt:start]isEqual:output]){view=candidate;break;}
    if(!view||view.gesture||view.heldPress||view.pressedSource||view.pressedTablet||view.pressedPointerGrab||self.nativeGestureView||self.nativeOwnershipTransfer||self.nativeHoverTransfer
        ||[[self.resize busyWindow]isEqual:source.logical]||![[self.nativeViews desiredOwnerForWindow:source.logical]isEqual:output])return NO;
    NSDictionary *snapshot=[self call:@{@"op":@"snapshot"}],*record=nil,*pose=nil;
    for(NSDictionary *row in snapshot[@"windows"])if([row[@"window"]isEqual:source.logical]){record=row;break;}
    for(NSDictionary *row in snapshot[@"outputs"])if([row[@"id"]isEqual:output]){pose=row;break;}
    NSDictionary *binding=DWTyped(record[@"source"],NSDictionary.class);
    if(!pose||[record[@"mode"]isEqual:@"fullscreen"]||!boundIdentity(source.identity,binding[@"identity"])||![binding[@"generation"]isEqual:held[@"generation"]]
        ||![pose[@"camera"]isEqual:held[@"camera"]]||![pose[@"zoom"]isEqual:held[@"zoom"]]||![pose[@"screen_bounds"]isEqual:held[@"screen_bounds"]])return NO;
    NSDictionary *begun=[self call:@{@"op":@"begin_drag",@"window":source.logical,@"output":output,@"group":@NO}];
    if(!begun)return NO;
    // The drag the application started is WindowServer's own (the window follows the pointer whatever the event taps swallow), and
    // it ends when WindowServer sees the button come up. One release is posted at the HID tap for that, from a private event source so
    // that AppKit's combined button state keeps the physical button down: a release that cleared it made -endLostInput end the
    // taken-over gesture 50 ms later as a release that never arrived (measured in the guest). It carries the source's lifetime tag,
    // which both taps let through.
    CGEventSourceRef quiet=CGEventSourceCreate(kCGEventSourceStatePrivate);
    CGEventRef up=quiet?CGEventCreateMouseEvent(quiet,kCGEventLeftMouseUp,point,kCGMouseButtonLeft):NULL;
    if(up){CGEventSetIntegerValueField(up,kCGEventSourceUserData,source.router.tag);CGEventSetIntegerValueField(up,kCGMouseEventClickState,1);CGEventPost(kCGHIDEventTap,up);CFRelease(up);}
    if(quiet)CFRelease(quiet);
    if(!up){[self call:@{@"op":@"end_gesture"}];return NO;}
    held[@"taken"]=@YES;
    [self.nativeInput takeNativeButton:0];
    NSDictionary *intent=@{@"window":source.logical,@"output":output,@"identity":source.identity.copy,@"generation":binding[@"generation"]};
    [self finishNativeMouseOwner:source reason:@"native window drag taken over"];
    // The same initialization as -earlyNativeTitle:event:, for a title press that began at the press point.
    view.clickWindow=nil;[self.navigation releaseCycle];[self cancelGestures];[self cancelNavigation];[self.panLaunch cancel];view.scrollPanTime=0;
    self.nativeGestureView=view;self.nativeGestureButton=0;
    view.startPoint=view.lastPoint=start;view.dragOutput=view.lastOutput=output;view.gestureButton=0;view.lastDragPan=0;view.lastScrollPan=0;view.clearsFocus=NO;
    view.nativeTitlePress=intent;view.nativeTitleMoved=YES;view.nativeTitleReleased=NO;view.takenOverAt=CACurrentMediaTime();
    view.gesture=2;[self.navigation perform:begun];
    if([[self call:@{@"op":@"gesture_to",@"screen_delta":pointJSON(CGPointMake(point.x-start.x,point.y-start.y)),@"pointer":pointJSON(point)}][@"needs_frames"]boolValue])[self ensureFrames];
    view.lastPoint=point;[self render];
    if(DWDebugTrace())fprintf(stderr,"debug: native window drag taken over window=#%s native=%g,%g drawn=%g,%g\n",source.logical.description.UTF8String,native.origin.x,native.origin.y,drawn.origin.x,drawn.origin.y);
    return YES;
}
- (void)finishNativeMouseOwner:(LiveSource *)source reason:(NSString *)reason {
    NSDictionary *held=source.nativeMouseOwnership;if(!held)return;
    // A lost up can retire geometry after polling, but is never a completed
    // click. An actual up already classified above is left intact.
    [self.navigation endNativeClick:held[@"click_binding"] completed:NO];
    source.nativeMouseOwnership=nil;source.observationToken=++self.observationEpoch;
    if(self.nativeMouseOwner==source)self.nativeMouseOwner=nil;
    [self.native resumeWindow:held[@"identity"]];self.nativeViewSnapshot=nil;
    if(DWDebugTrace())fprintf(stderr,"debug: native mouse owner window=#%s end=%s\n",source.logical.description.UTF8String,reason.UTF8String);
    [self render];
}
- (void)updateNativeMouseOwners {
    if(self.cleaning||self.sessionInactive||!self.native||self.native.ended)return;
    CFTimeInterval now=CACurrentMediaTime();
    for(LiveSource *source in self.sources.allValues.copy){
        NSMutableDictionary *held=source.nativeMouseOwnership;if(!held)continue;
        if([held[@"session"]unsignedLongLongValue]!=self.nativeSessionEpoch){
            source.nativeMouseOwnership=nil;source.nativeMouseAdopting=NO;source.observationToken=++self.observationEpoch;
            if(self.nativeMouseOwner==source)self.nativeMouseOwner=nil;continue;
        }
        __block BOOL physical=NO;[(NSIndexSet *)held[@"buttons"]enumerateIndexesUsingBlock:^(NSUInteger button,BOOL *stop){(void)stop;if(CGEventSourceButtonState(kCGEventSourceStateHIDSystemState,(CGMouseButton)button))physical=YES;}];
        // Cancellation is not a release. Lost ups settle only after the stored
        // physical buttons are up; an additional button keeps the same owner.
        if(physical){[held removeObjectForKey:@"released"];[held removeObjectForKey:@"stable_since"];continue;}
        if(!held[@"released"]){if(now-[held[@"last_packet"]doubleValue]<.05)continue;held[@"released"]=@(now);if(self.nativeMouseOwner==source)self.nativeMouseOwner=nil;}
        if(source.detached||!boundIdentity(source.identity,held[@"identity"])||![birth(source.router.pid)isEqual:source.router.processBirth]){[self finishNativeMouseOwner:source reason:@"identity changed"];continue;}
        if([[self.resize busyWindow]isEqual:source.logical])continue;
        CGRect native,after,screen;NSDictionary *row=windowInfo(source.router.wid);
        if(!row||![row[(id)kCGWindowIsOnscreen]boolValue]){
            source.nativeMouseAdopting=YES;@try{[self track:source info:row];}@finally{source.nativeMouseAdopting=NO;}
            [self finishNativeMouseOwner:source reason:@"native window closed or hidden"];continue;
        }
        if(now-[held[@"released"]doubleValue]>2){[self finishNativeMouseOwner:source reason:@"final geometry did not settle within two seconds"];continue;}
        if(!DWNativeBounds(source.router.wid,&native)||[row[(id)kCGWindowOwnerPID]intValue]!=source.router.pid||![row[(id)kCGWindowIsOnscreen]boolValue]
            ||!row[(id)kCGWindowBounds]||!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)row[(id)kCGWindowBounds],&screen)
            ||!DWNativeBounds(source.router.wid,&after)||!CGRectEqualToRect(native,after))continue;
        if(!isfinite(screen.origin.x)||!isfinite(screen.origin.y)||!isfinite(screen.size.width)||!isfinite(screen.size.height)||screen.size.width<=0||screen.size.height<=0)continue;
        if(CGRectEqualToRect(DWRectFromJSON(held[@"initial_native"]),native)&&CGRectEqualToRect(DWRectFromJSON(held[@"initial_screen"]),screen)){
            [self finishNativeMouseOwner:source reason:@"unchanged native click"];continue;
        }
        if(!held[@"stable_since"]||!CGRectEqualToRect(DWRectFromJSON(held[@"native"]),native)||!CGRectEqualToRect(DWRectFromJSON(held[@"screen"]),screen)){
            held[@"native"]=DWRectJSON(native);held[@"screen"]=DWRectJSON(screen);held[@"stable_since"]=@(now);continue;
        }
        if(now-[held[@"stable_since"]doubleValue]<.15)continue;
        source.observationToken=++self.observationEpoch;source.nativeMouseAdopting=YES;
        @try{[self track:source info:row];}@finally{source.nativeMouseAdopting=NO;}
        if([held[@"topology_changed"]boolValue]){[self finishNativeMouseOwner:source reason:@"display topology changed; native basis refreshed"];continue;}
        NSDictionary *snapshot=[self call:@{@"op":@"snapshot"}],*record=nil,*view=nil,*placement=nil;
        for(NSDictionary *item in snapshot[@"windows"])if([item[@"window"]isEqual:source.logical]){record=item;break;}
        for(NSDictionary *item in snapshot[@"outputs"])if([item[@"id"]isEqual:held[@"output"]]){view=item;break;}
        for(NSDictionary *item in snapshot[@"placements"])if([item[@"window"]isEqual:source.logical]&&[item[@"output"]isEqual:held[@"output"]]){placement=item;break;}
        NSDictionary *binding=DWTyped(record[@"source"],NSDictionary.class);double zoom=[view[@"zoom"]doubleValue];
        BOOL current=boundIdentity(source.identity,binding[@"identity"])&&[binding[@"generation"]isEqual:held[@"generation"]]
            &&[[self.nativeViews desiredOwnerForWindow:source.logical]isEqual:held[@"output"]]
            &&[view[@"camera"]isEqual:held[@"camera"]]&&[view[@"zoom"]isEqual:held[@"zoom"]]&&[view[@"screen_bounds"]isEqual:held[@"screen_bounds"]]
            &&placement&&CGRectEqualToRect(DWRectFromJSON(binding[@"observed_rect"]),native)&&![record[@"mode"]isEqual:@"fullscreen"]&&isfinite(zoom)&&zoom>0;
        if(!current){[self finishNativeMouseOwner:source reason:@"adoption basis changed"];continue;}
        CGRect planned=DWRectFromJSON(placement[@"screen_rect"]);BOOL pinned=[placement[@"pinned"]boolValue];
        CGPoint delta=CGPointMake((screen.origin.x-planned.origin.x)/(pinned?1:zoom),(screen.origin.y-planned.origin.y)/(pinned?1:zoom));
        NSString *status=self.statusText;NSDictionary *moved=CGPointEqualToPoint(delta,CGPointZero)?@{@"moved":@YES}:[self call:@{@"op":@"relocate_source",@"window":source.logical,@"identity":source.identity,@"generation":binding[@"generation"],@"observed_rect":DWRectJSON(native),@"expected_world_rect":record[@"world_rect"],@"delta":pointJSON(delta)}];self.statusText=status;
        if([moved[@"deferred"]boolValue])continue;
        BOOL extent=fabs(screen.size.width-planned.size.width)<=1&&fabs(screen.size.height-planned.size.height)<=1;
        if([moved[@"moved"]boolValue])self.sceneDirty=YES;
        [self finishNativeMouseOwner:source reason:[moved[@"moved"]boolValue]?(extent?@"adopted displayed origin":@"adopted origin; displayed extent differs"):@"adoption refused"];
    }
}
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
- (void)refreshNativeButtons:(LiveSource *)source {
    CFTimeInterval now=CACurrentMediaTime();
    if(self.cleaning||self.sessionInactive||self.native.ended||!source||source.detached||source.nativeVisibilityHeld||source.nativeButtonsReading||source.nativeButtonsNext>now||!AXIsProcessTrusted()||!DWInScope(self.scope,source.router.pid))return;
    source.nativeButtonsReading=YES;source.nativeButtonsNext=now+.2;
    if(!self.nativeButtonQueue)self.nativeButtonQueue=dispatch_queue_create("org.infinify.native-decorations",dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,QOS_CLASS_USER_INITIATED,0));
    // Routine, unchanged window observations must not starve an AX chrome read.
    // Only source/chrome changes or a different native session invalidate it.
    NSDictionary *identity=[source.identity copy];uint64_t revision=source.nativeButtonsRevision,session=self.nativeSessionEpoch;__weak Desktop *weak=self;
    dispatch_async(self.nativeButtonQueue,^{@autoreleasepool{
        NSDictionary *report=DWNativeDecorationButtons(identity);
        dispatch_async(dispatch_get_main_queue(),^{Desktop *d=weak;source.nativeButtonsReading=NO;
            if(!d||d.cleaning||d.sessionInactive||d.native.ended||d.nativeSessionEpoch!=session||d.sources[source.logical]!=source||source.detached||source.nativeButtonsRevision!=revision||![source.identity isEqual:identity]||!DWInScope(d.scope,source.router.pid))return;
            NSDictionary *current=source.nativeButtons;CGRect native=CGRectZero;BOOL nativeCurrent=NO;
            if(!report&&current){
                DWFocusIdentity selected={.pid=[identity[@"pid"]intValue],.window=[identity[@"wid"]unsignedIntValue],.seconds=[identity[@"birth_sec"]unsignedLongLongValue],.microseconds=[identity[@"birth_usec"]unsignedLongLongValue]};
                nativeCurrent=dw_focus_owner(selected,&native);
            }
            source.nativeButtons=DWNativeButtonsAfterRefresh(report,current,identity,CACurrentMediaTime(),nativeCurrent,native);
            source.nativeButtonsMoveCandidate=nil;
            if(DWDebugTrace()){
                NSString *reason=DWTyped(source.nativeButtons[@"title_reason"],NSString.class)?:report?@"stale_report":@"report_unavailable";
                if(![source.nativeTitleDebugReason isEqual:reason]){
                    source.nativeTitleDebugReason=reason;
                    NSDictionary *detail=DWTyped(source.nativeButtons[@"title_detail"],NSDictionary.class);
                    NSString *geometry=detail?[[NSString alloc]initWithData:[NSJSONSerialization dataWithJSONObject:detail options:0 error:nil] encoding:NSUTF8StringEncoding]:nil;
                    fprintf(stderr,"debug: native title cache window=#%s pid=%d wid=%u region=%d reason=%s detail=%s\n",source.logical.description.UTF8String,source.router.pid,source.router.wid,DWTyped(source.nativeButtons[@"title"][@"region"],NSDictionary.class)!=nil,reason.UTF8String,geometry.UTF8String?:"none");
                }
            }
        });
    }});
}
- (BOOL)nativeGreen:(LiveSource *)source at:(CGPoint)point {
    if(!source.nativeButtons||CACurrentMediaTime()-[source.nativeButtons[@"sampled_at"]doubleValue]>1||![birth(source.router.pid)isEqual:source.router.processBirth]||!DWInScope(self.scope,source.router.pid))return NO;
    if(self.native.familiesNeeded){uint32_t parent=0;if(!DWNativeWindowParent(source.identity,&parent)||parent)return NO;}
    NSDictionary *info=windowInfo(source.router.wid);CGRect displayed=CGRectZero,own=CGRectZero;
    if([info[(id)kCGWindowOwnerPID]intValue]!=source.router.pid||![info[(id)kCGWindowIsOnscreen]boolValue]||[info[(id)kCGWindowAlpha]doubleValue]<=0
        ||!info[(id)kCGWindowBounds]||!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)info[(id)kCGWindowBounds],&displayed)||!DWNativeBounds(source.router.wid,&own))return NO;
    return DWNativeDecorationHit(source.nativeButtons,source.identity,own,displayed,point);
}
- (BOOL)replicaGreen:(LiveSource *)source at:(CGPoint)point output:(NSNumber *)output {
    if(!DWCapturedInputAvailable(source)||!source.pixels||(self.native&&![self.nativeViews replica:source.logical output:output])||!source.nativeButtons||CACurrentMediaTime()-[source.nativeButtons[@"sampled_at"]doubleValue]>1||!DWInScope(self.scope,source.router.pid)||![birth(source.router.pid)isEqual:source.router.processBirth])return NO;
    NSDictionary *placement=nil;for(NSDictionary *item in [self presentationSnapshot][@"placements"])if([item[@"window"]isEqual:source.logical]&&[item[@"output"]isEqual:output]){placement=item;break;}
    if(!placement||[placement[@"family_only"]boolValue])return NO;CGRect own=CGRectZero;
    NSDictionary *info=windowInfo(source.router.wid);
    if([info[(id)kCGWindowOwnerPID]intValue]!=source.router.pid||!DWNativeBounds(source.router.wid,&own)||!CGRectContainsPoint(DWRectFromJSON(placement[@"clip_rect"]),point))return NO;
    if(!self.native||self.native.familiesNeeded){uint32_t parent=0;if(!DWNativeWindowParent(source.identity,&parent)||parent)return NO;}
    return DWCapturedInputAvailable(source)&&DWNativeDecorationHit(source.nativeButtons,source.identity,own,DWRectFromJSON(placement[@"screen_rect"]),point);
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
// These are the actual window's events, observed before AppKit delivers them. Only
// a binding, pick-mode policy or normal resize border takes an annotated press;
// a qualified title down arrives earlier through the session-stage path. A
// plain interior click remains the app's.
// Once taken, the matching drag and release stay with this view even as a pan
// moves the window out from under the pointer. No global input is synthesized.
- (void)deliverNative:(NSEvent *)event type:(CGEventType)type view:(DesktopView *)view at:(CGPoint)point {
    [self deliverNative:event type:type view:view at:point familyHit:nil];
}
- (void)deliverNative:(NSEvent *)event type:(CGEventType)type view:(DesktopView *)view at:(CGPoint)point familyHit:(NSDictionary *)hit {
    BOOL saved=view.nativePointValid;CGPoint previous=view.nativePoint;NSDictionary *previousHit=view.nativeFamilyHit;view.nativePointValid=YES;view.nativePoint=point;view.nativeFamilyHit=hit;
    @try {
        switch(type){
            case kCGEventLeftMouseDown:case kCGEventRightMouseDown:case kCGEventOtherMouseDown:[view mouseDown:event];break;
            case kCGEventLeftMouseDragged:case kCGEventRightMouseDragged:case kCGEventOtherMouseDragged:[view mouseDragged:event];break;
            case kCGEventLeftMouseUp:case kCGEventRightMouseUp:case kCGEventOtherMouseUp:[view mouseUp:event];break;
            case kCGEventScrollWheel:[view scrollWheel:event];break;
            default:if(event.type==NSEventTypeMagnify)[view magnifyWithEvent:event];break;
        }
    } @finally {view.nativePointValid=saved;view.nativePoint=previous;view.nativeFamilyHit=previousHit;}
}
- (BOOL)validateInputTarget:(NSDictionary *)target {
    if(!target||self.cleaning||self.sessionInactive||self.native.ended||!AXIsProcessTrusted())return NO;
    LiveSource *source=self.sources[target[@"window"]];if(!source||source.detached)return NO;
    BOOL ownsOutput=NO;for(DesktopView *view in self.views)if([view.outputs containsObject:target[@"output"]])ownsOutput=YES;if(!ownsOutput)return NO;
    NSDictionary *binding=nil;for(NSDictionary *window in [self call:@{@"op":@"snapshot"}][@"windows"])if([window[@"window"]isEqual:source.logical])binding=DWTyped(window[@"source"],NSDictionary.class);
    if(![binding[@"generation"]isEqual:target[@"generation"]]||!boundIdentity(source.identity,binding[@"identity"])||!boundIdentity(source.identity,target[@"root_identity"]?:target[@"identity"]))return NO;
    if(!self.native&&![target[@"native_member"]boolValue])return boundIdentity(source.identity,target[@"identity"])&&[source.router valid];
    if(!DWInScope(self.scope,source.router.pid)||(self.native?![[self.native rootWindowFor:source.router.wid]isEqual:@(source.router.wid)]:![source.router valid]))return NO;
    // Admission from a copy also checks the active capture epoch in -forward:.
    // A release can outlive that capture geometry, but still belongs only to the
    // exact same freshly validated root binding and native descendant.
    return DWNativeWindowBelongsToRoot(target[@"identity"],source.identity);
}
- (BOOL)postInput:(CGEventRef)event target:(NSDictionary *)target local:(CGPoint)local {
    LiveSource *source=self.sources[target[@"window"]];if(!source||source.detached)return NO;
    if(!self.native&&![target[@"native_member"]boolValue])return [source.router post:event at:local];
    if(!event||![self validateInputTarget:target]){[self.relativeMotion reset];return NO;}
    CGRect bounds=DWRectFromJSON(target[@"native_bounds"]);CGEventType type=CGEventGetType(event);
    BOOL release=type==kCGEventLeftMouseUp||type==kCGEventRightMouseUp||type==kCGEventOtherMouseUp
        ||(DWNativeTabletProximityEvent(event)&&!CGEventGetIntegerValueField(event,kCGTabletProximityEventEnterProximity))
        ||(type==kCGEventTabletPointer&&CGEventGetDoubleValueField(event,kCGTabletEventPointPressure)==0&&!CGEventGetIntegerValueField(event,kCGTabletEventPointButtons));
    if(release){if(![self validateInputTarget:target]||!DWNativeBounds([target[@"identity"][@"wid"]unsignedIntValue],&bounds))return NO;}
    // Adapt a copy exactly once at the posting boundary. In particular the
    // physical event tap's packet must never inherit native coordinates or tags.
    CGEventRef packet=CGEventCreateCopy(event);if(!packet){[self.relativeMotion reset];return NO;}
    if(DWNativeRelativeMotionEvent(packet)){
        if(!self.relativeMotion)self.relativeMotion=[DWNativeRelativeMotion new];CGPoint scale=jsonPoint(target[@"motion_scale"]);
        if(![self.relativeMotion adjustEvent:packet target:target scaleX:scale.x scaleY:scale.y]){CFRelease(packet);return NO;}
    }
    if(!self.postingTags)self.postingTags=[NSMutableSet set];[self.postingTags addObject:@(source.router.tag)];
    BOOL sent=DWNativeReplicaPost(packet,source.router.eventSource,source.router.tag,target[@"identity"],bounds,local);
    CFRelease(packet);if(!sent)[self.relativeMotion reset];return sent;
}
- (NSDictionary *)resolveCapturedPointer:(NSDictionary *)target screen:(CGPoint)screen {
    if(![self validateInputTarget:target]||!isfinite(screen.x)||!isfinite(screen.y))return nil;
    NSDictionary *snapshot=[self presentationSnapshot],*placement=nil;
    LiveSource *source=self.sources[target[@"window"]];
    if(!DWCapturedInputAvailable(source)||!source.pixels||(self.native&&![self.nativeViews replica:source.logical output:target[@"output"]]))return nil;
    for(NSDictionary *item in snapshot[@"placements"])if([item[@"window"]isEqual:source.logical]&&[item[@"output"]isEqual:target[@"output"]]){placement=item;break;}
    NSDictionary *binding=nil;for(NSDictionary *window in [self call:@{@"op":@"snapshot"}][@"windows"])if([window[@"window"]isEqual:source.logical])binding=DWTyped(window[@"source"],NSDictionary.class);
    if(![binding[@"observation_known"]boolValue])return nil;
    CGRect own=CGRectZero,current=CGRectZero,site=DWRectFromJSON(placement[@"screen_rect"]);
    if(!source.router.bounds||!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)source.router.bounds,&own)
       ||!DWNativeBounds(source.router.wid,&current)||!CGRectEqualToRect(own,current)
       ||CGRectIsEmpty(own)||CGRectIsInfinite(own)||CGRectIsNull(own)
       ||CGRectIsEmpty(site)||CGRectIsInfinite(site)||CGRectIsNull(site))return nil;
    CGRect recipient=own;
    if([target[@"native_member"]boolValue]&&!DWNativeBounds([target[@"identity"][@"wid"]unsignedIntValue],&recipient))return nil;
    if(CGRectIsEmpty(recipient)||CGRectIsInfinite(recipient)||CGRectIsNull(recipient))return nil;
    // Keep the original output and recipient even beyond its viewport. A
    // moving camera changes this mapping, never the application's ownership.
    CGPoint scale=CGPointMake(own.size.width/site.size.width,own.size.height/site.size.height);
    CGPoint local=CGPointMake((screen.x-site.origin.x)*scale.x+own.origin.x-recipient.origin.x,
                             (screen.y-site.origin.y)*scale.y+own.origin.y-recipient.origin.y);
    if(!isfinite(scale.x)||!isfinite(scale.y)||!isfinite(local.x)||!isfinite(local.y))return nil;
    NSMutableDictionary *updated=[target mutableCopy];updated[@"native_bounds"]=DWRectJSON(recipient);updated[@"motion_scale"]=pointJSON(scale);
    return DWCapturedInputAvailable(source)?@{@"target":updated.copy,@"local":pointJSON(local)}:nil;
}
- (BOOL)forwardCapturedPointer:(CGEventRef)event screen:(CGPoint)screen {
    __weak Desktop *weak=self;
    BOOL sent=[self.pointerGrab forwardEvent:event screen:screen resolve:^NSDictionary *(NSDictionary *target,CGPoint point){return [weak resolveCapturedPointer:target screen:point];}
        validate:^BOOL(NSDictionary *target){return [weak validateInputTarget:target];}
        post:^BOOL(CGEventRef packet,NSDictionary *target,CGPoint local){return [weak postInput:packet target:target local:local];}];
    if(!self.pointerGrab.active)[self.relativeMotion reset];return sent;
}
- (BOOL)forwardTabletTail:(CGEventRef)event {
    if(![self.tablet ownsEvent:event])return NO;
    __weak Desktop *weak=self;NSDictionary *captured=[self.tablet capturedTargetForEvent:event];
    if(captured&&!DWCapturedInputAvailable(self.sources[captured[@"window"]])){
        // Closing an admitted contact checks its original identity, not capture
        // availability. Suppress its physical tail, including additional downs.
        [self.tablet cancelTargetsMatching:^BOOL(NSDictionary *target){return sameInputTarget(target,captured);}
            validate:^BOOL(NSDictionary *target){return [weak validateInputTarget:target];}
            post:^BOOL(CGEventRef packet,NSDictionary *target,CGPoint local){return [weak postInput:packet target:target local:local];}];
    }
    NSDictionary *resolved=nil;
    if(!DWNativeTabletProximityEvent(event)||CGEventGetIntegerValueField(event,kCGTabletProximityEventEnterProximity)){
        NSDictionary *target=[self.tablet capturedTargetForEvent:event];
        if(target)resolved=[self resolveCapturedPointer:target screen:CGEventGetLocation(event)];
    }
    // A held tool always retains its original root/member and output. A current
    // placement supplies the camera mapping even outside that display's clip.
    // Missing/stale geometry suppresses motion; release/tool-out still closes
    // the admitted recipient at its last validated application point.
    return [self.tablet forwardEvent:event target:resolved[@"target"] local:resolved?jsonPoint(resolved[@"local"]):CGPointZero validate:^BOOL(NSDictionary *target){return [weak validateInputTarget:target];} post:^BOOL(CGEventRef packet,NSDictionary *target,CGPoint local){return [weak postInput:packet target:target local:local];}];
}
- (void)cancelCapturedInputForWindow:(NSNumber *)window {
    __weak Desktop *weak=self;
    [self cancelNativeHoverForWindow:window];
    // A held down has not reached any native recipient. Cancel its entire
    // queued sequence without synthesizing a release or completed click.
    for(DesktopView *view in self.views)if(view.heldPress&&(!window||[view.heldWindow isEqual:window])){
        [view.heldTimer invalidate];view.heldTimer=nil;view.heldPress=view.heldDrag=view.heldRelease=nil;
        view.heldWindow=view.heldOutput=nil;view.heldIntent=nil;view.heldReleased=view.heldNavigate=NO;view.clickWindow=nil;
    }
    [self.tablet cancelTargetsMatching:^BOOL(NSDictionary *target){return !window||[target[@"window"]isEqual:window];} validate:^BOOL(NSDictionary *target){return [weak validateInputTarget:target];} post:^BOOL(CGEventRef event,NSDictionary *target,CGPoint local){return [weak postInput:event target:target local:local];}];
    if(!window||[self.pointerGrab.target[@"window"]isEqual:window]){
        [self.pointerGrab cancelWithValidate:^BOOL(NSDictionary *target){return [weak validateInputTarget:target];} post:^BOOL(CGEventRef event,NSDictionary *target,CGPoint local){return [weak postInput:event target:target local:local];}];
        [self.relativeMotion reset];
    }
}
- (BOOL)earlyNativeTitle:(CGEventType)type event:(CGEventRef)cg {
    if(!cg||type!=kCGEventLeftMouseDown||CGEventGetIntegerValueField(cg,kCGMouseEventButtonNumber)!=0
        ||DWNativeTabletEvent(cg)||!self.native||[self nativeUnavailable]||self.cleaning||self.sessionInactive
        ||self.routingEarlyNativeTitle||self.nativeGestureView||self.nativeScrollView||self.nativeMagnifyView||self.pointerGrab.active
        ||self.gestureOwner||self.trackpad.engaged||self.globalGestureContact||self.globalTrackpad.ownsTouches
        ||self.globalTrackpad.hasNativeMousePress||self.magnifying||(NSEvent.pressedMouseButtons&~1UL))return NO;
    NSEvent *event=[NSEvent eventWithCGEvent:cg];if(!event||event.subtype==NSEventSubtypeTouch)return NO;
    CGPoint point=CGEventGetLocation(cg);DesktopView *view=nil;NSNumber *output=nil;
    for(DesktopView *candidate in self.views){
        if(candidate.gesture||candidate.heldPress||candidate.pressedSource||candidate.pressedTablet||candidate.pressedPointerGrab)return NO;
        NSNumber *found=[candidate outputAt:point];if(found){if(view)return NO;view=candidate;output=found;}
    }
    if(!view)return NO;
    NSDictionary *recipient=DWNativeEventRecipientAtPoint(point);CGWindowID wid=[recipient[@"wid"]unsignedIntValue];LiveSource *source=nil;
    // A temporary background has no current logical hit site. Refuse its
    // complete native family before title tracking, even without chrome data.
    NSNumber *root=[self.native rootWindowFor:wid];
    for(LiveSource *held in self.sources.allValues){NSDictionary *identity=held.identity;
        if(held.nativeVisibilityHeld&&!held.detached&&[root isEqual:identity[@"wid"]]
            &&[recipient[@"pid"]isEqual:identity[@"pid"]]&&[recipient[@"birth_sec"]isEqual:identity[@"birth_sec"]]
            &&[recipient[@"birth_usec"]isEqual:identity[@"birth_usec"]]&&DWInScope(self.scope,held.router.pid)){
            [self cancelNativeTitleClick];self.nativeFillBlockedButtons|=1;return YES;
        }
    }
    for(NSDictionary *placement in self.nativeFillHandoff[@"background"][@"placements"]){
        LiveSource *background=self.sources[placement[@"window"]];NSDictionary *identity=background.identity;
        if(background&&!background.detached&&[placement[@"output"]isEqual:self.nativeFillHandoff[@"output"]]
            &&boundIdentity(placement[@"source"][@"identity"],identity)&&[root isEqual:identity[@"wid"]]
            &&[recipient[@"pid"]isEqual:identity[@"pid"]]&&[recipient[@"birth_sec"]isEqual:identity[@"birth_sec"]]
            &&[recipient[@"birth_usec"]isEqual:identity[@"birth_usec"]]&&DWInScope(self.scope,background.router.pid)){
            [self cancelNativeTitleClick];self.nativeFillBlockedButtons|=1;return YES;
        }
    }
    for(LiveSource *candidate in self.sources.allValues)
        if(!candidate.detached&&candidate.router.wid==wid&&boundIdentity(recipient,candidate.identity)){source=candidate;break;}
    if(!source||!DWInScope(self.scope,source.router.pid))return NO;
    // Physical chrome recognition precedes logical/renderer admission. An
    // unavailable ACK or layout must never lend a recognized down to AppKit.
    BOOL title=DWNativeWindowDragHit(source.identity,source.nativeButtons,point);
    BOOL green=!title&&[self nativeGreen:source at:point];
    NSDictionary *snapshot=[self call:@{@"op":@"snapshot"}],*record=nil,*placement=nil,*out=nil;
    for(NSDictionary *row in snapshot[@"windows"])if([row[@"window"]isEqual:source.logical]){record=row;break;}
    for(NSDictionary *row in snapshot[@"placements"])if([row[@"window"]isEqual:source.logical]&&[row[@"output"]isEqual:output]){placement=row;break;}
    for(NSDictionary *row in snapshot[@"outputs"])if([row[@"id"]isEqual:output]){out=row;break;}
    NSDictionary *binding=DWTyped(record[@"source"],NSDictionary.class);CGRect own=CGRectZero,displayed=CGRectZero;NSDictionary *info=windowInfo(wid);
    BOOL frame=[info[(id)kCGWindowOwnerPID]intValue]==source.router.pid&&[info[(id)kCGWindowIsOnscreen]boolValue]&&[info[(id)kCGWindowAlpha]doubleValue]>0
        &&info[(id)kCGWindowBounds]&&CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)info[(id)kCGWindowBounds],&displayed)
        &&DWNativeBounds(wid,&own)&&DWNativeChromeFrameMatches(own,displayed,placement,out,point);
    NSMutableDictionary *context=[@{@"window":source.logical}mutableCopy];for(NSString *flag in @[@"pinned",@"widget"])if([placement[flag]boolValue])context[flag]=@YES;
    NSDictionary *hit=context[@"pinned"]||context[@"widget"]||[placement[@"fullscreen"]boolValue]?context:DWPickHit(context,snapshot,output);
    NSDictionary *border=frame?[view resizeBorderForButton:0 flags:event.modifierFlags hit:hit at:point output:output]:nil;
    if(border&&![border[@"window"]isEqual:source.logical])border=nil;
    if(!title&&!green&&!border)return NO; // Unknown content and native controls keep their original packets.
    [self cancelNativeTitleClick];[self.navigation cancelNativeClick];
    self.nativeGestureView=view;self.nativeGestureButton=0;
    const char *refusal=NULL;
    if(!frame)refusal="physical_frame";
    else if(!binding[@"generation"]||!boundIdentity(source.identity,binding[@"identity"]))refusal="binding";
    else if(![[self.nativeViews desiredOwnerForWindow:source.logical]isEqual:output]||[self.nativeViews replica:source.logical output:output])refusal="native_owner";
    else if(self.nativeFillHandoff||source.nativeMouseOwnership||self.nativeOwnershipTransfer||self.nativeHoverTransfer||[[self.resize busyWindow]isEqual:source.logical])refusal="geometry_owned";
    else if([hit[@"widget"]boolValue])refusal="widget";
    if(refusal){DWNativeTitleRefused(YES,refusal,source.logical,wid,point,nil);return YES;}
    NSDictionary *intent=@{@"window":source.logical,@"output":output,@"identity":source.identity.copy,@"generation":binding[@"generation"]};
    NSEventModifierFlags modifiers=event.modifierFlags&(NSEventModifierFlagCommand|NSEventModifierFlagControl|NSEventModifierFlagOption|NSEventModifierFlagShift);
    NSDictionary *mouseBinding=[self mouseBinding:@"left" source:nil flags:event.modifierFlags window:YES under:source.logical pick:[hit[@"pick"]boolValue]];
    NSString *kind=DWTyped(mouseBinding[@"kind"],NSString.class);
    BOOL actionBinding=[@[@"pan_viewport",@"move_window",@"move_snapped_windows",@"resize_window",@"resize_window_snapped",@"center_nearest",@"action"]containsObject:kind?:@""];
    if((green&&!(modifiers&(NSEventModifierFlagCommand|NSEventModifierFlagControl|NSEventModifierFlagShift)))
        ||(title&&!modifiers&&!mouseBinding&&![hit[@"pick"]boolValue]&&event.clickCount==2)){
        NSMutableDictionary *press=[intent mutableCopy];press[@"action"]=(green&&(modifiers&NSEventModifierFlagOption))?@"fit":@"fullscreen";
        press[@"start"]=pointJSON(point);press[@"replica"]=@NO;if(title)press[@"title"]=@YES;
        self.nativeDecorationPress=press;return YES;
    }
    if(!border&&!actionBinding&&(!title||modifiers||mouseBinding||[hit[@"pick"]boolValue])){
        DWNativeTitleRefused(YES,"chrome_policy",source.logical,wid,point,nil);return YES;
    }
    // Same initialization as a canvas press, without a second renderer hit.
    // This dispatches controller gestures only; it cannot enter holdPress or
    // post a content click. Native/capture metadata is never rewritten.
    view.clickWindow=nil;[self.navigation releaseCycle];[self cancelGestures];[self cancelNavigation];[self.panLaunch cancel];view.scrollPanTime=0;
    NSDictionary *current=[self call:@{@"op":@"snapshot"}],*currentBinding=nil;
    for(NSDictionary *row in current[@"windows"])if([row[@"window"]isEqual:source.logical]){currentBinding=DWTyped(row[@"source"],NSDictionary.class);break;}
    if(self.cleaning||self.sessionInactive||self.native.ended||self.sources[source.logical]!=source||source.detached
        ||!boundIdentity(source.identity,currentBinding[@"identity"])||![binding[@"generation"]isEqual:currentBinding[@"generation"]]
        ||![[self.nativeViews desiredOwnerForWindow:source.logical]isEqual:output]||![recipient isEqual:DWNativeEventRecipientAtPoint(point)]){
        DWNativeTitleRefused(YES,"changed_before_chrome",source.logical,wid,point,nil);return YES;
    }
    view.startPoint=view.lastPoint=point;view.dragOutput=view.lastOutput=output;view.gestureButton=0;view.lastDragPan=0;view.lastScrollPan=0;view.clearsFocus=NO;
    if(border){[view beginResize:source.logical edges:DWTyped(border[@"edges"],NSString.class) snapped:[border[@"snapped"]boolValue] at:point output:output];[self render];}
    else if(actionBinding){
        // Use the already selected binding, with no ordinary-click fallback.
        // Re-entering press: could re-resolve policy and forward a native down.
        if([kind isEqual:@"move_window"]||[kind isEqual:@"move_snapped_windows"]){
            NSDictionary *begun=[self call:@{@"op":@"begin_drag",@"window":source.logical,@"output":output,@"group":@([kind isEqual:@"move_snapped_windows"])}];
            if(begun){view.gesture=2;[self.navigation perform:begun];}
        }else if([kind isEqual:@"resize_window"]||[kind isEqual:@"resize_window_snapped"])
            [view beginResize:source.logical edges:nil snapped:[kind isEqual:@"resize_window_snapped"] at:point output:output];
        else if([kind isEqual:@"pan_viewport"])view.gesture=1;
        else if([kind isEqual:@"center_nearest"]){view.gesture=DWPolicyPress;[view.hover nearestPress:point output:output focus:[mouseBinding[@"focus"]isEqual:@YES]];}
        else if([kind isEqual:@"action"]&&DWTyped(mouseBinding[@"action"],NSString.class)){
            [self applyReply:[self call:@{@"op":@"focus",@"window":source.logical}]];
            [self action:mouseBinding[@"action"] output:output at:point held:[DWCycleHold modifiersDown]!=0];
        }
        [self render];
    }
    else {
        view.nativeTitlePress=intent;view.nativeTitleMoved=view.nativeTitleReleased=NO;
        NSDictionary *begun=[self call:@{@"op":@"begin_drag",@"window":source.logical,@"output":output,@"group":@NO}];
        if(begun){view.gesture=2;[self.navigation perform:begun];}[self render];
    }
    if(DWDebugTrace())fprintf(stderr,"debug: native chrome owned window=#%s kind=%s gesture=%ld\n",source.logical.description.UTF8String,border?"resize":actionBinding?"binding":"title",(long)view.gesture);
    return YES;
}
// Is a mouse-moved packet at `point`, over the managed native window `root` (the window server's own answer to what is under the
// pointer), one the application must not get: below [zoom] interact_min (DWPickMotion, DWControllerHit.h) a canvas window is a pick target
// and a widget, a screen-pinned and a fullscreen window are not (upstream's pointer_focus_under_pick; their placement says which). The
// window server delivers the motion to the real window under the pointer by itself, so the tap dropping the packet is all that keeps
// hover from the application. Every moved packet comes here, so nothing in it calls the controller: the last render's outputs say
// whether the pointer's output is in pick mode, and only then is the last rendered presentation's placement of the window read.
- (BOOL)pickMotionAt:(CGPoint)point window:(NSNumber *)root {
    static NSDictionary *pick;if(!pick)pick=@{@"pick":@YES};
    return DWPickMotion(self.pointerOutputs,point,^NSDictionary *(NSNumber *output){
        for(NSNumber *logical in self.sources){LiveSource *source=self.sources[logical];
            if(source.detached||source.router.wid!=root.unsignedIntValue)continue;
            for(NSDictionary *placement in self.renderedPresentation[@"placements"])if([placement[@"window"]isEqual:logical]&&[placement[@"output"]isEqual:output])
                return [placement[@"widget"]boolValue]||[placement[@"pinned"]boolValue]||[placement[@"fullscreen"]boolValue]?nil:pick;
            return nil;}
        return nil;});
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
        // Below [zoom] interact_min a window takes no pointer input, hover included (POINTER.md): the canvas has had this motion above, so
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
