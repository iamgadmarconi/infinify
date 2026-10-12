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
@end
@implementation InputViews
- (BOOL)replica:(NSNumber *)window output:(NSNumber *)output { (void)window;(void)output;return YES; }
@end
@interface InputFamilies : NSObject
- (BOOL)contains:(NSNumber *)window identity:(NSDictionary *)identity generation:(NSNumber *)generation bounds:(CGRect)bounds;
@end
@implementation InputFamilies
- (BOOL)contains:(NSNumber *)window identity:(NSDictionary *)identity generation:(NSNumber *)generation bounds:(CGRect)bounds {
    (void)window;(void)identity;(void)generation;(void)bounds;return YES;
}
@end
@interface InputDesktop : NSObject
@property NSMutableDictionary *sources;
@property NSDictionary *snapshot,*scope;
@property InputNative *native;
@property InputViews *nativeViews;
@property InputFamilies *nativeFamilies;
@property BOOL sessionInactive,cleaning;
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
- (BOOL)validateInputTarget:(NSDictionary *)target;
- (BOOL)postInput:(CGEventRef)event target:(NSDictionary *)target local:(CGPoint)local;
- (NSDictionary *)resolveCapturedPointer:(NSDictionary *)target screen:(CGPoint)screen;
- (BOOL)forwardCapturedPointer:(CGEventRef)event screen:(CGPoint)screen;
- (BOOL)forwardTabletTail:(CGEventRef)event;
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
#include "captured-input-target-functions.inc"
#define AXIsProcessTrusted inputTrusted
#define Desktop InputDesktop
@implementation InputView
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
    (void)request;dispatch_block_t before=self.beforeReply;self.beforeReply=nil;if(before)before();
    return @{@"hit":@{@"window":@1,@"local":pointJSON(CGPointMake(4,5))},@"windows":self.snapshot[@"windows"]};
}
- (void)cancelNavigation {}
- (void)clickReleased:(NSNumber *)window output:(NSNumber *)output { (void)window;(void)output; }
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
static CGEventRef tabletPacket(CGEventType type,int64_t button,double pressure) {
    CGEventRef event=CGEventCreate(NULL);CGEventSetType(event,type);
    if(type==kCGEventTabletProximity){CGEventSetIntegerValueField(event,kCGTabletProximityEventDeviceID,42);CGEventSetIntegerValueField(event,kCGTabletProximityEventEnterProximity,1);}
    else{CGEventSetIntegerValueField(event,kCGMouseEventSubtype,kCGEventMouseSubtypeTabletPoint);CGEventSetIntegerValueField(event,kCGTabletEventDeviceID,42);CGEventSetDoubleValueField(event,kCGTabletEventPointPressure,pressure);CGEventSetIntegerValueField(event,kCGMouseEventButtonNumber,button);}
    return event;
}
int main(void) {@autoreleasepool {
    jobs=[NSMutableArray array];checks=0;LiveSource *s=source(NO);InputView *v=inputView(s);InputDesktop *d=v.desktop;
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
