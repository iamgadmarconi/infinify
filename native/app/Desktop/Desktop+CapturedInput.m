// SPDX-License-Identifier: GPL-3.0-or-later
// Desktop captured-input forwarding: native event delivery, input target validation, posting and tablet tails.
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
@implementation Desktop (CapturedInput)
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
@end
