// SPDX-License-Identifier: GPL-3.0-or-later
// Press admission extracted from Desktop categories at 7d4a6d6; original split from native/desktop/main.m at 37b27b1.
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
#import "DWNativeResize.h"
#import "DWAXLookup.h"
#import "DWControllerHit.h"
#import "DWGeometryJSON.h"
#import "DWPressAdmission.h"
#import "DWPressGesture.h"
// This authorizes only our own chrome gesture, never forwarding content. The
// physical root must already be where the controller expects it, including the
// pin's unit scale; a stale capture/renderer receipt is immaterial to that fact.
static BOOL DWNativeChromeFrameMatches(CGRect own,CGRect displayed,DWPlacement *placement,DWOutput *output,CGPoint point) {
    CGRect wanted=(placement?placement.nativeScreenRect:CGRectZero),clip=(output?output.nativeScreenBounds:CGRectZero);
    double scale=[placement.pinned boolValue]?1:output.nativeZoom;
    if(!isfinite(scale)||scale<=0||!isfinite(own.size.width)||!isfinite(own.size.height)||own.size.width<=0||own.size.height<=0
        ||!isfinite(displayed.origin.x)||!isfinite(displayed.origin.y)||!isfinite(displayed.size.width)||!isfinite(displayed.size.height)
        ||displayed.size.width<=0||displayed.size.height<=0||[placement.familyOnly boolValue]
        ||!CGRectContainsPoint(clip,point))return NO;
    return fabs(wanted.size.width-own.size.width*scale)<=1.01&&fabs(wanted.size.height-own.size.height*scale)<=1.01
        &&fabs(CGRectGetMinX(wanted)-CGRectGetMinX(displayed))<=1.01&&fabs(CGRectGetMaxX(wanted)-CGRectGetMaxX(displayed))<=1.01
        &&fabs(CGRectGetMinY(wanted)-CGRectGetMinY(displayed))<=1.01&&fabs(CGRectGetMaxY(wanted)-CGRectGetMaxY(displayed))<=1.01;
}
static const NSTimeInterval DWNativeGreenMapLifetime=1;
// Failed AX refresh is not a new chrome observation. Only a still-public map
// can survive it, under its original title-hit age and exact native geometry.
// A returned report (including a negative title result) always supersedes it.
static NSDictionary *DWNativeButtonsAfterRefresh(NSDictionary *report,NSDictionary *current,NSDictionary *identity,
    CFTimeInterval now,BOOL nativeCurrent,CGRect native) {
    if(report){
        if([report[@"title_incomplete"]boolValue]&&current&&[current[@"title"]count]){
            double currentSampled=[current[@"sampled_at"]doubleValue],currentAge=now-currentSampled;
            if(nativeCurrent&&[current[@"identity"]isEqual:identity]&&isfinite(currentSampled)&&currentSampled>0
                &&isfinite(currentAge)&&currentAge>=0&&currentAge<=.5&&isfinite(native.origin.x)&&isfinite(native.origin.y)
                &&isfinite(native.size.width)&&isfinite(native.size.height)&&native.size.width>0&&native.size.height>0
                &&CGRectEqualToRect(DWRectFromJSON(current[@"native_bounds"]),native)
                &&CGRectEqualToRect(DWRectFromJSON(report[@"native_bounds"]),native))return current;
        }
        // A busy main queue can delay publication. Keep evidence that is
        // still valid for green-button hit testing. Title hits check their own
        // shorter lifetime when the press arrives.
        double age=now-[report[@"sampled_at"]doubleValue];
        return age>=0&&age<=DWNativeGreenMapLifetime?report:nil;
    }
    double sampled=[current[@"sampled_at"]doubleValue],age=now-sampled;
    if(!current||!nativeCurrent||![current[@"identity"]isEqual:identity]||!isfinite(sampled)||sampled<=0
        ||!isfinite(age)||age<0||age>.5||!isfinite(native.origin.x)||!isfinite(native.origin.y)
        ||!isfinite(native.size.width)||!isfinite(native.size.height)||native.size.width<=0||native.size.height<=0
        ||!CGRectEqualToRect(DWRectFromJSON(current[@"native_bounds"]),native))return nil;
    return current;
}
// Scheduling evidence is separate from hit-test authority: old maps may only
// avoid an AX read for known content, never authorize an old chrome hit.
@interface DWPressChromeSchedule : NSObject
@property NSDictionary *goodMap;
@property id generation;
@property uint64_t revision,session,requested,completed;
@property BOOL failed,keyBurst;
@property uint64_t keySerial;
@end
@implementation DWPressChromeSchedule
@end

@interface DWPressAdmission ()
@property (weak) Desktop *desktop;
@property (readwrite) DesktopView *gestureView;
@property (weak) LiveSource *nativeMouseOwner;
@property id<DWPressSceneLookup> scene;
@property id<DWPressNativeLookup> nativeLookup;
@property NSDictionary *onDemandButtons;
@property NSMapTable<DesktopView *,DWPressGesture *> *titleGestures;
@property uint64_t nativeFillBlockedButtons;
@property BOOL nativeFillBlockedScroll;
@property NSInteger nativeGestureButton;
@property NSDictionary *nativeDecorationPress;
@property NSNumber *nativeButtonHover;
@property CFTimeInterval nativeButtonMotion;
@property dispatch_queue_t nativeButtonQueue;
@property NSMapTable<LiveSource *,DWPressChromeSchedule *> *chromeSchedules;
@property CGPoint chromePointer;
@property BOOL chromePointerKnown;
@property BOOL chromeHoverRefreshPending;
- (void)readNativeButtons:(LiveSource *)source;
- (void)requestNativeButtons:(LiveSource *)source;
- (BOOL)settledContent:(LiveSource *)source at:(CGPoint)point;
- (void)refreshNativeButtons:(LiveSource *)source;
- (BOOL)nativeGreen:(LiveSource *)source at:(CGPoint)point;
- (BOOL)replicaGreen:(LiveSource *)source at:(CGPoint)point output:(NSNumber *)output;
- (BOOL)earlyNativeTitle:(CGEventType)type event:(CGEventRef)cg;
- (BOOL)pickMotionAt:(CGPoint)point window:(NSNumber *)root;
- (void)cancelNativeInput;
- (BOOL)nativeInput:(CGEventType)type event:(CGEventRef)cg;
- (LiveSource *)nativeSource:(CGWindowID)window at:(CGPoint)point;
- (void)nativeMouseOwnershipChanged:(CGEventRef)event buttons:(NSIndexSet *)buttons;
- (BOOL)takeOverNativeDrag:(LiveSource *)source event:(CGEventRef)event;
- (BOOL)takeOverNativeDrag:(LiveSource *)source at:(CGPoint)point early:(BOOL)early;
- (void)watchNativePress:(LiveSource *)source;
- (void)finishNativeMouseOwner:(LiveSource *)source reason:(NSString *)reason;
- (void)updateNativeMouseOwners;
@end

static BOOL decorationDragMiss(NSDictionary *identity,CGPoint point,const char *reason){
    if(getenv("INFINIFY_DEBUG"))fprintf(stderr,"debug: native title miss pid=%d wid=%u point=%g,%g reason=%s\n",[identity[@"pid"]intValue],[identity[@"wid"]unsignedIntValue],point.x,point.y,reason);
    return NO;
}
// The one rule that turns a title report into "canvas-owned" or not, for a point in window-local native points: nil when the point is
// inside the title region (or one of its additional regions) and in none of the native control rectangles, else why not. Shared by the
// live press path and the recorded-shape tests.
static NSString *decorationRegionVerdict(NSDictionary *title,CGPoint local){
    NSArray *regions=[@[title]arrayByAddingObjectsFromArray:[title[@"additional_regions"]isKindOfClass:NSArray.class]?title[@"additional_regions"]:@[]];
    BOOL inside=NO;
    for(NSDictionary *candidate in regions){
        if(CGRectContainsPoint(DWRectFromJSON(candidate[@"region"]),local))inside=YES;
        for(NSDictionary *excluded in candidate[@"excluded"])if(CGRectContainsPoint(DWRectFromJSON(excluded),local)){CGRect frame=DWRectFromJSON(excluded);
            return [NSString stringWithFormat:@"excluded=%g,%g,%g,%g",frame.origin.x,frame.origin.y,frame.size.width,frame.size.height];}
    }
    if(inside)return nil;CGRect region=DWRectFromJSON(title[@"region"]);
    return [NSString stringWithFormat:@"outside title=%g,%g,%g,%g",region.origin.x,region.origin.y,region.size.width,region.size.height];
}

// The published NSDictionary is an immutable view, not a copy: the native watch
// compares record identity. Only admission creates and mutates the backing record.
static NSMutableDictionary *mutableMouseOwnership(LiveSource *source) {
    return (NSMutableDictionary *)source.nativeMouseOwnership;
}
static uint64_t DWClickRevertToken;
@implementation DWPressAdmission
- (void)displayTopologyChanged {
    // Existing display notification: revoke even non-hovered negative evidence.
    self.chromeSchedules=[NSMapTable weakToStrongObjectsMapTable];
    [self refreshHoveredChrome];
    for(LiveSource *source in self.desktop.sources.allValues){
        NSMutableDictionary *held=mutableMouseOwnership(source);
        if(held){held[@"topology_changed"]=@YES;[held removeObjectForKey:@"stable_since"];}
    }
}
- (void)forgetNativeMouseOwner {
    self.nativeMouseOwner=nil;
    for(LiveSource *source in self.desktop.sources.allValues){[(NSTimer *)source.nativeMouseOwnership[@"watch"]invalidate];source.nativeMouseOwnership=nil;source.nativeMouseAdopting=NO;source.observationToken=++self.desktop.observationEpoch;}
}
- (BOOL)consume:(CGEventType)type event:(CGEventRef)event stage:(DWPressStage)stage {
    return stage==DWPressSession?[self earlyNativeTitle:type event:event]:[self nativeInput:type event:event];
}
- (BOOL)titleHit:(NSDictionary *)identity report:(NSDictionary *)report at:(CGPoint)point {
    if(!NSThread.isMainThread)return decorationDragMiss(identity,point,"stale_report");
    LiveSource *mappedSource=nil;
    for(LiveSource *source in self.desktop.sources.allValues)
        if([source.identity isEqual:identity]){mappedSource=source;break;}
    if([self settledContent:mappedSource at:point])return NO;
    NSDictionary *recipient=[self.nativeLookup recipient:point];
    for(NSString *key in @[@"pid",@"wid",@"birth_sec",@"birth_usec"])if(!identity[key]||![identity[key]isEqual:recipient[key]])return decorationDragMiss(identity,point,"recipient_changed");
    
    CGRect own;if(![self.nativeLookup owner:identity bounds:&own])return decorationDragMiss(identity,point,"native_unavailable");
    NSArray *rows=[self.nativeLookup windows:[identity[@"wid"]unsignedIntValue]];
    if(rows.count!=1)return decorationDragMiss(identity,point,"window_list_changed");NSDictionary *row=rows[0];CGRect displayed;
    if([row[(id)kCGWindowOwnerPID]intValue]!=[identity[@"pid"]intValue]||![row[(id)kCGWindowIsOnscreen]boolValue]||[row[(id)kCGWindowAlpha]doubleValue]<=0
        ||!row[(id)kCGWindowBounds]||!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)row[(id)kCGWindowBounds],&displayed)||CGRectIsEmpty(displayed)||!CGRectContainsPoint(displayed,point))return decorationDragMiss(identity,point,"not_in_displayed_window");
    CFTimeInterval now=[self.nativeLookup mediaTime];
    BOOL usable=report&&[report[@"identity"]isEqual:identity]&&now-[report[@"sampled_at"]doubleValue]<=.5&&CGRectEqualToRect(own,DWRectFromJSON(report[@"native_bounds"]));
    if(!usable&&self.onDemandButtons&&[self.onDemandButtons[@"identity"]isEqual:identity]&&now-[self.onDemandButtons[@"sampled_at"]doubleValue]<=.5&&CGRectEqualToRect(own,DWRectFromJSON(self.onDemandButtons[@"native_bounds"]))){
        report=self.onDemandButtons;usable=YES;
    }
    if(!usable){
        // Only a completed scheduled read settles negative evidence. The
        // synchronous fallback (including failure) makes the whole window hot
        // until that asynchronous path publishes a complete map again.
        [self chromeSchedule:mappedSource].failed=YES;
        NSDictionary *fresh=[self.nativeLookup buttons:identity];
        if(fresh){self.onDemandButtons=fresh;report=fresh;usable=[report[@"identity"]isEqual:identity]&&[self.nativeLookup mediaTime]-[report[@"sampled_at"]doubleValue]<=.5;}
    }
    if(!usable)return decorationDragMiss(identity,point,"stale_report");
    CGRect cached=DWRectFromJSON(report[@"native_bounds"]);
    if(!CGRectEqualToRect(own,cached)){
        if(getenv("INFINIFY_DEBUG"))fprintf(stderr,"debug: native title miss native=%g,%g,%g,%g cached=%g,%g,%g,%g\n",own.origin.x,own.origin.y,own.size.width,own.size.height,cached.origin.x,cached.origin.y,cached.size.width,cached.size.height);
        return decorationDragMiss(identity,point,"native_changed");
    }
    NSDictionary *title=report[@"title"];CGRect region=DWRectFromJSON(title[@"region"]);if(CGRectIsEmpty(region))return decorationDragMiss(identity,point,"no_region");
    CGPoint local=CGPointMake((point.x-displayed.origin.x)*own.size.width/displayed.size.width,(point.y-displayed.origin.y)*own.size.height/displayed.size.height);
    NSString *verdict=decorationRegionVerdict(title,local);
    if(verdict){
        if(getenv("INFINIFY_DEBUG"))fprintf(stderr,"debug: native title miss local=%g,%g %s\n",local.x,local.y,verdict.UTF8String);
        return decorationDragMiss(identity,point,[verdict hasPrefix:@"excluded"]?"native_control":"outside_title");
    }
    CGRect after;if(![self.nativeLookup owner:identity bounds:&after]||!CGRectEqualToRect(own,after)
        ||![recipient isEqual:[self.nativeLookup recipient:point]])return decorationDragMiss(identity,point,"changed_during_hit");
    return YES;
}
- (DWHit *)hit:(CGPoint)point output:(NSNumber *)output view:(DesktopView *)view { return [self.scene hit:point output:output view:view]; }
- (NSDictionary *)decorationPress { return self.nativeDecorationPress; }
- (NSNumber *)buttonHover { return self.nativeButtonHover; }
- (NSDictionary *)fillHandoff { return self.desktop.sizeTransition.fillHandoff; }
- (instancetype)initWithDesktop:(Desktop *)desktop scene:(id<DWPressSceneLookup>)scene native:(id<DWPressNativeLookup>)native {
    if((self=[super init])){_desktop=desktop;_scene=scene;_nativeLookup=native;_titleGestures=[NSMapTable weakToStrongObjectsMapTable];_chromeSchedules=[NSMapTable weakToStrongObjectsMapTable];}
    return self;
}
- (DWPressChromeSchedule *)chromeSchedule:(LiveSource *)source {
    if(!source)return nil;
    DWPressChromeSchedule *state=[self.chromeSchedules objectForKey:source];
    if(!state){state=[DWPressChromeSchedule new];[self.chromeSchedules setObject:state forKey:source];}
    return state;
}
- (id)chromeGeneration:(LiveSource *)source {
    for(DWWindow *window in self.desktop.controller.visualScene.windows)
        if([window.window isEqual:source.logical])return window.source.generation;
    return nil;
}
// Cached presentation only. An unknown/ambiguous placement conservatively keeps
// the entire window hot. No WS, AX, controller command or guessed title height.
- (BOOL)chromeBand:(LiveSource *)source at:(CGPoint)point {
    DWPressChromeSchedule *state=[self.chromeSchedules objectForKey:source];
    NSDictionary *map=state.goodMap;
    if(!map||state.failed||[map[@"title_incomplete"]boolValue]||![map[@"identity"]isEqual:source.identity]
        ||state.revision!=source.nativeButtonsRevision||state.session!=self.desktop.nativeSessionEpoch
        ||![state.generation isEqual:[self chromeGeneration:source]]
        ||!CGRectEqualToRect(DWRectFromJSON(map[@"native_bounds"]),DWRectFromJSON(source.router.bounds))
        ||!map[@"title"][@"region"])return YES;
    CGRect own=DWRectFromJSON(map[@"native_bounds"]);
    if(CGRectIsEmpty(own))return YES;
    DWPlacement *placement=nil;
    for(DWPlacement *candidate in self.desktop.renderedPresentation.placements){
        if(![candidate.window isEqual:source.logical]||candidate.familyOnly.boolValue)continue;
        CGRect rect=candidate.nativeScreenRect;
        if(CGRectContainsPoint(CGRectInset(rect,-8,-8),point)){
            if(placement)return YES;placement=candidate;
        }
    }
    if(!placement)return YES;
    CGRect displayed=(placement?placement.nativeScreenRect:CGRectZero);
    double sx=displayed.size.width/own.size.width,sy=displayed.size.height/own.size.height;
    if(!isfinite(sx)||!isfinite(sy)||sx<=0||sy<=0)return YES;
    CGPoint local=CGPointMake((point.x-displayed.origin.x)/sx,(point.y-displayed.origin.y)/sy);
    // 8 native points, at least 4 display points, around every reported
    // title/caption/toolbar/button. Exclusions remain hot: they are native controls.
    double mx=fmax(8,4/sx),my=fmax(8,4/sy);
    NSDictionary *title=map[@"title"];
    NSArray *regions=[@[title]arrayByAddingObjectsFromArray:title[@"additional_regions"]?:@[]];
    for(NSDictionary *region in regions)
        if(CGRectContainsPoint(CGRectInset(DWRectFromJSON(region[@"region"]),-mx,-my),local))return YES;
    for(NSDictionary *button in map[@"buttons"])
        if(CGRectContainsPoint(CGRectInset(DWRectFromJSON(button),-mx,-my),local))return YES;
    // Superset of resize_border: its outside band is 8 canvas points, its
    // inside edge is 5 native points / at least 3 display points (quarter cap).
    // Using >=8 display points outside is conservative at supported zoom <=1.
    double bx=fmax(mx,8/sx),by=fmax(my,8/sy);
    CGRect outer=CGRectInset(displayed,-8,-8),inner=CGRectInset(displayed,bx*sx,by*sy);
    return CGRectContainsPoint(outer,point)&&!CGRectContainsPoint(inner,point);
}
- (BOOL)settledContent:(LiveSource *)source at:(CGPoint)point {
    if(!source)return NO;
    DWPressChromeSchedule *state=[self.chromeSchedules objectForKey:source];
    return source&&!source.detached&&state.goodMap&&state.goodMap==source.nativeButtons
        &&!state.failed&&!state.keyBurst&&!source.nativeButtonsReading
        &&state.requested==state.completed&&![self chromeBand:source at:point];
}
- (LiveSource *)hoveredChromeSource {
    NSPoint at=NSEvent.mouseLocation;CGPoint point=CGPointMake(at.x,screenTop()-at.y);
    self.chromePointer=point;self.chromePointerKnown=YES;
    CGWindowID wid=[self.nativeLookup windowAt:point];NSNumber *root=[self.desktop.native rootWindowFor:wid];
    LiveSource *hovered=nil;
    for(LiveSource *source in self.desktop.sources.allValues)
        if(!source.detached&&source.router.wid==root.unsignedIntValue){hovered=source;break;}
    if(!hovered)for(DesktopView *view in self.desktop.views)if((CGWindowID)view.window.windowNumber==wid){
        NSNumber *output=[view outputAt:point];DWHit *hit=output?[view hit:point output:output]:nil;
        LiveSource *source=self.desktop.sources[hit.window];
        if(source&&!source.detached&&!hit.nativeMember)hovered=source;break;
    }
    self.nativeButtonHover=hovered.logical;return hovered;
}
- (void)refreshHoveredChrome {
    if(self.desktop.cleaning||self.desktop.sessionInactive)return;
    [self requestNativeButtons:[self hoveredChromeSource]];
}
- (void)chromeKeyDown:(CGEventRef)event {
    // No NSEvent allocation or keyboard-layout lookup for ordinary typing:
    // qualify using only flags and the physical virtual-key code (F1..F20).
    CGEventFlags flags=CGEventGetFlags(event);
    int64_t code=CGEventGetIntegerValueField(event,kCGKeyboardEventKeycode);
    if(!(flags&(kCGEventFlagMaskCommand|kCGEventFlagMaskControl))&&code!=kVK_Escape){
        switch(code){
            case kVK_F1:case kVK_F2:case kVK_F3:case kVK_F4:case kVK_F5:
            case kVK_F6:case kVK_F7:case kVK_F8:case kVK_F9:case kVK_F10:
            case kVK_F11:case kVK_F12:case kVK_F13:case kVK_F14:case kVK_F15:
            case kVK_F16:case kVK_F17:case kVK_F18:case kVK_F19:case kVK_F20:break;
            default:return;
        }
    }
    if(self.desktop.cleaning||self.desktop.sessionInactive)return;
    LiveSource *source=[self hoveredChromeSource];if(!source)return;
    DWPressChromeSchedule *state=[self chromeSchedule:source];
    NSDictionary *identity=source.identity.copy;uint64_t session=self.desktop.nativeSessionEpoch;
    uint64_t serial=++state.keySerial;__weak DWPressAdmission *weak=self;
    if(!state.keyBurst){
        state.keyBurst=YES;
        // One early trailing read per burst, after the app sees the key.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,50*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
            DWPressAdmission *admission=weak;
            if(admission.desktop.nativeSessionEpoch==session&&[source.identity isEqual:identity]
                &&[admission.chromeSchedules objectForKey:source]==state)
                [admission requestNativeButtons:source];
        });
    }
    // One late read after 250 ms of quiet; obsolete timers never read AX.
    // Until both reads are accounted for, cached-content refusal is disabled.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,250*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
        DWPressAdmission *admission=weak;
        if(state.keySerial!=serial)return;
        state.keyBurst=NO;
        if(admission.desktop.nativeSessionEpoch==session&&[source.identity isEqual:identity]
            &&[admission.chromeSchedules objectForKey:source]==state)
            [admission requestNativeButtons:source];
    });
}
- (void)pollNativeButtons {
    // Draining an event request is independent of the band. Idle periodic work
    // is only for hovered chrome (including a missing/failed/incomplete map).
    for(LiveSource *source in self.chromeSchedules.keyEnumerator){
        DWPressChromeSchedule *state=[self.chromeSchedules objectForKey:source];
        if(state.requested!=state.completed)[self readNativeButtons:source];
    }
    LiveSource *hovered=self.desktop.sources[self.nativeButtonHover];
    if(hovered&&self.chromePointerKnown&&[self chromeBand:hovered at:self.chromePointer])
        [self readNativeButtons:hovered];
}
- (void)refreshNativeButtons:(LiveSource *)source {
    // Request the named window immediately, but resolve stationary hover only
    // once after this turn's observation batch (which can name every window of
    // a PID). Never multiply WindowServer/hit queries by the batch's size.
    [self requestNativeButtons:source];
    if(self.chromeHoverRefreshPending)return;
    self.chromeHoverRefreshPending=YES;__weak DWPressAdmission *weak=self;
    dispatch_async(dispatch_get_main_queue(),^{
        DWPressAdmission *admission=weak;
        admission.chromeHoverRefreshPending=NO;
        [admission refreshHoveredChrome];
    });
}
- (void)requestNativeButtons:(LiveSource *)source {
    if(!source)return;
    [self chromeSchedule:source].requested++;
    [self readNativeButtons:source];
}
- (void)readNativeButtons:(LiveSource *)source {
    CFTimeInterval now=[self.nativeLookup mediaTime];
    if(self.desktop.cleaning||self.desktop.sessionInactive||self.desktop.native.ended||!source||source.detached||source.nativeVisibilityHeld||source.nativeButtonsReading||source.nativeButtonsNext>now||![self.nativeLookup trusted]||![self.nativeLookup scope:self.desktop.scope contains:source.router.pid])return;
    source.nativeButtonsReading=YES;source.nativeButtonsNext=now+.2;
    DWPressChromeSchedule *state=[self chromeSchedule:source];
    uint64_t requested=state.requested;
    id generation=[self chromeGeneration:source];
    if(!self.nativeButtonQueue)self.nativeButtonQueue=dispatch_queue_create("org.infinify.native-decorations",dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,QOS_CLASS_USER_INITIATED,0));
    // Routine, unchanged window observations must not starve an AX chrome read.
    // Only source/chrome changes or a different native session invalidate it.
    NSDictionary *identity=[source.identity copy];uint64_t revision=source.nativeButtonsRevision,session=self.desktop.nativeSessionEpoch;__weak Desktop *weak=self.desktop;
    dispatch_async(self.nativeButtonQueue,^{@autoreleasepool{
        NSDictionary *report=[self.nativeLookup buttons:identity];
        dispatch_async(dispatch_get_main_queue(),^{Desktop *d=weak;source.nativeButtonsReading=NO;
            if(!d||d.cleaning||d.sessionInactive||d.native.ended||d.nativeSessionEpoch!=session||d.sources[source.logical]!=source||source.detached||source.nativeButtonsRevision!=revision||![source.identity isEqual:identity]||![self.nativeLookup scope:d.scope contains:source.router.pid])return;
            NSDictionary *current=source.nativeButtons;CGRect native=CGRectZero;BOOL nativeCurrent=NO;
            if((!report||[report[@"title_incomplete"]boolValue])&&current){
                nativeCurrent=[self.nativeLookup owner:identity bounds:&native];
            }
            source.nativeButtons=DWNativeButtonsAfterRefresh(report,current,identity,[self.nativeLookup mediaTime],nativeCurrent,native);
            source.nativeButtonsMoveCandidate=nil;
            state.completed=requested;
            state.failed=!report||[report[@"title_incomplete"]boolValue]||source.nativeButtons!=report;
            if(!state.failed){state.goodMap=report;state.revision=revision;state.session=session;state.generation=generation;}
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
    if([self settledContent:source at:point])return NO;
    if(![[self.nativeLookup birth:source.router.pid]isEqual:source.router.processBirth]||![self.nativeLookup scope:self.desktop.scope contains:source.router.pid])return NO;
    if(self.desktop.native.familiesNeeded){uint32_t parent=0;if(![self.nativeLookup parent:source.identity result:&parent]||parent)return NO;}
    NSDictionary *info=[self.nativeLookup windowInfo:source.router.wid];CGRect displayed=CGRectZero,own=CGRectZero;
    if([info[(id)kCGWindowOwnerPID]intValue]!=source.router.pid||![info[(id)kCGWindowIsOnscreen]boolValue]||[info[(id)kCGWindowAlpha]doubleValue]<=0
        ||!info[(id)kCGWindowBounds]||!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)info[(id)kCGWindowBounds],&displayed)
        ||!CGRectContainsPoint(displayed,point)||![self.nativeLookup bounds:source.router.wid result:&own])return NO;
    if(!source.nativeButtons||[self.nativeLookup mediaTime]-[source.nativeButtons[@"sampled_at"]doubleValue]>DWNativeGreenMapLifetime){
        [self chromeSchedule:source].failed=YES;
        NSDictionary *fresh=[self.nativeLookup buttons:source.identity];
        if(fresh)source.nativeButtons=fresh;
    }
    if(!source.nativeButtons||[self.nativeLookup mediaTime]-[source.nativeButtons[@"sampled_at"]doubleValue]>DWNativeGreenMapLifetime)return NO;
    return DWNativeDecorationHit(source.nativeButtons,source.identity,own,displayed,point);
}
- (BOOL)replicaGreen:(LiveSource *)source at:(CGPoint)point output:(NSNumber *)output {
    if(!DWCapturedInputAvailable(source)||!source.pixels||(self.desktop.native&&![self.desktop.nativeViews replica:source.logical output:output])||!source.nativeButtons||[self.nativeLookup mediaTime]-[source.nativeButtons[@"sampled_at"]doubleValue]>DWNativeGreenMapLifetime||![self.nativeLookup scope:self.desktop.scope contains:source.router.pid]||![[self.nativeLookup birth:source.router.pid]isEqual:source.router.processBirth])return NO;
    DWPlacement *placement=nil;for(DWPlacement *item in [self.scene presentationSnapshot].placements)if([item.window isEqual:source.logical]&&[item.output isEqual:output]){placement=item;break;}
    if(!placement||[placement.familyOnly boolValue])return NO;CGRect own=CGRectZero;
    NSDictionary *info=[self.nativeLookup windowInfo:source.router.wid];
    if([info[(id)kCGWindowOwnerPID]intValue]!=source.router.pid||![self.nativeLookup bounds:source.router.wid result:&own]||!CGRectContainsPoint((placement?placement.nativeClipRect:CGRectZero),point))return NO;
    if(!self.desktop.native||self.desktop.native.familiesNeeded){uint32_t parent=0;if(![self.nativeLookup parent:source.identity result:&parent]||parent)return NO;}
    return DWCapturedInputAvailable(source)&&DWNativeDecorationHit(source.nativeButtons,source.identity,own,(placement?placement.nativeScreenRect:CGRectZero),point);
}
- (BOOL)earlyNativeTitle:(CGEventType)type event:(CGEventRef)cg {
    if(!cg||type!=kCGEventLeftMouseDown||CGEventGetIntegerValueField(cg,kCGMouseEventButtonNumber)!=0
        ||DWNativeTabletEvent(cg)||!self.desktop.native||[self.desktop nativeUnavailable]||self.desktop.cleaning||self.desktop.sessionInactive
        ||self.gestureView||self.desktop.nativeScrollView||self.desktop.nativeMagnifyView||self.desktop.pointerGrab.active
        ||self.desktop.gestureOwner||self.desktop.trackpad.engaged||self.desktop.globalGestureContact||self.desktop.globalTrackpad.ownsTouches
        ||self.desktop.globalTrackpad.hasNativeMousePress||self.desktop.magnifying||([self.nativeLookup pressedButtons]&~1UL))return NO;
    NSEvent *event=[NSEvent eventWithCGEvent:cg];if(!event)return NO;
    CGPoint point=CGEventGetLocation(cg);DesktopView *view=nil;NSNumber *output=nil;
    for(DesktopView *candidate in self.desktop.views){
        if(candidate.gesture||candidate.heldPress||candidate.pressedSource||candidate.pressedTablet||candidate.pressedPointerGrab)return NO;
        NSNumber *found=[candidate outputAt:point];if(found){if(view)return NO;view=candidate;output=found;}
    }
    if(!view)return NO;
    NSDictionary *recipient=[self.nativeLookup recipient:point];CGWindowID wid=[recipient[@"wid"]unsignedIntValue];LiveSource *source=nil;
    // A temporary background has no current logical hit site. Refuse its
    // complete native family before title tracking, even without chrome data.
    NSNumber *root=[self.desktop.native rootWindowFor:wid];
    for(LiveSource *held in self.desktop.sources.allValues){NSDictionary *identity=held.identity;
        if(held.nativeVisibilityHeld&&!held.detached&&[root isEqual:identity[@"wid"]]
            &&[recipient[@"pid"]isEqual:identity[@"pid"]]&&[recipient[@"birth_sec"]isEqual:identity[@"birth_sec"]]
            &&[recipient[@"birth_usec"]isEqual:identity[@"birth_usec"]]&&[self.nativeLookup scope:self.desktop.scope contains:held.router.pid]){
            [self.desktop cancelNativeTitleClick];self.nativeFillBlockedButtons|=1;return YES;
        }
    }
    for(DWPlacement *placement in DWTyped([self fillHandoff][@"background"],DWScene.class).placements){
        LiveSource *background=self.desktop.sources[placement.window];NSDictionary *identity=background.identity;
        if(background&&!background.detached&&[placement.output isEqual:[self fillHandoff][@"output"]]
            &&boundIdentity(DWNativeIdentity(placement.source.identity),identity)&&[root isEqual:identity[@"wid"]]
            &&[recipient[@"pid"]isEqual:identity[@"pid"]]&&[recipient[@"birth_sec"]isEqual:identity[@"birth_sec"]]
            &&[recipient[@"birth_usec"]isEqual:identity[@"birth_usec"]]&&[self.nativeLookup scope:self.desktop.scope contains:background.router.pid]){
            [self.desktop cancelNativeTitleClick];self.nativeFillBlockedButtons|=1;return YES;
        }
    }
    for(LiveSource *candidate in self.desktop.sources.allValues)
        if(!candidate.detached&&candidate.router.wid==wid&&boundIdentity(recipient,candidate.identity)){source=candidate;break;}
    // WindowServer's early hit test excludes part of its native resize margin:
    // it can name our canvas here, then deliver the same down to the window at
    // the annotated tap, after native resizing has already begun. Ask the
    // controller for that border now, but ONLY through this view's exact panel.
    // A foreign window, child, overlay or another panel must remain an occluder.
    DWResizeBorder *canvasBorder=nil;
    if(!source&&view.window&&wid==(CGWindowID)view.window.windowNumber&&[recipient[@"pid"]intValue]==getpid()){
        canvasBorder=[view resizeBorderForButton:0 flags:event.modifierFlags hit:nil at:point output:output];
        LiveSource *candidate=canvasBorder?self.desktop.sources[canvasBorder.window]:nil;
        if(candidate&&!candidate.detached&&[[self.desktop.native rootWindowFor:candidate.router.wid]isEqual:@(candidate.router.wid)]
            &&[[self.nativeLookup birth:candidate.router.pid]isEqual:candidate.router.processBirth]){
            source=candidate;wid=source.router.wid;
        }
    }
    if(!source||![self.nativeLookup scope:self.desktop.scope contains:source.router.pid])return NO;
    // Physical chrome recognition precedes logical/renderer admission. An
    // unavailable ACK or layout must never lend a recognized down to AppKit.
    BOOL title=[self titleHit:source.identity report:source.nativeButtons at:point];
    BOOL green=!title&&[self nativeGreen:source at:point];
    DWScene *snapshot=[self.scene.controller scene];DWWindow *record=nil;DWPlacement *placement=nil;DWOutput *out=nil;
    for(DWWindow *row in snapshot.windows)if([row.window isEqual:source.logical]){record=row;break;}
    for(DWPlacement *row in snapshot.placements)if([row.window isEqual:source.logical]&&[row.output isEqual:output]){placement=row;break;}
    for(DWOutput *row in snapshot.outputs)if([row.identifier isEqual:output]){out=row;break;}
    DWSource *binding=record.source;CGRect own=CGRectZero,displayed=CGRectZero;NSDictionary *info=[self.nativeLookup windowInfo:wid];
    BOOL frame=[info[(id)kCGWindowOwnerPID]intValue]==source.router.pid&&[info[(id)kCGWindowIsOnscreen]boolValue]&&[info[(id)kCGWindowAlpha]doubleValue]>0
        &&info[(id)kCGWindowBounds]&&CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)info[(id)kCGWindowBounds],&displayed)
        &&[self.nativeLookup bounds:wid result:&own]&&DWNativeChromeFrameMatches(own,displayed,placement,out,point);
    DWHit *context=[DWHit hitWithWindow:source.logical identity:nil generation:nil local:nil nativeMember:nil pick:nil widget:placement.widget.boolValue?@YES:nil pinned:placement.pinned.boolValue?@YES:nil];
    DWHit *hit=context.pinned||context.widget||[placement.fullscreen boolValue]?context:DWPickHit(context,snapshot,output);
    DWResizeBorder *border=canvasBorder?: (frame?[view resizeBorderForButton:0 flags:event.modifierFlags hit:hit at:point output:output]:nil);
    if(border&&![border.window isEqual:source.logical])border=nil;
    // Below [zoom] interact_min every window is a pick target and takes no pointer input (upstream's try_pick_button): the press is the
    // canvas's whether or not the title is recognised. It has to be claimed here, at the session tap: WindowServer begins its own
    // window drag of a press in the title band between this tap and the annotated one, so a pick press left to that later tap moved
    // the native frame under the canvas move (the owner's UTM drag at low zoom, "native origin ... basis_only" for the whole drag),
    // and a recognised title press was refused below as chrome_policy and did nothing at all.
    if([hit.pick boolValue]&&[hit.window isEqual:source.logical]&&!hit.nativeMember&&!hit.widget&&!hit.pinned&&!(event.modifierFlags&(NSEventModifierFlagCommand|NSEventModifierFlagControl|NSEventModifierFlagOption|NSEventModifierFlagShift))){
        [self.desktop cancelNativeTitleClick];[self.desktop.navigation cancelNativeClick];
        self.gestureView=view;self.nativeGestureButton=0;
        [self.desktop deliverNative:event type:kCGEventLeftMouseDown view:view at:point];
        if(DWDebugTrace())fprintf(stderr,"debug: native chrome owned window=#%s kind=pick gesture=%ld\n",source.logical.description.UTF8String,(long)view.gesture);
        return YES;
    }
    // A press that a bound gesture claims (alt-drag moves, resizes and pans the canvas) is the canvas's whether or not Accessibility knows a
    // title there. Left to the annotated tap it was claimed after WindowServer had begun its own window drag of a title-band press, which then
    // ran under the canvas move (measured in the guest with the Option key held: the drawn window went to scale 1 for the whole drag).
    DWBinding *earlyBinding=!title&&!green&&!border&&!hit.widget&&!hit.nativeMember?[self.scene binding:@"left" source:nil flags:event.modifierFlags window:YES under:source.logical pick:[hit.pick boolValue]]:nil;
    BOOL chromeless=!title&&!green&&!border;
    if(chromeless&&![@[@"pan_viewport",@"move_window",@"move_snapped_windows",@"resize_window",@"resize_window_snapped"]containsObject:earlyBinding.kind?:@""])return NO; // Unknown content and native controls keep their original packets.
    const char *refusal=NULL;
    if(!frame)refusal="physical_frame";
    else if(!binding.generation||!boundIdentity(source.identity,DWNativeIdentity(binding.identity)))refusal="binding";
    else if(![[self.desktop.nativeViews desiredOwnerForWindow:source.logical]isEqual:output]||[self.desktop.nativeViews replica:source.logical output:output])refusal="native_owner";
    else if([self fillHandoff]||source.nativeMouseOwnership||self.desktop.nativeOwnershipTransfer||self.desktop.nativeHoverTransfer||[[self.desktop.sizeTransition busyWindow]isEqual:source.logical])refusal="geometry_owned";
    else if([hit.widget boolValue])refusal="widget";
    if(refusal&&chromeless){DWNativeTitleRefused(YES,refusal,source.logical,wid,point,nil);return NO;}
    [self.desktop cancelNativeTitleClick];[self.desktop.navigation cancelNativeClick];
    self.gestureView=view;self.nativeGestureButton=0;
    if(refusal){DWNativeTitleRefused(YES,refusal,source.logical,wid,point,nil);return YES;}
    NSDictionary *intent=@{@"window":source.logical,@"output":output,@"identity":source.identity.copy,@"generation":binding.generation};
    NSEventModifierFlags modifiers=event.modifierFlags&(NSEventModifierFlagCommand|NSEventModifierFlagControl|NSEventModifierFlagOption|NSEventModifierFlagShift);
    DWBinding *mouseBinding=[self.scene binding:@"left" source:nil flags:event.modifierFlags window:YES under:source.logical pick:[hit.pick boolValue]];
    NSString *kind=mouseBinding.kind;
    BOOL actionBinding=[@[@"pan_viewport",@"move_window",@"move_snapped_windows",@"resize_window",@"resize_window_snapped",@"center_nearest",@"action"]containsObject:kind?:@""];
    if((green&&!(modifiers&(NSEventModifierFlagCommand|NSEventModifierFlagControl|NSEventModifierFlagShift)))
        ||(title&&!modifiers&&!mouseBinding&&![hit.pick boolValue]&&event.clickCount==2)){
        NSMutableDictionary *press=[intent mutableCopy];press[@"action"]=(green&&(modifiers&NSEventModifierFlagOption))?@"fit":@"fullscreen";
        press[@"start"]=pointJSON(point);press[@"replica"]=@NO;if(title)press[@"title"]=@YES;
        self.nativeDecorationPress=press;return YES;
    }
    if(!border&&!actionBinding&&(!title||modifiers||mouseBinding||[hit.pick boolValue])){
        DWNativeTitleRefused(YES,"chrome_policy",source.logical,wid,point,nil);return YES;
    }
    // Same initialization as a canvas press, without a second renderer hit.
    // This dispatches controller gestures only; it cannot enter holdPress or
    // post a content click. Native/capture metadata is never rewritten.
    view.clickWindow=nil;[self.desktop.navigation releaseCycle];[self.desktop cancelGestures];[self.desktop cancelNavigation];[self.desktop.panLaunch cancel];view.scrollPanTime=0;
    DWScene *current=[self.scene.controller scene];DWSource *currentBinding=nil;
    for(DWWindow *row in current.windows)if([row.window isEqual:source.logical]){currentBinding=row.source;break;}
    if(self.desktop.cleaning||self.desktop.sessionInactive||self.desktop.native.ended||self.desktop.sources[source.logical]!=source||source.detached
        ||!boundIdentity(source.identity,DWNativeIdentity(currentBinding.identity))||![binding.generation isEqual:currentBinding.generation]
        ||![[self.desktop.nativeViews desiredOwnerForWindow:source.logical]isEqual:output]||![recipient isEqual:[self.nativeLookup recipient:point]]){
        DWNativeTitleRefused(YES,"changed_before_chrome",source.logical,wid,point,nil);return YES;
    }
    view.startPoint=view.lastPoint=point;view.dragOutput=view.lastOutput=output;view.gestureButton=0;view.lastDragPan=0;view.lastScrollPan=0;view.clearsFocus=NO;
    if(border){[view beginResize:source.logical edges:DWTyped(border.edges,NSString.class) snapped:[border.snapped boolValue] at:point output:output];[self.desktop render];}
    else if(actionBinding){
        // Use the already selected binding, with no ordinary-click fallback.
        // Re-entering press: could re-resolve policy and forward a native down.
        if([kind isEqual:@"move_window"]||[kind isEqual:@"move_snapped_windows"]){
            DWControllerReply *begun=[self.scene.controller beginDragWindow:source.logical output:output group:[kind isEqual:@"move_snapped_windows"]];
            if(begun){view.gesture=2;[self.desktop.navigation perform:begun];}
        }else if([kind isEqual:@"resize_window"]||[kind isEqual:@"resize_window_snapped"])
            [view beginResize:source.logical edges:nil snapped:[kind isEqual:@"resize_window_snapped"] at:point output:output];
        else if([kind isEqual:@"pan_viewport"])view.gesture=1;
        else if([kind isEqual:@"center_nearest"]){view.gesture=DWPolicyPress;[view.hover nearestPress:point output:output focus:[mouseBinding.focus isEqual:@YES]];}
        else if([kind isEqual:@"action"]&&mouseBinding.action){
            [self.desktop applyReply:[self.scene.controller focusWindow:source.logical]];
            [self.desktop action:mouseBinding.action output:output at:point held:[DWCycleHold modifiersDown]!=0];
        }
        [self.desktop render];
    }
    else {
        [self titleState:view].intent=intent;[self titleState:view].moved=[self titleState:view].released=NO;
        DWControllerReply *begun=[self.scene.controller beginDragWindow:source.logical output:output group:NO];
        if(begun){view.gesture=2;[self.desktop.navigation perform:begun];}[self.desktop render];
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
    static DWHit *pick;if(!pick)pick=[DWHit hitWithWindow:nil identity:nil generation:nil local:nil nativeMember:nil pick:@YES widget:nil pinned:nil];
    return DWPickMotion(self.desktop.pointerOutputs,point,^DWHit *(NSNumber *output){
        for(NSNumber *logical in self.desktop.sources){LiveSource *source=self.desktop.sources[logical];
            if(source.detached||source.router.wid!=root.unsignedIntValue)continue;
            for(DWPlacement *placement in self.desktop.renderedPresentation.placements)if([placement.window isEqual:logical]&&[placement.output isEqual:output])
                return [placement.widget boolValue]||[placement.pinned boolValue]||[placement.fullscreen boolValue]?nil:pick;
            return nil;}
        return nil;});
}
- (void)cancelNativeInput {
    [self.desktop cancelNativeTitleClick];
    [self.desktop.navigation cancelNativeClick];
    [self.desktop cancelNativeHoverForWindow:nil];
    self.nativeDecorationPress=nil;
    self.nativeButtonHover=nil;self.chromePointerKnown=NO;
    DesktopView *view=self.gestureView;self.gestureView=nil;
    if(view.gesture){view.clearsFocus=NO;view.lastDragPan=0;[view released:view.lastPoint at:NSProcessInfo.processInfo.systemUptime];}
    [self titleState:view].intent=nil;
    self.desktop.nativeScrollView.scrollPan=nil;self.desktop.nativeScrollView.scrollPanTime=0;self.desktop.nativeScrollView.lastScrollPan=0;
    self.desktop.nativeScrollView=nil;self.desktop.nativeScrollTime=0;[self.desktop.panLaunch cancel];
    if(self.desktop.nativeMagnifyView)[self.desktop cancelGestures];self.desktop.nativeMagnifyView=nil;self.desktop.nativeMagnifySource=nil;
}
- (BOOL)nativeInput:(CGEventType)type event:(CGEventRef)cg {
    int64_t tag=CGEventGetIntegerValueField(cg,kCGEventSourceUserData);
    if(tag&&[self.desktop.postingTags containsObject:@(tag)])return NO;
    if(tag)for(LiveSource *source in self.desktop.sources.allValues)if(source.router.tag==tag)return NO;
    // Native Fill owns temporary geometry. Consume each refused button's whole
    // pair, including its tail after the handoff ends; never map an intermediate
    // app frame through the controller's already-final camera.
    NSInteger fillButton=CGEventGetIntegerValueField(cg,kCGMouseEventButtonNumber);
    BOOL fillDown=type==kCGEventLeftMouseDown||type==kCGEventRightMouseDown||type==kCGEventOtherMouseDown;
    if(fillDown)[self.desktop cancelNativeTitleClick];
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
    if([self fillHandoff]&&(fillDown||type==kCGEventScrollWheel)){
        CGWindowID recipient=(CGWindowID)CGEventGetIntegerValueField(cg,kCGMouseEventWindowUnderMousePointerThatCanHandleThisEvent);
        if(!recipient)recipient=(CGWindowID)CGEventGetIntegerValueField(cg,kCGMouseEventWindowUnderMousePointer);
        NSNumber *root=[self.desktop.native rootWindowFor:recipient];
        BOOL held=[root isEqual:[self fillHandoff][@"identity"][@"wid"]];
        // Retained background windows are visual coverage only. Their current
        // fullscreen scene has no input site, so consume the complete pair.
        for(DWPlacement *placement in DWTyped([self fillHandoff][@"background"],DWScene.class).placements){
            LiveSource *live=self.desktop.sources[placement.window];
            if(live&&!live.detached&&[placement.output isEqual:[self fillHandoff][@"output"]]
                &&boundIdentity(DWNativeIdentity(placement.source.identity),live.identity)&&[root isEqual:live.identity[@"wid"]])held=YES;
        }
        for(DesktopView *view in self.desktop.views)if((CGWindowID)view.window.windowNumber==recipient)held=YES;
        if(held){if(fillDown)self.nativeFillBlockedButtons|=fillBit;if(fillScrollPhased&&!fillScrollEnd)self.nativeFillBlockedScroll=YES;return YES;}
    }
    if(fillDown||type==kCGEventScrollWheel){
        CGWindowID recipient=(CGWindowID)CGEventGetIntegerValueField(cg,kCGMouseEventWindowUnderMousePointerThatCanHandleThisEvent);
        if(!recipient)recipient=(CGWindowID)CGEventGetIntegerValueField(cg,kCGMouseEventWindowUnderMousePointer);
        NSNumber *root=[self.desktop.native rootWindowFor:recipient];
        for(LiveSource *source in self.desktop.sources.allValues)if(source.nativeVisibilityHeld&&[root isEqual:source.identity[@"wid"]]){
            if(fillDown)self.nativeFillBlockedButtons|=fillBit;if(fillScrollPhased&&!fillScrollEnd)self.nativeFillBlockedScroll=YES;return YES;
        }
    }
    // A shell-owned decoration/action pair predates any second button that
    // may have reached a captured child. That grab must not consume this up.
    BOOL nativePair=self.gestureView&&!DWNativeTabletEvent(cg)
        &&CGEventGetIntegerValueField(cg,kCGMouseEventButtonNumber)==self.nativeGestureButton
        &&(type==kCGEventLeftMouseDragged||type==kCGEventRightMouseDragged||type==kCGEventOtherMouseDragged
           ||type==kCGEventLeftMouseUp||type==kCGEventRightMouseUp||type==kCGEventOtherMouseUp);
    if(!nativePair&&[self.desktop.pointerGrab ownsEvent:cg]){
        NSDictionary *target=self.desktop.pointerGrab.target;CGPoint point=CGEventGetLocation(cg);
        [self.desktop forwardCapturedPointer:cg screen:point];
        BOOL up=type==kCGEventLeftMouseUp||type==kCGEventRightMouseUp||type==kCGEventOtherMouseUp;
        if(up)for(DesktopView *view in self.desktop.views)if(view.pressedPointerGrab&&(!target||sameInputTarget(view.pressedTarget,target))&&view.pressedButton==CGEventGetIntegerValueField(cg,kCGMouseEventButtonNumber)){
            // The adapter owns any other held buttons. End this view's gesture
            // without cancelling those independently paired native presses.
            view.pressedSource=nil;view.pressedTarget=nil;view.pressedPointerGrab=NO;
            [view released:point at:[NSEvent eventWithCGEvent:cg].timestamp];
        }
        return YES;
    }
    if(DWNativeTabletEvent(cg)){
        [self.desktop cancelNativeHoverForWindow:nil];
        if(!self.desktop.tablet)self.desktop.tablet=[DWNativeTabletRouter new];[self.desktop.tablet observeEvent:cg];
        if(self.desktop.cleaning||self.desktop.sessionInactive||self.desktop.native.ended){[self.desktop.tablet reset];return NO;}
        __weak Desktop *weak=self.desktop;
        NSDictionary *retired=[self.desktop.tablet retireReplacedToolForEvent:cg validate:^BOOL(NSDictionary *target){return [weak validateInputTarget:target];} post:^BOOL(CGEventRef packet,NSDictionary *target,CGPoint local){return [weak postInput:packet target:target local:local];}];
        NSNumber *device=@(CGEventGetIntegerValueField(cg,DWNativeTabletProximityEvent(cg)?kCGTabletProximityEventDeviceID:kCGTabletEventDeviceID));
        CGPoint point=CGEventGetLocation(cg);
        if(retired)for(DesktopView *view in self.desktop.views)if(view.pressedTablet&&[view.pressedTabletDevice isEqual:device]&&sameInputTarget(view.pressedTarget,retired)){
            view.pressedSource=nil;view.pressedTarget=nil;view.pressedTablet=NO;view.pressedTabletDevice=nil;view.clickWindow=nil;
            [view released:point at:[NSEvent eventWithCGEvent:cg].timestamp];
        }
        BOOL owned=[self.desktop.tablet ownsEvent:cg];
        NSDictionary *capturedTarget=[self.desktop.tablet capturedTargetForEvent:cg];
        BOOL toolOut=DWNativeTabletProximityEvent(cg)&&!CGEventGetIntegerValueField(cg,kCGTabletProximityEventEnterProximity);
        if(owned){
            // Ownership is established by the admitted tool, not today's hit.
            // Overlay and independent native views therefore share the same
            // contact tail even over another source, display or native app.
            [self.desktop forwardTabletTail:cg];
            BOOL up=type==kCGEventLeftMouseUp||type==kCGEventRightMouseUp||type==kCGEventOtherMouseUp;
            if(up||toolOut)for(DesktopView *view in self.desktop.views)if(view.pressedTablet&&[view.pressedTabletDevice isEqual:device]&&(!capturedTarget||sameInputTarget(view.pressedTarget,capturedTarget))&&(toolOut||view.pressedButton==CGEventGetIntegerValueField(cg,kCGMouseEventButtonNumber))){
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
        if(self.desktop.native&&(type==kCGEventTabletPointer||type==kCGEventTabletProximity)){
            CGPoint at=CGEventGetLocation(cg);
            for(DesktopView *view in self.desktop.views){NSNumber *output=[view outputAt:at];if(!output)continue;
                if([[view hit:at output:output].pick isEqual:@YES])return YES;
                break;}
        }
        if(type==kCGEventTabletPointer||type==kCGEventTabletProximity){
            // The overlay's fresh packets still go through AppKit's normal
            // canvas admission. Observing proximity above does not authorize
            // intercepting a pen which is drawing in an unrelated native app.
            if(!self.desktop.native)return NO;
            // Dedicated tablet packets may omit mouse-only annotations. Fresh
            // admission still belongs to the actual canvas panel under the pen,
            // never a logical replica covered by another application.
            CGWindowID recipient=[self.nativeLookup windowAt:point];
            for(DesktopView *view in self.desktop.views){NSNumber *output=[view outputAt:point];if(!output)continue;DWHit *hit=[view hit:point output:output];LiveSource *source=self.desktop.sources[hit.window];
                if(recipient!=(CGWindowID)view.window.windowNumber)return NO;
                if(!source||![self.desktop.nativeViews replica:source.logical output:output])return NO;
                BOOL old=view.nativePointValid;CGPoint previous=view.nativePoint;view.nativePointValid=YES;view.nativePoint=point;
                BOOL sent=NO;@try{sent=[view forward:cg at:point output:output];}@finally{view.nativePointValid=old;view.nativePoint=previous;}return sent;
            }
            return NO;
        }
    }
    if(type!=kCGEventMouseMoved&&type!=kCGEventScrollWheel&&type!=kCGEventLeftMouseDown&&type!=kCGEventLeftMouseDragged&&type!=kCGEventLeftMouseUp
        &&type!=kCGEventRightMouseDown&&type!=kCGEventRightMouseDragged&&type!=kCGEventRightMouseUp&&type!=kCGEventOtherMouseDown&&type!=kCGEventOtherMouseDragged&&type!=kCGEventOtherMouseUp){
        NSEvent *event=[NSEvent eventWithCGEvent:cg];if(!self.desktop.native||event.type!=NSEventTypeMagnify||self.desktop.globalTrackpad.running)return NO;
        BOOL over=(event.phase&(NSEventPhaseEnded|NSEventPhaseCancelled))!=0;
        if(event.phase&NSEventPhaseMayBegin)return NO;
        if(self.desktop.cleaning||self.desktop.sessionInactive||self.desktop.native.ended){if(self.desktop.nativeMagnifyView)[self cancelNativeInput];return NO;}
        // Magnify is not a CG mouse event: its mouse-specific window/location
        // fields need not be populated. Resolve the real pointer recipient.
        CGPoint point=pointer();DesktopView *view=self.desktop.nativeMagnifyView;LiveSource *source=self.desktop.nativeMagnifySource;
        if(view&&(source.detached||self.desktop.sources[source.logical]!=source||![self.nativeLookup scope:self.desktop.scope contains:source.router.pid]||![self.desktop.views containsObject:view])){[self cancelNativeInput];return NO;}
        if(!view){
            if(over||self.desktop.gestureOwner||self.desktop.magnifying||[self.nativeLookup pressedButtons])return NO;
            CGWindowID wid=[self.nativeLookup windowAt:point];
            source=[self nativeSource:wid at:point];if(!source)return NO;
            for(DesktopView *candidate in self.desktop.views)if([candidate outputAt:point]){view=candidate;break;}
            if(!view)return NO;self.desktop.nativePinchAccepted=NO;
            [self.desktop deliverNative:event type:type view:view at:point];
            if(!self.desktop.nativePinchAccepted){[self.desktop cancelGestures];return NO;}
            if(!over&&event.phase!=NSEventPhaseNone){self.desktop.nativeMagnifyView=view;self.desktop.nativeMagnifySource=source;}
            return YES;
        }
        [self.desktop deliverNative:event type:type view:view at:point];
        if(over||event.phase==NSEventPhaseNone){self.desktop.nativeMagnifyView=nil;self.desktop.nativeMagnifySource=nil;}
        return YES;
    }
    if(type==kCGEventMouseMoved){
        CFTimeInterval now=[self.nativeLookup mediaTime];if(self.desktop.cleaning||self.desktop.sessionInactive||self.desktop.native.ended)return NO;
        [self.desktop queueNativeHover:cg];
        CGWindowID wid=(CGWindowID)CGEventGetIntegerValueField(cg,kCGMouseEventWindowUnderMousePointerThatCanHandleThisEvent);
        if(!wid)wid=(CGWindowID)CGEventGetIntegerValueField(cg,kCGMouseEventWindowUnderMousePointer);
        if(!wid)wid=[self.nativeLookup windowAt:CGPointMake(CGEventGetLocation(cg).x,CGEventGetLocation(cg).y)];
        NSNumber *root=[self.desktop.native rootWindowFor:wid];CGPoint point=CGEventGetLocation(cg);
        if(root){NSEvent *motion=[NSEvent eventWithCGEvent:cg];if(motion)for(DesktopView *view in self.desktop.views)if([view outputAt:point]){[view.hover nativeMotion:motion];break;}}
        // Below [zoom] interact_min a window takes no pointer input, hover included (docs/crates/desktop/POINTER.md): the canvas has had this motion above, so
        // its own hover, sloppy focus and edge pan go on, and the packet goes no further. The window server has already moved the cursor.
        if(root&&[self pickMotionAt:point window:root])return YES;
        NSNumber *hovered=nil;LiveSource *hoveredSource=nil;
        for(LiveSource *source in self.desktop.sources.allValues)if(!source.detached&&source.router.wid==root.unsignedIntValue){hovered=source.logical;hoveredSource=source;break;}
        if(!hovered)for(DesktopView *view in self.desktop.views)if((CGWindowID)view.window.windowNumber==wid){
            NSNumber *output=[view outputAt:point];DWHit *hit=output?[view hit:point output:output]:nil;
            LiveSource *source=self.desktop.sources[hit.window];
            if(source&&!hit.nativeMember&&!source.detached&&(!self.desktop.native||[self.desktop.nativeViews replica:source.logical output:output])){hovered=source.logical;hoveredSource=source;}break;
        }
        BOOL sameHover=(hovered==self.nativeButtonHover)||(hovered&&[hovered isEqual:self.nativeButtonHover]);
        self.chromePointer=point;self.chromePointerKnown=YES;
        if(sameHover&&now-self.nativeButtonMotion<.1)return NO;
        BOOL rested=!sameHover||now-self.nativeButtonMotion>=.2;
        self.nativeButtonMotion=now;self.nativeButtonHover=hovered;
        // The first packet after rest must not wait on the last poll's throttle.
        if(hoveredSource&&rested)hoveredSource.nativeButtonsNext=0;
        if(hoveredSource)[self requestNativeButtons:hoveredSource];
        return NO;
    }
    BOOL down=type==kCGEventLeftMouseDown||type==kCGEventRightMouseDown||type==kCGEventOtherMouseDown;
    BOOL up=type==kCGEventLeftMouseUp||type==kCGEventRightMouseUp||type==kCGEventOtherMouseUp;
    BOOL drag=type==kCGEventLeftMouseDragged||type==kCGEventRightMouseDragged||type==kCGEventOtherMouseDragged;
    CGPoint point=CGEventGetLocation(cg);NSEvent *event=[NSEvent eventWithCGEvent:cg];if(!event)return NO;
    NSInteger button=CGEventGetIntegerValueField(cg,kCGMouseEventButtonNumber);
    DesktopView *captured=self.gestureView;
    if(down&&captured&&button==self.nativeGestureButton){[self cancelNativeInput];captured=nil;}
    if(captured&&(drag||up)&&button==self.nativeGestureButton){
        if([self titleState:captured].intent&&![self titleCurrent:captured]){[self cancelNativeInput];return YES;}
        NSDictionary *press=self.nativeDecorationPress;
        if(press){
            CGPoint started=jsonPoint(press[@"start"]);if(drag&&hypot(point.x-started.x,point.y-started.y)>5)self.nativeDecorationPress=nil;
            if(up){self.nativeDecorationPress=nil;LiveSource *source=self.desktop.sources[press[@"window"]];
                BOOL green=[press[@"title"]boolValue]?[self titleHit:source.identity report:source.nativeButtons at:point]:[press[@"replica"]boolValue]?[self replicaGreen:source at:point output:press[@"output"]]:[self nativeGreen:source at:point];
                if([press[@"replica"]boolValue]){
                    DWHit *hit=[captured hit:point output:press[@"output"]];
                    CGWindowID top=[self.nativeLookup windowAt:point];
                    green&=top==(CGWindowID)captured.window.windowNumber&&[hit.window isEqual:press[@"window"]]&&!hit.nativeMember;
                }
                if(!self.desktop.cleaning&&!self.desktop.sessionInactive&&!self.desktop.native.ended&&source&&!source.detached&&[self.desktop.views containsObject:captured]&&[captured.outputs containsObject:press[@"output"]]&&boundIdentity(source.identity,press[@"identity"])&&green){
                    [self.desktop applyReply:[self.scene.controller nativeDecoration:press[@"action"] window:press[@"window"] output:press[@"output"] identity:DWControllerIdentity(press[@"identity"]) generation:press[@"generation"]]];
                }
            }
        }
        if(!self.desktop.cleaning&&!self.desktop.native.ended&&[self.desktop.views containsObject:captured]){
            // An action or a refused grab still owns its button pair, even if it
            // started no drag. Never let its release become an app's lone mouse-up.
            if(captured.gesture)[self.desktop deliverNative:event type:type view:captured at:point];
        }else if(captured.gesture){captured.clearsFocus=NO;captured.lastDragPan=0;[captured released:captured.lastPoint at:event.timestamp];}
        if(up){[self titleState:captured].intent=nil;self.gestureView=nil;}
        return YES;
    }
    if(self.desktop.cleaning||self.desktop.sessionInactive||self.desktop.native.ended||(!down&&type!=kCGEventScrollWheel))return NO;
    // Overlay gestures and scrolling stay in AppKit. This tap additionally
    // claims only a positively identified green control and its button pair.
    if(!self.desktop.native&&!down)return NO;
    if(type==kCGEventScrollWheel&&self.desktop.nativeScrollView){
        BOOL begin=(event.phase&(NSEventPhaseBegan|NSEventPhaseMayBegin))!=0;
        BOOL tail=event.momentumPhase!=NSEventPhaseNone;
        if(!begin&&(tail||event.timestamp-self.desktop.nativeScrollTime<.35)&&[self.desktop.views containsObject:self.desktop.nativeScrollView]){
            DesktopView *view=self.desktop.nativeScrollView;self.desktop.nativeScrollTime=event.timestamp;
            [self.desktop deliverNative:event type:type view:view at:point];
            if(((event.phase|event.momentumPhase)&NSEventPhaseCancelled)||(event.momentumPhase&NSEventPhaseEnded))self.desktop.nativeScrollView=nil;
            return YES;
        }
        self.desktop.nativeScrollView=nil;
    }
    CGWindowID wid=(CGWindowID)CGEventGetIntegerValueField(cg,kCGMouseEventWindowUnderMousePointerThatCanHandleThisEvent);
    if(!wid)wid=(CGWindowID)CGEventGetIntegerValueField(cg,kCGMouseEventWindowUnderMousePointer);
    if(!wid)wid=[self.nativeLookup windowAt:point];
    LiveSource *source=[self nativeSource:wid at:point];BOOL replica=NO;
    if(!source)for(DesktopView *view in self.desktop.views)if((CGWindowID)view.window.windowNumber==wid){
        NSNumber *output=[view outputAt:point];DWHit *hit=output?[view hit:point output:output]:nil;LiveSource *candidate=self.desktop.sources[hit.window];
        BOOL covered=self.desktop.native&&down&&[self.desktop.nativeViews requiresPlacementAdmissionForWindow:candidate.logical];
        if(candidate&&(covered||!self.desktop.native||[self.desktop.nativeViews replica:candidate.logical output:output])
            &&(covered||(candidate.pixels&&!candidate.error))&&!candidate.detached){source=candidate;replica=YES;break;}
    }
    if(!source)return DWNativeTitleRefused(NO,"native_source",nil,wid,point,nil);
    // The session-stage copy may only install a title grab. Coverage refusal
    // and ordinary input policies remain at the annotated destination tap.
    if(self.desktop.native&&down&&[self.desktop.nativeViews requiresPlacementAdmissionForWindow:source.logical]){
        // Even a cancelled transfer with no eligible recovery token still has
        // coverage. Its physically addressed root/member must get no down.
        pid_t expected=replica?getpid():source.router.pid;
        BOOL addressedCanvas=replica&&CGEventGetIntegerValueField(cg,kCGMouseEventWindowUnderMousePointerThatCanHandleThisEvent)==wid
            &&CGEventGetIntegerValueField(cg,kCGEventTargetUnixProcessID)==getpid();
        // Refusing an already addressed canvas packet grants no input. A later
        // hit mismatch must not send this down into its captured forwarder.
        if(!addressedCanvas){NSDictionary *recipient=[self.nativeLookup recipient:point];
            if(recipient){
                if([recipient[@"wid"]unsignedIntValue]!=wid||[recipient[@"pid"]intValue]!=expected
                    ||(!replica&&(![recipient[@"birth_sec"]isEqual:source.identity[@"birth_sec"]]
                        ||![recipient[@"birth_usec"]isEqual:source.identity[@"birth_usec"]])))return NO;
            }else if(CGEventGetIntegerValueField(cg,kCGMouseEventWindowUnderMousePointerThatCanHandleThisEvent)!=wid
                ||CGEventGetIntegerValueField(cg,kCGEventTargetUnixProcessID)!=expected)return NO;
        }
        [self.desktop cancelNativeHoverForWindow:source.logical];return YES;
    }
    if(self.desktop.native&&down&&!replica){
        DWNativeAppliedPlacement *placement=[self.desktop.nativeViews admittedPlacementForWindow:source.logical];
        if(placement){DWNativeViewTransfer *transfer=[self.desktop.nativeViews currentTransferForWindow:source.logical];
            NSDictionary *recipient=[self.nativeLookup recipient:point],*identity=nil;
            for(NSDictionary *member in placement.members)if([member[@"identity"][@"wid"]unsignedIntValue]==wid){identity=member[@"identity"];break;}
            const char *refused=NULL;
            if([recipient[@"wid"]unsignedIntValue]!=wid||!boundIdentity(recipient,identity))refused="placement_recipient";
            else if(![self.desktop.nativeViews isAdmissionCurrentForTransfer:transfer placement:placement])refused="placement_admission_before";
            else if(![self.nativeLookup placement:placement presenter:self.desktop.native recipient:recipient at:point])refused="placement_input";
            else if(![self.desktop.nativeViews isAdmissionCurrentForTransfer:transfer placement:placement])refused="placement_admission_after";
            if(refused){DWNativeTitleRefused(NO,refused,source.logical,wid,point,@{@"recipient_wid":recipient[@"wid"]?:NSNull.null,@"recipient_pid":recipient[@"pid"]?:NSNull.null});return YES;}
        }
    }
    for(DesktopView *view in self.desktop.views){
        if(!CGRectContainsPoint(view.globalBounds,point))continue;
        NSNumber *output=[view outputAt:point];if(!output)return DWNativeTitleRefused(NO,"output",source.logical,wid,point,nil);
        DWHit *hit=[view hit:point output:output],*familyHit=nil;
        if(!replica&&wid!=source.router.wid){
            DWScene *snapshot=[self.scene.controller scene];
            for(DWPlacement *placement in snapshot.placements)if([placement.window isEqual:source.logical]&&[placement.output isEqual:output]){
                DWHit *context=[DWHit hitWithWindow:source.logical identity:nil generation:nil local:nil nativeMember:nil pick:nil widget:placement.widget.boolValue?@YES:nil pinned:placement.pinned.boolValue?@YES:nil];
                familyHit=DWPickHit(context,snapshot,output);hit=familyHit;break;
            }
        }
        if(![hit.window isEqual:source.logical])return DWNativeTitleRefused(NO,"controller_hit",source.logical,wid,point,@{@"output":output,@"hit_window":hit.window?:NSNull.null,@"hit_present":@(hit!=nil)});
        BOOL pick=[hit.pick isEqual:@YES],claimed=pick;
        if(down){
            if(captured||view.gesture)return DWNativeTitleRefused(NO,"existing_gesture",source.logical,wid,point,@{@"captured":@(captured!=nil),@"view_gesture":@(view.gesture)});
            NSArray *triggers=@[@"left",@"right",@"middle",@"back",@"forward"];
            DWBinding *binding=button>=0&&button<(NSInteger)triggers.count?[self.scene binding:triggers[button] source:nil flags:event.modifierFlags window:YES under:source.logical pick:pick]:nil;
                    if(replica&&[self.desktop queuedNativeHoverPress:event source:source hit:hit view:view output:output at:point]){
                [self.desktop cancelNativeHoverForWindow:source.logical];return YES;
            }
            NSEventModifierFlags extra=event.modifierFlags&(NSEventModifierFlagCommand|NSEventModifierFlagControl|NSEventModifierFlagShift);
            if(button==0&&!extra&&!pick&&!hit.nativeMember&&![hit.widget boolValue]&&(replica?[self replicaGreen:source at:point output:output]:(wid==source.router.wid&&[self nativeGreen:source at:point]))){
                DWScene *snapshot=[self.scene.controller scene];
                for(DWWindow *window in snapshot.windows)if([window.window isEqual:source.logical]){DWSource *binding=window.source;
                    if(!boundIdentity(source.identity,DWNativeIdentity(binding.identity)))return NO;
                    self.nativeDecorationPress=@{@"window":source.logical,@"output":output,@"identity":DWNativeIdentity(binding.identity),@"generation":binding.generation,@"action":(event.modifierFlags&NSEventModifierFlagOption)?@"fit":@"fullscreen",@"start":pointJSON(point),@"replica":@(replica)};
                    self.gestureView=view;self.nativeGestureButton=button;return YES;
                }
            }
            [self requestNativeButtons:source];
            if(replica)return NO; // Canvas view owns ordinary replica input and bound gestures.
            NSString *kind=binding.kind;
            claimed|=[@[@"pan_viewport",@"move_window",@"move_snapped_windows",@"resize_window",@"resize_window_snapped",@"center_nearest",@"action"]containsObject:kind?:@""];
            if([hit.widget boolValue]&&([kind hasPrefix:@"move_"]||[kind hasPrefix:@"resize_"]))claimed=NO;
            // AppKit's own resize uses unscaled native coordinates. A transformed
            // root's normal edge press must enter the same pointer-anchored
            // transaction as the canvas, before the app owns its button pair.
            // Family members keep their independent native controls and drags.
            if(wid==source.router.wid&&[view resizeBorderForButton:button flags:event.modifierFlags hit:hit at:point output:output])claimed=YES;
            // Title chrome is admitted only at the session tap.
            if(!claimed)return NO;
            self.gestureView=view;self.nativeGestureButton=button;
        }else{
            DWBinding *binding=[self.scene binding:@"scroll" source:event.hasPreciseScrollingDeltas?@"finger":@"wheel" flags:event.modifierFlags window:YES under:source.logical pick:pick];
            NSString *kind=binding.kind;claimed|=[kind isEqual:@"pan_viewport"]||[kind isEqual:@"zoom"];
            if(!event.hasPreciseScrollingDeltas){
                int64_t lines=CGEventGetIntegerValueField(cg,kCGScrollWheelEventDeltaAxis1);
                if(!lines&&(event.modifierFlags&NSEventModifierFlagShift))lines=CGEventGetIntegerValueField(cg,kCGScrollWheelEventDeltaAxis2);
                if(lines)claimed|=[[self.scene binding:lines>0?@"wheel_up":@"wheel_down" source:nil flags:event.modifierFlags window:YES under:source.logical pick:pick].kind isEqual:@"action"];
            }
            if(!claimed)return NO;
            if(event.hasPreciseScrollingDeltas&&event.phase!=NSEventPhaseNone){self.desktop.nativeScrollView=view;self.desktop.nativeScrollTime=event.timestamp;}
        }
        [self.desktop deliverNative:event type:type view:view at:point familyHit:familyHit];return YES;
    }
    return DWNativeTitleRefused(NO,"view_bounds",source.logical,wid,point,nil);
}
- (LiveSource *)nativeSource:(CGWindowID)window at:(CGPoint)point {
    if(!window||!self.desktop.native||self.desktop.native.ended||self.desktop.cleaning)return nil;
    NSNumber *root=[self.desktop.native rootWindowFor:window];if(!root)return nil;
    for(LiveSource *source in self.desktop.sources.allValues)if(!source.detached&&source.router.wid==root.unsignedIntValue){
        if(![self.nativeLookup scope:self.desktop.scope contains:source.router.pid]||![[self.nativeLookup birth:source.router.pid]isEqual:source.router.processBirth])return nil;
        NSDictionary *info=[self.nativeLookup windowInfo:window];CGRect bounds=CGRectZero;
        if([info[(id)kCGWindowOwnerPID]intValue]!=source.router.pid||![info[(id)kCGWindowIsOnscreen]boolValue]
            ||[info[(id)kCGWindowAlpha]doubleValue]<=0||!info[(id)kCGWindowBounds]
            ||!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)info[(id)kCGWindowBounds],&bounds)
            ||!CGRectContainsPoint(bounds,point))return nil;
        if(window!=source.router.wid){NSMutableDictionary *member=[source.identity mutableCopy];member[@"wid"]=@(window);[member removeObjectForKey:@"owner"];if(![self.nativeLookup member:member belongsTo:source.identity])return nil;}
        return source;
    }
    return nil;
}
- (void)nativeMouseOwnershipChanged:(CGEventRef)event buttons:(NSIndexSet *)buttons {
    LiveSource *source=self.nativeMouseOwner;CFTimeInterval now=[self.nativeLookup mediaTime];
    if(source.nativeMouseOwnership){
        NSMutableDictionary *held=mutableMouseOwnership(source);
        if(!event){held[@"click_possible"]=@NO;[self.desktop.navigation cancelNativeClick];}
        else {
            CGEventType type=CGEventGetType(event);
            BOOL drag=type==kCGEventLeftMouseDragged||type==kCGEventRightMouseDragged||type==kCGEventOtherMouseDragged;
            CGPoint point=CGEventGetLocation(event),start=jsonPoint(held[@"click_start"]);
            if((drag&&hypot(point.x-start.x,point.y-start.y)>5)||buttons.count>1)held[@"click_possible"]=@NO;
            if(drag&&type==kCGEventLeftMouseDragged&&buttons.count==1&&[self takeOverNativeDrag:source event:event])return;
            if(!buttons.count){
                CGPoint point=CGEventGetLocation(event),start=jsonPoint(held[@"click_start"]);DWScene *snapshot=[self.scene.controller scene];DWSource *binding=nil;DWOutput *view=nil;
                for(DWWindow *row in snapshot.windows)if([row.window isEqual:source.logical])binding=row.source;
                for(DWOutput *row in snapshot.outputs)if([row.identifier isEqual:held[@"output"]])view=row;
                BOOL click=type==kCGEventLeftMouseUp&&[held[@"click_possible"]boolValue]&&!held[@"topology_changed"]
                    &&[held[@"session"]unsignedLongLongValue]==self.desktop.nativeSessionEpoch&&hypot(point.x-start.x,point.y-start.y)<=5
                    &&boundIdentity(source.identity,DWNativeIdentity(binding.identity))&&[binding.generation isEqual:held[@"generation"]]
                    &&[view hasSamePoseAsOutput:DWTyped(held[@"view"],DWOutput.class)]
                    &&CGRectContainsPoint((view?view.nativeScreenBounds:CGRectZero),point)&&[[self.desktop.nativeViews desiredOwnerForWindow:source.logical]isEqual:held[@"output"]];
                [self.desktop.navigation endNativeClick:held[@"click_binding"] completed:click];
                // A press that ends within the click slop with the button released (no takeover, no second button) is a click whatever the
                // canvas's own checks above made of it: the revert in -updateNativeMouseOwners keys on this.
                held[@"click_ended"]=@(type==kCGEventLeftMouseUp&&[held[@"click_possible"]boolValue]&&hypot(point.x-start.x,point.y-start.y)<=5);
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
    [self.desktop.navigation cancelNativeClick];
    [self.desktop cancelNativeTitleClick];
    if(!event||buttons.count!=1||![buttons containsIndex:0]||CGEventGetType(event)!=kCGEventLeftMouseDown
        ||self.desktop.cleaning||self.desktop.sessionInactive||!self.desktop.native||self.desktop.native.ended||[self fillHandoff])return;
    CGWindowID wid=(CGWindowID)CGEventGetIntegerValueField(event,kCGMouseEventWindowUnderMousePointerThatCanHandleThisEvent);
    if(!wid)wid=(CGWindowID)CGEventGetIntegerValueField(event,kCGMouseEventWindowUnderMousePointer);
    source=[self nativeSource:wid at:CGEventGetLocation(event)];
    // INFINIFY_DEBUG: a native press no managed window owns is left entirely to the application and WindowServer, so say why.
    if(!source){if(DWDebugTrace())fprintf(stderr,"debug: native press unowned wid=%u reason=no_source root=%d\n",wid,[self.desktop.native rootWindowFor:wid].intValue);return;}
    if([[self.desktop.sizeTransition busyWindow]isEqual:source.logical]||[self.desktop grabbed:source]
        ||self.desktop.nativeOwnershipTransfer||self.desktop.nativeHoverTransfer||[self.desktop.nativeViews requiresPlacementAdmissionForWindow:source.logical]){
        if(DWDebugTrace())fprintf(stderr,"debug: native press unowned window=#%s reason=busy_or_admission\n",source.logical.description.UTF8String);return;}
    DWScene *snapshot=[self.scene.controller scene];DWWindow *record=nil;DWOutput *view=nil;DWPlacement *planned=nil;NSNumber *output=[self.desktop.nativeViews desiredOwnerForWindow:source.logical];
    for(DWWindow *row in snapshot.windows)if([row.window isEqual:source.logical]){record=row;break;}
    for(DWOutput *row in snapshot.outputs)if([row.identifier isEqual:output]){view=row;break;}
    for(DWPlacement *row in snapshot.placements)if([row.window isEqual:source.logical]&&[row.output isEqual:output]){planned=row.screenRectPresence==DWValuePresent?row:nil;break;}
    DWSource *binding=record.source;double zoom=view.nativeZoom;
    if(source.nativeMouseOwnership){
        NSMutableDictionary *held=mutableMouseOwnership(source);held[@"buttons"]=buttons;[held removeObjectForKey:@"released"];self.nativeMouseOwner=source;
        BOOL root=wid==source.router.wid&&boundIdentity(source.identity,DWNativeIdentity(binding.identity))&&[binding.generation isEqual:held[@"generation"]]
            &&[view hasSamePoseAsOutput:DWTyped(held[@"view"],DWOutput.class)]
            &&CGRectContainsPoint((view?view.nativeScreenBounds:CGRectZero),CGEventGetLocation(event));
        held[@"click_start"]=pointJSON(CGEventGetLocation(event));held[@"click_possible"]=@(root);
        // Each press of a double-click answers for its own displacement: a pending or finished revert belongs to the press before.
        [held removeObjectsForKeys:@[@"click_ended",@"revert",@"revert_token",@"early_tried"]];[self watchNativePress:source];
        if(root)[self.desktop.navigation beginNativeClick:held[@"click_binding"] output:output];return;
    }
    CGRect initialNative,initialScreen;NSDictionary *initialRow=[self.nativeLookup windowInfo:source.router.wid];
    if(![self.nativeLookup bounds:source.router.wid result:&initialNative]||!initialRow[(id)kCGWindowBounds]
        ||!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)initialRow[(id)kCGWindowBounds],&initialScreen)
        ||!boundIdentity(source.identity,DWNativeIdentity(binding.identity))||!binding.generation||!view||!isfinite(zoom)||zoom<=0
        ||![self.desktop.native withholdWindow:source.identity]){if(DWDebugTrace())fprintf(stderr,"debug: native press unowned window=#%s reason=basis_or_withhold\n",source.logical.description.UTF8String);return;}
    source.nativeMouseOwnership=[@{@"identity":source.identity.copy,@"generation":binding.generation,@"output":output,@"session":@(self.desktop.nativeSessionEpoch),
        @"view":view,@"buttons":buttons,@"last_packet":@(now),
        @"initial_native":DWRectJSON(initialNative),@"initial_screen":DWRectJSON(initialScreen)}mutableCopy];
    // Where the controller draws the window. The window list's bounds are not always the drawn rectangle (a Finder window drawn at half
    // size from its own top-left corner read back as its native frame in the guest, so no takeover ever saw a transformed window).
    if(planned)mutableMouseOwnership(source)[@"planned_screen"]=[NSValue valueWithRect:planned.nativeScreenRect];
    DWSourceBinding *clickBinding=[DWSourceBinding bindingWithWindow:source.logical identity:binding.identity generation:binding.generation];
    BOOL root=wid==source.router.wid&&CGRectContainsPoint((view?view.nativeScreenBounds:CGRectZero),CGEventGetLocation(event));
    mutableMouseOwnership(source)[@"click_binding"]=clickBinding;mutableMouseOwnership(source)[@"click_start"]=pointJSON(CGEventGetLocation(event));mutableMouseOwnership(source)[@"click_possible"]=@(root);mutableMouseOwnership(source)[@"root"]=@(root);
    if(root)[self.desktop.navigation beginNativeClick:clickBinding output:output];
    source.observationToken=++self.desktop.observationEpoch;self.nativeMouseOwner=source;[self watchNativePress:source];
    [self.desktop cancelNativeHoverForWindow:source.logical];self.desktop.nativeViewSnapshot=nil;
    // Omission preserves the current transform; it does not restore or rebase.
    // An already submitted frame can still drain before the omission ACK.
    [self.desktop render];
    if(DWDebugTrace())fprintf(stderr,"debug: native mouse owner window=#%s begin buttons=%lu\n",source.logical.description.UTF8String,(unsigned long)buttons.count);
}
// A press that went to a transformed native window and became the application's own window drag. WindowServer moves the native
// frame from where the window is drawn (not from the native frame), keeps or drops the transform as it likes while the button
// is down, and puts the transform back at the release: measured in the guest, the window left the pointer at the first packet
// (it jumped, and at zoom below 1 changed size) and the release adopted a displaced origin; macOS tiling reads the native place.
// The first drag packet that shows the native origin moving with the extent unchanged takes the pair over instead: the application's
// drag is ended with a tagged release, the rest of the physical pair is the canvas's, and the window moves by the pointer from
// the press point exactly as after a recognized title press. Resizes and content drags (the extent or nothing changes) stay native.
- (BOOL)takeOverNativeDrag:(LiveSource *)source event:(CGEventRef)event { return [self takeOverNativeDrag:source at:CGEventGetLocation(event) early:NO]; }
// `early`: the same takeover for a press that has not moved at all (the pointer within 4 points of where it fell) but whose native origin
// has: the application began WindowServer's drag at the mouse down, and the picture sits at scale 1 from then on (measured: 50 to 65 ms
// after the down, for the rest of the press), so it is not worth waiting for pointer motion. The press stays the canvas's own as an
// unmoved title press: a motion past the click slop moves the window by the pointer, a release is the title click (focus) and moves nothing.
- (BOOL)takeOverNativeDrag:(LiveSource *)source at:(CGPoint)point early:(BOOL)early {
    NSMutableDictionary *held=mutableMouseOwnership(source);
    // INFINIFY_DEBUG: why a drag packet of a native press was not taken over, once per reason and press.
    BOOL (^no)(const char *)=^BOOL(const char *reason){
        if(DWDebugTrace()&&held&&![held[@"takeover_refused"]isEqual:@(reason)]){held[@"takeover_refused"]=@(reason);fprintf(stderr,"debug: native takeover declined window=#%s reason=%s\n",source.logical.description.UTF8String,reason);}
        return NO;};
    if(!held)return NO;
    if([held[@"taken"]boolValue]||![held[@"root"]boolValue]||!self.desktop.nativeInput||self.desktop.cleaning||self.desktop.sessionInactive||!self.desktop.native||self.desktop.native.ended||[self fillHandoff]
        ||source.detached||!boundIdentity(source.identity,held[@"identity"])||[held[@"session"]unsignedLongLongValue]!=self.desktop.nativeSessionEpoch)return no("state");
    CGPoint start=jsonPoint(held[@"click_start"]);
    CGRect first=DWRectFromJSON(held[@"initial_native"]),drawn=held[@"planned_screen"]?[held[@"planned_screen"]rectValue]:DWRectFromJSON(held[@"initial_screen"]),native;
    if((hypot(point.x-start.x,point.y-start.y)<=4)==!early||![self.nativeLookup bounds:source.router.wid result:&native])return NO;
    if(early?!DWNativeWindowDragBegunInPlace(first,drawn,native,start,point):!DWNativeWindowDragStarted(first,drawn,native,start,point)){
        if(!early&&DWDebugTrace()&&(fabs(native.origin.x-first.origin.x)>1||fabs(native.origin.y-first.origin.y)>1))fprintf(stderr,"debug: native takeover declined window=#%s reason=drag_test first=%g,%g,%g,%g drawn=%g,%g,%g,%g now=%g,%g,%g,%g\n",source.logical.description.UTF8String,first.origin.x,first.origin.y,first.size.width,first.size.height,drawn.origin.x,drawn.origin.y,drawn.size.width,drawn.size.height,native.origin.x,native.origin.y,native.size.width,native.size.height);
        return NO;}
    NSNumber *output=held[@"output"];DesktopView *view=nil;
    for(DesktopView *candidate in self.desktop.views)if([[candidate outputAt:start]isEqual:output]){view=candidate;break;}
    if(early)held[@"early_tried"]=@YES;
    if(!view||view.gesture||view.heldPress||view.pressedSource||view.pressedTablet||view.pressedPointerGrab||self.gestureView||self.desktop.nativeOwnershipTransfer||self.desktop.nativeHoverTransfer
        ||[[self.desktop.sizeTransition busyWindow]isEqual:source.logical]||![[self.desktop.nativeViews desiredOwnerForWindow:source.logical]isEqual:output])return no("view_state");
    DWScene *snapshot=[self.scene.controller scene];DWWindow *record=nil;DWOutput *pose=nil;
    for(DWWindow *row in snapshot.windows)if([row.window isEqual:source.logical]){record=row;break;}
    for(DWOutput *row in snapshot.outputs)if([row.identifier isEqual:output]){pose=row;break;}
    DWSource *binding=record.source;
    if(!pose||[record.mode isEqual:@"fullscreen"]||!boundIdentity(source.identity,DWNativeIdentity(binding.identity))||![binding.generation isEqual:held[@"generation"]]
        ||![pose hasSamePoseAsOutput:DWTyped(held[@"view"],DWOutput.class)])return no("pose");
    DWControllerReply *begun=[self.scene.controller beginDragWindow:source.logical output:output group:NO];
    if(!begun)return NO;
    // The drag the application started is WindowServer's own (the window follows the pointer whatever the event taps swallow), and
    // it ends when WindowServer sees the button come up. One release is posted at the HID tap for that, from a private event source so
    // that AppKit's combined button state keeps the physical button down: a release that cleared it made -endLostInput end the
    // taken-over gesture 50 ms later as a release that never arrived (measured in the guest). It carries the source's lifetime tag,
    // which both taps let through.
    if(![self.nativeLookup endNativeDragAt:point tag:source.router.tag]){[self.scene.controller endGesture];return NO;}
    held[@"taken"]=@YES;
    [self.desktop.nativeInput takeNativeButton:0];
    NSDictionary *intent=@{@"window":source.logical,@"output":output,@"identity":source.identity.copy,@"generation":binding.generation};
    [self finishNativeMouseOwner:source reason:@"native window drag taken over"];
    // The same initialization as -earlyNativeTitle:event:, for a title press that began at the press point.
    view.clickWindow=nil;[self.desktop.navigation releaseCycle];[self.desktop cancelGestures];[self.desktop cancelNavigation];[self.desktop.panLaunch cancel];view.scrollPanTime=0;
    self.gestureView=view;self.nativeGestureButton=0;
    view.startPoint=view.lastPoint=start;view.dragOutput=view.lastOutput=output;view.gestureButton=0;view.lastDragPan=0;view.lastScrollPan=0;view.clearsFocus=NO;
    [self titleState:view].intent=intent;[self titleState:view].moved=!early;[self titleState:view].released=NO;view.takenOverAt=[self.nativeLookup mediaTime];
    view.gesture=2;[self.desktop.navigation perform:begun];
    // An unmoved press makes no gesture_to: even a zero delta can magnetically snap and arm edge pan (DesktopView -mouseDragged:).
    if(!early&&[[self.scene.controller gestureTo:CGPointMake(point.x-start.x,point.y-start.y) pointer:[NSValue valueWithPoint:point]].needsFrames boolValue])[self.desktop ensureFrames];
    view.lastPoint=point;[self.desktop render];
    if(DWDebugTrace())fprintf(stderr,"debug: native window drag taken over%s window=#%s native=%g,%g drawn=%g,%g\n",early?" at the press":"",source.logical.description.UTF8String,native.origin.x,native.origin.y,drawn.origin.x,drawn.origin.y);
    return YES;
}
// A press forwarded to a transformed window can become the application's own window drag without one pointer packet: the application
// calls performWindowDragWithEvent: at the down and WindowServer moves the native frame then. Nothing on the event tap sees that, so the
// press is watched at 4 ms while the button is down, and takes over as soon as the origin moves with the pointer still at rest.
- (void)watchNativePress:(LiveSource *)source {
    NSMutableDictionary *held=mutableMouseOwnership(source);if(!held||[(NSTimer *)held[@"watch"]isValid])return;
    __weak Desktop *weak=self.desktop;__weak LiveSource *weakSource=source;
    NSTimer *timer=[NSTimer timerWithTimeInterval:.004 repeats:YES block:^(NSTimer *tick){
        Desktop *desktop=weak;LiveSource *owner=weakSource;NSMutableDictionary *current=mutableMouseOwnership(owner);
        if(!desktop||!owner||current!=held||current[@"watch"]!=tick||[current[@"taken"]boolValue]||[current[@"early_tried"]boolValue]||desktop.pressAdmission.nativeMouseOwner!=owner
            ||![self.nativeLookup physicalButton:kCGMouseButtonLeft]){[tick invalidate];return;}
        CGEventRef here=CGEventCreate(NULL);CGPoint point=here?CGEventGetLocation(here):CGPointZero;if(here)CFRelease(here);
        if([desktop.pressAdmission takeOverNativeDrag:owner at:point early:YES])[tick invalidate];
    }];
    held[@"watch"]=timer;[NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
}
- (void)finishNativeMouseOwner:(LiveSource *)source reason:(NSString *)reason {
    NSDictionary *held=source.nativeMouseOwnership;if(!held)return;
    [(NSTimer *)held[@"watch"]invalidate];
    // A lost up can retire geometry after polling, but is never a completed
    // click. An actual up already classified above is left intact.
    [self.desktop.navigation endNativeClick:held[@"click_binding"] completed:NO];
    source.nativeMouseOwnership=nil;source.observationToken=++self.desktop.observationEpoch;
    if(self.nativeMouseOwner==source)self.nativeMouseOwner=nil;
    [self.desktop.native resumeWindow:held[@"identity"]];self.desktop.nativeViewSnapshot=nil;
    if(DWDebugTrace())fprintf(stderr,"debug: native mouse owner window=#%s end=%s\n",source.logical.description.UTF8String,reason.UTF8String);
    [self.desktop render];
}
- (void)updateNativeMouseOwners {
    if(self.desktop.cleaning||self.desktop.sessionInactive||!self.desktop.native||self.desktop.native.ended)return;
    CFTimeInterval now=[self.nativeLookup mediaTime];
    for(LiveSource *source in self.desktop.sources.allValues.copy){
        NSMutableDictionary *held=mutableMouseOwnership(source);if(!held)continue;
        if([held[@"session"]unsignedLongLongValue]!=self.desktop.nativeSessionEpoch){
            [(NSTimer *)held[@"watch"]invalidate];source.nativeMouseOwnership=nil;source.nativeMouseAdopting=NO;source.observationToken=++self.desktop.observationEpoch;
            if(self.nativeMouseOwner==source)self.nativeMouseOwner=nil;continue;
        }
        __block BOOL physical=NO;[(NSIndexSet *)held[@"buttons"]enumerateIndexesUsingBlock:^(NSUInteger button,BOOL *stop){(void)stop;if([self.nativeLookup physicalButton:(CGMouseButton)button])physical=YES;}];
        // Cancellation is not a release. Lost ups settle only after the stored
        // physical buttons are up; an additional button keeps the same owner.
        if(physical){[held removeObjectForKey:@"released"];[held removeObjectForKey:@"stable_since"];continue;}
        if(!held[@"released"]){if(now-[held[@"last_packet"]doubleValue]<.05)continue;held[@"released"]=@(now);if(self.nativeMouseOwner==source)self.nativeMouseOwner=nil;}
        if(source.detached||!boundIdentity(source.identity,held[@"identity"])||![[self.nativeLookup birth:source.router.pid]isEqual:source.router.processBirth]){[self finishNativeMouseOwner:source reason:@"identity changed"];continue;}
        if([[self.desktop.sizeTransition busyWindow]isEqual:source.logical])continue;
        CGRect native,after,screen;NSDictionary *row=[self.nativeLookup windowInfo:source.router.wid];
        if(!row||![row[(id)kCGWindowIsOnscreen]boolValue]){
            source.nativeMouseAdopting=YES;@try{[self.desktop track:source info:row];}@finally{source.nativeMouseAdopting=NO;}
            [self finishNativeMouseOwner:source reason:@"native window closed or hidden"];continue;
        }
        if(now-[held[@"released"]doubleValue]>2){[self finishNativeMouseOwner:source reason:@"final geometry did not settle within two seconds"];continue;}
        if(![self.nativeLookup bounds:source.router.wid result:&native]||[row[(id)kCGWindowOwnerPID]intValue]!=source.router.pid||![row[(id)kCGWindowIsOnscreen]boolValue]
            ||!row[(id)kCGWindowBounds]||!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)row[(id)kCGWindowBounds],&screen)
            ||![self.nativeLookup bounds:source.router.wid result:&after]||!CGRectEqualToRect(native,after))continue;
        if(!isfinite(screen.origin.x)||!isfinite(screen.origin.y)||!isfinite(screen.size.width)||!isfinite(screen.size.height)||screen.size.width<=0||screen.size.height<=0)continue;
        NSString *revert=held[@"revert"];
        if([revert isEqual:@"pending"])continue;
        if([revert isEqual:@"done"]){[self finishNativeMouseOwner:source reason:@"reverted native click move"];continue;}
        CGRect first=DWRectFromJSON(held[@"initial_native"]);
        DWNativeClickSettle settle=DWNativeClickSettleKind([held[@"click_ended"]boolValue],[held[@"taken"]boolValue],first,native,CGRectEqualToRect(DWRectFromJSON(held[@"initial_screen"]),screen));
        if(settle==DWNativeClickSettleUnchanged){
            [self finishNativeMouseOwner:source reason:@"unchanged native click"];continue;
        }
        if(!held[@"stable_since"]||!CGRectEqualToRect(DWRectFromJSON(held[@"native"]),native)||!CGRectEqualToRect(DWRectFromJSON(held[@"screen"]),screen)){
            held[@"native"]=DWRectJSON(native);held[@"screen"]=DWRectJSON(screen);held[@"stable_since"]=@(now);continue;
        }
        if(now-[held[@"stable_since"]doubleValue]<.15)continue;
        // A click must never move the window. A press the application answered with WindowServer's own window drag (a caption area the shell
        // does not recognise: Chromium's performWindowDragWithEvent:) moves the native frame from where the window is DRAWN, so a plain click,
        // or each press of a double-click, left the frame displaced by the distance between the drawn and the native place (+327 pt per click
        // at zoom 0.5, measured in the guest) and the adoption below turned that into a world move. The click is not a move: the native frame
        // goes back to where it was at the press, through the AX position write the fill rebase uses (dw_resize_reposition), the world
        // rectangle stays, and the transform the shell draws is the one it already had. Only a refused write falls through to adoption,
        // which then keeps the world rectangle and takes the displaced frame as the basis (below).
        if(!revert&&settle==DWNativeClickSettleRevert){
            NSDictionary *who=source.identity;NSNumber *token=@(++DWClickRevertToken);held[@"revert"]=@"pending";held[@"revert_token"]=token;
            DWResizeIdentity target={[who[@"pid"]intValue],[who[@"birth_sec"]unsignedLongLongValue],[who[@"birth_usec"]unsignedLongLongValue],[who[@"wid"]unsignedIntValue]};
            __weak Desktop *weak=self.desktop;__weak LiveSource *weakSource=source;CGRect from=native;NSString *logical=source.logical.description;
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{@autoreleasepool{
                DWResizeResult result=[self.nativeLookup reposition:target from:from to:first.origin deadline:[self.nativeLookup monotonicSeconds]+.4];
                dispatch_async(dispatch_get_main_queue(),^{Desktop *desktop=weak;LiveSource *owner=weakSource;NSMutableDictionary *current=mutableMouseOwnership(owner);
                    if(DWDebugTrace())fprintf(stderr,"debug: native click move revert window=#%s outcome=%s ax_error=%d from=%g,%g to=%g,%g now=%g,%g\n",logical.UTF8String,dw_resize_outcome_name(result.outcome),result.ax_error,from.origin.x,from.origin.y,first.origin.x,first.origin.y,result.actual_cg.origin.x,result.actual_cg.origin.y);
                    if(!desktop||!current||![current[@"revert_token"]isEqual:token])return;
                    BOOL back=result.outcome==DWResizeApplied&&result.observed&&fabs(result.actual_cg.origin.x-first.origin.x)<=1&&fabs(result.actual_cg.origin.y-first.origin.y)<=1;
                    current[@"revert"]=back?@"done":@"failed";if(!back)current[@"revert_outcome"]=[NSString stringWithUTF8String:dw_resize_outcome_name(result.outcome)];});
            }});
            continue;
        }
        source.observationToken=++self.desktop.observationEpoch;source.nativeMouseAdopting=YES;
        @try{[self.desktop track:source info:row];}@finally{source.nativeMouseAdopting=NO;}
        if([held[@"topology_changed"]boolValue]){[self finishNativeMouseOwner:source reason:@"display topology changed; native basis refreshed"];continue;}
        DWScene *snapshot=[self.scene.controller scene];DWWindow *record=nil;DWOutput *view=nil;DWPlacement *placement=nil;
        for(DWWindow *item in snapshot.windows)if([item.window isEqual:source.logical]){record=item;break;}
        for(DWOutput *item in snapshot.outputs)if([item.identifier isEqual:held[@"output"]]){view=item;break;}
        for(DWPlacement *item in snapshot.placements)if([item.window isEqual:source.logical]&&[item.output isEqual:held[@"output"]]){placement=item;break;}
        DWSource *binding=record.source;double zoom=view.nativeZoom;
        BOOL current=boundIdentity(source.identity,DWNativeIdentity(binding.identity))&&[binding.generation isEqual:held[@"generation"]]
            &&[[self.desktop.nativeViews desiredOwnerForWindow:source.logical]isEqual:held[@"output"]]
            &&[view hasSamePoseAsOutput:DWTyped(held[@"view"],DWOutput.class)]
            &&placement&&CGRectEqualToRect((binding?binding.nativeObservedRect:CGRectZero),native)&&![record.mode isEqual:@"fullscreen"]&&isfinite(zoom)&&zoom>0;
        if(!current){[self finishNativeMouseOwner:source reason:@"adoption basis changed"];continue;}
        CGRect planned=(placement?placement.nativeScreenRect:CGRectZero);BOOL pinned=[placement.pinned boolValue];
        CGPoint delta=CGPointMake((screen.origin.x-planned.origin.x)/(pinned?1:zoom),(screen.origin.y-planned.origin.y)/(pinned?1:zoom));
        BOOL kept=[revert isEqual:@"failed"];if(kept)delta=CGPointZero;
        NSString *status=self.desktop.statusText;BOOL stationary=CGPointEqualToPoint(delta,CGPointZero);DWControllerReply *moved=stationary?nil:[self.scene.controller relocateSourceWindow:source.logical identity:DWControllerIdentity(source.identity) generation:binding.generation observedRect:native expectedWorldRect:record.worldRect delta:delta];self.desktop.statusText=status;
        if(moved.deferred.boolValue)continue;
        BOOL extent=fabs(screen.size.width-planned.size.width)<=1&&fabs(screen.size.height-planned.size.height)<=1;
        if((stationary||moved.moved.boolValue))self.desktop.sceneDirty=YES;
        [self finishNativeMouseOwner:source reason:(stationary||moved.moved.boolValue)?(kept?[NSString stringWithFormat:@"native click move kept, revert %@; basis only",held[@"revert_outcome"]]:extent?@"adopted displayed origin":@"adopted origin; displayed extent differs"):@"adoption refused"];
    }
}
- (BOOL)titleCurrent:(DesktopView *)view {
    NSDictionary *intent=[self titleState:view].intent;Desktop *d=view.desktop;LiveSource *source=intent?d.sources[intent[@"window"]]:nil;
    if(!intent||!d.native||[d nativeUnavailable]||d.cleaning||d.sessionInactive
        ||![d.views containsObject:view]||![view.outputs containsObject:intent[@"output"]]
        ||![view.dragOutput isEqual:intent[@"output"]]
        ||![[d.nativeViews desiredOwnerForWindow:intent[@"window"]]isEqual:intent[@"output"]]||!source||source.detached
        ||!boundIdentity(source.identity,intent[@"identity"])||![self.nativeLookup scope:d.scope contains:source.router.pid]
        ||![[self.nativeLookup birth:source.router.pid]isEqual:source.router.processBirth]
        ||![[d.native rootWindowFor:source.router.wid]isEqual:@(source.router.wid)])return NO;
    DWScene *snapshot=[self.scene.controller scene];DWSource *binding=nil;BOOL output=NO;
    for(DWWindow *window in snapshot.windows)if([window.window isEqual:intent[@"window"]]){binding=window.source;break;}
    for(DWOutput *view in snapshot.outputs)if([view.identifier isEqual:intent[@"output"]]){output=YES;break;}
    return output&&boundIdentity(source.identity,DWNativeIdentity(binding.identity))&&[binding.generation isEqual:intent[@"generation"]];
}
- (void)press:(NSEvent *)e button:(NSInteger)button hit:(DWHit *)hit at:(CGPoint)p output:(NSNumber *)output view:(DesktopView *)view {
    if([self fillHandoff])return;
    NSArray<NSString *> *triggers=@[@"left",@"right",@"middle",@"back",@"forward"];LiveSource *source=hit?view.desktop.sources[hit.window]:nil;view.lastScrollPan=0;view.clearsFocus=NO;
    // One lookup says all of it: the binding, or nil for none, for one the window under the pointer claims by its pass_mouse rule, and
    // over a pick target for a button whose modifiers are not held. A pick target claims nothing; a pinned window is never one, and keeps
    // its button claims below [zoom] interact_min (upstream's try_pinned_button, which stands ahead of try_pick_button).
    DWBinding *binding=button<(NSInteger)triggers.count?[self.scene binding:triggers[button] source:nil flags:e.modifierFlags window:hit!=nil under:liveHit(hit) pick:[hit.pick isEqual:@YES]]:nil;NSString *kind=binding.kind,*action=binding.action;
    BOOL move=[kind isEqual:@"move_window"]||[kind isEqual:@"move_snapped_windows"],resize=[kind isEqual:@"resize_window"]||[kind isEqual:@"resize_window_snapped"];
    // Upstream's resize border ([mouse] resize_on_border): a left press in the band across a window's visible edge raises and focuses that
    // window and resizes it by that edge, with the cluster when decoration_resize_snapped says so, unless a binding whose modifiers are
    // held claims the press on that window (on_pointer_button asks modifier_button_binding first). The controller says where the band is.
    // A press it does not take goes on as the canvas press it is to -hit:, where upstream would still count the band as the window.
    DWResizeBorder *border=[view resizeBorderForButton:button flags:e.modifierFlags hit:hit at:p output:output];
    if(border){
        if(DWDebugTrace())fprintf(stderr,"debug: pointer down button=%ld trigger=left binding=none border=%s window=#%s\n",(long)button,((NSString *)DWTyped(border.edges,NSString.class)).UTF8String?:"?",[border.window description].UTF8String);
        [view beginResize:DWTyped(border.window,NSNumber.class) edges:DWTyped(border.edges,NSString.class) snapped:[DWTyped(border.snapped,NSNumber.class)boolValue] at:p output:output];[view.desktop render];return;}
    if(DWDebugTrace())fprintf(stderr,"debug: pointer down button=%ld trigger=%s binding=%s window=%s\n",(long)button,button<(NSInteger)triggers.count?triggers[button].UTF8String:"?",kind.UTF8String?:"none",hit?[NSString stringWithFormat:@"#%@",hit.window].UTF8String:"none");
    // Upstream try_pick_button, ahead of everything but a binding whose modifiers are held, which is the only kind the
    // lookup answers over a pick target: below [zoom] interact_min a window or placeholder is one target, whatever the
    // button, and the press is never the application's.
    if([view.hover pickPress:hit button:button claimed:binding!=nil at:p output:output]){view.gesture=DWPolicyPress;return;}
    // ⌃⌥-click still dismisses a detached placeholder while no binding claims that press.
    if(!binding&&!button&&hit&&!source&&(e.modifierFlags&NSEventModifierFlagControl)&&(e.modifierFlags&NSEventModifierFlagOption)){[self.scene.controller forgetWindow:hit.window];[view.desktop render];[view.desktop saveScene];return;}
    // pointer.rs try_suspended_button: modified bindings and pick mode won
    // above; the label relaunches, the bar moves, the body only focuses.
    if(!binding&&!button&&[hit.placeholder boolValue]){
        DWScene *snapshot=[self.scene presentationSnapshot];
        NSString *part=[self.scene standInPart:hit.window output:output screen:p snapshot:snapshot];
        if([part isEqual:@"close"]){view.gesture=DWPolicyPress;
            [view.desktop applyReply:[self.scene.controller closeWindow:hit.window output:output]];return;}
        if([part isEqual:@"label"]){view.gesture=DWPolicyPress;
            [view.desktop applyReply:[self.scene.controller focusWindow:hit.window]];
            [view.desktop applyReply:[self.scene.controller relaunchWindow:hit.window output:output]];return;}
        if([part isEqual:@"title"])move=YES;
    }
    if([self titleState:view].intent){
        // This is an internal, already intercepted native chrome press. A
        // refusal stays swallowed; it must not fall through to app forwarding.
        if(binding||button!=0||[hit.pick boolValue]||[hit.widget boolValue]||hit.nativeMember
            ||![hit.window isEqual:[self titleState:view].intent[@"window"]]||![self titleCurrent:view])return;
        move=YES;
    }
    // A widget ignores drags and resizes, as upstream's does: the bound press starts no gesture and goes to the widget as a plain click (upstream's move and resize arms fall through to click-to-focus and forward it).
    if((move||resize)&&[DWTyped(hit.widget,NSNumber.class)boolValue]){[view.desktop flashStatus:@"A widget stays where its rule puts it: drags and resizes are ignored"];move=resize=NO;}
    // Upstream on_pointer_button: raise_and_focus, then the move grab. The controller does both inside begin_drag, a pinned window's included, and its reply
    // carries the focus request an activate reply carries: the coordinator's to perform on the native window, as a click's is and a move gesture's.
    if(move&&hit){DWControllerReply *begun=[self.scene.controller beginDragWindow:hit.window output:output group:[kind isEqual:@"move_snapped_windows"]];if(begun){view.gesture=2;[view.desktop.navigation perform:begun];}}
    else if(resize&&hit)[view beginResize:hit.window edges:nil snapped:[kind isEqual:@"resize_window_snapped"] at:p output:output];
    // Upstream's pan grab remembers that it began on empty canvas: released without a drag, it unfocuses.
    else if([kind isEqual:@"pan_viewport"]){view.gesture=1;view.clearsFocus=!hit;}
    // Upstream's NavigateGrab: the drag, not the press, takes the direction.
    else if([kind isEqual:@"center_nearest"]){view.gesture=DWPolicyPress;[view.hover nearestPress:p output:output focus:[binding.focus isEqual:@YES]];}
    // Upstream raises and focuses the window under the pointer, stand-ins included, then runs the action on it.
    else if([kind isEqual:@"action"]&&action){if(hit)[view.desktop applyReply:[self.scene.controller focusWindow:hit.window]];[view.desktop action:action output:output at:p held:[DWCycleHold modifiersDown]!=0];return;}
    // Unbound, or bound to a gesture with nothing to act on here: click-to-focus, then the press is the native window's,
    // once the window has the focus that was asked for (-holdPress:window:intent:at:output:).
    else if(hit){NSDictionary *intent=[view inputIntentForHit:hit output:output];BOOL child=hit.nativeMember!=nil;view.gesture=3;view.clickWindow=child?nil:hit.window;
        if(child){if(![view focusChildIntent:intent])return;}else {
            DWControllerReply *reply=[self.scene.controller activateWindow:hit.window output:output cause:@"click" identity:nil generation:nil];
            // Pin before applying the reply: completion/rendering must not lend
            // this physical press a later request for the same logical window.
            if(intent){NSMutableDictionary *held=[intent mutableCopy];held[@"focus_effect"]=reply.primaryFocusEffect?:NSNull.null;intent=held.copy;}
            [view.desktop applyReply:reply];
        }
        [view.desktop render];if(![hit.placeholder boolValue])[view holdPress:e window:hit.window intent:intent at:p output:output];return;}
    [view.desktop render];
}
- (DWPressGesture *)titleState:(DesktopView *)view {
    if(!view)return nil;
    DWPressGesture *state=[self.titleGestures objectForKey:view];
    if(!state){state=[DWPressGesture new];[self.titleGestures setObject:state forKey:view];}
    return state;
}
- (BOOL)prepareDrag:(NSEvent *)event at:(CGPoint)p view:(DesktopView *)view {
    (void)event;
    DWPressGesture *state=[self titleState:view];
    if(state.intent){
        if(hypot(p.x-view.startPoint.x,p.y-view.startPoint.y)>5)state.moved=YES;
        // A stationary title click must never snap or arm edge pan.
        if(!state.moved){view.lastPoint=p;return NO;}
    }
    return YES;
}
- (void)noteRelease:(NSEvent *)event view:(DesktopView *)view {
    DWPressGesture *state=[self titleState:view];
    state.released=state.intent&&event.type==NSEventTypeLeftMouseUp;
}
- (NSDictionary *)releaseTitleAt:(CGPoint)p view:(DesktopView *)view {
    DWPressGesture *state=[self titleState:view];
    NSDictionary *titleClick=state.released&&!state.moved&&view.gesture==2&&view.gestureButton==0
        &&hypot(p.x-view.startPoint.x,p.y-view.startPoint.y)<=5&&[[view outputAt:p]isEqual:view.dragOutput]
        &&[self titleCurrent:view]?state.intent:nil;
    state.released=NO;
    // Apply the final up through the same mapping only after title click slop.
    if(state.intent&&view.gesture==2&&(state.moved||hypot(p.x-view.startPoint.x,p.y-view.startPoint.y)>5)&&[self titleCurrent:view])
        [self.scene.controller gestureTo:CGPointMake(p.x-view.startPoint.x,p.y-view.startPoint.y) pointer:[NSValue valueWithPoint:p]];
    state.intent=nil;
    return titleClick;
}
- (void)mouseDown:(NSEvent *)e view:(DesktopView *)view {
    if(view.desktop.sessionInactive||[view.desktop nativeUnavailable])return;
    [view.desktop.compositor finishGeometryTransitions];
    if(view.desktop.compositor.hasGeometryTransitions)return;
    // One gesture at a time: another button waits until the first is released.
    NSInteger button=e.buttonNumber;if(view.gesture&&button!=view.gestureButton){if([view.desktop.pointerGrab ownsEvent:e.CGEvent])[view.desktop forwardCapturedPointer:e.CGEvent screen:[view screenPoint:e]];return;}
    // A press still held for its window's focus goes first, before this one withdraws that request.
    [view deliverHeld];
    // A press is a fresh interaction, as upstream. It ends an open cycle as letting go of its modifiers does, committing a
    // settled selection as upstream's focus_changed commits it. The pad is one device: in a normal run the press then ends
    // a trackpad gesture in progress, cancelled, so that the coast a pan's end launches stops with the rest. Only then is
    // the focus request still in flight withdrawn and every flight and coast stopped, and a scroll pan still waiting to
    // launch never does, at its delay or at the lift of fingers still down.
    view.clickWindow=nil;[view.desktop.navigation releaseCycle];[view.desktop cancelGestures];[view.desktop cancelNavigation];[view.desktop.panLaunch cancel];view.scrollPanTime=0;
    CGPoint p=[view screenPoint:e];NSNumber *output=[view outputAt:p];if(!output)return;
    view.startPoint=view.lastPoint=p;view.dragOutput=view.lastOutput=output;view.gestureButton=button;view.lastDragPan=0;
    DWHit *hit=[view hit:p output:output];BOOL isHit=[hit isKindOfClass:DWHit.class];
    [self press:e button:button hit:isHit?hit:nil at:p output:output view:view];
}
@end
