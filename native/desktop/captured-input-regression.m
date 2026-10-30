// SPDX-License-Identifier: GPL-3.0-or-later
// Actual captured-input consumers extracted from main.m. Native identity/AX,
// controller replies and posting are substituted; mouse/tablet capture uses
// the real adapters and in-memory CGEvent packets. No application is launched,
// no native window is read/mutated, and no event is posted to WindowServer.
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import "native-pointer-grab.h"
#import "native-tablet.h"
#import "native-relative-motion.h"
#import "hotkeys.h"
#import <Carbon/Carbon.h>
@interface DWHotKeys (StandInRegression)
- (CGEventRef)filterKey:(CGEventType)type event:(CGEventRef)event;
@end
#include <signal.h>
#define main mailboxRegressionMain
#include "root-capture-mailbox-regression.m"
#undef main

@interface LiveSource (FillBackgroundRegression)
@property(readonly) NSDictionary *nativeMouseOwnership;
@end
@implementation LiveSource (FillBackgroundRegression)
- (NSDictionary *)nativeMouseOwnership { return nil; }
@end

@interface Router : NSObject
@property pid_t pid;
@property uint32_t wid;
@property NSArray *processBirth;
@property NSDictionary *bounds;
@property BOOL validIdentity;
@property NSUInteger posts;
@property CGEventType lastType;
@property(readonly) CGEventSourceRef eventSource;
- (BOOL)valid;
- (BOOL)post:(CGEventRef)event at:(CGPoint)point;
@end
@implementation Router
- (CGEventSourceRef)eventSource { return NULL; }
- (BOOL)valid { return self.validIdentity; }
- (BOOL)post:(CGEventRef)event at:(CGPoint)point {
    (void)point;if(!self.validIdentity)return NO;self.posts++;self.lastType=CGEventGetType(event);return YES;
}
@end
@interface InputNative : NSObject
@property BOOL ended;
- (NSNumber *)rootWindowFor:(uint32_t)wid;
@end
@implementation InputNative
- (NSNumber *)rootWindowFor:(uint32_t)wid { return @(wid); }
@end
@interface InputViews : NSObject
- (BOOL)replica:(NSNumber *)window output:(NSNumber *)output;
- (NSNumber *)desiredOwnerForWindow:(NSNumber *)window;
@end
@implementation InputViews
- (BOOL)replica:(NSNumber *)window output:(NSNumber *)output { (void)window;(void)output;return YES; }
- (NSNumber *)desiredOwnerForWindow:(NSNumber *)window { (void)window;return @3; }
@end
@interface InputFamilies : NSObject
- (BOOL)contains:(NSNumber *)window identity:(NSDictionary *)identity generation:(NSNumber *)generation bounds:(CGRect)bounds;
@end
@implementation InputFamilies
- (BOOL)contains:(NSNumber *)window identity:(NSDictionary *)identity generation:(NSNumber *)generation bounds:(CGRect)bounds {
    (void)window;(void)identity;(void)generation;(void)bounds;return YES;
}
@end
@interface InputResize : NSObject
- (NSDictionary *)request:(NSDictionary *)request;
@end
@implementation InputResize
- (NSDictionary *)request:(NSDictionary *)request { (void)request;return @{}; }
@end
@interface InputHover : NSObject
- (BOOL)pressDragged:(CGPoint)point;
- (void)pressReleased:(CGPoint)point;
@end
@implementation InputHover
- (BOOL)pressDragged:(CGPoint)point { (void)point;return NO; }
- (void)pressReleased:(CGPoint)point { (void)point; }
@end
@interface InputDesktop : NSObject
@property NSMutableDictionary *sources;
@property NSDictionary *snapshot,*scope;
@property NSDictionary *nativeFillHandoff;
@property NSObject *nativeFillRoot;
@property BOOL nativeFillAnimated,nativeFillResuming;
@property NSArray *nativeFillBackgroundTrace;
@property uint64_t nativeFillBlockedButtons;
@property BOOL nativeFillBlockedScroll;
@property InputNative *native;
@property InputViews *nativeViews;
@property InputFamilies *nativeFamilies;
@property BOOL sessionInactive,cleaning,logicalFocus;
@property BOOL configured;
@property BOOL probe,probeDrivingGesture,probeHumanInput;
@property NSArray *views;
@property InputResize *resize;
@property NSDictionary *nativeTitleClick;
@property NSTimer *nativeTitleClickTimer;
@property uint64_t nativeSessionEpoch;
@property NSUInteger titleClicks,endedGestures;
@property NSUInteger gestureMoves;
@property NSDictionary *lastGestureMove;
@property NSString *statusText;
@property DWNativePointerGrab *pointerGrab;
@property DWNativeTabletRouter *tablet;
@property DWNativeRelativeMotion *relativeMotion;
@property NSUInteger posts,downs,ups,toolOuts;
@property(copy) dispatch_block_t beforeReply;
- (NSDictionary *)presentationSnapshot;
- (NSDictionary *)call:(NSDictionary *)request;
- (void)cancelNavigation;
- (void)clickReleased:(NSNumber *)window output:(NSNumber *)output;
- (void)deferNativeTitleClick:(NSDictionary *)intent;
- (void)cancelNativeTitleClick;
- (void)fireNativeTitleClick:(NSTimer *)timer;
- (BOOL)nativeUnavailable;
- (void)applyReply:(NSDictionary *)reply;
- (void)panEnd:(NSNumber *)output;
- (void)clearFocus;
- (void)saveScene;
- (void)render;
- (void)ensureFrames;
- (BOOL)validateInputTarget:(NSDictionary *)target;
- (BOOL)postInput:(CGEventRef)event target:(NSDictionary *)target local:(CGPoint)local;
- (NSDictionary *)resolveCapturedPointer:(NSDictionary *)target screen:(CGPoint)screen;
- (BOOL)forwardCapturedPointer:(CGEventRef)event screen:(CGPoint)screen;
- (BOOL)forwardTabletTail:(CGEventRef)event;
- (BOOL)fillInput:(CGEventType)type event:(CGEventRef)event;
- (BOOL)nativeFillCurrent:(NSDictionary *)held snapshot:(NSDictionary *)snapshot;
- (NSDictionary *)nativeFillBackground:(NSDictionary *)snapshot;
@end
@interface InputApplication : NSObject
@property pid_t processIdentifier;
@property NSString *bundleIdentifier;
@end
@implementation InputApplication
@end
@interface InputWorkspace : NSObject
@property InputApplication *frontmostApplication;
+ (instancetype)sharedWorkspace;
@end
@implementation InputWorkspace
+ (instancetype)sharedWorkspace { static InputWorkspace *workspace;if(!workspace){workspace=[InputWorkspace new];workspace.frontmostApplication=[InputApplication new];workspace.frontmostApplication.processIdentifier=7;}return workspace; }
@end
@interface InputView : NSObject
@property NSWindow *window;
@property InputDesktop *desktop;
@property NSDictionary *testHit;
@property LiveSource *pressedSource;
@property NSDictionary *pressedTarget;
@property BOOL pressedTablet,pressedPointerGrab;
@property NSNumber *pressedTabletDevice;
@property CGPoint pressedLocal;
@property int64_t pressedButton;
@property NSEvent *heldPress,*heldDrag,*heldRelease;
@property NSNumber *heldWindow,*heldOutput,*clickWindow;
@property NSDictionary *heldIntent;
@property BOOL heldReleased,heldNavigate;
@property CGPoint heldPoint,heldDragPoint;
@property CFTimeInterval heldSince;
@property NSTimer *heldTimer;
@property(copy) dispatch_block_t duringFocus;
@property NSDictionary *nativeTitlePress;
@property BOOL nativeTitleMoved,nativeTitleReleased,clearsFocus;
@property NSInteger gesture,gestureButton;
@property CGPoint startPoint,lastPoint;
@property NSNumber *dragOutput,*resizeTransaction;
@property CFTimeInterval liftSeen,lastDragPan;
@property CFTimeInterval takenOverAt; // as main.m: a native window drag taken over; 0 here
@property InputHover *hover;
- (BOOL)nativeTitlePressCurrent;
- (NSNumber *)outputAt:(CGPoint)point;
- (void)refreshCursor;
- (void)released:(CGPoint)point at:(NSTimeInterval)time;
- (NSDictionary *)hit:(CGPoint)point output:(NSNumber *)output;
- (NSDictionary *)inputIntentForHit:(NSDictionary *)hit output:(NSNumber *)output;
- (BOOL)childPressCurrent:(NSDictionary *)intent;
- (BOOL)focusPending:(NSNumber *)window intent:(NSDictionary *)intent;
- (void)focusSource:(LiveSource *)source;
- (CGPoint)screenPoint:(NSEvent *)event;
- (void)mouseDragged:(NSEvent *)event;
- (void)pan:(CGPoint)delta output:(NSNumber *)output event:(NSEvent *)event source:(NSString *)source;
- (void)deliverHeld;
- (void)releasePressed;
- (BOOL)forward:(CGEventRef)event at:(CGPoint)point output:(NSNumber *)output activate:(BOOL)activate;
- (BOOL)forward:(CGEventRef)event at:(CGPoint)point output:(NSNumber *)output activate:(BOOL)activate expected:(NSDictionary *)expected;
- (BOOL)forwardCaptured:(CGEventRef)event at:(CGPoint)point output:(NSNumber *)output activate:(BOOL)activate expected:(NSDictionary *)expected;
@end
static NSNumber *asNumber(id value) { return [value isKindOfClass:NSNumber.class]?value:nil; }
static BOOL boundIdentity(NSDictionary *a,NSDictionary *b) { return a&&b&&[a isEqual:b]; }
static NSDictionary *pointJSON(CGPoint p) { return @{@"x":@(p.x),@"y":@(p.y)}; }
static CGPoint jsonPoint(NSDictionary *p) { return CGPointMake([p[@"x"]doubleValue],[p[@"y"]doubleValue]); }
static NSDictionary *rectJSON(CGRect r) { return @{@"origin":pointJSON(r.origin),@"size":@{@"width":@(r.size.width),@"height":@(r.size.height)}}; }
static CGRect jsonRect(NSDictionary *r) { return CGRectMake([r[@"origin"][@"x"]doubleValue],[r[@"origin"][@"y"]doubleValue],[r[@"size"][@"width"]doubleValue],[r[@"size"][@"height"]doubleValue]); }
static CGRect originalRect(void) { return CGRectMake(10,20,64,48); }
static BOOL DWNativeBounds(uint32_t wid,CGRect *bounds) { (void)wid;*bounds=originalRect();return YES; }
static BOOL DWInScope(NSDictionary *scope,pid_t pid) { (void)scope;return pid==7; }
static NSArray *birth(pid_t pid) { return pid==7?@[@123,@456]:nil; }
static NSDictionary *windowInfo(uint32_t wid) {
    return wid==9?@{(id)kCGWindowOwnerPID:@7,(id)kCGWindowBounds:(__bridge_transfer NSDictionary *)CGRectCreateDictionaryRepresentation(originalRect())}:nil;
}
static BOOL DWInputTrace(void) { return NO; }
static BOOL inputTrusted(void) { return YES; }
// WindowServer's recipient annotation is read-only on constructed scroll
// packets. Substitute only that annotation; AppKit decodes real packet phases.
static int64_t fillEventInteger(CGEventRef packet,CGEventField field) {
    if(field==kCGMouseEventWindowUnderMousePointerThatCanHandleThisEvent||field==kCGMouseEventWindowUnderMousePointer)return 9;
    return CGEventGetIntegerValueField(packet,field);
}
static volatile sig_atomic_t stopped;
static NSArray *asArray(id value) {return [value isKindOfClass:NSArray.class]?value:nil;}
#include "native-chrome-geometry.inc"
#include "captured-input-target-functions.inc"
#define AXIsProcessTrusted inputTrusted
#define Desktop InputDesktop
#define DesktopView InputView
#define NSWorkspace InputWorkspace
enum { DWPolicyPress=5 };
@implementation InputView
- (BOOL)nativeTitlePressCurrent { return self.nativeTitlePress!=nil; }
- (NSNumber *)outputAt:(CGPoint)point { return point.x<500?self.dragOutput:@4; }
- (void)refreshCursor {}
- (NSDictionary *)hit:(CGPoint)point output:(NSNumber *)output { (void)point;(void)output;return self.testHit; }
- (BOOL)childPressCurrent:(NSDictionary *)intent { return [self.desktop validateInputTarget:intent]; }
- (BOOL)focusPending:(NSNumber *)window intent:(NSDictionary *)intent { (void)window;(void)intent;return NO; }
- (void)focusSource:(LiveSource *)source { (void)source;if(self.duringFocus)self.duringFocus(); }
- (CGPoint)screenPoint:(NSEvent *)event { return CGEventGetLocation(event.CGEvent); }
- (void)pan:(CGPoint)delta output:(NSNumber *)output event:(NSEvent *)event source:(NSString *)source { (void)delta;(void)output;(void)event;(void)source; }
#include "captured-input-view-consumers.inc"
@end
@implementation InputDesktop
- (NSDictionary *)presentationSnapshot { return self.snapshot; }
- (NSDictionary *)call:(NSDictionary *)request {
    if([request[@"op"]isEqual:@"end_gesture"])self.endedGestures++;
    if([request[@"op"]isEqual:@"gesture_to"]){self.gestureMoves++;self.lastGestureMove=request;}
    if([request[@"cause"]isEqual:@"click_release"])self.titleClicks++;
    (void)request;dispatch_block_t before=self.beforeReply;self.beforeReply=nil;if(before)before();
    NSMutableDictionary *reply=[self.snapshot mutableCopy];reply[@"hit"]=@{@"window":@1,@"local":pointJSON(CGPointMake(4,5))};return reply;
}
- (void)cancelNavigation {}
- (void)clickReleased:(NSNumber *)window output:(NSNumber *)output { (void)window;(void)output; }
- (BOOL)nativeUnavailable { return self.native.ended; }
- (void)applyReply:(NSDictionary *)reply { (void)reply; }
- (void)panEnd:(NSNumber *)output { (void)output; }
- (void)clearFocus {}
- (void)saveScene {}
- (void)render {}
- (void)ensureFrames {}
- (BOOL)validateInputTarget:(NSDictionary *)target {
    LiveSource *s=self.sources[target[@"window"]];return s&&s.router.validIdentity&&!s.detached
        &&[target[@"identity"]isEqual:s.identity]&&[target[@"generation"]isEqual:@2];
}
- (BOOL)postInput:(CGEventRef)event target:(NSDictionary *)target local:(CGPoint)local {
    (void)local;if(![self validateInputTarget:target])return NO;
    self.posts++;CGEventType type=CGEventGetType(event);
    if(type==kCGEventLeftMouseDown||type==kCGEventRightMouseDown||type==kCGEventOtherMouseDown)self.downs++;
    if(type==kCGEventLeftMouseUp||type==kCGEventRightMouseUp||type==kCGEventOtherMouseUp)self.ups++;
    if(DWNativeTabletProximityEvent(event)&&!CGEventGetIntegerValueField(event,kCGTabletProximityEventEnterProximity))self.toolOuts++;
    return YES;
}
- (BOOL)fillInput:(CGEventType)type event:(CGEventRef)cg {
#define CGEventGetIntegerValueField fillEventInteger
#include "captured-input-fill-blocker.inc"
#undef CGEventGetIntegerValueField
    return NO;
}
#include "captured-input-desktop-consumers.inc"
@end
#undef NSWorkspace
#undef Desktop
#undef AXIsProcessTrusted

static InputView *inputView(LiveSource *s) {
    s.logical=@1;s.identity=@{@"pid":@7,@"wid":@9,@"birth_sec":@123,@"birth_usec":@456};
    s.router=[Router new];s.router.pid=7;s.router.wid=9;s.router.processBirth=@[@123,@456];s.router.validIdentity=YES;
    s.router.bounds=(__bridge_transfer NSDictionary *)CGRectCreateDictionaryRepresentation(originalRect());
    InputDesktop *desktop=[InputDesktop new];desktop.sources=[@{@1:s}mutableCopy];
    desktop.snapshot=@{@"windows":@[@{@"window":@1,@"source":@{@"identity":s.identity,@"generation":@2,@"observation_known":@YES}}],
        @"placements":@[@{@"window":@1,@"output":@3,@"screen_rect":rectJSON(CGRectMake(100,200,32,24))}]};
    InputView *view=[InputView new];view.desktop=desktop;view.testHit=@{@"window":@1};return view;
}
static CGEventRef mousePacket(CGEventType type,CGMouseButton button) { return CGEventCreateMouseEvent(NULL,type,CGPointMake(104,205),button); }
static void titleReleaseCase(NSString *mode,BOOL expected) {
    InputView *v=inputView(source(NO));v.desktop.configured=YES;v.gesture=2;v.gestureButton=0;v.startPoint=CGPointMake(100,200);v.dragOutput=@3;
    LiveSource *s=v.desktop.sources[@1];v.nativeTitlePress=@{@"window":@1,@"output":@3,@"identity":s.identity,@"generation":@2};v.nativeTitleReleased=YES;
    NSMutableDictionary *snapshot=[v.desktop.snapshot mutableCopy];snapshot[@"outputs"]=@[@{@"id":@3,@"camera":pointJSON(CGPointZero),@"zoom":@.5,@"screen_bounds":rectJSON(CGRectMake(0,0,500,500))}];
    snapshot[@"focus"]=@{@"intent":@1,@"observed_native":v.nativeTitlePress};v.desktop.snapshot=snapshot;v.desktop.nativeViews=[InputViews new];
    CGPoint release=v.startPoint;
    if([mode isEqual:@"slop"])release=CGPointMake(103,204);
    if([mode isEqual:@"drag"])release.x=106;
    if([mode isEqual:@"out_and_back"])v.nativeTitleMoved=YES;
    if([mode isEqual:@"lost_up"])v.nativeTitleReleased=NO;
    if([mode isEqual:@"other_output"])release.x=501;
    [v released:release at:1];
    NSUInteger expectedMoves=([mode isEqual:@"drag"]||[mode isEqual:@"out_and_back"]||[mode isEqual:@"other_output"])?1:0;
    check(v.desktop.gestureMoves==expectedMoves,[NSString stringWithFormat:@"title release %@ moves only after crossing click slop",mode]);
    check((v.desktop.nativeTitleClick!=nil)==expected,[NSString stringWithFormat:@"title click %@ release eligibility",mode]);
    check(v.desktop.titleClicks==0,@"title click never navigates before the double-click interval");
    check(v.gesture==0&&v.nativeTitlePress==nil,@"title release always ends original drag ownership");
    if(expected){
        check(v.desktop.gestureMoves==0,@"stationary title click never enters magnetic snapping or arms edge pan");
        check(v.desktop.endedGestures==1,@"title click is armed after ending the world drag");
        [v.desktop fireNativeTitleClick:v.desktop.nativeTitleClickTimer];
        check(v.desktop.titleClicks==1,@"current stationary title click reaches controller navigation after delay");
    }
    [v.desktop cancelNativeTitleClick];
}
static void titleMotionCase(void) {
    InputView *v=inputView(source(NO));v.desktop.configured=YES;v.gesture=2;v.gestureButton=0;v.startPoint=CGPointMake(100,200);v.dragOutput=@3;
    v.nativeTitlePress=@{@"window":@1,@"output":@3};
    CGEventRef packet=mousePacket(kCGEventLeftMouseDragged,kCGMouseButtonLeft);
    CGEventSetLocation(packet,CGPointMake(103,204));[v mouseDragged:[NSEvent eventWithCGEvent:packet]];
    check(!v.nativeTitleMoved&&v.desktop.gestureMoves==0,@"title motion inside click slop never enters snapping or edge pan");
    CGEventSetLocation(packet,CGPointMake(106,200));[v mouseDragged:[NSEvent eventWithCGEvent:packet]];
    check(v.nativeTitleMoved&&v.desktop.gestureMoves==1&&[v.desktop.lastGestureMove[@"screen_delta"]isEqual:pointJSON(CGPointMake(6,0))],@"crossing title click slop immediately sends the complete drag displacement");
    CGEventSetLocation(packet,v.startPoint);[v mouseDragged:[NSEvent eventWithCGEvent:packet]];
    check(v.nativeTitleMoved&&v.desktop.gestureMoves==2,@"a real drag returning into click slop continues moving");
    v.nativeTitleReleased=YES;[v released:CGPointMake(108,200) at:1];
    check(v.desktop.gestureMoves==3&&[v.desktop.lastGestureMove[@"screen_delta"]isEqual:pointJSON(CGPointMake(8,0))],@"real title drag consumes final release displacement");
    check(!v.desktop.nativeTitleClick&&v.desktop.endedGestures==1,@"real title drag ends without click navigation");
    CFRelease(packet);
    v=inputView(source(NO));v.desktop.configured=YES;v.gesture=2;v.gestureButton=0;v.startPoint=CGPointMake(100,200);v.dragOutput=@3;
    v.nativeTitlePress=@{@"window":@1,@"output":@3};v.nativeTitleReleased=YES;
    [v released:CGPointMake(106,200) at:1];
    check(v.desktop.gestureMoves==1&&[v.desktop.lastGestureMove[@"screen_delta"]isEqual:pointJSON(CGPointMake(6,0))],@"release crossing click slop starts movement even without a drag packet");
    v=inputView(source(NO));v.desktop.configured=YES;v.gesture=2;v.gestureButton=0;v.startPoint=CGPointMake(100,200);v.dragOutput=@3;
    packet=mousePacket(kCGEventLeftMouseDragged,kCGMouseButtonLeft);CGEventSetLocation(packet,v.startPoint);
    [v mouseDragged:[NSEvent eventWithCGEvent:packet]];
    check(v.desktop.gestureMoves==1,@"bound window moves retain their existing immediate gesture behavior");CFRelease(packet);
}
static void titleDeferredCase(NSString *mode) {
    InputView *v=inputView(source(NO));InputDesktop *d=v.desktop;LiveSource *s=d.sources[@1];d.configured=YES;d.nativeViews=[InputViews new];
    NSDictionary *intent=@{@"window":@1,@"output":@3,@"identity":s.identity,@"generation":@2};
    NSMutableDictionary *pose=[@{@"id":@3,@"camera":pointJSON(CGPointZero),@"zoom":@.5,@"screen_bounds":rectJSON(CGRectMake(0,0,500,500))}mutableCopy];
    NSMutableDictionary *focus=[@{@"intent":@1,@"observed_native":intent}mutableCopy],*snapshot=[d.snapshot mutableCopy];snapshot[@"focus"]=focus;snapshot[@"outputs"]=@[pose];d.snapshot=snapshot;
    [d deferNativeTitleClick:intent];NSTimer *first=d.nativeTitleClickTimer;
    if([mode isEqual:@"second_down"])[d cancelNativeTitleClick];
    if([mode isEqual:@"rebound"]){NSMutableDictionary *binding=[snapshot[@"windows"][0][@"source"]mutableCopy];binding[@"generation"]=@3;snapshot[@"windows"]=@[@{@"window":@1,@"source":binding}];}
    if([mode isEqual:@"focus"])focus[@"intent"]=@2;
    if([mode isEqual:@"pose"])pose[@"zoom"]=@1;
    if([mode isEqual:@"session"])d.nativeSessionEpoch++;
    [d fireNativeTitleClick:first];check(d.titleClicks==0,[NSString stringWithFormat:@"deferred title click rejects %@",mode]);[d cancelNativeTitleClick];
}
static CGEventRef tabletPacket(CGEventType type,int64_t button,double pressure) {
    CGEventRef event=CGEventCreate(NULL);CGEventSetType(event,type);
    if(type==kCGEventTabletProximity){CGEventSetIntegerValueField(event,kCGTabletProximityEventDeviceID,42);CGEventSetIntegerValueField(event,kCGTabletProximityEventEnterProximity,1);}
    else{CGEventSetIntegerValueField(event,kCGMouseEventSubtype,kCGEventMouseSubtypeTabletPoint);CGEventSetIntegerValueField(event,kCGTabletEventDeviceID,42);CGEventSetDoubleValueField(event,kCGTabletEventPointPressure,pressure);CGEventSetIntegerValueField(event,kCGMouseEventButtonNumber,button);}
    return event;
}
static void heldFocusCase(NSString *name,NSString *mode,BOOL succeeds) {
    LiveSource *s=source(NO);InputView *v=inputView(s);publish(s,1);InputDesktop *d=v.desktop;
    NSDictionary *effect=@{@"op":@"focus_native_window",@"effect_id":@11,@"window":@1,@"generation":@2,@"identity":s.identity};
    NSMutableDictionary *observed=[effect mutableCopy];observed[@"op"]=@"observed_native_focus";observed[@"effect_id"]=@0;
    NSMutableDictionary *focus=[@{@"intent":@1,@"pending_effect":NSNull.null,@"last_result":@{@"effect":effect,@"success":@YES},@"observed_native":observed}mutableCopy];
    CFTimeInterval now=CACurrentMediaTime();
    NSMutableDictionary *intent=[[v inputIntentForHit:v.testHit output:@3]mutableCopy];intent[@"focus_effect"]=effect;intent[@"focus_deadline"]=@(now+1.5);
    InputWorkspace.sharedWorkspace.frontmostApplication.processIdentifier=7;
    if([mode isEqual:@"pending"])focus[@"pending_effect"]=effect;
    if([mode isEqual:@"failure"])focus[@"last_result"]=@{@"effect":effect,@"success":@NO};
    if([mode isEqual:@"cancelled"])focus[@"last_result"]=NSNull.null;
    if([mode isEqual:@"superseded"]){NSMutableDictionary *other=[effect mutableCopy];other[@"effect_id"]=@12;focus[@"pending_effect"]=other;}
    if([mode isEqual:@"wrong_result"]){NSMutableDictionary *other=[effect mutableCopy];other[@"effect_id"]=@12;focus[@"last_result"]=@{@"effect":other,@"success":@YES};}
    if([mode isEqual:@"observation_changed"])observed[@"window"]=@2;
    if([mode isEqual:@"generation_changed"])observed[@"generation"]=@3;
    if([mode isEqual:@"identity_changed"]){NSMutableDictionary *other=[s.identity mutableCopy];other[@"birth_usec"]=@457;observed[@"identity"]=other;}
    if([mode isEqual:@"placeholder_intent"])focus[@"intent"]=@2;
    if([mode isEqual:@"cleared_intent"])focus[@"intent"]=NSNull.null;
    if([mode isEqual:@"foreground_changed"])InputWorkspace.sharedWorkspace.frontmostApplication.processIdentifier=8;
    if([mode isEqual:@"expired"])intent[@"focus_deadline"]=@(now-.01);
    if([mode isEqual:@"logical"]){d.logicalFocus=YES;focus[@"last_result"]=@{@"effect":effect,@"success":@NO,@"logical":@YES};focus[@"observed_native"]=NSNull.null;InputWorkspace.sharedWorkspace.frontmostApplication.processIdentifier=8;}
    NSMutableDictionary *snapshot=[d.snapshot mutableCopy];snapshot[@"focus"]=focus;d.snapshot=snapshot;
    CGEventRef down=mousePacket(kCGEventLeftMouseDown,kCGMouseButtonLeft),up=mousePacket(kCGEventLeftMouseUp,kCGMouseButtonLeft);
    v.heldPress=[NSEvent eventWithCGEvent:down];v.heldRelease=[NSEvent eventWithCGEvent:up];v.heldReleased=YES;v.heldWindow=@1;v.heldOutput=@3;v.heldIntent=intent;v.heldSince=now-([mode isEqual:@"slow_success"]?1:0);v.clickWindow=@1;
    if([mode isEqual:@"revoked_during_forward"]){__weak InputDesktop *weak=d;d.beforeReply=^{weak.beforeReply=^{focus[@"last_result"]=@{@"effect":effect,@"success":@NO};};};}
    [v deliverHeld];check((s.router.posts>0)==succeeds,name);check(!v.heldPress&&(!succeeds?!v.clickWindow:YES),@"held focus result retires unsent state");
    CFRelease(down);CFRelease(up);resetSource(s);InputWorkspace.sharedWorkspace.frontmostApplication.processIdentifier=7;
}
static void standInKeys(void) {
    NSDictionary *row=@{@"window":@61,@"kind":@"standin",@"source":NSNull.null};
    NSMutableDictionary *snapshot=[@{@"focus":@{@"intent":@61},@"windows":@[row],@"lifecycle":@{@"standins":@[@61]}}mutableCopy];
    check([DWFocusedStandIn(snapshot) isEqual:row],@"only the focused lifecycle stand-in owns Enter");
    snapshot[@"lifecycle"]=@{@"standins":@[]};check(!DWFocusedStandIn(snapshot),@"ordinary detached placeholders cannot relaunch");
    snapshot[@"lifecycle"]=@{@"standins":@[@61]};snapshot[@"focus"]=@{@"intent":@61,@"cycle":@0};check(!DWFocusedStandIn(snapshot),@"held cycling takes precedence over stand-in Enter");
    snapshot[@"focus"]=@{@"intent":@61,@"pending_effect":@{}};check(!DWFocusedStandIn(snapshot),@"pending native focus cannot lend Enter to a stand-in");
    __block NSUInteger launches=0,admissions=0;__block BOOL owned=YES;
    DWHotKeys *keys=[[DWHotKeys alloc]initWithFire:^(NSString *action){(void)action;}];
    check([keys respondsToSelector:@selector(setStandinEnter:)],@"hotkey filter provides stand-in Enter admission");
    keys.standinEnter=^dispatch_block_t{admissions++;return owned?^{if(owned)launches++;}:nil;};
    [keys setValue:[NSMutableDictionary dictionary] forKey:@"suppressedKeys"];[keys setValue:[NSMutableIndexSet indexSet] forKey:@"tapKeys"];
    CGEventRef event=CGEventCreateKeyboardEvent(NULL,36,true);
    check([keys filterKey:kCGEventKeyDown event:event]==NULL,@"plain unbound Return owns its down");
    CGEventSetIntegerValueField(event,kCGKeyboardEventAutorepeat,1);check([keys filterKey:kCGEventKeyDown event:event]==NULL&&admissions==1,@"held Return repeat cannot relaunch twice");
    check([keys filterKey:kCGEventKeyUp event:event]==NULL,@"owned Return release never leaks to a newly opened app");
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];check(launches==1,@"one admitted Return dispatches one relaunch");
    CGEventSetIntegerValueField(event,kCGKeyboardEventAutorepeat,0);CGEventSetFlags(event,kCGEventFlagMaskShift);
    check([keys filterKey:kCGEventKeyDown event:event]==event&&admissions==1,@"modified Return remains the application's unless configured");
    CGEventSetFlags(event,0);[keys setValue:@[@{@"chord":DWChord(36,0)}] forKey:@"keys"];
    check([keys filterKey:kCGEventKeyDown event:event]==event&&admissions==1,@"authored Return binding precedes stand-in affordance");
    [keys setValue:@[] forKey:@"keys"];owned=NO;check([keys filterKey:kCGEventKeyDown event:event]==event,@"no current canvas keyboard owner leaves Return untouched");
    owned=YES;CGEventSetIntegerValueField(event,kCGKeyboardEventKeycode,76);
    check([keys filterKey:kCGEventKeyDown event:event]==NULL,@"keypad Enter owns the same affordance");owned=NO;
    check([keys filterKey:kCGEventKeyUp event:event]==NULL,@"focus loss still consumes the admitted pair tail");
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];check(launches==1,@"deferred relaunch rechecks canvas ownership");
    CFRelease(event);[keys invalidate];
}
static void nativeWindowControlKeys(void) {
    __block NSUInteger admitted=0,fired=0;__block BOOL current=YES;
    __block DWNativeWindowControl selected=DWNativeWindowControlToggleFullscreen,delivered=DWNativeWindowControlToggleFullscreen;
    DWHotKeys *keys=[[DWHotKeys alloc]initWithFire:^(NSString *action){(void)action;}];
    keys.nativeWindowControl=^dispatch_block_t(DWNativeWindowControl action){admitted++;selected=action;return current?^{if(current){fired++;delivered=action;}}:nil;};
    // Pin the resolver's output: this input-policy test never changes the host layout.
    [keys setValue:@3 forKey:@"nativeFullscreenKey"];[keys setValue:@15 forKey:@"nativeRestoreKey"];[keys setValue:@8 forKey:@"nativeCenterKey"];
    [keys setValue:[NSMutableDictionary dictionary] forKey:@"suppressedKeys"];[keys setValue:[NSMutableIndexSet indexSet] forKey:@"tapKeys"];
    CGEventRef event=CGEventCreateKeyboardEvent(NULL,3,true);CGEventSetFlags(event,kCGEventFlagMaskControl|kCGEventFlagMaskCommand);
    check([keys filterKey:kCGEventKeyDown event:event]==NULL,@"native fullscreen owns an admitted Control-Command-F down");
    CGEventSetIntegerValueField(event,kCGKeyboardEventAutorepeat,1);
    check([keys filterKey:kCGEventKeyDown event:event]==NULL&&admitted==1,@"fullscreen repeat cannot toggle twice");
    check([keys filterKey:kCGEventKeyUp event:event]==NULL,@"fullscreen owns its physical release");
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];check(fired==1&&delivered==DWNativeWindowControlToggleFullscreen,@"fullscreen dispatches one admitted toggle job");
    CGEventSetIntegerValueField(event,kCGKeyboardEventAutorepeat,0);current=NO;
    check([keys filterKey:kCGEventKeyDown event:event]==event,@"unknown or unmanaged focus keeps native fullscreen");current=YES;
    NSUInteger before=admitted;CGEventSetFlags(event,kCGEventFlagMaskCommand);
    check([keys filterKey:kCGEventKeyDown event:event]==event&&admitted==before,@"ordinary Command-F remains native");
    CGEventSetFlags(event,kCGEventFlagMaskControl|kCGEventFlagMaskCommand|kCGEventFlagMaskShift);
    check([keys filterKey:kCGEventKeyDown event:event]==event&&admitted==before,@"modified fullscreen chord remains native");
    CGEventSetFlags(event,kCGEventFlagMaskControl|kCGEventFlagMaskCommand);
    [keys setValue:@[@{@"chord":DWChord(3,controlKey|cmdKey)}] forKey:@"keys"];
    check([keys filterKey:kCGEventKeyDown event:event]==event&&admitted==before,@"authored fullscreen chord precedes native fallback");
    [keys setValue:@[] forKey:@"keys"];[keys pass:@[@"ctrl+f"]];
    check([keys filterKey:kCGEventKeyDown event:event]==event&&admitted==before,@"explicit F passthrough conservatively preserves native fullscreen");[keys pass:@YES];
    check([keys filterKey:kCGEventKeyDown event:event]==event&&admitted==before,@"pass-all retains native fullscreen chord");[keys pass:@NO];
    check([keys filterKey:kCGEventKeyDown event:event]==NULL,@"fullscreen readmits after pass-all ends");current=NO;
    check([keys filterKey:kCGEventKeyUp event:event]==NULL,@"focus loss retains admitted fullscreen release ownership");
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];check(fired==1,@"deferred fullscreen respects exact target revocation");
    current=YES;CGEventSetFlags(event,kCGEventFlagMaskSecondaryFn|kCGEventFlagMaskControl|kCGEventFlagMaskCommand);before=admitted;
    check([keys filterKey:kCGEventKeyDown event:event]==event&&admitted==before,@"Fn-Control-Command-F is not either native fullscreen chord");
    CGEventSetFlags(event,kCGEventFlagMaskSecondaryFn|kCGEventFlagMaskShift);
    check([keys filterKey:kCGEventKeyDown event:event]==event&&admitted==before,@"modified Fn-F remains native");
    CGEventSetFlags(event,kCGEventFlagMaskSecondaryFn);
    check([keys filterKey:kCGEventKeyDown event:event]==NULL,@"native Fn-F owns an admitted pair");
    check([keys filterKey:kCGEventKeyUp event:event]==NULL,@"native Fn-F owns its release");
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];check(fired==2&&delivered==DWNativeWindowControlToggleFullscreen,@"Fn-F dispatches the same pinned toggle action");
    // Exact Apple window-control combinations only. Modifier mapping has no Fn,
    // so both authored bindings and explicit terminal-key pass rules still win.
    CGEventFlags fnControl=kCGEventFlagMaskSecondaryFn|kCGEventFlagMaskControl;
    NSMutableArray<NSDictionary *> *controls=[@[
        @{ @"code":@3,@"flags":@(fnControl),@"action":@(DWNativeWindowControlFill),@"terminal":@"f" },
        @{ @"code":@15,@"flags":@(fnControl),@"action":@(DWNativeWindowControlRestore),@"terminal":@"r" },
        @{ @"code":@8,@"flags":@(fnControl),@"action":@(DWNativeWindowControlCenter),@"terminal":@"c" }
    ]mutableCopy];
    NSArray *arrows=@[@"left",@"right",@"down",@"up"];
    for(NSUInteger i=0;i<4;i++)for(NSNumber *extra in @[@0,@(kCGEventFlagMaskShift),@(kCGEventFlagMaskShift|kCGEventFlagMaskAlternate)])
        [controls addObject:@{@"code":@(123+i),@"flags":@(fnControl|extra.unsignedLongLongValue),@"action":@(DWNativeWindowControlSuppressTiling),@"terminal":arrows[i]}];
    for(NSDictionary *control in controls){
        UInt32 code=[control[@"code"]unsignedIntValue];CGEventFlags flags=[control[@"flags"]unsignedLongLongValue];
        DWNativeWindowControl expected=[control[@"action"]unsignedIntegerValue];
        NSString *label=[NSString stringWithFormat:@"%@ flags %llu",control[@"terminal"],(unsigned long long)flags];
        CGEventSetIntegerValueField(event,kCGKeyboardEventKeycode,code);CGEventSetFlags(event,flags);CGEventSetIntegerValueField(event,kCGKeyboardEventAutorepeat,0);
        NSUInteger admissions=admitted,deliveries=fired;
        check([keys filterKey:kCGEventKeyDown event:event]==NULL&&selected==expected&&admitted==admissions+1,[label stringByAppendingString:@" admits the exact semantic action"]);
        CGEventSetIntegerValueField(event,kCGKeyboardEventAutorepeat,1);
        check([keys filterKey:kCGEventKeyDown event:event]==NULL&&admitted==admissions+1,[label stringByAppendingString:@" owns repeats without replay"]);
        [keys pass:@YES];CGEventSetFlags(event,0);
        [keys filterKey:kCGEventTapDisabledByTimeout event:event];
        check([keys filterKey:kCGEventKeyUp event:event]==NULL,[label stringByAppendingString:@" retains release after timeout, modifier release and pass-policy change"]);
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.001]];
        check(fired==deliveries+1&&delivered==expected,[label stringByAppendingString:@" dispatches the semantic action once"]);
        [keys pass:@NO];CGEventSetFlags(event,flags);CGEventSetIntegerValueField(event,kCGKeyboardEventAutorepeat,0);
        UInt32 modifiers=controlKey|(flags&kCGEventFlagMaskShift?shiftKey:0)|(flags&kCGEventFlagMaskAlternate?optionKey:0);
        [keys setValue:@[@{@"chord":DWChord(code,modifiers)}] forKey:@"keys"];
        check([keys filterKey:kCGEventKeyDown event:event]==event&&admitted==admissions+1,[label stringByAppendingString:@" defers to authored Carbon chord without Fn"]);
        [keys setValue:@[] forKey:@"keys"];[keys pass:@[[@"mod+" stringByAppendingString:[control[@"terminal"]uppercaseString]]]];
        check([keys filterKey:kCGEventKeyDown event:event]==event&&admitted==admissions+1,[label stringByAppendingString:@" respects case-insensitive terminal-key passthrough"]);
        [keys pass:@NO];current=NO;
        check([keys filterKey:kCGEventKeyDown event:event]==event&&admitted==admissions+2,[label stringByAppendingString:@" leaves unverified native focus untouched"]);current=YES;
    }
    // Content navigation, accessibility function keys, and near-miss modifiers
    // must not become window controls merely because Fn or Control is held.
    NSArray *ordinary=@[
        @[@3,@(kCGEventFlagMaskControl)],@[@3,@(kCGEventFlagMaskCommand)],
        @[@8,@(kCGEventFlagMaskCommand)],@[@15,@(kCGEventFlagMaskCommand)],
        @[@8,@(fnControl|kCGEventFlagMaskShift)],@[@15,@(fnControl|kCGEventFlagMaskAlternate)],
        @[@3,@(fnControl|kCGEventFlagMaskCommand)],@[@120,@(fnControl)],
        @[@123,@(kCGEventFlagMaskSecondaryFn)],@[@124,@(kCGEventFlagMaskControl)],
        @[@125,@(fnControl|kCGEventFlagMaskAlternate)],@[@126,@(fnControl|kCGEventFlagMaskCommand)],
        @[@123,@(kCGEventFlagMaskSecondaryFn|kCGEventFlagMaskShift)],
        @[@124,@(kCGEventFlagMaskControl|kCGEventFlagMaskAlternate|kCGEventFlagMaskShift)]
    ];
    for(NSArray *ordinaryKey in ordinary){
        CGEventSetIntegerValueField(event,kCGKeyboardEventKeycode,[ordinaryKey[0]unsignedIntValue]);CGEventSetFlags(event,[ordinaryKey[1]unsignedLongLongValue]);before=admitted;
        check([keys filterKey:kCGEventKeyDown event:event]==event&&admitted==before,@"ordinary or unsupported chord does not request window-control admission");
    }
    [keys pass:@[@"ctrl+f"]];CGEventSetIntegerValueField(event,kCGKeyboardEventKeycode,8);CGEventSetFlags(event,fnControl);
    check([keys filterKey:kCGEventKeyDown event:event]==NULL&&selected==DWNativeWindowControlCenter,@"F passthrough does not suppress unrelated Center admission");
    check([keys filterKey:kCGEventKeyUp event:event]==NULL,@"Center owns its release with another terminal passed");[keys pass:@NO];
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.001]];
    for(NSDictionary *letter in @[@{@"key":@"nativeRestoreKey",@"old":@15,@"new":@31,@"action":@(DWNativeWindowControlRestore)},@{@"key":@"nativeCenterKey",@"old":@8,@"new":@35,@"action":@(DWNativeWindowControlCenter)}]){
        [keys setValue:letter[@"new"] forKey:letter[@"key"]];CGEventSetIntegerValueField(event,kCGKeyboardEventKeycode,[letter[@"old"]unsignedIntValue]);
        check([keys filterKey:kCGEventKeyDown event:event]==event,@"layout-resolved control does not also claim its ANSI key");
        CGEventSetIntegerValueField(event,kCGKeyboardEventKeycode,[letter[@"new"]unsignedIntValue]);
        check([keys filterKey:kCGEventKeyDown event:event]==NULL&&selected==[letter[@"action"]unsignedIntegerValue],@"control follows its resolved keyboard-layout key");
        check([keys filterKey:kCGEventKeyUp event:event]==NULL,@"layout-resolved control owns release");
    }
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.001]];NSUInteger beforeStop=fired;
    CGEventSetIntegerValueField(event,kCGKeyboardEventKeycode,3);
    CGEventSetFlags(event,kCGEventFlagMaskControl|kCGEventFlagMaskCommand);
    current=YES;[keys setValue:@40 forKey:@"nativeFullscreenKey"];
    check([keys filterKey:kCGEventKeyDown event:event]==event,@"layout-resolved F does not also claim ANSI F");
    CGEventSetIntegerValueField(event,kCGKeyboardEventKeycode,40);
    current=YES;check([keys filterKey:kCGEventKeyDown event:event]==NULL,@"fullscreen admission before stop");[keys stop];
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];check(fired==beforeStop,@"stopping fences queued window-control action");
    CFRelease(event);[keys invalidate];check(!keys.nativeWindowControl,@"invalidation releases window-control admission callback");
}

static CGEventRef fillScrollPacket(CGScrollPhase phase,CGMomentumScrollPhase momentum,BOOL continuous) {
    CGEventRef packet=CGEventCreateScrollWheelEvent(NULL,continuous?kCGScrollEventUnitPixel:kCGScrollEventUnitLine,1,1);
    CGEventSetIntegerValueField(packet,kCGScrollWheelEventIsContinuous,continuous);
    CGEventSetIntegerValueField(packet,kCGScrollWheelEventScrollPhase,phase);
    CGEventSetIntegerValueField(packet,kCGScrollWheelEventMomentumPhase,momentum);
    return packet;
}
static BOOL fillScroll(InputDesktop *desktop,CGScrollPhase phase,CGMomentumScrollPhase momentum,BOOL continuous) {
    CGEventRef packet=fillScrollPacket(phase,momentum,continuous);
    BOOL consumed=[desktop fillInput:kCGEventScrollWheel event:packet];CFRelease(packet);return consumed;
}
static void fillInputTails(void) {
    InputView *view=inputView(source(NO));InputDesktop *desktop=view.desktop;desktop.native=[InputNative new];LiveSource *live=desktop.sources[@1];
    NSDictionary *handoff=@{@"identity":@{@"wid":@99},@"output":@3,@"background":@{@"placements":@[@{@"window":@1,@"output":@3,@"source":@{@"identity":live.identity}}]}};
    desktop.nativeFillHandoff=handoff;
    check(fillScroll(desktop,kCGScrollPhaseBegan,kCGMomentumScrollPhaseNone,YES)&&desktop.nativeFillBlockedScroll,@"a retained background owns a swallowed precise scroll from its beginning");
    desktop.nativeFillHandoff=nil;
    check(fillScroll(desktop,kCGScrollPhaseChanged,kCGMomentumScrollPhaseNone,YES),@"blocked scroll changed survives handoff cleanup");
    check(fillScroll(desktop,kCGScrollPhaseEnded,kCGMomentumScrollPhaseNone,YES)&&desktop.nativeFillBlockedScroll,@"finger end keeps suppression for pending momentum");
    check(fillScroll(desktop,0,kCGMomentumScrollPhaseBegin,YES)&&fillScroll(desktop,0,kCGMomentumScrollPhaseContinue,YES),@"blocked momentum cannot enter the newly fullscreen app");
    check(fillScroll(desktop,0,kCGMomentumScrollPhaseEnd,YES)&&!desktop.nativeFillBlockedScroll,@"momentum end consumes its final packet and releases ownership");
    check(!fillScroll(desktop,kCGScrollPhaseBegan,kCGMomentumScrollPhaseNone,YES),@"a later independent gesture keeps normal admission");
    desktop.nativeFillHandoff=handoff;check(fillScroll(desktop,kCGScrollPhaseBegan,kCGMomentumScrollPhaseNone,YES),@"second held scroll starts");desktop.nativeFillHandoff=nil;
    check(!fillScroll(desktop,kCGScrollPhaseMayBegin,kCGMomentumScrollPhaseNone,YES)&&!desktop.nativeFillBlockedScroll,@"new physical may-begin retires a lost terminal packet");
    desktop.nativeFillHandoff=handoff;check(fillScroll(desktop,kCGScrollPhaseBegan,kCGMomentumScrollPhaseNone,YES),@"third held scroll starts");desktop.nativeFillHandoff=nil;
    check(fillScroll(desktop,kCGScrollPhaseCancelled,kCGMomentumScrollPhaseNone,YES)&&!desktop.nativeFillBlockedScroll,@"cancelled scroll closes its swallowed sequence after cleanup");
    desktop.nativeFillHandoff=handoff;
    check(fillScroll(desktop,0,kCGMomentumScrollPhaseNone,NO)&&!desktop.nativeFillBlockedScroll,@"a discrete wheel event is blocked without reserving later wheel events");
    desktop.nativeFillHandoff=nil;check(!fillScroll(desktop,0,kCGMomentumScrollPhaseNone,NO),@"later discrete wheel event keeps ordinary admission");
    NSMutableDictionary *other=[handoff mutableCopy];other[@"output"]=@4;desktop.nativeFillHandoff=other;
    check(!fillScroll(desktop,kCGScrollPhaseBegan,kCGMomentumScrollPhaseNone,YES),@"another output's roots are not retained input targets");
    desktop.nativeFillHandoff=handoff;NSDictionary *identity=live.identity;live.identity=@{@"pid":@7,@"wid":@9,@"birth_sec":@124,@"birth_usec":@456};
    check(!fillScroll(desktop,kCGScrollPhaseBegan,kCGMomentumScrollPhaseNone,YES),@"a rebound native identity cannot inherit a background input hold");live.identity=identity;
    CGEventRef packet=mousePacket(kCGEventLeftMouseDown,kCGMouseButtonLeft);
    check([desktop fillInput:kCGEventLeftMouseDown event:packet]&&desktop.nativeFillBlockedButtons==1,@"retained background mouse down reserves its complete pair");
    desktop.nativeFillHandoff=nil;CGEventSetType(packet,kCGEventLeftMouseDragged);check([desktop fillInput:kCGEventLeftMouseDragged event:packet],@"retained background drag stays swallowed after cleanup");
    CGEventSetType(packet,kCGEventLeftMouseUp);check([desktop fillInput:kCGEventLeftMouseUp event:packet]&&!desktop.nativeFillBlockedButtons,@"retained background up closes its own swallowed pair");CFRelease(packet);
}

static void fillBackgroundCase(NSString *mode,BOOL retained) {
    InputDesktop *desktop=inputView(source(NO)).desktop;desktop.native=[InputNative new];desktop.nativeViews=[InputViews new];desktop.nativeFillRoot=[NSObject new];
    LiveSource *background=source(NO);background.logical=@2;background.identity=@{@"pid":@7,@"wid":@10,@"birth_sec":@123,@"birth_usec":@456};desktop.sources[@2]=background;
    BOOL pinned=[mode hasPrefix:@"pin_"];
    NSDictionary *screen=rectJSON(CGRectMake(0,0,1600,1200)),*parked=pointJSON(CGPointMake(12,-4));
    NSDictionary *oldOutput=@{@"id":@3,@"camera":pointJSON(CGPointMake(12.25,-4.5)),@"zoom":@.75,@"screen_bounds":screen};
    NSMutableDictionary *output=[@{@"id":@3,@"camera":parked,@"zoom":@1,@"screen_bounds":screen}mutableCopy];
    NSDictionary *root=desktop.snapshot[@"windows"][0],*binding=@{@"identity":background.identity,@"generation":@3,@"observation_known":@YES};
    NSDictionary *screenRect=rectJSON(CGRectMake(100,110,pinned?200:150,pinned?100:75));
    NSDictionary *pin=@{@"output":@3,@"screen_rect":screenRect};
    NSDictionary *old=@{@"window":@2,@"source":binding,@"world_rect":rectJSON(CGRectMake(50,60,200,100)),@"pinned":pinned?pin:(id)NSNull.null};
    NSDictionary *placement=@{@"window":@2,@"output":@3,@"source":binding,@"screen_rect":screenRect,@"clip_rect":screenRect,@"pinned":@(pinned)};
    NSMutableDictionary *current=[old mutableCopy],*currentRoot=[root mutableCopy];
    if(pinned||[mode isEqual:@"moved"])current[@"world_rect"]=rectJSON(CGRectMake(112,106,200,100));
    if([mode isEqual:@"display"])output[@"screen_bounds"]=rectJSON(CGRectMake(0,0,1800,1200));
    if([mode isEqual:@"camera"])output[@"camera"]=pointJSON(CGPointMake(13,-4));
    if([mode isEqual:@"binding"]){NSMutableDictionary *changed=[root[@"source"]mutableCopy];changed[@"generation"]=@4;currentRoot[@"source"]=changed;}
    if([mode isEqual:@"source"]){NSMutableDictionary *changed=[binding mutableCopy];changed[@"generation"]=@4;current[@"source"]=changed;}
    if([mode isEqual:@"identity"])background.identity=@{@"pid":@7,@"wid":@10,@"birth_sec":@124,@"birth_usec":@456};
    if([mode isEqual:@"pin_screen"])current[@"pinned"]=@{@"output":@3,@"screen_rect":rectJSON(CGRectMake(101,110,200,100))};
    if([mode isEqual:@"pin_output"])current[@"pinned"]=@{@"output":@4,@"screen_rect":screenRect};
    NSDictionary *prior=@{@"outputs":@[oldOutput],@"windows":@[root,old],@"placements":@[placement]};
    NSDictionary *snapshot=@{@"outputs":@[output],@"windows":@[currentRoot,current],@"placements":@[]};
    desktop.nativeFillHandoff=@{@"window":@1,@"output":@3,@"identity":root[@"source"][@"identity"],@"generation":@2,@"presenter":desktop.native,
        @"session":@(desktop.nativeSessionEpoch),@"transaction":@1,@"camera":parked,@"zoom":@1,@"screen_bounds":screen,@"background":prior};
    if([mode isEqual:@"session"])desktop.nativeSessionEpoch++;
    if([mode isEqual:@"animated"])desktop.nativeFillAnimated=YES;
    NSDictionary *result=[desktop nativeFillBackground:snapshot];
    check(retained?([result[@"placements"]count]==1&&result[@"placements"][0]==placement):result==snapshot,
        [NSString stringWithFormat:@"Fill background %@ %@",mode,retained?@"retains its exact prior screen placement":@"refuses obsolete projection"]);
    check([snapshot[@"placements"]count]==0&&prior[@"placements"][0]==placement,@"Fill background projection leaves both input snapshots unchanged");
}

int main(void) {@autoreleasepool {
    jobs=[NSMutableArray array];checks=0;
    CGRect chromeNative=CGRectMake(90,100,230,408),chromeScreen=CGRectMake(600,200,230,408);
    NSMutableDictionary *chrome=[@{@"pinned":@YES,@"screen_rect":rectJSON(chromeScreen),@"clip_rect":rectJSON(chromeScreen)}mutableCopy];
    NSDictionary *chromeOutput=@{@"zoom":@.5,@"screen_bounds":rectJSON(CGRectMake(0,0,1600,1200))};
    check(DWNativeChromeFrameMatches(chromeNative,chromeScreen,chrome,chromeOutput,CGPointMake(610,210)),@"pinned chrome stays unit scale at overview zoom");
    check(!DWNativeChromeFrameMatches(chromeNative,CGRectMake(600,200,115,204),chrome,chromeOutput,CGPointMake(610,210)),@"scaled pin cannot authorize a direct chrome action");
    chrome[@"pinned"]=@NO;chrome[@"screen_rect"]=rectJSON(CGRectMake(600.2,200.3,115,204));
    check(DWNativeChromeFrameMatches(chromeNative,CGRectMake(600,200,116,205),chrome,chromeOutput,CGPointMake(610,210)),@"four-edge outward raster rounding is accepted");
    check(!DWNativeChromeFrameMatches(chromeNative,CGRectMake(610,200,116,205),chrome,chromeOutput,CGPointMake(620,210)),@"stale displayed translation refuses direct chrome");
    chrome[@"screen_rect"]=rectJSON(CGRectMake(-100,200,115,204));chrome[@"clip_rect"]=rectJSON(CGRectMake(0,200,15,204));
    check(DWNativeChromeFrameMatches(chromeNative,CGRectMake(-100,200,115,204),chrome,chromeOutput,CGPointMake(5,210)),@"visible chrome of a partially offscreen root remains eligible");
    check(DWNativeChromeFrameMatches(chromeNative,CGRectMake(-100,200,115,204),chrome,chromeOutput,CGPointMake(16,210)),@"frame proof permits separately controller-qualified outer resize band");
    check(!DWNativeChromeFrameMatches(chromeNative,CGRectMake(-100,200,115,204),chrome,chromeOutput,CGPointMake(-1,210)),@"chrome point outside output clip refuses");
    NSDictionary *chromeIdentity=@{@"pid":@7,@"wid":@9};double chromeSample=CACurrentMediaTime();
    NSDictionary *chromeReport=@{@"identity":chromeIdentity,@"native_bounds":rectJSON(chromeNative),@"sampled_at":@(chromeSample),@"title":@{@"excluded":@[@"same local controls"]}};
    NSDictionary *moved=DWNativeMovedButtons(chromeReport,chromeIdentity,CGRectMake(600,200,230,408));
    check(moved&&[moved[@"sampled_at"]isEqual:chromeReport[@"sampled_at"]]&&[moved[@"title"]isEqual:chromeReport[@"title"]],@"move-only report preserves sample age and local exclusions");
    check(!DWNativeMovedButtons(chromeReport,chromeIdentity,CGRectMake(600,200,231,408)),@"extent change invalidates move-only chrome");
    check(!DWNativeMovedButtons(chromeReport,@{@"pid":@7,@"wid":@10},chromeNative),@"identity change invalidates move-only chrome");
    NSMutableDictionary *expired=[chromeReport mutableCopy];expired[@"sampled_at"]=@(chromeSample-1);
    check(!DWNativeMovedButtons(expired,chromeIdentity,chromeNative),@"move hint never freshens expired AX geometry");
    CFTimeInterval refreshNow=chromeSample+.2;
    check(DWNativeButtonsAfterRefresh(nil,chromeReport,chromeIdentity,refreshNow,YES,chromeNative)==chromeReport,@"nil refresh preserves the exact current public map and its original timestamp");
    check(!DWNativeButtonsAfterRefresh(nil,chromeReport,chromeIdentity,chromeSample+.501,YES,chromeNative),@"failed refresh cannot extend the half-second title authority");
    check(!DWNativeButtonsAfterRefresh(nil,chromeReport,chromeIdentity,refreshNow,NO,chromeNative),@"failed native owner validation cannot retain title authority");
    check(!DWNativeButtonsAfterRefresh(nil,chromeReport,chromeIdentity,refreshNow,YES,CGRectOffset(chromeNative,1,0)),@"failed refresh cannot translate a public title map");
    check(!DWNativeButtonsAfterRefresh(nil,chromeReport,@{@"pid":@7,@"wid":@10},refreshNow,YES,chromeNative),@"failed refresh cannot retain a different source identity");
    check(!DWNativeButtonsAfterRefresh(nil,nil,chromeIdentity,refreshNow,YES,chromeNative),@"invalidated public map cannot be resurrected from a prior request");
    NSDictionary *negativeChrome=@{@"identity":chromeIdentity,@"native_bounds":rectJSON(chromeNative),@"sampled_at":@(refreshNow),@"title":@{}};
    check(DWNativeButtonsAfterRefresh(negativeChrome,chromeReport,chromeIdentity,refreshNow,YES,chromeNative)==negativeChrome,@"successful negative title report replaces the older map");
    check(!DWNativeButtonsAfterRefresh(chromeReport,chromeReport,chromeIdentity,refreshNow,YES,chromeNative),@"late nonnil report cannot fall back to an older map");

    fillInputTails();
    fillBackgroundCase(@"fractional",YES);fillBackgroundCase(@"pin_world",YES);
    for(NSString *mode in @[@"display",@"binding",@"source",@"identity",@"pin_screen",@"pin_output",@"moved",@"camera",@"session",@"animated"])fillBackgroundCase(mode,NO);
    titleReleaseCase(@"stationary",YES);titleReleaseCase(@"slop",YES);titleMotionCase();
    titleReleaseCase(@"drag",NO);titleReleaseCase(@"out_and_back",NO);
    titleReleaseCase(@"lost_up",NO);titleReleaseCase(@"other_output",NO);
    for(NSString *mode in @[@"second_down",@"rebound",@"focus",@"pose",@"session"])titleDeferredCase(mode);
    standInKeys();
    nativeWindowControlKeys();
    heldFocusCase(@"pending root focus never posts early",@"pending",NO);
    heldFocusCase(@"failed root focus drops the unsent pair",@"failure",NO);
    heldFocusCase(@"cancelled root focus drops the unsent pair",@"cancelled",NO);
    heldFocusCase(@"superseded root focus drops the unsent pair",@"superseded",NO);
    heldFocusCase(@"another successful effect cannot authorize this press",@"wrong_result",NO);
    heldFocusCase(@"changed observed root refuses the press",@"observation_changed",NO);
    heldFocusCase(@"changed observed generation refuses the press",@"generation_changed",NO);
    heldFocusCase(@"changed observed identity refuses the press",@"identity_changed",NO);
    heldFocusCase(@"foreground departure refuses the press",@"foreground_changed",NO);
    heldFocusCase(@"expired root press cannot be revived by success",@"expired",NO);
    heldFocusCase(@"placeholder focus intent supersedes confirmed root press",@"placeholder_intent",NO);
    heldFocusCase(@"cleared focus intent supersedes confirmed root press",@"cleared_intent",NO);
    heldFocusCase(@"matching success accepts an independently observed focus",@"success",YES);
    heldFocusCase(@"valid focus completion after half a second remains usable",@"slow_success",YES);
    heldFocusCase(@"logical-only focus keeps deliberate captured click semantics",@"logical",YES);
    heldFocusCase(@"focus invalidated during mapping cannot post the held press",@"revoked_during_forward",NO);
    LiveSource *s=source(NO);InputView *v=inputView(s);InputDesktop *d=v.desktop;
    CGEventRef down=mousePacket(kCGEventLeftMouseDown,kCGMouseButtonLeft),up=mousePacket(kCGEventLeftMouseUp,kCGMouseButtonLeft);
    check([v inputIntentForHit:v.testHit output:@3]==nil,@"unpublished captured image cannot establish a click intent");publish(s,1);
    NSDictionary *intent=[v inputIntentForHit:v.testHit output:@3];check(intent!=nil,@"published captured image establishes exact recipient intent");
    deliverPacket(s,packet(@(SCFrameStatusSuspended),NO,NO,0));
    check([v inputIntentForHit:v.testHit output:@3]==nil&&![v forward:down at:CGPointMake(104,205) output:@3 activate:NO],@"retained suspended image refuses fresh mouse input");
    check(s.router.posts==0,@"refused fresh down does not reach router");
    v.heldPress=[NSEvent eventWithCGEvent:down];v.heldRelease=[NSEvent eventWithCGEvent:up];v.heldReleased=YES;v.heldWindow=@1;v.heldOutput=@3;v.heldIntent=intent;v.clickWindow=@1;
    [v deliverHeld];check(s.router.posts==0&&!v.heldPress&&!v.clickWindow,@"focus-delayed click is rechecked and drops its whole unsent pair");
    publish(s,2);check([v forward:down at:CGPointMake(104,205) output:@3 activate:NO],@"current captured down reaches router");
    deliverPacket(s,packet(@(SCFrameStatusStopped),NO,NO,0));
    check(![v forward:up at:CGPointMake(104,205) output:@3 activate:NO],@"unavailable capture cannot map another synthetic packet");
    [v releasePressed];check(s.router.posts==2&&s.router.lastType==kCGEventLeftMouseUp&&!v.pressedSource,@"already-admitted normal button closes original recipient despite unavailable capture");
    publish(s,3);__weak LiveSource *weak=s;v.duringFocus=^{deliverPacket(weak,packet(@(SCFrameStatusBlank),NO,NO,0));};
    check(![v forward:down at:CGPointMake(104,205) output:@3 activate:YES]&&s.router.posts==2,@"revocation during focus is rechecked immediately before posting");v.duringFocus=nil;
    publish(s,4);intent=[v inputIntentForHit:v.testHit output:@3];
    check([d resolveCapturedPointer:intent screen:CGPointMake(104,205)]!=nil,@"current captured pointer uses existing mapping");
    deliverPacket(s,packet(@(SCFrameStatusSuspended),NO,NO,0));check([d resolveCapturedPointer:intent screen:CGPointMake(104,205)]==nil&&[d validateInputTarget:intent],@"motion mapping revokes while original-identity release validation stays valid");
    d.pointerGrab=[DWNativePointerGrab new];check([d.pointerGrab admitEvent:down target:intent local:CGPointMake(4,5)],@"existing posted mouse pair admitted in real adapter");
    CGEventRef second=mousePacket(kCGEventRightMouseDown,kCGMouseButtonRight),secondUp=mousePacket(kCGEventRightMouseUp,kCGMouseButtonRight);
    check(![d forwardCapturedPointer:second screen:CGPointMake(104,205)]&&d.ups==1&&d.downs==0,@"unavailable pointer capture pairs original down but never posts additional down");
    [d forwardCapturedPointer:up screen:CGPointMake(104,205)];[d forwardCapturedPointer:secondUp screen:CGPointMake(104,205)];
    check(d.posts==1&&!d.pointerGrab.active&&!d.pointerGrab.suppressed,@"physical mouse tail is suppressed and retires without duplicate release");
    publish(s,5);d.tablet=[DWNativeTabletRouter new];CGEventRef enter=tabletPacket(kCGEventTabletProximity,0,0),pen=tabletPacket(kCGEventLeftMouseDown,0,.5),extra=tabletPacket(kCGEventRightMouseDown,1,.5);
    [d.tablet observeEvent:enter];
    check([d.tablet forwardEvent:pen target:intent local:CGPointMake(4,5) validate:^BOOL(NSDictionary *t){return [d validateInputTarget:t];} post:^BOOL(CGEventRef e,NSDictionary *t,CGPoint p){return [d postInput:e target:t local:p];}],@"real tablet adapter admits original contact");
    NSUInteger downs=d.downs,ups=d.ups;deliverPacket(s,packet(@(SCFrameStatusSuspended),NO,NO,0));
    check(![d forwardTabletTail:extra]&&d.downs==downs&&d.ups==ups+1&&d.toolOuts==1,@"capture revocation closes exact tablet contact and blocks additional down");
    CGEventRef penUp=tabletPacket(kCGEventLeftMouseUp,0,0),extraUp=tabletPacket(kCGEventRightMouseUp,1,0);NSUInteger posted=d.posts;
    [d forwardTabletTail:penUp];[d forwardTabletTail:extraUp];
    check(d.posts==posted&&![d.tablet ownsEvent:extraUp],@"tablet physical tail retires without repost or duplicate cleanup");
    publish(s,6);s.synth=[NSObject new];check([v inputIntentForHit:v.testHit output:@3]==nil&&![v forward:down at:CGPointMake(104,205) output:@3 activate:NO],@"synthetic load never authorizes app input");s.synth=nil;
    resetSource(s);s.composited=NO;check([v inputIntentForHit:v.testHit output:@3]!=nil,@"distinct AV fixture does not invent a production mailbox requirement");
    s.router.validIdentity=NO;check(![v forward:down at:CGPointMake(104,205) output:@3 activate:NO],@"AV fixture still requires original native binding validation");
    for(NSValue *value in @[[NSValue valueWithPointer:down],[NSValue valueWithPointer:up],[NSValue valueWithPointer:second],[NSValue valueWithPointer:secondUp],[NSValue valueWithPointer:enter],[NSValue valueWithPointer:pen],[NSValue valueWithPointer:extra],[NSValue valueWithPointer:penUp],[NSValue valueWithPointer:extraUp]])CFRelease(value.pointerValue);
    printf("captured input: %lu checks passed (actual consumers; substituted posting)\n",(unsigned long)checks);return 0;
}}
