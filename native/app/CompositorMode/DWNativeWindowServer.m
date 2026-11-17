// SPDX-License-Identifier: GPL-3.0-or-later
// Original implementation over the client library of native/dock-helper/Client (DWHelperClient.h,
// DWHelperProtocol.h). The two window-server queries are resolved by name, with the signatures
// native/dock-helper/Payload/DWPayloadState.m uses, cross-checked there against yabai
// dd845723416f5fe92af49fad5ebab00369e07edd (src/misc/extern.h), https://github.com/asmvik/yabai;
// see native/app/Resources/YABAI-NOTICE.txt. Nothing here changes a window: every change is the
// helper's, asked for through its socket.
// Split from native/desktop/native-presenter.m (37b27b1): the window-server queries and clip geometry of DWNativeWindowServer.h.
#import "DWNativeWindowServer.h"
#import "DWGeometryJSON.h"
#include <dlfcn.h>
#include <unistd.h>

bool DWNativeBounds(uint32_t wid,CGRect *out) {
    static int (*connection)(void);static CGError (*bounds)(int,uint32_t,CGRect *);static dispatch_once_t once;
    dispatch_once(&once,^{void *sky=dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",RTLD_NOW|RTLD_LOCAL);if(!sky)return;connection=dlsym(sky,"SLSMainConnectionID");bounds=dlsym(sky,"SLSGetWindowBounds");});
    CGRect r=CGRectZero;if(!connection||!bounds||!wid||bounds(connection(),wid,&r)!=kCGErrorSuccess)return false;
    if(!isfinite(r.origin.x)||!isfinite(r.origin.y)||!isfinite(r.size.width)||!isfinite(r.size.height)||r.size.width<=0||r.size.height<=0)return false;
    if(out)*out=r;return true;
}

// Public ABI: SDK System/Library/Frameworks/CoreGraphics.framework/Headers/
// CGWindow.h:271-274, CGWindowListCreateImage (SDK declaration
// SCREEN_CAPTURE_OBSOLETE(10.5,14.0,15.0)). Resolve by name like our private
// adapters: current systems may still provide it, but future ones need not.
// IncludingWindow + CGRectNull reads the backing surface even while the
// presentation transform parks it beyond every display. It changes no placement.
CGImageRef DWNativeCopyWindowImage(uint32_t wid,BOOL *empty) {
    if(empty)*empty=NO;
    static CGImageRef (*capture)(CGRect,CGWindowListOption,CGWindowID,CGWindowImageOption);static dispatch_once_t once;
    dispatch_once(&once,^{capture=dlsym(RTLD_DEFAULT,"CGWindowListCreateImage");});
    if(!capture||!wid)return NULL;
    for(NSUInteger attempt=0;attempt<5;attempt++){
    CGImageRef image=capture(CGRectNull,kCGWindowListOptionIncludingWindow,wid,kCGWindowImageBoundsIgnoreFraming|kCGWindowImageBestResolution);
    if(!image)return NULL;
    size_t width=CGImageGetWidth(image),height=CGImageGetHeight(image);
    if(!width||!height||width>16384||height>16384){CGImageRelease(image);return NULL;}
    // An empty/transparent surface is not a successful screenshot. Sample on
    // this worker before installation; uniform surfaces fall back conservatively.
    uint32_t sample[32*32]={0};CGColorSpaceRef space=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context=CGBitmapContextCreate(sample,32,32,8,32*4,space,kCGImageAlphaPremultipliedFirst|kCGBitmapByteOrder32Little);CGColorSpaceRelease(space);
    BOOL opaque=NO,varied=NO;
    if(context){CGContextDrawImage(context,CGRectMake(0,0,32,32),image);CGContextRelease(context);
        for(NSUInteger i=0;i<32*32;i++){if(sample[i]>>24)opaque=YES;if(sample[i]!=sample[0])varied=YES;}}
    if(opaque&&varied)return image;
    CGImageRelease(image);
    if(attempt<4)usleep(250000);
    }
    if(empty)*empty=YES;return NULL;
}

// yabai dd845723416f5fe92af49fad5ebab00369e07edd src/misc/extern.h:23-24;
// src/window_manager.c:618-699 brackets AX writes plus its own proxy swap.
// This app-connection bracket still requires independent live observation.
CGError DWNativeScreenUpdates(BOOL enabled) {
    static int (*connection)(void);static CGError (*disable)(int),(*enable)(int);static dispatch_once_t once;
    dispatch_once(&once,^{void *sky=dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",RTLD_NOW|RTLD_LOCAL);if(!sky)return;
        connection=dlsym(sky,"SLSMainConnectionID");disable=dlsym(sky,"SLSDisableUpdate");enable=dlsym(sky,"SLSReenableUpdate");});
    if(!connection||!disable||!enable)return kCGErrorNotImplemented;
    return enabled?enable(connection()):disable(connection());
}

bool DWNativeClipPlacement(CGRect native,CGRect rootNative,CGRect rootScreen,CGRect viewport,DWNativeClipGeometry *out) {
    if(!out||!DWFiniteRect(native)||!DWFiniteRect(rootNative)||!DWFiniteRect(rootScreen)||!DWFiniteRect(viewport))return false;
    double zx=rootScreen.size.width/rootNative.size.width,zy=rootScreen.size.height/rootNative.size.height;
    if(!isfinite(zx)||!isfinite(zy)||zx<=0||zy<=0)return false;
    CGRect screen=CGRectMake(rootScreen.origin.x+(native.origin.x-rootNative.origin.x)*zx,
        rootScreen.origin.y+(native.origin.y-rootNative.origin.y)*zy,native.size.width*zx,native.size.height*zy);
    if(!DWFiniteRect(screen))return false;
    CGRect visible=CGRectIntersection(screen,viewport),local=CGRectZero;
    // A fully off-output child needs an empty local clip. Never serialize
    // CGRectNull's infinite origin as if it were a valid region.
    if(CGRectIsNull(visible)||CGRectIsEmpty(visible))visible=CGRectZero;
    else {
        double left=fmax(0,fmin(native.size.width,(CGRectGetMinX(visible)-CGRectGetMinX(screen))/zx));
        double top=fmax(0,fmin(native.size.height,(CGRectGetMinY(visible)-CGRectGetMinY(screen))/zy));
        double right=fmax(left,fmin(native.size.width,(CGRectGetMaxX(visible)-CGRectGetMinX(screen))/zx));
        double bottom=fmax(top,fmin(native.size.height,(CGRectGetMaxY(visible)-CGRectGetMinY(screen))/zy));
        local=CGRectMake(left,top,right-left,bottom-top);
    }
    *out=(DWNativeClipGeometry){.screen=screen,.visible=visible,.local=local,.required=!CGRectContainsRect(viewport,screen)};
    return true;
}
