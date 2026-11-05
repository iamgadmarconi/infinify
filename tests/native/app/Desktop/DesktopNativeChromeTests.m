// SPDX-License-Identifier: GPL-3.0-or-later
// Exact earlyNativeTitle implementation extracted at build time. Real tap pair handling,
// in-memory packets and NSEvent conversion. All controller/native reads are substitutes.
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import "DWTypedValue.h"
#import "DWGeometryJSON.h"
#import "DWControllerHit.h"
#import "DWNativeInput.m"
#import "DWNativeTabletRouter.h"
static const NSInteger DWPolicyPress=9;
static CGRect nativeRect,screenRect;
static NSDictionary *recipient,*changedRecipient,*snapshot;
static BOOL isTitle,scopeOK=YES,frameOK=YES,changeGeneration;
static NSUInteger recipientReads;
static NSDictionary *identity;
static NSDictionary *pointJSON(CGPoint p){return @{@"x":@(p.x),@"y":@(p.y)};}
static NSDictionary *DWPickHit(NSDictionary *hit,NSDictionary *s,NSNumber *output){(void)output;if([s[@"outputs"][0][@"pick"]boolValue]){NSMutableDictionary *h=[hit mutableCopy];h[@"pick"]=@YES;return h;}return hit;}
static NSArray *birth(pid_t pid){(void)pid;return @[@123,@0];}
static BOOL boundIdentity(NSDictionary *a,NSDictionary *b){for(NSString *key in @[@"pid",@"wid",@"birth_sec",@"birth_usec"])if(![a[key]isEqual:b[key]])return NO;return YES;}
static BOOL DWInScope(id scope,pid_t pid){(void)scope;(void)pid;return scopeOK;}
static BOOL DWNativeBounds(uint32_t wid,CGRect *out){(void)wid;*out=nativeRect;return frameOK;}
static NSDictionary *windowInfo(uint32_t wid){return @{(id)kCGWindowOwnerPID:identity[@"pid"],(id)kCGWindowNumber:@(wid),(id)kCGWindowIsOnscreen:@YES,(id)kCGWindowAlpha:@1,(id)kCGWindowBounds:CFBridgingRelease(CGRectCreateDictionaryRepresentation(screenRect))};}
static NSDictionary *DWNativeEventRecipientAtPoint(CGPoint p){(void)p;return recipientReads++&&changedRecipient?changedRecipient:recipient;}
static BOOL DWNativeWindowDragHit(NSDictionary *who,NSDictionary *buttons,CGPoint p){(void)who;(void)buttons;(void)p;return isTitle;}
static void DWNativeTitleRefused(BOOL early,const char *why,NSNumber *logical,uint32_t wid,CGPoint p,id extra){(void)early;(void)why;(void)logical;(void)wid;(void)p;(void)extra;}
#include "ChromeGeometry.inc"
@interface Mock : NSObject
@property BOOL ended,active,engaged,ownsTouches,hasNativeMousePress;
@property pid_t pid;
@property uint32_t wid;
@property NSInteger windowNumber;
@property NSArray *processBirth;
@property NSNumber *owner,*busy;
@property BOOL replica;
- (NSNumber *)rootWindowFor:(uint32_t)wid;
- (NSNumber *)desiredOwnerForWindow:(NSNumber *)window;
- (id)replica:(NSNumber *)window output:(NSNumber *)output;
- (NSNumber *)busyWindow;
- (void)cancel;
- (void)cancelNativeClick;
- (void)releaseCycle;
- (void)perform:(id)reply;
- (void)nearestPress:(CGPoint)p output:(NSNumber *)o focus:(BOOL)f;
@end
@implementation Mock
- (NSNumber *)rootWindowFor:(uint32_t)wid{return wid==300?@300:nil;}
- (NSNumber *)desiredOwnerForWindow:(NSNumber *)window{(void)window;return self.owner;}
- (id)replica:(NSNumber *)window output:(NSNumber *)output{(void)window;(void)output;return self.replica?@YES:nil;}
- (NSNumber *)busyWindow{return self.busy;}
- (void)nearestPress:(CGPoint)p output:(NSNumber *)o focus:(BOOL)f{(void)p;(void)o;(void)f;}
- (void)cancel{}
- (void)cancelNativeClick{}
- (void)releaseCycle{}
- (void)perform:(id)reply{(void)reply;}
@end
@interface DWCycleHold : NSObject
+ (NSUInteger)modifiersDown;
@end
@implementation DWCycleHold
+ (NSUInteger)modifiersDown{return 0;}
@end
@interface LiveSource : NSObject
@property BOOL detached,nativeVisibilityHeld;
@property Mock *router;
@property NSDictionary *identity,*nativeButtons,*nativeMouseOwnership;
@property NSNumber *logical;
@end
@implementation LiveSource @end
@interface DesktopView : NSObject
@property NSInteger gesture,gestureButton;
@property id heldPress,pressedSource,pressedTablet,pressedPointerGrab,clickWindow;
@property Mock *window,*hover;
@property NSDictionary *border,*nativeTitlePress;
@property NSNumber *dragOutput,*lastOutput;
@property CGPoint startPoint,lastPoint;
@property double lastDragPan,lastScrollPan,scrollPanTime;
@property BOOL clearsFocus,nativeTitleMoved,nativeTitleReleased;
@property NSUInteger begins;
- (NSNumber *)outputAt:(CGPoint)p;
- (NSDictionary *)resizeBorderForButton:(NSInteger)b flags:(NSEventModifierFlags)f hit:(NSDictionary *)hit at:(CGPoint)p output:(NSNumber *)out;
- (void)beginResize:(NSNumber *)w edges:(NSString *)e snapped:(BOOL)s at:(CGPoint)p output:(NSNumber *)o;
@end
@implementation DesktopView
- (NSNumber *)outputAt:(CGPoint)p{(void)p;return @1;}
- (NSDictionary *)resizeBorderForButton:(NSInteger)b flags:(NSEventModifierFlags)f hit:(NSDictionary *)hit at:(CGPoint)p output:(NSNumber *)out{
    (void)b;(void)hit;(void)p;(void)out;return f&NSEventModifierFlagOption?nil:self.border;}
- (void)beginResize:(NSNumber *)w edges:(NSString *)e snapped:(BOOL)s at:(CGPoint)p output:(NSNumber *)o{
    (void)w;(void)e;(void)s;(void)p;(void)o;self.begins++;self.gesture=4;}
@end
@interface Desktop : NSObject
@property Mock *native,*pointerGrab,*trackpad,*globalTrackpad,*resize,*nativeViews,*navigation,*panLaunch;
@property BOOL cleaning,sessionInactive,routingEarlyNativeTitle,globalGestureContact,magnifying;
@property id nativeScrollView,nativeMagnifyView,gestureOwner,nativeOwnershipTransfer,nativeHoverTransfer,scope;
@property DesktopView *nativeGestureView;
@property NSInteger nativeGestureButton;
@property NSUInteger nativeFillBlockedButtons;
@property NSDictionary *nativeFillHandoff,*nativeDecorationPress;
@property NSArray<DesktopView *> *views;
@property NSMutableDictionary<NSNumber *,LiveSource *> *sources;
@property NSDictionary *binding;
@property NSUInteger snapshots,picks,drags;
- (BOOL)earlyNativeTitle:(CGEventType)t event:(CGEventRef)e;
- (BOOL)nativeUnavailable;
- (BOOL)nativeGreen:(LiveSource *)s at:(CGPoint)p;
- (NSDictionary *)call:(NSDictionary *)command;
- (NSDictionary *)mouseBinding:(NSString *)button source:(id)s flags:(NSEventModifierFlags)f window:(BOOL)w under:(NSNumber *)u pick:(BOOL)p;
- (void)cancelNativeTitleClick;
- (void)cancelGestures;
- (void)cancelNavigation;
- (void)render;
- (void)deliverNative:(NSEvent *)e type:(CGEventType)t view:(DesktopView *)v at:(CGPoint)p;
- (void)applyReply:(id)r;
- (void)action:(id)a output:(id)o at:(CGPoint)p held:(BOOL)h;
@end
@implementation Desktop
- (BOOL)nativeUnavailable{return NO;}
- (BOOL)nativeGreen:(LiveSource *)s at:(CGPoint)p{(void)s;(void)p;return NO;}
- (NSDictionary *)call:(NSDictionary *)command{
    if([command[@"op"]isEqual:@"snapshot"]){
        if(self.snapshots++&&changeGeneration){NSMutableDictionary *row=[snapshot[@"windows"][0]mutableCopy];NSMutableDictionary *source=[row[@"source"]mutableCopy];source[@"generation"]=@99;row[@"source"]=source;NSMutableDictionary *s=[snapshot mutableCopy];s[@"windows"]=@[row];return s;}
        return snapshot;
    }
    if([command[@"op"]isEqual:@"begin_drag"])self.drags++;
    return @{};
}
- (NSDictionary *)mouseBinding:(NSString *)button source:(id)s flags:(NSEventModifierFlags)f window:(BOOL)w under:(NSNumber *)u pick:(BOOL)p{
    (void)button;(void)s;(void)f;(void)w;(void)u;(void)p;return self.binding;}
- (void)cancelNativeTitleClick{}
- (void)cancelGestures{}
- (void)cancelNavigation{}
- (void)render{}
- (void)deliverNative:(NSEvent *)e type:(CGEventType)t view:(DesktopView *)v at:(CGPoint)p{(void)e;(void)t;(void)v;(void)p;self.picks++;}
- (void)applyReply:(id)r{(void)r;}
- (void)action:(id)a output:(id)o at:(CGPoint)p held:(BOOL)h{(void)a;(void)o;(void)p;(void)h;}
#include "ChromeConsumer.inc"
@end
static int checks,failures;
static void check(BOOL ok,const char *label){checks++;if(!ok){failures++;fprintf(stderr,"FAIL: %s\n",label);}}
static Desktop *setup(void){
    nativeRect=CGRectMake(300,200,600,400);screenRect=CGRectMake(800,400,300,200);
    identity=@{@"pid":@42,@"wid":@300,@"birth_sec":@123,@"birth_usec":@0};
    recipient=@{@"pid":@(getpid()),@"wid":@299,@"birth_sec":@10,@"birth_usec":@0,@"owner":@5};
    changedRecipient=nil;recipientReads=0;scopeOK=frameOK=YES;isTitle=changeGeneration=NO;
    NSDictionary *source=@{@"identity":identity,@"generation":@7};
    snapshot=@{@"windows":@[@{@"window":@49,@"source":source}],@"placements":@[@{@"window":@49,@"output":@1,@"screen_rect":DWRectJSON(screenRect)}],
        @"outputs":@[@{@"id":@1,@"zoom":@0.5,@"screen_bounds":DWRectJSON(CGRectMake(0,0,1920,1200))}]};
    Desktop *d=[Desktop new];d.native=[Mock new];d.nativeViews=[Mock new];d.nativeViews.owner=@1;d.resize=[Mock new];
    LiveSource *s=[LiveSource new];s.identity=identity;s.logical=@49;s.router=[Mock new];s.router.wid=300;s.router.pid=42;s.router.processBirth=@[@123,@0];
    d.sources=[@{@49:s}mutableCopy];DesktopView *v=[DesktopView new];v.window=[Mock new];v.window.windowNumber=299;v.border=@{@"window":@49,@"edges":@"top",@"snapped":@NO};d.views=@[v];
    return d;
}
static CGEventRef packet(CGEventType type){CGEventRef e=CGEventCreateMouseEvent(NULL,type,CGPointMake(950,398),kCGMouseButtonLeft);CGEventSetFlags(e,0);return e;}
static BOOL down(Desktop *d){CGEventRef e=packet(kCGEventLeftMouseDown);BOOL yes=[d earlyNativeTitle:kCGEventLeftMouseDown event:e];CFRelease(e);return yes;}
int main(void){@autoreleasepool{
    Desktop *d=setup();DWNativeInput *tap=[[DWNativeInput alloc]initWithConsume:^BOOL(CGEventType t,CGEventRef e){(void)t;(void)e;return YES;}
        earlyConsume:^BOOL(CGEventType t,CGEventRef e){return [d earlyNativeTitle:t event:e];} ignoreEvent:nil cancelled:nil];
    CGEventRef e=packet(kCGEventLeftMouseDown);check([tap handleEarly:kCGEventLeftMouseDown event:e]==NULL,"outer border: early down is swallowed");CFRelease(e);
    check(d.views[0].begins==1,"outer border: controller resize begins once");
    e=packet(kCGEventLeftMouseDragged);check([tap handleEarly:kCGEventLeftMouseDragged event:e]==NULL,"owned drag never leaks to WindowServer");CFRelease(e);
    e=packet(kCGEventLeftMouseUp);check([tap handleEarly:kCGEventLeftMouseUp event:e]==NULL,"owned release never leaks to WindowServer");CFRelease(e);
    check(!tap.hasEarlyMousePress,"release retires early ownership");
    d=setup();recipient=identity;check(down(d)&&d.views[0].begins==1,"same-root border remains claimed");
    d=setup();recipient=@{@"pid":@87,@"wid":@400};check(!down(d)&&!d.views[0].begins,"foreign occluder wins");
    d=setup();recipient=@{@"pid":@42,@"wid":@301};check(!down(d),"child is not a root border");
    d=setup();recipient=nil;check(!down(d),"unreadable recipient fails closed");
    d=setup();recipient=@{@"pid":@(getpid()),@"wid":@298};check(!down(d),"another own panel is not this canvas");
    d=setup();scopeOK=NO;check(!down(d),"out-of-scope source is not captured");
    d=setup();d.sources[@49].router.processBirth=@[@999,@0];check(!down(d),"reused PID cannot nominate a canvas-border source");
    d=setup();screenRect.origin.x+=5;down(d);check(!d.views[0].begins,"displayed rectangle must match the placement");
    d=setup();e=packet(kCGEventLeftMouseDown);CGEventSetFlags(e,kCGEventFlagMaskAlternate);
    check(![d earlyNativeTitle:kCGEventLeftMouseDown event:e],"modified canvas binding is not turned into an unmodified border resize");CFRelease(e);
    d=setup();d.views[0].border=nil;check(!down(d),"canvas content is not a border");
    d=setup();frameOK=NO;down(d);check(!d.views[0].begins,"unreadable native frame cannot start resize");
    d=setup();d.nativeViews.replica=YES;down(d);check(!d.views[0].begins,"replica cannot resize a native owner");
    d=setup();d.resize.busy=@49;down(d);check(!d.views[0].begins,"busy resize cannot restart");
    d=setup();changedRecipient=@{@"pid":@87,@"wid":@400};down(d);check(!d.views[0].begins,"recipient changed during admission");
    d=setup();changeGeneration=YES;down(d);check(!d.views[0].begins,"generation changed during admission");
    d=setup();d.nativeViews.owner=@2;down(d);check(!d.views[0].begins,"wrong output owner");
    d=setup();recipient=identity;d.views[0].border=nil;isTitle=YES;check(down(d)&&d.drags==1,"recognized caption begins canvas drag");
    fprintf(stderr,"%d checks, %d failures\n",checks,failures);return failures?1:0;
}}
