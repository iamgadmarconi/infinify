// SPDX-License-Identifier: GPL-3.0-or-later
#import "native-display-space.h"
#import <Foundation/Foundation.h>
#include <dlfcn.h>

// Private getter declarations cross-checked against yabai (MIT), revision
// dd845723416f5fe92af49fad5ebab00369e07edd, src/misc/extern.h:13,22,42,54,56.
// Attribution and upstream license: ../families/YABAI-NOTICE.txt.
uint64_t DWNativeDisplaySpace(CGRect viewport) {
    static int (*connection)(void),(*type)(int,uint64_t);
    static uint64_t (*current)(int,CFStringRef);
    static CFStringRef (*display)(int,uint64_t);
    static CFUUIDRef (*uuidForDisplay)(uint32_t);
    static dispatch_once_t once;
    dispatch_once(&once,^{
        void *sky=dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",RTLD_NOW|RTLD_LOCAL);
        if(!sky)return;
        connection=dlsym(sky,"SLSMainConnectionID");current=dlsym(sky,"SLSManagedDisplayGetCurrentSpace");
        type=dlsym(sky,"SLSSpaceGetType");display=dlsym(sky,"SLSCopyManagedDisplayForSpace");
        uuidForDisplay=dlsym(RTLD_DEFAULT,"CGDisplayCreateUUIDFromDisplayID");
    });
    if(!connection||!current||!type||!display||!uuidForDisplay)return 0;
    CGDirectDisplayID ids[32]={0},matched=0;uint32_t count=0;
    if(CGGetActiveDisplayList(32,ids,&count)!=kCGErrorSuccess||count>=32)return 0;
    for(uint32_t i=0;i<count;i++)if(CGRectEqualToRect(CGDisplayBounds(ids[i]),viewport)){
        if(matched||CGDisplayMirrorsDisplay(ids[i])||!CGDisplayIsOnline(ids[i])||CGDisplayIsAsleep(ids[i]))return 0;
        matched=ids[i];
    }
    if(!matched)return 0;
    CFUUIDRef uuid=uuidForDisplay(matched);if(!uuid)return 0;
    CFStringRef name=CFUUIDCreateString(NULL,uuid);CFRelease(uuid);if(!name)return 0;
    int cid=connection();uint64_t sid=current(cid,name);CFStringRef owner=sid?display(cid,sid):NULL;
    BOOL valid=sid&&owner&&CFGetTypeID(owner)==CFStringGetTypeID()&&CFEqual(name,owner)
        &&type(cid,sid)==0&&current(cid,name)==sid&&CGRectEqualToRect(CGDisplayBounds(matched),viewport);
    if(owner)CFRelease(owner);CFRelease(name);return valid?sid:0;
}

BOOL DWNativeWindowOnDisplaySpace(CGWindowID window, CGRect viewport) {
    if(!window)return NO;
    uint64_t expected=DWNativeDisplaySpace(viewport);if(!expected)return NO;
    static int (*connection)(void);
    static CFArrayRef (*copySpaces)(int,int,CFArrayRef);
    static dispatch_once_t once;
    dispatch_once(&once,^{
        void *sky=dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",RTLD_NOW|RTLD_LOCAL);
        if(!sky)return;
        connection=dlsym(sky,"SLSMainConnectionID");copySpaces=dlsym(sky,"SLSCopySpacesForWindows");
    });
    if(!connection||!copySpaces)return NO;
    // Selector 7 includes every membership, matching the existing helper's
    // v2WindowSpace query; sticky/multiple-Space windows must not pass.
    CFArrayRef raw=copySpaces(connection(),7,(__bridge CFArrayRef)@[@(window)]);
    if(!raw)return NO;
    uint64_t observed=0;
    if(CFGetTypeID(raw)==CFArrayGetTypeID()&&CFArrayGetCount(raw)==1){
        id value=(__bridge id)CFArrayGetValueAtIndex(raw,0);
        if(value&&CFGetTypeID((__bridge CFTypeRef)value)==CFNumberGetTypeID()
            &&!CFNumberIsFloatType((__bridge CFNumberRef)value)&&[value compare:@0]==NSOrderedDescending)
            observed=[value unsignedLongLongValue];
    }
    CFRelease(raw);
    return observed==expected&&DWNativeDisplaySpace(viewport)==expected;
}
