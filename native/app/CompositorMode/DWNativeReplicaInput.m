// SPDX-License-Identifier: GPL-3.0-or-later
// The per-window posting fields and signatures are referenced from Cantrip
// 4da10af479701c8007074c65f9eb6a2db03c8ffc, macos/skylight.rs (no code copied):
// https://github.com/ArcaneArts/Cantrip/blob/4da10af479701c8007074c65f9eb6a2db03c8ffc/cantrip_cua/src/macos/skylight.rs
// New adapter geometry: the application's local point is unscaled while
// the global location follows the real window's current WindowServer rectangle.
#import "DWNativeReplicaInput.h"
#import "DWNativeTabletRouter.h"
#import "DWNativePresenter.h"
#import "DWNativeFocus.h"
#include <dlfcn.h>
#include <math.h>

BOOL DWNativeReplicaPost(CGEventRef event,CGEventSourceRef source,int64_t tag,NSDictionary *identity,CGRect observed,CGPoint local) {
    if(!event||!source||!identity||!isfinite(local.x)||!isfinite(local.y))return NO;
    CGEventType type=CGEventGetType(event);
    if(!DWMouseForwardable(type)&&type!=kCGEventScrollWheel&&!DWNativeTabletEvent(event))return NO;
    pid_t pid=[identity[@"pid"]intValue];uint32_t wid=[identity[@"wid"]unsignedIntValue];uint64_t sec=0,usec=0;
    if(pid<=0||!wid||!dw_focus_birth(pid,&sec,&usec)||sec!=[identity[@"birth_sec"]unsignedLongLongValue]||usec!=[identity[@"birth_usec"]unsignedLongLongValue])return NO;
    NSArray *windows=CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow,wid));NSDictionary *info=nil;
    for(NSDictionary *window in windows)if([window[(id)kCGWindowNumber]unsignedIntValue]==wid){info=window;break;}
    CGRect actual=CGRectZero,own=CGRectZero;
    if([info[(id)kCGWindowOwnerPID]intValue]!=pid||!info[(id)kCGWindowBounds]||!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)info[(id)kCGWindowBounds],&actual)
       ||!DWNativeBounds(wid,&own)||!CGRectEqualToRect(own,observed)||CGRectIsEmpty(actual)||CGRectIsInfinite(actual)||CGRectIsNull(actual))return NO;
    CGPoint screen=CGPointMake(actual.origin.x+local.x*actual.size.width/own.size.width,actual.origin.y+local.y*actual.size.height/own.size.height);
    if(!isfinite(screen.x)||!isfinite(screen.y))return NO;
    static void (*post)(pid_t,CGEventRef),(*location)(CGEventRef,CGPoint),(*field)(CGEventRef,uint32_t,int64_t);static dispatch_once_t once;
    dispatch_once(&once,^{void *sky=dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",RTLD_NOW|RTLD_LOCAL);post=sky?dlsym(sky,"SLEventPostToPid"):NULL;field=sky?dlsym(sky,"SLEventSetIntegerValueField"):NULL;location=dlsym(RTLD_DEFAULT,"CGEventSetWindowLocation");});
    if(!post||!location||!field)return NO;
    CGEventSetSource(event,source);CGEventSetIntegerValueField(event,kCGEventSourceUserData,tag);
    CGEventSetIntegerValueField(event,(CGEventField)91,wid);CGEventSetIntegerValueField(event,(CGEventField)92,wid);CGEventSetLocation(event,screen);
    location(event,local);field(event,40,pid);field(event,51,wid);field(event,58,tag);field(event,91,wid);field(event,92,wid);
    if(type==kCGEventLeftMouseDown||type==kCGEventLeftMouseUp||type==kCGEventLeftMouseDragged)field(event,7,3);
    post(pid,event);return YES;
}
