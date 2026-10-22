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
- (void)pressReleased:(CGPoint)point;
@end
@implementation InputHover
- (void)pressReleased:(CGPoint)point { (void)point; }
@end
@interface InputDesktop : NSObject
@property NSMutableDictionary *sources;
@property NSDictionary *snapshot,*scope;
@property NSDictionary *nativeFillHandoff;
@property InputNative *native;
@property InputViews *nativeViews;
@property InputFamilies *nativeFamilies;
@property BOOL sessionInactive,cleaning,logicalFocus;
@property BOOL configured;
@property NSArray *views;
@property InputResize *resize;
@property NSDictionary *nativeTitleClick;
@property NSTimer *nativeTitleClickTimer;
@property uint64_t nativeSessionEpoch;
@property NSUInteger titleClicks,endedGestures;
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
- (BOOL)validateInputTarget:(NSDictionary *)target;
- (BOOL)postInput:(CGEventRef)event target:(NSDictionary *)target local:(CGPoint)local;
- (NSDictionary *)resolveCapturedPointer:(NSDictionary *)target screen:(CGPoint)screen;
- (BOOL)forwardCapturedPointer:(CGEventRef)event screen:(CGPoint)screen;
- (BOOL)forwardTabletTail:(CGEventRef)event;
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
#include "captured-input-view-consumers.inc"
@end
@implementation InputDesktop
- (NSDictionary *)presentationSnapshot { return self.snapshot; }
- (NSDictionary *)call:(NSDictionary *)request {
    if([request[@"op"]isEqual:@"end_gesture"])self.endedGestures++;
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
    CGPoint release=CGPointMake(103,204);
    if([mode isEqual:@"drag"])release.x=106;
    if([mode isEqual:@"out_and_back"])v.nativeTitleMoved=YES;
    if([mode isEqual:@"lost_up"])v.nativeTitleReleased=NO;
    if([mode isEqual:@"other_output"])release.x=501;
    [v released:release at:1];
    check((v.desktop.nativeTitleClick!=nil)==expected,[NSString stringWithFormat:@"title click %@ release eligibility",mode]);
    check(v.desktop.titleClicks==0,@"title click never navigates before the double-click interval");
    check(v.gesture==0&&v.nativeTitlePress==nil,@"title release always ends original drag ownership");
    if(expected){
        check(v.desktop.endedGestures==1,@"title click is armed after ending the world drag");
        [v.desktop fireNativeTitleClick:v.desktop.nativeTitleClickTimer];
        check(v.desktop.titleClicks==1,@"current stationary title click reaches controller navigation after delay");
    }
    [v.desktop cancelNativeTitleClick];
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
static void nativeFullscreenKeys(void) {
    __block NSUInteger admitted=0,fired=0;__block BOOL current=YES;
    DWHotKeys *keys=[[DWHotKeys alloc]initWithFire:^(NSString *action){(void)action;}];
    keys.nativeFullscreen=^dispatch_block_t{admitted++;return current?^{if(current)fired++;}:nil;};
    // Pin the resolver's output: this input-policy test never changes the host layout.
    [keys setValue:@3 forKey:@"nativeFullscreenKey"];
    [keys setValue:[NSMutableDictionary dictionary] forKey:@"suppressedKeys"];[keys setValue:[NSMutableIndexSet indexSet] forKey:@"tapKeys"];
    CGEventRef event=CGEventCreateKeyboardEvent(NULL,3,true);CGEventSetFlags(event,kCGEventFlagMaskControl|kCGEventFlagMaskCommand);
    check([keys filterKey:kCGEventKeyDown event:event]==NULL,@"native fullscreen owns an admitted Control-Command-F down");
    CGEventSetIntegerValueField(event,kCGKeyboardEventAutorepeat,1);
    check([keys filterKey:kCGEventKeyDown event:event]==NULL&&admitted==1,@"fullscreen repeat cannot toggle twice");
    check([keys filterKey:kCGEventKeyUp event:event]==NULL,@"fullscreen owns its physical release");
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];check(fired==1,@"fullscreen dispatches one admitted job");
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
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];check(fired==2,@"Fn-F dispatches the same pinned action");
    CGEventSetFlags(event,kCGEventFlagMaskControl|kCGEventFlagMaskCommand);
    current=YES;[keys setValue:@40 forKey:@"nativeFullscreenKey"];
    check([keys filterKey:kCGEventKeyDown event:event]==event,@"layout-resolved F does not also claim ANSI F");
    CGEventSetIntegerValueField(event,kCGKeyboardEventKeycode,40);
    current=YES;check([keys filterKey:kCGEventKeyDown event:event]==NULL,@"fullscreen admission before stop");[keys stop];
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];check(fired==2,@"stopping fences queued fullscreen action");
    CFRelease(event);[keys invalidate];check(!keys.nativeFullscreen,@"invalidation releases fullscreen admission callback");
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
    titleReleaseCase(@"stationary",YES);
    titleReleaseCase(@"drag",NO);titleReleaseCase(@"out_and_back",NO);
    titleReleaseCase(@"lost_up",NO);titleReleaseCase(@"other_output",NO);
    for(NSString *mode in @[@"second_down",@"rebound",@"focus",@"pose",@"session"])titleDeferredCase(mode);
    standInKeys();
    nativeFullscreenKeys();
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
