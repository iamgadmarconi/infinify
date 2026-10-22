// SPDX-License-Identifier: GPL-3.0-or-later
#import "native-transition.h"
#import "native-family.h"
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <QuartzCore/QuartzCore.h>
#include <math.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <libproc.h>
#include <unistd.h>

static BOOL validRect(CGRect rect) {
    return isfinite(rect.origin.x)&&isfinite(rect.origin.y)&&isfinite(rect.size.width)&&isfinite(rect.size.height)
        &&rect.size.width>0&&rect.size.height>0&&isfinite(CGRectGetMaxX(rect))&&isfinite(CGRectGetMaxY(rect));
}
// Flip about the main display's top, not the union's top: a display above the
// main display has negative CG y but positive AppKit y. Preserve negative x too.
static BOOL screenBasis(CGPoint *basis) {
    CGDirectDisplayID main=CGMainDisplayID();CGRect display=CGDisplayBounds(main);
    if(!validRect(display))return NO;
    for(NSScreen *screen in NSScreen.screens)if([screen.deviceDescription[@"NSScreenNumber"]unsignedIntValue]==main){
        NSRect frame=screen.frame;if(!validRect(NSRectToCGRect(frame)))return NO;
        *basis=CGPointMake(NSMinX(frame)-display.origin.x,NSMaxY(frame)+display.origin.y);return YES;
    }
    return NO;
}
static NSRect appKitRect(CGRect rect,CGPoint basis) {
    return NSMakeRect(rect.origin.x+basis.x,basis.y-CGRectGetMaxY(rect),rect.size.width,rect.size.height);
}
static CGImageRef copyPixels(CVPixelBufferRef buffer) CF_RETURNS_RETAINED {
    if(!buffer||CVPixelBufferIsPlanar(buffer)||CVPixelBufferGetPixelFormatType(buffer)!=kCVPixelFormatType_32BGRA)return NULL;
    size_t width=CVPixelBufferGetWidth(buffer),height=CVPixelBufferGetHeight(buffer),stride=CVPixelBufferGetBytesPerRow(buffer);
    if(!width||!height||width>16384||height>16384||stride<width*4||stride>SIZE_MAX/height||stride*height>INT32_MAX)return NULL;
    if(CVPixelBufferLockBaseAddress(buffer,kCVPixelBufferLock_ReadOnly)!=kCVReturnSuccess)return NULL;
    const UInt8 *bytes=CVPixelBufferGetBaseAddress(buffer);
    CFDataRef data=bytes?CFDataCreate(kCFAllocatorDefault,bytes,(CFIndex)(stride*height)):NULL;
    CVPixelBufferUnlockBaseAddress(buffer,kCVPixelBufferLock_ReadOnly);
    if(!data)return NULL;
    CGDataProviderRef provider=CGDataProviderCreateWithCFData(data);CFRelease(data);
    CGColorSpaceRef attached=CVImageBufferGetColorSpace(buffer),color=attached?CGColorSpaceRetain(attached):CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGImageRef image=provider&&color?CGImageCreate(width,height,8,32,stride,color,kCGBitmapByteOrder32Little|kCGImageAlphaPremultipliedFirst,provider,NULL,YES,kCGRenderingIntentDefault):NULL;
    if(color)CGColorSpaceRelease(color);if(provider)CGDataProviderRelease(provider);return image;
}
@interface DWTransitionPanel : NSPanel
@end

@interface DWNativeTransitionCaptureResult ()
- (instancetype)initWithImage:(CGImageRef)image screenRect:(CGRect)screen nativeBounds:(CGRect)native;
@end
@implementation DWNativeTransitionCaptureResult {
    CGImageRef _image;
    CGRect _screenRect,_nativeBounds;
}
- (instancetype)initWithImage:(CGImageRef)image screenRect:(CGRect)screen nativeBounds:(CGRect)native {
    if((self=[super init])){_image=CGImageCreateCopy(image);_screenRect=screen;_nativeBounds=native;if(!_image)return nil;}return self;
}
- (CGImageRef)image {return _image;}
- (CGRect)screenRect {return _screenRect;}
- (CGRect)nativeBounds {return _nativeBounds;}
- (void)dealloc {if(_image)CGImageRelease(_image);}
@end

static BOOL captureInteger(id value,uint64_t low,uint64_t high) {
    if(![value isKindOfClass:NSNumber.class]||CFGetTypeID((__bridge CFTypeRef)value)==CFBooleanGetTypeID()
        ||CFNumberIsFloatType((__bridge CFNumberRef)value)||[value compare:@(low)]==NSOrderedAscending||[value compare:@(high)]==NSOrderedDescending)return NO;
    return [value isEqual:@([value unsignedLongLongValue])];
}
static NSDictionary *captureIdentity(NSDictionary *identity) {
    if(![identity isKindOfClass:NSDictionary.class]||(identity[@"owner"]&&identity[@"owner"]!=NSNull.null)
        ||!captureInteger(identity[@"pid"],2,INT32_MAX)||!captureInteger(identity[@"wid"],1,UINT32_MAX)
        ||!captureInteger(identity[@"birth_sec"],1,UINT64_MAX)||!captureInteger(identity[@"birth_usec"],0,999999))return nil;
    return @{@"pid":identity[@"pid"],@"wid":identity[@"wid"],@"birth_sec":identity[@"birth_sec"],@"birth_usec":identity[@"birth_usec"]};
}
static CGRect captureRect(NSDictionary *rect) {
    if(![rect isKindOfClass:NSDictionary.class]||![rect[@"origin"]isKindOfClass:NSDictionary.class]||![rect[@"size"]isKindOfClass:NSDictionary.class])return CGRectNull;
    NSDictionary *origin=rect[@"origin"],*size=rect[@"size"];
    for(id value in @[origin[@"x"]?:NSNull.null,origin[@"y"]?:NSNull.null,size[@"width"]?:NSNull.null,size[@"height"]?:NSNull.null])if(![value isKindOfClass:NSNumber.class])return CGRectNull;
    CGRect frame=CGRectMake([origin[@"x"]doubleValue],[origin[@"y"]doubleValue],[size[@"width"]doubleValue],[size[@"height"]doubleValue]);return validRect(frame)?frame:CGRectNull;
}
static BOOL captureBirthCurrent(NSDictionary *identity) {
    struct proc_bsdinfo process={0};
    return proc_pidinfo([identity[@"pid"]intValue],PROC_PIDTBSDINFO,0,&process,sizeof(process))==sizeof(process)&&process.pbi_uid==getuid()
        &&process.pbi_start_tvsec==[identity[@"birth_sec"]unsignedLongLongValue]&&process.pbi_start_tvusec==[identity[@"birth_usec"]unsignedLongLongValue];
}
static BOOL captureScreenBounds(NSDictionary *identity,CGRect *screen) {
    if(!captureBirthCurrent(identity))return NO;
    NSArray *rows=CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow,[identity[@"wid"]unsignedIntValue]));
    NSUInteger matches=0;CGRect observed=CGRectNull;
    for(NSDictionary *row in rows)if([row[(id)kCGWindowNumber]isEqual:identity[@"wid"]]){
        CGRect frame=CGRectZero;
        if(++matches!=1||![row[(id)kCGWindowOwnerPID]isEqual:identity[@"pid"]]||![row[(id)kCGWindowIsOnscreen]boolValue]
            ||![row[(id)kCGWindowBounds]isKindOfClass:NSDictionary.class]
            ||!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)row[(id)kCGWindowBounds],&frame)||!validRect(frame))return NO;
        observed=frame;
    }
    if(matches!=1||!captureBirthCurrent(identity))return NO;
    *screen=observed;return YES;
}
static BOOL captureScreenCurrent(NSDictionary *identity,CGRect screen) {
    CGRect observed=CGRectNull;return captureScreenBounds(identity,&observed)&&CGRectEqualToRect(observed,screen);
}
static BOOL roundedEdgesMatch(CGRect mapping,CGRect observed) {
    // CGWindowList and AppKit window frames can round each edge outward to
    // whole screen points, so the extent can differ by more than one point.
    // This comparison does not change the caller's exact logical mapping.
    return fabs(CGRectGetMinX(mapping)-CGRectGetMinX(observed))<1&&fabs(CGRectGetMinY(mapping)-CGRectGetMinY(observed))<1
        &&fabs(CGRectGetMaxX(mapping)-CGRectGetMaxX(observed))<1&&fabs(CGRectGetMaxY(mapping)-CGRectGetMaxY(observed))<1;
}
static BOOL captureRefused(NSString *__autoreleasing *reason,NSString *value) {
    if(reason)*reason=value;return NO;
}
static BOOL captureRootCurrent(NSDictionary *identity,CGRect native,CGRect screen,NSString *__autoreleasing *reason) {
    if(!captureScreenCurrent(identity,screen))return captureRefused(reason,@"screen_changed_before_family");
    NSString *familyFailure=nil;NSDictionary *family=DWNativeWindowFamily(identity,reason?&familyFailure:NULL);NSArray *members=family[@"members"];
    if(!family)return captureRefused(reason,familyFailure?:@"family_unavailable");
    if(![family[@"identity"]isEqual:identity]||![family[@"root"]isEqual:identity[@"wid"]])return captureRefused(reason,@"family_root_identity_changed");
    if(![members isKindOfClass:NSArray.class]||members.count!=1)return captureRefused(reason,@"family_not_root_only");
    NSDictionary *member=members.firstObject;
    if(![member[@"identity"]isEqual:identity]||![member[@"parent"]isEqual:@0])return captureRefused(reason,@"family_member_identity_changed");
    if(!CGRectEqualToRect(captureRect(member[@"native_bounds"]),native))return captureRefused(reason,@"native_bounds_changed");
    return captureScreenCurrent(identity,screen)||captureRefused(reason,@"screen_changed_after_family");
}
@interface DWNativeTransitionCapture ()
- (instancetype)initPrivate;
- (void)begin;
- (void)enumerate;
- (void)capture:(SCShareableContent *)content;
- (void)complete:(nullable DWNativeTransitionCaptureResult *)result failure:(nullable NSString *)failure;
@end
@implementation DWNativeTransitionCapture {
    atomic_bool _completed;
    NSDictionary *_identity;
    CGRect _native,_screen,_observedScreen;
    CFTimeInterval _deadline;
    dispatch_queue_t _queue;
    BOOL (^_validate)(void);
    void (^_completion)(DWNativeTransitionCaptureResult *,NSString *);
}
- (instancetype)initPrivate {if((self=[super init]))atomic_init(&_completed,false);return self;}
+ (instancetype)captureIdentity:(NSDictionary *)identity nativeBounds:(CGRect)nativeBounds screenRect:(CGRect)screenRect validate:(BOOL (^)(void))validate completion:(void (^)(DWNativeTransitionCaptureResult *,NSString *))completion {
    NSAssert(NSThread.isMainThread,@"Native capture requires the main thread");
    DWNativeTransitionCapture *request=[[self alloc]initPrivate];request->_identity=captureIdentity(identity);request->_native=nativeBounds;request->_screen=screenRect;
    request->_validate=[validate copy];request->_completion=[completion copy];request->_deadline=CACurrentMediaTime()+2;
    request->_queue=dispatch_queue_create("org.infinify.native-transition-capture",DISPATCH_QUEUE_SERIAL);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),dispatch_get_main_queue(),^{[request complete:nil failure:@"Native transition capture timed out"];});
    dispatch_async(dispatch_get_main_queue(),^{[request begin];});return request;
}
- (BOOL)isCompleted {return atomic_load(&_completed);}
- (BOOL)active {return !atomic_load(&_completed)&&CACurrentMediaTime()<_deadline;}
- (BOOL)callerCurrent {
    if(![self active]){[self complete:nil failure:@"Native transition capture timed out"];return NO;}
    BOOL (^validate)(void)=_validate;BOOL valid=validate&&validate();
    if(!valid||![self active]){[self complete:nil failure:@"Native transition capture ownership changed or expired"];return NO;}return YES;
}
- (void)complete:(DWNativeTransitionCaptureResult *)result failure:(NSString *)failure {
    NSAssert(NSThread.isMainThread,@"Native capture completion requires the main thread");
    if(atomic_exchange(&_completed,true))return;
    if(result&&CACurrentMediaTime()>=_deadline){result=nil;failure=@"Native transition capture timed out";}
    void (^done)(DWNativeTransitionCaptureResult *,NSString *)=_completion;_completion=nil;_validate=nil;if(done)done(result,failure);
}
- (void)cancel {NSAssert(NSThread.isMainThread,@"Native capture requires the main thread");[self complete:nil failure:@"Native transition capture cancelled"];}
- (void)begin {
    if(!_identity||!validRect(_native)||!validRect(_screen)||!_completion){[self complete:nil failure:@"Invalid native transition capture request"];return;}
    if(![self callerCurrent])return;
    if(!CGPreflightScreenCaptureAccess()){[self complete:nil failure:@"Screen Recording access is unavailable"];return;}
    dispatch_async(_queue,^{
        if(![self active])return;CGRect observed=CGRectNull;NSString *reason=nil;
        BOOL current=captureScreenBounds(self->_identity,&observed);
        if(!current)reason=@"screen_identity_or_bounds_unavailable";
        else if(!roundedEdgesMatch(self->_screen,observed)){current=NO;reason=@"mapping_edges_differ";}
        else current=captureRootCurrent(self->_identity,self->_native,observed,&reason);
        if(current)self->_observedScreen=observed;
        else if(getenv("INFINIFY_DEBUG")&&atoi(getenv("INFINIFY_DEBUG"))==1){CGRect mapping=self->_screen;
            fprintf(stderr,"debug: native transition capture initial refused pid=%d wid=%u mapping=%g,%g %gx%g observed=%g,%g %gx%g reason=%s\n",[self->_identity[@"pid"]intValue],[self->_identity[@"wid"]unsignedIntValue],mapping.origin.x,mapping.origin.y,mapping.size.width,mapping.size.height,observed.origin.x,observed.origin.y,observed.size.width,observed.size.height,(reason?:@"unknown").UTF8String);}
        dispatch_async(dispatch_get_main_queue(),^{if(![self callerCurrent])return;if(!current){[self complete:nil failure:@"Native transition needs an unchanged root without attached windows"];return;}[self enumerate];});
    });
}
- (void)enumerate {
    [SCShareableContent getShareableContentExcludingDesktopWindows:YES onScreenWindowsOnly:NO completionHandler:^(SCShareableContent *content,NSError *error){
        dispatch_async(dispatch_get_main_queue(),^{if(![self callerCurrent])return;
            if(error||!content){[self complete:nil failure:error.localizedDescription?:@"Native transition capture has no window list"];return;}[self capture:content];});
    }];
}
- (void)capture:(SCShareableContent *)content {
    SCWindow *window=nil;NSUInteger matches=0;
    for(SCWindow *candidate in content.windows)if(candidate.windowID==[_identity[@"wid"]unsignedIntValue]&&candidate.owningApplication.processID==[_identity[@"pid"]intValue]){window=candidate;matches++;}
    if(matches!=1){[self complete:nil failure:@"Native transition root is unavailable or ambiguous for capture"];return;}
    SCContentFilter *filter=[[SCContentFilter alloc]initWithDesktopIndependentWindow:window];CGRect area=filter.contentRect;double density=filter.pointPixelScale;
    double width=ceil(area.size.width*density),height=ceil(area.size.height*density);
    if(!validRect(area)||!isfinite(density)||density<=0||!isfinite(width)||!isfinite(height)||width<1||height<1||width>16384||height>16384
        ||fabs(width*_screen.size.height-height*_screen.size.width)>_screen.size.width+_screen.size.height){[self complete:nil failure:@"Native transition capture has invalid image geometry"];return;}
    SCScreenshotConfiguration *config=[SCScreenshotConfiguration new];config.width=(NSInteger)width;config.height=(NSInteger)height;config.destinationRect=CGRectMake(0,0,width,height);
    config.showsCursor=NO;config.ignoreShadows=YES;config.ignoreClipping=YES;config.includeChildWindows=NO;config.dynamicRange=SCScreenshotDynamicRangeSDR;
    dispatch_async(_queue,^{
        if(![self active])return;
        if(!CGPreflightScreenCaptureAccess()||!captureRootCurrent(self->_identity,self->_native,self->_observedScreen,NULL)){
            dispatch_async(dispatch_get_main_queue(),^{[self complete:nil failure:@"Native transition capture permission, root or geometry changed"];});return;}
        if(![self active])return;
        [SCScreenshotManager captureScreenshotWithFilter:filter configuration:config completionHandler:^(SCScreenshotOutput *output,NSError *error){
            if(![self active])return;
            CGImageRef image=output.sdrImage;
            DWNativeTransitionCaptureResult *result=!error&&image&&CGImageGetWidth(image)==(size_t)width&&CGImageGetHeight(image)==(size_t)height
                ?[[DWNativeTransitionCaptureResult alloc]initWithImage:image screenRect:self->_screen nativeBounds:self->_native]:nil;
            dispatch_async(self->_queue,^{
                if(![self active])return;BOOL current=result&&captureRootCurrent(self->_identity,self->_native,self->_observedScreen,NULL);
                dispatch_async(dispatch_get_main_queue(),^{if(![self callerCurrent])return;
                    if(!current){[self complete:nil failure:error.localizedDescription?:@"Native transition root, geometry or raw image changed during capture"];return;}[self complete:result failure:nil];});
            });
        }];
    });
}
@end
@implementation DWTransitionPanel
- (BOOL)canBecomeKeyWindow {return NO;}
- (BOOL)canBecomeMainWindow {return NO;}
// A canvas placement can extend beyond the usable screen. Keep its snapshot
// aligned with that exact projection instead of clamping it below the menu bar.
- (NSRect)constrainFrameRect:(NSRect)frame toScreen:(NSScreen *)screen {(void)screen;return frame;}
@end

@implementation DWNativeTransition {
    DWTransitionPanel *_panel;
    CGPoint _basis;
    BOOL _animating,_closed,_animated;
    NSUInteger _serial;
    void (^_completion)(BOOL);
}
- (instancetype)initWithImage:(CGImageRef)image screenRect:(CGRect)rect {
    NSAssert(NSThread.isMainThread,@"Native transition requires the main thread");
    if(!image||!CGImageGetWidth(image)||!CGImageGetHeight(image)||CGImageGetWidth(image)>16384||CGImageGetHeight(image)>16384||!validRect(rect))return nil;
    CGPoint basis;if(!screenBasis(&basis))return nil;
    CGImageRef owned=CGImageCreateCopy(image);if(!owned)return nil;
    if((self=[super init])){
        _basis=basis;
        _panel=[[DWTransitionPanel alloc]initWithContentRect:appKitRect(rect,basis) styleMask:NSWindowStyleMaskBorderless|NSWindowStyleMaskNonactivatingPanel backing:NSBackingStoreBuffered defer:NO];
        _panel.releasedWhenClosed=NO;_panel.hidesOnDeactivate=NO;_panel.canHide=NO;_panel.ignoresMouseEvents=YES;_panel.acceptsMouseMovedEvents=NO;
        _panel.becomesKeyOnlyIfNeeded=YES;_panel.opaque=NO;_panel.backgroundColor=NSColor.clearColor;_panel.hasShadow=NO;
        _panel.level=MIN(CGWindowLevelForKey(kCGDockWindowLevelKey),CGWindowLevelForKey(kCGMainMenuWindowLevelKey))-1;
        if(_panel.level<=NSNormalWindowLevel){CGImageRelease(owned);return nil;}
        _panel.animationBehavior=NSWindowAnimationBehaviorNone;
        _panel.collectionBehavior=NSWindowCollectionBehaviorCanJoinAllSpaces|NSWindowCollectionBehaviorStationary|NSWindowCollectionBehaviorIgnoresCycle|NSWindowCollectionBehaviorFullScreenAuxiliary;
        NSImageView *picture=[[NSImageView alloc]initWithFrame:NSMakeRect(0,0,rect.size.width,rect.size.height)];
        picture.image=[[NSImage alloc]initWithCGImage:owned size:NSMakeSize(CGImageGetWidth(owned),CGImageGetHeight(owned))];
        picture.imageScaling=NSImageScaleAxesIndependently;picture.imageAlignment=NSImageAlignCenter;picture.animates=NO;
        picture.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;picture.accessibilityElement=NO;_panel.contentView=picture;
    }
    CGImageRelease(owned);return self;
}
- (instancetype)initWithPixelBuffer:(CVPixelBufferRef)buffer screenRect:(CGRect)rect {
    CGImageRef image=copyPixels(buffer);if(!image)return nil;
    self=[self initWithImage:image screenRect:rect];CGImageRelease(image);return self;
}
- (BOOL)isVisible {return !_closed&&_panel.isVisible;}
- (BOOL)isAnimating {return _animating;}
- (BOOL)isClosed {return _closed;}
- (BOOL)basisCurrent {CGPoint basis;return screenBasis(&basis)&&CGPointEqualToPoint(_basis,basis);}
- (BOOL)show {
    NSAssert(NSThread.isMainThread,@"Native transition requires the main thread");
    if(_closed||![self basisCurrent])return NO;
    [_panel.contentView displayIfNeeded];[_panel orderFrontRegardless];return _panel.isVisible;
}
- (BOOL)animateToScreenRect:(CGRect)rect completion:(void (^)(BOOL))completion {
    NSAssert(NSThread.isMainThread,@"Native transition requires the main thread");
    if(_closed||_animating||_animated||!self.visible||!validRect(rect)||!completion||![self basisCurrent])return NO;
    NSRect frame=appKitRect(rect,_basis);_animating=YES;_animated=YES;_completion=[completion copy];NSUInteger serial=++_serial;
    __weak DWNativeTransition *weak=self;
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context){
        context.duration=[self->_panel animationResizeTime:frame];
        [[self->_panel animator]setFrame:frame display:YES];
    } completionHandler:^{
        DWNativeTransition *strong=weak;if(!strong||strong->_closed||strong->_serial!=serial)return;
        strong->_animating=NO;void (^done)(BOOL)=strong->_completion;strong->_completion=nil;
        NSRect actual=strong->_panel.frame;BOOL visible=strong.visible,basis=[strong basisCurrent];
        BOOL rounded=validRect(NSRectToCGRect(actual))&&roundedEdgesMatch(NSRectToCGRect(frame),NSRectToCGRect(actual));
        if(getenv("INFINIFY_DEBUG")&&atoi(getenv("INFINIFY_DEBUG"))==1)fprintf(stderr,"debug: native transition panel completed actual=%s target=%s visible=%d basis=%d rounded_match=%d\n",NSStringFromRect(actual).UTF8String,NSStringFromRect(frame).UTF8String,visible,basis,rounded);
        if(done)done(basis&&visible&&rounded);
    }];return YES;
}
- (void)finish {[self cancel];}
- (void)cancel {
    NSAssert(NSThread.isMainThread,@"Native transition requires the main thread");
    if(_closed)return;_closed=YES;_animating=NO;++_serial;
    void (^done)(BOOL)=_completion;_completion=nil;[_panel orderOut:nil];[_panel close];_panel=nil;if(done)done(NO);
}
- (void)dealloc {
    NSAssert(NSThread.isMainThread,@"Native transition requires main-thread release");
    [_panel orderOut:nil];[_panel close];if(_completion)_completion(NO);
}
@end
