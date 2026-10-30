// SPDX-License-Identifier: GPL-3.0-or-later
// Desktop native chrome buttons and titles: the AX button map, green-button admission, the session-stage title press, pick-mode motion.
// Split from native/app/Desktop/Desktop+Input.m (0b3f028; native/desktop/main.m at 37b27b1), moved verbatim.
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
@implementation Desktop (NativeTitles)
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
@end
