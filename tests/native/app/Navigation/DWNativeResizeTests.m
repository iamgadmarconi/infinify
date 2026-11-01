// SPDX-License-Identifier: GPL-3.0-or-later
// Executes the adapter with AX and WindowServer substitutes. No native window,
// AX message, permission request or input event is created by this regression.
#import <AppKit/AppKit.h>
#include <dlfcn.h>
#include <unistd.h>
#include <time.h>
#import "DWNativeResize.h"

static CGRect nativeFrame;
static NSMutableArray<NSString *> *writes;
static BOOL ignorePosition,positionSettable,sizeSettable,resizeOnPosition,staleAfterSize,disagreeAfterSize,stale,disagree;
static BOOL offsetCGAfterPosition;
static CGFloat cgWidthOffset;
static BOOL positionExhaustsDeadline;
static int sizeTimeouts,positionTimeouts,positionReadTimeouts,sizeReadTimeouts,positionReads,sizeReads;
static BOOL staleAfterReadTimeout,readTimeoutAfterSize;
static AXError positionReadError;
static id menuRoot;
static BOOL frontmost,focusChangesAfterMenu,fillStale,fillDisagree,fillTransientDisagree,fillUnchanged,fillAnimating,fillDrifting,menuTimeout;
static uint32_t focusedWindow;
static AXError fillError;
static AXError fillReadError;
static CGRect fillFrame;
static double pressedAt,animationDelay;
static NSString *pressedIdentifier;
static double monotonicSeconds,messageTimeout;
static double sizeReturnedAt,postSizeReadSeconds,sizeSettlesAfter,lastSizeObservationStarted;
static BOOL clampSize,animateSize;
static CGFloat clampHeight;
static int transientDisagree;
static CGSize requestedSize;
static int monotonicClock(clockid_t clock,struct timespec *t) {(void)clock;*t=(struct timespec){(time_t)monotonicSeconds,(long)((monotonicSeconds-floor(monotonicSeconds))*1e9)};return 0;}
static int sleepMicros(useconds_t duration) {monotonicSeconds+=duration/1e6;return 0;}
@interface FrameScreen : NSObject
+ (NSArray *)screens;
@property(readonly) NSRect frame,visibleFrame;
@property(readonly) NSEdgeInsets safeAreaInsets;
@end
@implementation FrameScreen
+ (NSArray *)screens {return @[[self new]];}
- (NSRect)frame {return NSMakeRect(0,0,1000,800);}
- (NSRect)visibleFrame {return NSMakeRect(0,0,1000,770);}
- (NSEdgeInsets)safeAreaInsets {return NSEdgeInsetsMake(0,0,0,0);}
@end
static AXUIElementRef fakeApp;
static NSArray *axWindows;
static CFArrayRef windowInfo(CGWindowListOption options,CGWindowID wid) {
    (void)options;
    CGRect cg=nativeFrame;cg.size.width+=cgWidthOffset;double sincePress=monotonicSeconds-pressedAt;
    if(transientDisagree>0&&sizeReturnedAt){transientDisagree--;cg.origin.x+=10;}
    if(disagree||(fillTransientDisagree&&pressedAt&&sincePress>=.09&&sincePress<.21))cg.origin.x+=10;
    NSDictionary *row=@{(id)kCGWindowNumber:@(wid),(id)kCGWindowOwnerPID:@(stale?0:getpid()),
        (id)kCGWindowBounds:CFBridgingRelease(CGRectCreateDictionaryRepresentation(cg))};
    return CFRetain((__bridge CFArrayRef)@[row]);
}
static AXUIElementRef application(pid_t pid) {
    (void)pid;fakeApp=(AXUIElementRef)CFRetain((__bridge CFTypeRef)@{@"app":@YES});return fakeApp;
}
static AXError messaging(AXUIElementRef element,float seconds) {(void)element;messageTimeout=seconds;return kAXErrorSuccess;}
static AXError getPid(AXUIElementRef element,pid_t *pid) {NSDictionary *w=(__bridge NSDictionary *)element;*pid=w[@"pid"]?[w[@"pid"]intValue]:getpid();return [w[@"pid_error"]intValue];}
static AXError getWid(AXUIElementRef element,uint32_t *wid) {NSDictionary *w=(__bridge NSDictionary *)element;*wid=w[@"wid"]?[w[@"wid"]unsignedIntValue]:42;return [w[@"window_error"]intValue];}
static void *symbol(void *handle,const char *name) {(void)handle;return strcmp(name,"_AXUIElementGetWindow")==0?(void *)getWid:NULL;}
static AXError copy(AXUIElementRef element,CFStringRef attribute,CFTypeRef *out) {
    if(CFEqual(attribute,kAXWindowsAttribute))*out=CFRetain((__bridge CFArrayRef)(axWindows?:@[@{@"window":@YES}]));
    else if(CFEqual(attribute,kAXFrontmostAttribute))*out=CFRetain(frontmost?kCFBooleanTrue:kCFBooleanFalse);
    else if(CFEqual(attribute,kAXFocusedWindowAttribute))*out=CFRetain((__bridge CFTypeRef)@{@"wid":@(focusedWindow)});
    else if(CFEqual(attribute,kAXMenuBarAttribute)){if(menuTimeout){monotonicSeconds+=3;return kAXErrorCannotComplete;}if(!menuRoot)return kAXErrorNoValue;*out=CFRetain((__bridge CFTypeRef)menuRoot);}
    else if(CFEqual(attribute,kAXIdentifierAttribute)||CFEqual(attribute,kAXChildrenAttribute)||CFEqual(attribute,kAXEnabledAttribute)){
        NSDictionary *e=(__bridge NSDictionary *)element;id value=e[(__bridge NSString *)attribute];if(!value)return kAXErrorNoValue;*out=CFRetain((__bridge CFTypeRef)value);
    }
    else if(CFEqual(attribute,kAXRoleAttribute)){NSDictionary *w=(__bridge NSDictionary *)element;if(w[@"role_error"])return [w[@"role_error"]intValue];if(!w[@"role"])return kAXErrorNoValue;*out=CFRetain((__bridge CFTypeRef)w[@"role"]);}
    else if(CFEqual(attribute,kAXPositionAttribute)) {
        if(sizeReturnedAt){lastSizeObservationStarted=monotonicSeconds;monotonicSeconds+=postSizeReadSeconds;
            if(sizeSettlesAfter>0&&monotonicSeconds-sizeReturnedAt>=sizeSettlesAfter)nativeFrame.size=requestedSize;}
        if(animateSize&&sizeReturnedAt&&nativeFrame.size.width<requestedSize.width)nativeFrame.size.width=fmin(requestedSize.width,nativeFrame.size.width+5);
        if(fillAnimating&&pressedAt&&monotonicSeconds-pressedAt>=animationDelay)nativeFrame=fillFrame;
        if(fillDrifting&&pressedAt)nativeFrame.origin.x+=.8;
        positionReads++;
        if(positionReadTimeouts>0){positionReadTimeouts--;monotonicSeconds+=messageTimeout;stale|=staleAfterReadTimeout;return kAXErrorCannotComplete;}
        if(positionReadError!=kAXErrorSuccess)return positionReadError;
        *out=AXValueCreate(kAXValueCGPointType,&nativeFrame.origin);
    } else if(CFEqual(attribute,kAXSizeAttribute)) {
        if(sizeReturnedAt)monotonicSeconds+=postSizeReadSeconds;
        sizeReads++;
        if(sizeReadTimeouts>0){sizeReadTimeouts--;monotonicSeconds+=messageTimeout;stale|=staleAfterReadTimeout;return kAXErrorCannotComplete;}
        *out=AXValueCreate(kAXValueCGSizeType,&nativeFrame.size);
    }
    else return kAXErrorAttributeUnsupported;
    return kAXErrorSuccess;
}
static AXError attributeSettable(AXUIElementRef element,CFStringRef attribute,Boolean *out) {
    (void)element;*out=CFEqual(attribute,kAXPositionAttribute)?positionSettable:sizeSettable;return kAXErrorSuccess;
}
static AXError set(AXUIElementRef element,CFStringRef attribute,CFTypeRef value) {
    (void)element;
    if(CFEqual(attribute,kAXPositionAttribute)) {
        [writes addObject:@"position"];if(!ignorePosition)AXValueGetValue((AXValueRef)value,kAXValueCGPointType,&nativeFrame.origin);
        if(resizeOnPosition)nativeFrame.size.width-=20;
        if(offsetCGAfterPosition)cgWidthOffset=.5;
        if(positionExhaustsDeadline){monotonicSeconds+=3;return kAXErrorCannotComplete;}
        if(positionTimeouts>0){positionTimeouts--;return kAXErrorCannotComplete;}
    } else if(CFEqual(attribute,kAXSizeAttribute)) {
        [writes addObject:@"size"];AXValueGetValue((AXValueRef)value,kAXValueCGSizeType,&nativeFrame.size);cgWidthOffset=0;
        requestedSize=nativeFrame.size;sizeReturnedAt=monotonicSeconds;if(clampSize)nativeFrame.size.width-=20;
        if(clampHeight>0&&nativeFrame.size.height>clampHeight)nativeFrame.size.height=clampHeight;
        stale|=staleAfterSize;disagree|=disagreeAfterSize;
        if(readTimeoutAfterSize){positionReadTimeouts=1;readTimeoutAfterSize=NO;}
        if(sizeTimeouts>0){sizeTimeouts--;return kAXErrorCannotComplete;}
    } else return kAXErrorAttributeUnsupported;
    return kAXErrorSuccess;
}
static Boolean trusted(void) {return true;}
static AXError actionNames(AXUIElementRef element,CFArrayRef *out){NSDictionary *e=(__bridge NSDictionary *)element;*out=CFRetain((__bridge CFArrayRef)(e[@"actions"]?:@[(id)kAXPressAction]));if(focusChangesAfterMenu)focusedWindow=99;return kAXErrorSuccess;}
static AXError press(AXUIElementRef element,CFStringRef action){if(!CFEqual(action,kAXPressAction))return kAXErrorActionUnsupported;pressedIdentifier=((__bridge NSDictionary *)element)[@"AXIdentifier"];[writes addObject:@"press"];pressedAt=monotonicSeconds;if(!fillUnchanged)nativeFrame=fillAnimating?CGRectMake(0,30,600,500):fillFrame;stale|=fillStale;disagree|=fillDisagree;positionReadError=fillReadError;return fillError;}
static NSDictionary *menuTree(NSArray *items){return @{@"role":(id)kAXMenuBarRole,@"AXChildren":@[@{@"role":(id)kAXMenuBarItemRole,@"AXChildren":@[@{@"role":(id)kAXMenuRole,@"AXChildren":items}]}]};}
static NSDictionary *nestedMenuTree(NSArray *items){return menuTree(@[@{@"role":(id)kAXMenuItemRole,@"AXChildren":@[@{@"role":(id)kAXMenuRole,@"AXChildren":items}]}]);}
#define CGWindowListCopyWindowInfo windowInfo
#define AXUIElementCreateApplication application
#define AXUIElementSetMessagingTimeout messaging
#define AXUIElementGetPid getPid
#define AXUIElementGetTypeID CFDictionaryGetTypeID
#define AXUIElementCopyAttributeValue copy
#define AXUIElementIsAttributeSettable attributeSettable
#define AXUIElementSetAttributeValue set
#define AXUIElementCopyActionNames actionNames
#define AXUIElementPerformAction press
#define AXIsProcessTrusted trusted
#define dlsym symbol
#define clock_gettime monotonicClock
#define usleep sleepMicros
#define NSScreen FrameScreen
#import "DWNativeResize.m"
#import "DWNativeResizeDriver.m"

static void check(BOOL condition,NSString *why) {if(!condition){fprintf(stderr,"FAIL: %s\n",why.UTF8String);exit(1);}}
// The helper's move (dw_resize_set_mover): it moves the native frame itself, as the Dock helper does, or declines, or answers too late.
static DWResizeMoveOutcome helperAnswer;static BOOL helperMoves;static CGPoint helperAskedTo;static int helperCalls;
static DWResizeMoveOutcome helperMove(DWResizeIdentity identity,CGPoint origin) {
    (void)identity;helperCalls++;helperAskedTo=origin;[writes addObject:@"helper"];if(helperMoves)nativeFrame.origin=origin;return helperAnswer;
}
static DWResizeIdentity reset(CGRect frame) {
    nativeFrame=frame;writes=[NSMutableArray array];positionSettable=sizeSettable=YES;axWindows=nil;
    ignorePosition=resizeOnPosition=staleAfterSize=disagreeAfterSize=stale=disagree=NO;
    offsetCGAfterPosition=NO;cgWidthOffset=0;
    positionExhaustsDeadline=staleAfterReadTimeout=readTimeoutAfterSize=NO;sizeTimeouts=positionTimeouts=positionReadTimeouts=sizeReadTimeouts=positionReads=sizeReads=0;
    positionReadError=kAXErrorSuccess;monotonicSeconds=100;messageTimeout=.15;
    sizeReturnedAt=postSizeReadSeconds=sizeSettlesAfter=lastSizeObservationStarted=0;clampSize=animateSize=NO;clampHeight=0;transientDisagree=0;requestedSize=CGSizeZero;
    frontmost=YES;focusedWindow=42;focusChangesAfterMenu=fillStale=fillDisagree=fillTransientDisagree=fillUnchanged=fillAnimating=fillDrifting=menuTimeout=NO;fillError=fillReadError=kAXErrorSuccess;pressedAt=0;animationDelay=.18;pressedIdentifier=nil;fillFrame=CGRectMake(0,30,960,740);
    menuRoot=menuTree(@[@{@"role":(id)kAXMenuItemRole,@"AXIdentifier":@"_zoomFill:",@"AXEnabled":@YES}]);
    DWResizeIdentity identity={.pid=getpid(),.window=42};
    check(birth(identity.pid,&identity.birth_seconds,&identity.birth_microseconds)&&owner(identity,NULL),@"mock identity is owned");return identity;
}
int main(void) {@autoreleasepool {
    CGRect original=CGRectMake(183.5,211.25,400.5,300.25);
    DWResizeIdentity identity=reset(CGRectMake(0,30,960,740));
    DWResizeResult restored=dw_resize_apply_frame(identity,original);
    check(restored.outcome==DWResizeApplied&&restored.observed&&restored.mutation_attempted&&CGRectEqualToRect(restored.actual_ax,original),@"full fractional frame restored");
    check([writes isEqual:@[@"size",@"position"]],@"exact AX and CG extent after positioning needs no second size write");
    // A size the app took that is not the one asked (a minimum, a maximum, an increment) is accepted when a second agreed read, 8ms
    // later, shows it unchanged: 2 reads after the setter and about 30ms here, not the five reads over 120ms that used to be spent.
    identity=reset(original);clampSize=YES;postSizeReadSeconds=.01;restored=dw_resize_apply(identity,CGSizeMake(600,400));
    check(restored.outcome==DWResizeClamped&&restored.observed&&CGSizeEqualToSize(restored.actual_ax.size,CGSizeMake(580,400))&&sizeReads==3&&monotonicSeconds-sizeReturnedAt<.06&&[writes isEqual:@[@"size"]],@"a non-exact size that holds still is accepted on its second agreed read, not after 120ms");
    identity=reset(original);postSizeReadSeconds=.01;restored=dw_resize_apply(identity,CGSizeMake(600,400));
    check(restored.outcome==DWResizeApplied&&sizeReads==2&&monotonicSeconds-sizeReturnedAt<.021&&[writes isEqual:@[@"size"]],@"an exact first read finishes without a settling delay or repeated setter");
    identity=reset(original);clampSize=YES;postSizeReadSeconds=.025;restored=dw_resize_apply(identity,CGSizeMake(600,400));
    check(restored.outcome==DWResizeClamped&&sizeReads==3&&monotonicSeconds-sizeReturnedAt<.12&&[writes isEqual:@[@"size"]],@"slow observations are not followed by sleeps past the 120ms they may take");
    // The screen's visible frame (1000x770 here) is AppKit's own limit: a size that reaches past it and comes back short is final on
    // the first agreed read. The request starts at the frame's origin after the room move, so it is asked as it is.
    identity=reset(original);clampSize=YES;postSizeReadSeconds=.01;restored=dw_resize_apply(identity,CGSizeMake(1200,400));
    check(restored.outcome==DWResizeClamped&&restored.observed&&CGSizeEqualToSize(restored.actual_ax.size,CGSizeMake(1180,400))&&sizeReads==3&&monotonicSeconds-sizeReturnedAt<.021&&[writes isEqual:@[@"position",@"size"]],@"a size past the screen that comes back short is accepted on the first read with no settling poll");
    identity=reset(CGRectMake(0,30,586,488));clampHeight=740;postSizeReadSeconds=.01;restored=dw_resize_apply(identity,CGSizeMake(586,1500));
    check(restored.outcome==DWResizeClamped&&restored.observed&&CGSizeEqualToSize(restored.actual_ax.size,CGSizeMake(586,740))&&sizeReads==2&&monotonicSeconds-sizeReturnedAt<.021&&[writes isEqual:@[@"size"]],@"a height past the screen, from the frame's own top, is accepted on the first read as a width is");
    // Room is made once and as large as the screen has: the frame's origin on each axis the request overflows, not the least move.
    identity=reset(original);postSizeReadSeconds=.001;restored=dw_resize_apply(identity,CGSizeMake(900,600));
    check(restored.outcome==DWResizeApplied&&restored.moved&&CGPointEqualToPoint(restored.actual_ax.origin,CGPointMake(0,30))&&[writes isEqual:@[@"position",@"size"]],@"a size that overflows is given the frame's origin on that axis in one move");
    // Under native presentation the room move is the helper's, which keeps the window drawn where it is; Accessibility is not asked.
    dw_resize_set_mover(helperMove);
    identity=reset(original);postSizeReadSeconds=.001;helperCalls=0;helperMoves=YES;helperAnswer=DWResizeMoveMoved;restored=dw_resize_apply(identity,CGSizeMake(900,600));
    check(restored.outcome==DWResizeApplied&&restored.moved&&CGPointEqualToPoint(restored.actual_ax.origin,CGPointMake(0,30))&&helperCalls==1&&CGPointEqualToPoint(helperAskedTo,CGPointMake(0,30))&&[writes isEqual:@[@"helper",@"size"]],@"the helper makes the room move and Accessibility sizes the window from there");
    // A helper that does not hold the window declines: Accessibility moves it, as before.
    identity=reset(original);postSizeReadSeconds=.001;helperCalls=0;helperMoves=NO;helperAnswer=DWResizeMoveDeclined;restored=dw_resize_apply(identity,CGSizeMake(900,600));
    check(restored.outcome==DWResizeApplied&&restored.moved&&helperCalls==1&&[writes isEqual:@[@"helper",@"position",@"size"]],@"a declined helper move falls back to the Accessibility position write");
    // No answer in time: the move may have been made, so no second setter is sent; the size is asked from wherever the window is read.
    identity=reset(original);postSizeReadSeconds=.001;helperCalls=0;helperMoves=NO;helperAnswer=DWResizeMoveUncertain;restored=dw_resize_apply(identity,CGSizeMake(900,600));
    check(restored.observed&&!restored.moved&&helperCalls==1&&[writes isEqual:@[@"helper",@"size"]],@"an uncertain helper move is never followed by an Accessibility position write");
    // No room needed, no move asked of anyone.
    identity=reset(original);postSizeReadSeconds=.001;helperCalls=0;helperMoves=YES;helperAnswer=DWResizeMoveMoved;restored=dw_resize_apply(identity,CGSizeMake(600,400));
    check(restored.outcome==DWResizeApplied&&!helperCalls&&[writes isEqual:@[@"size"]],@"a size that fits asks the helper for nothing");
    dw_resize_set_mover(NULL);
    identity=reset(CGRectMake(0,30,586,488));postSizeReadSeconds=.001;restored=dw_resize_apply(identity,CGSizeMake(600,700));
    check(restored.outcome==DWResizeApplied&&!restored.moved&&[writes isEqual:@[@"size"]],@"a window already at the frame's origin needs no second move for a larger size");
    // A frame still moving (an app's own animation) is followed until two reads agree.
    identity=reset(original);clampSize=YES;animateSize=YES;postSizeReadSeconds=.01;restored=dw_resize_apply(identity,CGSizeMake(600,400));
    check(restored.outcome==DWResizeApplied&&restored.observed&&CGSizeEqualToSize(restored.actual_ax.size,CGSizeMake(600,400))&&sizeReads>=5&&[writes isEqual:@[@"size"]],@"a size still changing between reads is followed to the size asked");
    // The window list shows the new frame a few ms after AX: the disagreeing read is retried in 2ms, not 30.
    identity=reset(original);postSizeReadSeconds=.001;transientDisagree=2;restored=dw_resize_apply(identity,CGSizeMake(600,400));
    check(restored.outcome==DWResizeApplied&&restored.observed&&monotonicSeconds-sizeReturnedAt<.012&&[writes isEqual:@[@"size"]],@"AX and the window list disagreeing for one read costs one 2ms retry, not a 30ms grid step");
    identity=reset(CGRectMake(0,30,960,740));resizeOnPosition=YES;restored=dw_resize_apply_frame(identity,original);
    check(restored.outcome==DWResizeApplied&&CGRectEqualToRect(restored.actual_ax,original)&&CGRectEqualToRect(restored.actual_cg,original)&&[writes isEqual:@[@"size",@"position",@"size"]],@"position-induced extent change retains size-position-size ordering");
    identity=reset(CGRectMake(0,30,960,740));offsetCGAfterPosition=YES;restored=dw_resize_apply_frame(identity,original);
    check(restored.outcome==DWResizeApplied&&CGRectEqualToRect(restored.actual_ax,original)&&CGRectEqualToRect(restored.actual_cg,original)&&[writes isEqual:@[@"size",@"position",@"size"]],@"near but non-exact CG extent cannot skip the corrective size write");
    identity=reset((CGRect){CGPointMake(0,30),original.size});restored=dw_resize_apply_frame(identity,original);
    check(restored.outcome==DWResizeApplied&&restored.moved&&CGRectEqualToRect(restored.actual_cg,original),@"origin restored when size was already correct");
    identity=reset((CGRect){CGPointMake(0,30),original.size});sizeSettable=NO;restored=dw_resize_apply_frame(identity,original);
    check(restored.outcome==DWResizeApplied&&restored.observed&&restored.mutation_attempted&&CGRectEqualToRect(restored.actual_ax,original)&&[writes isEqual:@[@"position"]],@"origin-only restore does not require a size setter");
    identity=reset((CGRect){CGPointMake(0,30),original.size});resizeOnPosition=YES;restored=dw_resize_apply_frame(identity,original);
    check(restored.outcome==DWResizeApplied&&CGRectEqualToRect(restored.actual_ax,original)&&[writes isEqual:@[@"position",@"size"]],@"position-induced size change is restored through readback");
    identity=reset(CGRectMake(0,30,960,740));sizeSettable=NO;restored=dw_resize_apply_frame(identity,original);
    check(restored.outcome==DWResizeUnsupported&&!restored.mutation_attempted&&writes.count==0,@"a non-resizable mismatched frame is not partially moved");
    identity=reset(CGRectMake(0,30,960,740));ignorePosition=YES;restored=dw_resize_apply_frame(identity,original);
    check(restored.observed&&restored.outcome==DWResizeClamped&&restored.actual_ax.origin.y==30,@"ignored position setter is never applied");
    identity=reset(CGRectMake(0,30,960,740));positionSettable=NO;restored=dw_resize_apply_frame(identity,original);
    check(restored.outcome==DWResizeUnsupported&&!restored.mutation_attempted&&writes.count==0,@"unsupported position fails before any setter");
    identity=reset(CGRectMake(0,30,960,740));staleAfterSize=YES;restored=dw_resize_apply_frame(identity,original);
    check(restored.outcome==DWResizeStaleIdentity&&!restored.observed&&restored.mutation_attempted&&[writes isEqual:@[@"size"]],@"replacement owner receives no position setter");
    identity=reset(CGRectMake(0,30,960,740));disagreeAfterSize=YES;restored=dw_resize_apply_frame(identity,original);
    check(restored.outcome==DWResizeReadbackFailed&&!restored.observed&&restored.mutation_attempted&&[writes isEqual:@[@"size"]],@"AX-CG disagreement blocks position write");
    identity=reset(CGRectMake(0,30,960,740));positionExhaustsDeadline=YES;restored=dw_resize_apply_frame(identity,original);
    check(restored.outcome==DWResizeTimedOut&&!restored.observed&&restored.mutation_attempted&&restored.ax_error==kAXErrorCannotComplete,@"a position deadline is an unresolved timeout, never an unobserved applied result");
    identity=reset((CGRect){CGPointMake(0,30),original.size});positionExhaustsDeadline=YES;restored=dw_resize_apply_frame(identity,original);
    check(restored.outcome==DWResizeTimedOut&&!restored.observed&&restored.mutation_attempted,@"an origin-only deadline is an unresolved timeout, never invalid request");
    identity=reset(CGRectMake(0,30,960,740));sizeTimeouts=1;restored=dw_resize_apply_frame(identity,original);
    check(restored.outcome==DWResizeApplied&&restored.observed&&restored.mutation_attempted&&restored.ax_error==kAXErrorCannotComplete,@"an initial size timeout survives later successful frame stages");
    identity=reset(CGRectMake(900,690,100,100));positionExhaustsDeadline=YES;restored=dw_resize_apply_frame(identity,original);
    check(restored.outcome==DWResizeTimedOut&&!restored.observed&&restored.mutation_attempted&&[writes isEqual:@[@"position"]],@"preparatory movement is counted even when no size setter can run");
    identity=reset(CGRectMake(0,30,960,740));
    NSDictionary *who=@{@"pid":@(identity.pid),@"birth_sec":@(identity.birth_seconds),@"birth_usec":@(identity.birth_microseconds),@"wid":@(identity.window)};
    NSDictionary *effect=@{@"identity":who,@"requested":@{@"width":@(original.size.width),@"height":@(original.size.height)},@"native_origin":@{@"x":@(original.origin.x),@"y":@(original.origin.y)}};
    DWNativeResizeDriver *driver=[DWNativeResizeDriver new];NSDictionary *receipt=[driver perform:effect];
    check([receipt[@"outcome"]isEqual:@"applied"]&&[receipt[@"actual_ax"][@"origin"][@"y"]doubleValue]==original.origin.y&&[writes isEqual:@[@"size",@"position"]],@"shell effect dispatches the frame adapter without a redundant final size write");
    [writes removeAllObjects];NSMutableDictionary *invalid=[effect mutableCopy];invalid[@"native_origin"]=@{@"x":@0};receipt=[driver perform:invalid];
    check([receipt[@"outcome"]isEqual:@"invalid_request"]&&writes.count==0,@"malformed frame effect cannot fall back to a size setter");
    identity=reset(original);positionReadTimeouts=1;restored=dw_resize_observe(identity);
    check(restored.outcome==DWResizeObserved&&restored.observed&&positionReads==2&&writes.count==0,@"a transient position query timeout is retried without mutation");
    identity=reset(CGRectMake(0,30,960,740));sizeReadTimeouts=1;restored=dw_resize_apply_frame(identity,original);
    check(restored.outcome==DWResizeApplied&&restored.observed&&CGRectEqualToRect(restored.actual_ax,original)&&[writes isEqual:@[@"size",@"position"]],@"a transient size query timeout does not abandon frame restoration or repeat setters");
    identity=reset(original);positionReadTimeouts=100;restored=dw_resize_observe(identity);
    check(restored.outcome==DWResizeTimedOut&&!restored.observed&&!restored.mutation_attempted&&writes.count==0&&monotonicSeconds<102.00001&&positionReads<14,@"persistent query timeouts exhaust only the shared deadline without mutation");
    identity=reset(original);positionReadTimeouts=1;staleAfterReadTimeout=YES;restored=dw_resize_observe(identity);
    check(restored.outcome==DWResizeStaleIdentity&&!restored.observed&&positionReads==1&&writes.count==0,@"a query timeout never retries against a replacement owner");
    identity=reset(original);positionReadError=kAXErrorAttributeUnsupported;restored=dw_resize_observe(identity);
    check(restored.outcome==DWResizeReadbackFailed&&!restored.observed&&positionReads==1&&writes.count==0,@"a permanent query failure is not retried");
    identity=reset(CGRectMake(0,30,960,740));sizeTimeouts=1;readTimeoutAfterSize=YES;restored=dw_resize_apply_frame(identity,original);
    check(restored.outcome==DWResizeApplied&&restored.observed&&restored.mutation_attempted&&restored.ax_error==kAXErrorCannotComplete&&CGRectEqualToRect(restored.actual_ax,original)&&[writes isEqual:@[@"size",@"position"]],@"post-setter query recovery preserves the original setter timeout without replaying writes");
    NSDictionary *target=@{@"wid":@42},*desktop=@{@"window_error":@(kAXErrorIllegalArgument),@"role":(id)kAXScrollAreaRole};
    for(NSArray *candidates in @[@[desktop,target],@[target,desktop]]){
        identity=reset(original);axWindows=candidates;restored=dw_resize_observe(identity);
        check(restored.outcome==DWResizeObserved&&restored.observed&&restored.ax_error==kAXErrorSuccess&&writes.count==0,@"Finder desktop scroll area cannot hide an exact ordinary window before or after it");
    }
    identity=reset(original);axWindows=@[target,desktop,target];restored=dw_resize_observe(identity);
    check(restored.outcome==DWResizeAmbiguousWindow&&!restored.observed&&writes.count==0,@"skipping Finder desktop still detects duplicate exact window matches");
    NSArray *unverifiable=@[
        @{@"window_error":@(kAXErrorIllegalArgument),@"role":(id)kAXWindowRole},
        @{@"window_error":@(kAXErrorIllegalArgument),@"role":(id)kAXScrollAreaRole,@"pid":@(getpid()+1)},
        @{@"window_error":@(kAXErrorIllegalArgument),@"role":(id)kAXScrollAreaRole,@"pid_error":@(kAXErrorCannotComplete)},
        @{@"window_error":@(kAXErrorIllegalArgument),@"role_error":@(kAXErrorCannotComplete)},
        @{@"window_error":@(kAXErrorCannotComplete),@"role":(id)kAXScrollAreaRole}];
    for(NSDictionary *candidate in unverifiable){
        identity=reset(original);axWindows=@[target,candidate];restored=dw_resize_observe(identity);
        check(restored.outcome==DWResizeUnavailable&&!restored.observed&&restored.ax_error==[candidate[@"window_error"]intValue]&&writes.count==0,@"a true window, foreign/unknown PID, unknown role or transient lookup failure remains a refusal");
    }
    identity=reset(original);restored=dw_resize_fill(identity,CGSizeMake(960,740));
    check(restored.outcome==DWResizeApplied&&restored.observed&&restored.moved&&restored.mutation_attempted&&CGRectEqualToRect(restored.actual_ax,fillFrame)&&[writes isEqual:@[@"press"]]&&monotonicSeconds>=100.25,@"Fill uses exactly one menu action and stable independent frame readback, never size/position setters");
    identity=reset(original);restored=dw_resize_fill(identity,CGSizeMake(1000,770));
    check(restored.outcome==DWResizeClamped&&CGSizeEqualToSize(restored.requested,CGSizeMake(1000,770))&&CGRectEqualToRect(restored.actual_cg,fillFrame)&&[writes isEqual:@[@"press"]],@"Fill preserves the effect request and reports the app's chosen extent");
    identity=reset(original);frontmost=NO;restored=dw_resize_fill(identity,fillFrame.size);
    check(restored.outcome==DWResizeUnavailable&&!restored.observed&&!restored.mutation_attempted&&writes.count==0,@"Fill cannot silently activate or resize a background app");
    identity=reset(original);focusedWindow=99;restored=dw_resize_fill(identity,fillFrame.size);
    check(restored.outcome==DWResizeUnavailable&&!restored.observed&&!restored.mutation_attempted&&writes.count==0,@"Fill requires the exact focused window in the frontmost app");
    identity=reset(original);focusChangesAfterMenu=YES;restored=dw_resize_fill(identity,fillFrame.size);
    check(restored.outcome==DWResizeUnavailable&&!restored.observed&&!restored.mutation_attempted&&writes.count==0,@"focus is checked again after menu discovery and before pressing");
    identity=reset(original);menuRoot=menuTree(@[@{@"role":(id)kAXMenuItemRole,@"AXIdentifier":@"_zoomFill:",@"AXEnabled":@NO}]);restored=dw_resize_fill(identity,fillFrame.size);
    check(restored.outcome==DWResizeUnsupported&&!restored.mutation_attempted&&writes.count==0,@"disabled Fill is an explicit pre-action unsupported result");
    identity=reset(original);id item=@{@"role":(id)kAXMenuItemRole,@"AXIdentifier":@"_zoomFill:",@"AXEnabled":@YES};menuRoot=menuTree(@[item,item]);restored=dw_resize_fill(identity,fillFrame.size);
    check(restored.outcome==DWResizeUnavailable&&!restored.observed&&!restored.mutation_attempted&&writes.count==0,@"duplicate Fill identifiers never select an arbitrary action");
    identity=reset(original);menuRoot=menuTree(@[]);restored=dw_resize_fill(identity,fillFrame.size);
    check(restored.outcome==DWResizeUnsupported&&!restored.mutation_attempted&&writes.count==0,@"missing Fill can be handled before a native mutation");
    identity=reset(original);menuTimeout=YES;restored=dw_resize_fill(identity,fillFrame.size);
    check(restored.outcome==DWResizeTimedOut&&!restored.observed&&!restored.mutation_attempted&&writes.count==0,@"menu discovery timeout is unresolved and carries no stale baseline observation");
    identity=reset(original);menuRoot=menuTree(@[@{@"role":(id)kAXMenuItemRole,@"AXChildren":@[@{@"role_error":@(kAXErrorCannotComplete)}]},item]);restored=dw_resize_fill(identity,fillFrame.size);
    check(restored.outcome==DWResizeApplied&&restored.observed&&[writes isEqual:@[@"press"]],@"unrelated deeper menus are never traversed to resolve the direct Fill action");
    identity=reset(original);fillError=kAXErrorCannotComplete;restored=dw_resize_fill(identity,fillFrame.size);
    check(restored.outcome==DWResizeApplied&&restored.observed&&restored.mutation_attempted&&restored.ax_error==kAXErrorCannotComplete&&[writes isEqual:@[@"press"]],@"a timed-out Fill is observed but never replayed or followed with a setter");
    identity=reset(original);fillStale=YES;restored=dw_resize_fill(identity,fillFrame.size);
    check(restored.outcome==DWResizeStaleIdentity&&!restored.observed&&restored.mutation_attempted&&[writes isEqual:@[@"press"]],@"loss of ownership after Fill retains the uncertain action attempt");
    identity=reset(original);fillTransientDisagree=YES;restored=dw_resize_fill(identity,fillFrame.size);
    check(restored.outcome==DWResizeApplied&&restored.observed&&restored.mutation_attempted&&CGRectEqualToRect(restored.actual_ax,fillFrame)&&monotonicSeconds>=100.36&&monotonicSeconds<102&&[writes isEqual:@[@"press"]],@"Fill waits through transient animation AX/native disagreement and restarts its quiet interval without replay");
    identity=reset(original);fillDisagree=YES;restored=dw_resize_fill(identity,fillFrame.size);
    check(restored.outcome==DWResizeTimedOut&&!restored.observed&&restored.mutation_attempted&&monotonicSeconds<=102.00001&&[writes isEqual:@[@"press"]],@"persistent Fill AX/native disagreement cannot be accepted and exhausts only the original deadline");
    identity=reset(original);fillReadError=kAXErrorAttributeUnsupported;restored=dw_resize_fill(identity,fillFrame.size);
    check(restored.outcome==DWResizeReadbackFailed&&!restored.observed&&restored.mutation_attempted&&monotonicSeconds==100&&positionReads==3&&[writes isEqual:@[@"press"]],@"a permanent post-Fill AX read error still stops immediately without replay");
    identity=reset(original);fillUnchanged=YES;restored=dw_resize_fill(identity,fillFrame.size);
    check(restored.outcome==DWResizeRejected&&restored.observed&&restored.mutation_attempted&&[writes isEqual:@[@"press"]]&&monotonicSeconds<=102.00001,@"unchanged Fill remains rejected and cannot trigger a fallback setter");
    identity=reset(original);fillAnimating=YES;restored=dw_resize_fill(identity,fillFrame.size);
    check(restored.outcome==DWResizeApplied&&restored.observed&&CGRectEqualToRect(restored.actual_ax,fillFrame)&&monotonicSeconds>=100.33&&[writes isEqual:@[@"press"]],@"Fill waits through changing intermediate geometry for a stable frame");
    identity=reset(original);fillDrifting=YES;restored=dw_resize_fill(identity,fillFrame.size);
    check(restored.outcome==DWResizeTimedOut&&!restored.observed&&restored.mutation_attempted&&[writes isEqual:@[@"press"]],@"cumulative subpixel drift cannot be mistaken for a stable Fill frame");
    NSDictionary *unfillItem=@{@"role":(id)kAXMenuItemRole,@"AXIdentifier":@"_zoomUntile:",@"AXEnabled":@YES};
    identity=reset(CGRectMake(0,30,960,740));menuRoot=nestedMenuTree(@[unfillItem]);fillFrame=original;restored=dw_resize_unfill(identity,original);
    check(restored.outcome==DWResizeApplied&&restored.observed&&restored.mutation_attempted&&restored.moved&&CGRectEqualToRect(restored.actual_ax,original)&&[pressedIdentifier isEqual:@"_zoomUntile:"]&&[writes isEqual:@[@"press"]],@"native Restore selects the observed nested identifier once and verifies the full saved frame");
    identity=reset(CGRectMake(0,30,960,740));frontmost=NO;menuRoot=nestedMenuTree(@[unfillItem]);fillFrame=original;restored=dw_resize_unfill(identity,original);
    check(restored.outcome==DWResizeApplied&&restored.observed&&restored.mutation_attempted&&CGRectEqualToRect(restored.actual_ax,original)&&!frontmost&&[pressedIdentifier isEqual:@"_zoomUntile:"]&&[writes isEqual:@[@"press"]],@"native Restore can press the exact app-local focused window's action while its app remains background");
    identity=reset(CGRectMake(0,30,960,740));frontmost=NO;focusedWindow=99;menuRoot=nestedMenuTree(@[unfillItem]);fillFrame=original;restored=dw_resize_unfill(identity,original);
    check(restored.outcome==DWResizeUnavailable&&!restored.observed&&!restored.mutation_attempted&&writes.count==0,@"background Restore refuses a different app-local focused window");
    identity=reset(CGRectMake(0,30,960,740));frontmost=NO;focusChangesAfterMenu=YES;menuRoot=nestedMenuTree(@[unfillItem]);fillFrame=original;restored=dw_resize_unfill(identity,original);
    check(restored.outcome==DWResizeUnavailable&&!restored.observed&&!restored.mutation_attempted&&writes.count==0,@"background Restore rechecks exact app-local focus after menu discovery before pressing");
    identity=reset(CGRectMake(0,30,960,740));menuRoot=nestedMenuTree(@[unfillItem]);fillFrame=original;fillAnimating=YES;animationDelay=.6;restored=dw_resize_unfill(identity,original);
    check(restored.outcome==DWResizeApplied&&restored.observed&&CGRectEqualToRect(restored.actual_ax,original)&&monotonicSeconds>=102&&monotonicSeconds<=102.00001&&[writes isEqual:@[@"press"]],@"native Restore observes beyond an early quiet plateau before accepting the final frame, without repeating its action");
    identity=reset(CGRectMake(0,30,960,740));menuRoot=nestedMenuTree(@[unfillItem]);fillFrame=original;fillAnimating=YES;animationDelay=1.92;restored=dw_resize_unfill(identity,original);
    check(restored.outcome==DWResizeTimedOut&&!restored.observed&&restored.mutation_attempted&&monotonicSeconds<=102.00001&&[writes isEqual:@[@"press"]],@"native Restore cannot accept a late frame without a complete quiet interval before its existing deadline");
    identity=reset(CGRectMake(0,30,960,740));menuRoot=nestedMenuTree(@[unfillItem]);fillFrame=original;fillFrame.origin.x+=40;restored=dw_resize_unfill(identity,original);
    check(restored.outcome==DWResizeClamped&&restored.observed&&CGSizeEqualToSize(restored.requested,original.size)&&restored.actual_ax.origin.x==original.origin.x+40&&[writes isEqual:@[@"press"]],@"same restored extent at a different origin is not Applied and receives no hidden correction");
    identity=reset((CGRect){CGPointMake(0,30),original.size});menuRoot=nestedMenuTree(@[unfillItem]);fillFrame=original;restored=dw_resize_unfill(identity,original);
    check(restored.outcome==DWResizeApplied&&restored.observed&&restored.moved&&CGRectEqualToRect(restored.actual_ax,original)&&[writes isEqual:@[@"press"]],@"native Restore can settle an origin-only change");
    identity=reset(CGRectMake(0,30,960,740));menuRoot=menuTree(@[unfillItem]);restored=dw_resize_unfill(identity,original);
    check(restored.outcome==DWResizeUnsupported&&!restored.mutation_attempted&&writes.count==0,@"native Restore ignores an identifier outside its observed submenu depth");
    identity=reset(CGRectMake(0,30,960,740));menuRoot=nestedMenuTree(@[unfillItem,unfillItem]);restored=dw_resize_unfill(identity,original);
    check(restored.outcome==DWResizeUnavailable&&!restored.observed&&!restored.mutation_attempted&&writes.count==0,@"duplicate nested Restore actions cannot select an arbitrary target");
    identity=reset(CGRectMake(0,30,960,740));menuRoot=nestedMenuTree(@[unfillItem]);fillFrame=original;fillError=kAXErrorCannotComplete;restored=dw_resize_unfill(identity,original);
    check(restored.outcome==DWResizeApplied&&restored.observed&&restored.mutation_attempted&&restored.ax_error==kAXErrorCannotComplete&&[writes isEqual:@[@"press"]],@"timed-out native Restore preserves its single action attempt and error after stable readback");
    CGPoint displayedOrigin=CGPointMake(380,150);
    identity=reset(original);sizeSettable=NO;restored=dw_resize_reposition(identity,original,displayedOrigin,100.35);
    check(restored.outcome==DWResizeApplied&&restored.observed&&restored.mutation_attempted&&CGRectEqualToRect(restored.actual_cg,(CGRect){displayedOrigin,original.size})&&[writes isEqual:@[@"position"]]&&messageTimeout<=.050001,@"lease preparation writes only position and verifies the unchanged extent without requiring a size setter");
    identity=reset(original);CGRect changedBaseline=original;changedBaseline.origin.x+=.25;restored=dw_resize_reposition(identity,changedBaseline,displayedOrigin,100.35);
    check(restored.outcome==DWResizeUnavailable&&!restored.observed&&!restored.mutation_attempted&&writes.count==0,@"lease preparation refuses even a fractional change to its exact native baseline");
    identity=reset(original);restored=dw_resize_reposition(identity,original,displayedOrigin,100.04);
    check(restored.outcome==DWResizeTimedOut&&!restored.observed&&!restored.mutation_attempted&&writes.count==0,@"a lease lacking the complete setter timeout cannot permit a position write");
    identity=reset(original);positionReadTimeouts=1;restored=dw_resize_reposition(identity,original,displayedOrigin,100.35);
    check(restored.outcome==DWResizeApplied&&restored.observed&&monotonicSeconds>=100.05&&monotonicSeconds<100.35&&[writes isEqual:@[@"position"]],@"lease readback retries a transient query within its shared budget without repeating position");
    identity=reset(original);positionExhaustsDeadline=YES;restored=dw_resize_reposition(identity,original,displayedOrigin,100.35);
    check(restored.outcome==DWResizeTimedOut&&!restored.observed&&restored.mutation_attempted&&restored.ax_error==kAXErrorCannotComplete&&[writes isEqual:@[@"position"]],@"a late position timeout preserves the attempt and never replays or accepts a result beyond the lease");
    identity=reset(original);positionTimeouts=1;restored=dw_resize_reposition(identity,original,displayedOrigin,100.35);
    check(restored.outcome==DWResizeApplied&&restored.observed&&restored.mutation_attempted&&restored.ax_error==kAXErrorCannotComplete&&CGRectEqualToRect(restored.actual_cg,(CGRect){displayedOrigin,original.size})&&[writes isEqual:@[@"position"]],@"an exact observed position never erases the setter timeout needed by the lease owner's final gate");
    identity=reset(original);resizeOnPosition=YES;restored=dw_resize_reposition(identity,original,displayedOrigin,100.12);
    check(restored.outcome==DWResizeTimedOut&&!restored.observed&&restored.mutation_attempted&&monotonicSeconds<=100.12001&&[writes isEqual:@[@"position"]],@"lease preparation cannot accept an owner-induced extent change or outlive the caller's shorter budget");
    identity=reset(original);ignorePosition=YES;restored=dw_resize_reposition(identity,original,displayedOrigin,104);
    check(restored.outcome==DWResizeTimedOut&&!restored.observed&&restored.mutation_attempted&&monotonicSeconds<=100.35001&&[writes isEqual:@[@"position"]],@"a long caller lease cannot extend normalization beyond its 350ms budget");
    puts("PASS: fullscreen native frame adapter with substituted AX/CG; no native window or input created");return 0;
}}
