// SPDX-License-Identifier: GPL-3.0-or-later
// Desktop's shell-internal interface: class extensions, the category interfaces of Desktop+*.m,
// and the static helpers more than one Desktop/DesktopView file shares.
#import "Desktop.h"
#import <AppKit/AppKit.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <Carbon/Carbon.h>
#import "DWDebugTrace.h"
#import "DWExportFrame.h"
#import "DWOnboarding.h"
#import "DWSessionWatch.h"
#import "DWTypedValue.h"
#import "DesktopView.h"
#import "IFBackground.h"
#import "LiveSource.h"
#import "DWDesktopSupport.h"
// DriftWM's pointer policy (DWPointerHover.h): every panel's view hosts one. DWPolicyPress is a view's
// `gesture` while a press is the policy's: one in pick mode, or one bound to center-nearest.
static const NSInteger DWPolicyPress=9;
// A normal run is the desktop, as DriftWM is the session: one panel per display covering all of it, on every Space, with
// no strip, toolbar or status line. Only --manual opens a chooser.
@interface Desktop () <NSApplicationDelegate>
@property NSString *said; // the status note last written to stderr (-say:)
@property DWSessionWatch *session; // while the panels are open: wake, the session and the Space coming back (-returned)
@property BOOL sessionInactive;
@property BOOL sessionAwaitingCanvas; // preserve the loaded scene until an initially blocked launch opens its outputs
@property BOOL desktopUp; // the desktop's canvas is open, on however many displays there are: with none there it has no panel and is still open
@end
// Explicit ivars: Desktop+Config.m takes these two by address (&_hotkeyHandler, &_exitHotkey); an ivar that
// only auto-synthesis creates is invisible outside Desktop.m. The properties bind to them unchanged.
@interface Desktop () {
    EventHotKeyRef _exitHotkey;
    EventHandlerRef _hotkeyHandler;
}
// Implemented in Desktop.m, called from the categories.
- (NSString *)restingStatus;
- (NSDictionary *)call:(NSDictionary *)command raw:(NSData *__autoreleasing *)raw;
@end
// Production input requires a currently published capture image in the source's
// exact stream.
static inline BOOL DWCapturedInputAvailable(LiveSource *source) {
    return source&&!source.detached&&!source.error&&source.pixels&&source.captureMailbox.currentImageAvailable;
}
// Is the native window behind a source gone: its process ended or was replaced, or the
// window list (`info`, for its window number) no longer has it under that owner?
static inline BOOL sourceGone(LiveSource *source,NSDictionary *info) { return ![birth(source.router.pid)isEqual:source.router.processBirth]||[info[(id)kCGWindowOwnerPID]intValue]!=source.router.pid; }
// The window of a hit the controller reported, for the binding lookup of a press or scroll over it. A stand-in's hit is
// built in -hit:output: and names none: upstream's pass_mouse_target_under answers only a client's content.
static inline NSDictionary *DWFocusedStandIn(NSDictionary *snapshot) {
    NSNumber *focused=DWTyped(DWTyped(snapshot[@"focus"],NSDictionary.class)[@"intent"],NSNumber.class);
    if(!focused||DWTyped(DWTyped(snapshot[@"focus"],NSDictionary.class)[@"pending_effect"],NSDictionary.class)||DWTyped(DWTyped(snapshot[@"focus"],NSDictionary.class)[@"cycle"],NSNumber.class))return nil;
    if(![asArray(DWTyped(snapshot[@"lifecycle"],NSDictionary.class)[@"standins"])containsObject:focused])return nil;
    for(NSDictionary *window in asArray(snapshot[@"windows"]))if([window[@"window"]isEqual:focused])
        return [window[@"kind"]isEqual:@"standin"]&&!DWTyped(window[@"source"],NSDictionary.class)?window:nil;
    return nil;
}
static inline NSNumber *liveHit(NSDictionary *hit) { return [hit[@"placeholder"]isEqual:@YES]?nil:DWTyped(hit[@"window"],NSNumber.class); }
static inline BOOL sameInputTarget(NSDictionary *a,NSDictionary *b) {
    if(!a||!b)return NO;
    for(NSString *key in @[@"window",@"output",@"generation",@"identity"])if(![a[key]isEqual:b[key]])return NO;
    return [(a[@"root_identity"]?:a[@"identity"])isEqual:(b[@"root_identity"]?:b[@"identity"])]&&[a[@"native_member"]boolValue]==[b[@"native_member"]boolValue];
}
// Fresh session-stage title admission only. These diagnostics use values already
// read by admission; they do not repeat native queries or change pair ownership.
static inline BOOL DWNativeTitleRefused(BOOL early,const char *reason,NSNumber *window,CGWindowID wid,CGPoint point,NSDictionary *detail) {
    if(early&&DWDebugTrace()){
        NSData *data=detail?[NSJSONSerialization dataWithJSONObject:detail options:0 error:nil]:nil;
        NSString *json=data?[[NSString alloc]initWithData:data encoding:NSUTF8StringEncoding]:nil;
        fprintf(stderr,"debug: native title admission refused window=#%s wid=%u point=%g,%g reason=%s detail=%s\n",window.description.UTF8String?:"?",wid,point.x,point.y,reason,json.UTF8String?:"{}");
    }
    return NO;
}
// Desktop+Input.m
@interface Desktop (Input)
- (void)endLostInput;
- (void)configureNativeInput;
- (void)cancelNativeInput;
- (BOOL)nativeInput:(CGEventType)type event:(CGEventRef)event;
@end
// Desktop+NativeMouse.m
@interface Desktop (NativeMouse)
- (void)nativeMouseOwnershipChanged:(CGEventRef)event buttons:(NSIndexSet *)buttons;
- (void)updateNativeMouseOwners;
- (LiveSource *)nativeSource:(CGWindowID)window at:(CGPoint)point;
- (BOOL)takeOverNativeDrag:(LiveSource *)source event:(CGEventRef)event;
- (void)finishNativeMouseOwner:(LiveSource *)source reason:(NSString *)reason;
@end
// Desktop+CapturedInput.m
@interface Desktop (CapturedInput)
- (BOOL)validateInputTarget:(NSDictionary *)target;
- (BOOL)postInput:(CGEventRef)event target:(NSDictionary *)target local:(CGPoint)local;
- (BOOL)forwardTabletTail:(CGEventRef)event;
- (void)cancelCapturedInputForWindow:(NSNumber *)window;
- (NSDictionary *)resolveCapturedPointer:(NSDictionary *)target screen:(CGPoint)screen;
- (BOOL)forwardCapturedPointer:(CGEventRef)event screen:(CGPoint)screen;
- (void)deliverNative:(NSEvent *)event type:(CGEventType)type view:(DesktopView *)view at:(CGPoint)point;
- (void)deliverNative:(NSEvent *)event type:(CGEventType)type view:(DesktopView *)view at:(CGPoint)point familyHit:(NSDictionary *)hit;
@end
// Desktop+NativeTitles.m
@interface Desktop (NativeTitles)
- (BOOL)earlyNativeTitle:(CGEventType)type event:(CGEventRef)event;
- (void)refreshNativeButtons:(LiveSource *)source;
- (BOOL)nativeGreen:(LiveSource *)source at:(CGPoint)point;
- (BOOL)replicaGreen:(LiveSource *)source at:(CGPoint)point output:(NSNumber *)output;
- (BOOL)pickMotionAt:(CGPoint)point window:(NSNumber *)root;
@end
// Desktop+Gestures.m
@interface Desktop (Gestures)
- (void)configureMultitouch;
- (void)multitouchFrame:(DWMultitouchFrame *)frame;
- (void)refreshGestureFingers;
- (void)configureGlobalTrackpad;
- (BOOL)globalGesturesEnabled;
- (BOOL)admitContact:(NSUInteger)fingers;
- (BOOL)admitGlobalTouches:(DWTrackpadTouchFrame *)frame;
- (void)globalTouches:(DWTrackpadTouchFrame *)frame;
- (BOOL)globalMagnify:(NSEvent *)event;
- (void)touches:(NSEvent *)event;
- (void)magnify:(NSEvent *)event;
- (BOOL)padBusy:(NSEvent *)event;
- (void)cancelGestures;
- (void)noteDockGesture:(NSDictionary *)event;
- (void)gesture:(NSDictionary *)event owner:(NSInteger)owner;
- (void)armTrackpad;
@end
// Desktop+Navigation.m
@interface Desktop (Navigation)
- (void)configureResize;
- (BOOL)sizing;
- (NSDictionary *)consumeSize:(NSDictionary *)reply;
- (void)cancelNavigation;
- (void)configureNavigation;
- (void)stopNavigation;
- (void)activate:(NSNumber *)window output:(NSNumber *)output;
- (void)clickReleased:(NSNumber *)window output:(NSNumber *)output;
- (void)cancelNativeTitleClick;
- (void)deferNativeTitleClick:(NSDictionary *)intent;
- (void)fireNativeTitleClick:(NSTimer *)timer;
- (void)raiseFocus:(NSNumber *)window;
- (void)resizeFocus:(NSDictionary *)reply;
- (void)clearFocus;
- (void)ensureFrames;
- (BOOL)cameraFrame;
- (NSNumber *)outputUnderPointer:(CGPoint)p;
- (void)panEnd:(NSNumber *)output;
- (NSDictionary *)resizeCall:(NSDictionary *)command;
- (NSDictionary *)navigationCall:(NSDictionary *)command;
- (void)refreshFocusAccess;
- (void)pointerFrame;
- (void)pointerFrame:(BOOL)moved;
@end
// Desktop+Fill.m
@interface Desktop (Fill)
- (void)prepareNativeFill:(NSDictionary *)effect;
- (BOOL)deferNativeRestore:(NSDictionary *)effect;
- (BOOL)nativeRestoreDeferredCurrent:(NSDictionary *)deferred snapshot:(NSDictionary *)snapshot;
- (void)retireDeferredNativeRestore;
- (void)updateDeferredNativeRestore;
- (void)clearNativeFillPresentation;
- (BOOL)nativeFillCurrent:(NSDictionary *)held snapshot:(NSDictionary *)snapshot;
- (void)updateNativeFill;
- (void)interruptFillForVisibility:(LiveSource *)source;
- (NSDictionary *)nativeFillBackground:(NSDictionary *)snapshot;
@end
// Desktop+Hover.m
@interface Desktop (Hover)
- (void)queueNativeHover:(CGEventRef)event;
- (void)updateNativeHover;
- (void)cancelNativeHoverForWindow:(NSNumber *)window;
- (BOOL)nativeHoverAllowed;
- (BOOL)nativeOwnershipReady:(LiveSource *)source;
- (BOOL)nativeHoverSite:(LiveSource *)source hit:(NSDictionary *)hit view:(DesktopView *)view output:(NSNumber *)output at:(CGPoint)point;
- (BOOL)queuedNativeHoverPress:(NSEvent *)event source:(LiveSource *)source hit:(NSDictionary *)hit view:(DesktopView *)view output:(NSNumber *)output at:(CGPoint)point;
- (DWNativeViewTransfer *)requestNativeOwnershipAt:(CGPoint)point view:(DesktopView *)view;
- (void)advanceNativeTransfers;
- (void)startNativeTransferTimer;
- (void)stopNativeTransferTimer;
@end
// Desktop+Windows.m
@interface Desktop (Windows) <DWWindowHost>
- (void)setNativeMinimized:(NSDictionary *)effect;
- (void)updateNativeVisibility;
- (void)requestVisibility:(LiveSource *)source;
- (void)observeVisibility:(DWWindowObservation *)observation source:(LiveSource *)source;
- (void)requestWindowObservation;
- (void)forgetNativeFamily:(LiveSource *)source;
- (void)fillRebind:(BOOL)keep;
- (void)attachChoice:(id)sender;
- (void)grantAccess:(id)sender;
- (BOOL)attach:(DWWindowCandidate *)window logical:(NSNumber *)logical world:(NSDictionary *)world;
- (void)detach:(LiveSource *)source;
- (void)track:(LiveSource *)source info:(NSDictionary *)info;
- (NSDictionary *)visibilityBinding:(LiveSource *)source;
- (BOOL)visibilityTicketCurrent:(NSDictionary *)ticket source:(LiveSource *)source;
- (void)closeWindow:(NSDictionary *)effect;
- (void)refreshChoices:(id)sender;
- (BOOL)attach:(DWWindowCandidate *)window logical:(NSNumber *)logical world:(NSDictionary *)world placed:(BOOL)placed;
- (void)follow:(NSDictionary *)reply;
- (BOOL)grabbed:(LiveSource *)source;
- (void)drop:(LiveSource *)source;
- (void)closed:(LiveSource *)source;
- (void)releaseUnplacedWindow:(CGWindowID)window pid:(pid_t)pid;
- (BOOL)marked:(LiveSource *)source;
- (void)track:(LiveSource *)source;
- (void)track:(LiveSource *)source info:(NSDictionary *)w observation:(DWWindowObservation *)observation;
- (BOOL)destroyed:(LiveSource *)source info:(NSDictionary *)info;
@end
// Desktop+Capture.m
@interface Desktop (Capture)
- (void)prepareScreenshot:(NSDictionary *)effect completed:(void (^)(NSString *))completed;
- (void)captureExportWindows:(NSArray<NSNumber *> *)windows index:(NSUInteger)index content:(SCShareableContent *)content request:(DWExportFrame *)request completed:(void (^)(NSString *))completed;
- (void)captureNativeExport:(DWExportFrame *)request index:(NSUInteger)index attempt:(NSUInteger)attempt content:(SCShareableContent *)content completed:(void (^)(NSString *))completed;
- (void)requestNativeExport:(DWExportFrame *)request index:(NSUInteger)index attempt:(NSUInteger)attempt completed:(void (^)(NSString *))completed;
- (void)retryNativeExport:(DWExportFrame *)request index:(NSUInteger)index attempt:(NSUInteger)attempt error:(NSError *)error completed:(void (^)(NSString *))completed;
- (CMTime)captureInterval;
- (BOOL)startCapture:(LiveSource *)source size:(CGSize)pixels interval:(CMTime)interval;
- (void)stopCapture:(LiveSource *)source;
- (CGSize)capturePixels:(LiveSource *)source native:(CGSize)native placements:(NSArray *)placements scales:(NSDictionary *)scales demandDensity:(double *)demand;
- (void)updateCapture:(LiveSource *)source size:(CGSize)pixels native:(CGSize)native interval:(CMTime)interval;
- (void)captureDemand;
- (void)captureRecovery;
@end
// Desktop+Session.m
@interface Desktop (Session)
- (BOOL)nativeUnavailable;
- (void)suspendPresentationLeavingSession:(BOOL)leaving;
- (void)resumeNative;
- (void)takeOverWindowSettings;
- (void)refreshStageManager;
- (void)leftSession;
- (void)returned;
- (void)endFullscreens;
@end
// Desktop+Config.m
@interface Desktop (Config)
- (NSNumber *)viewOutput;
- (void)action:(NSString *)action output:(NSNumber *)output;
- (void)action:(NSString *)action output:(NSNumber *)output at:(CGPoint)point held:(BOOL)held;
- (dispatch_block_t)standInEnter;
- (dispatch_block_t)nativeWindowControlKey:(DWNativeWindowControl)action;
- (void)updateStandInKeyboard:(NSDictionary *)snapshot;
- (NSDictionary *)mouseBinding:(NSString *)trigger source:(NSString *)source flags:(NSEventModifierFlags)flags window:(BOOL)window;
- (NSDictionary *)mouseBinding:(NSString *)trigger source:(NSString *)source flags:(NSEventModifierFlags)flags window:(BOOL)window under:(NSNumber *)under pick:(BOOL)pick;
- (void)watchCorners;
- (void)publishState;
- (NSString *)actionFeedback:(NSString *)action flight:(NSDictionary *)flight output:(NSNumber *)output;
- (void)exec:(NSDictionary *)effect;
- (void)reportLayout;
- (NSDictionary *)nativeWindowControlIntent;
- (void)launch:(NSString *)bundle;
- (void)armCorners:(NSDictionary *)bindings;
- (BOOL)fullscreenOn:(NSNumber *)output;
- (void)broadcastState;
- (void)holdCycle:(NSString *)action held:(BOOL)held;
- (void)action:(NSString *)action output:(NSNumber *)output at:(CGPoint)point held:(BOOL)held corner:(NSString *)corner;
- (void)action:(NSString *)action output:(NSNumber *)output at:(CGPoint)point held:(BOOL)held corner:(NSString *)corner tap:(NSDictionary *)tap;
- (void)configureExitKey;
- (void)stopExitKey;
- (NSArray<NSString *> *)startKeys;
- (void)stopKeys;
- (NSArray<NSString *> *)refreshBindings;
- (NSData *)ipcLine:(NSData *)line subscribe:(BOOL *)subscribe event:(NSData *__autoreleasing *)event deferred:(void (^)(NSData *))deferred;
- (NSData *)debugDecoration:(NSDictionary *)request;
- (void)injected:(DesktopView *)view phase:(int)phase;
- (void)armInjected:(DesktopView *)view;
- (NSData *)debugCapture:(NSDictionary *)request;
- (NSData *)debugPointer:(NSDictionary *)request;
@end
// Desktop+Rendering.m
@interface Desktop (Rendering)
- (NSDictionary *)nativeDescription:(NSDictionary *)snapshot;
- (NSDictionary *)presentationSnapshot;
- (NSDictionary *)visualSnapshot;
- (DWCanvasRenderer *)canvasRenderer;
- (void)render;
- (BOOL)animate:(BOOL)draw;
- (void)startFrames;
- (BOOL)frameComing:(BOOL)start;
- (NSArray<NSScreen *> *)canvasScreens;
- (IFBackgroundProgram *)macWallpaperForOutput:(NSNumber *)output description:(NSDictionary *)description base:(IFBackgroundProgram *)base;
- (void)refreshMacWallpapers;
- (void)watchMacWallpapers;
- (void)stopMacWallpapers;
- (void)startFrameStats;
- (void)frameStats;
- (void)adoptRender:(NSDictionary *)snapshot;
- (DesktopView *)panel:(NSRect)frame outputRects:(NSArray *)rects identities:(NSArray *)identities;
- (void)openPanels;
- (void)refreshOutputUsableAreas;
- (void)screensChanged:(NSNotification *)notification;
@end
