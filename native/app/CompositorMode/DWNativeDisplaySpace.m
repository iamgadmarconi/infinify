// SPDX-License-Identifier: GPL-3.0-or-later
#import "DWNativeDisplaySpace.h"
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <stdatomic.h>

// Private getter declarations cross-checked against yabai (MIT),
// https://github.com/asmvik/yabai, revision dd845723416f5fe92af49fad5ebab00369e07edd,
// src/misc/extern.h:13,22,42,54,56.
// Attribution and upstream license: native/app/Resources/YABAI-NOTICE.txt.
typedef struct {
    int (*connection)(void),(*type)(int,uint64_t);
    uint64_t (*current)(int,CFStringRef);
    CFStringRef (*display)(int,uint64_t);
    CFUUIDRef (*uuidForDisplay)(uint32_t);
} DWNativeDisplayAPI;
static DWNativeDisplayAPI *DWDisplayAPI(void) {
    static DWNativeDisplayAPI api;
    static dispatch_once_t once;
    dispatch_once(&once,^{
        void *sky=dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",RTLD_NOW|RTLD_LOCAL);
        if(!sky)return;
        api.connection=dlsym(sky,"SLSMainConnectionID");api.current=dlsym(sky,"SLSManagedDisplayGetCurrentSpace");
        api.type=dlsym(sky,"SLSSpaceGetType");api.display=dlsym(sky,"SLSCopyManagedDisplayForSpace");
        api.uuidForDisplay=dlsym(RTLD_DEFAULT,"CGDisplayCreateUUIDFromDisplayID");
    });
    return api.connection&&api.current&&api.type&&api.display&&api.uuidForDisplay?&api:NULL;
}
static CFStringRef DWDisplayName(DWNativeDisplayAPI *api,CGDirectDisplayID display) {
    CFUUIDRef uuid=api->uuidForDisplay(display);if(!uuid)return NULL;
    CFStringRef name=CFUUIDCreateString(NULL,uuid);CFRelease(uuid);return name;
}
static uint64_t DWDisplayCurrentSpace(DWNativeDisplayAPI *api,CGDirectDisplayID matched,CFStringRef name,CGRect viewport) {
    int cid=api->connection();uint64_t sid=api->current(cid,name);CFStringRef owner=sid?api->display(cid,sid):NULL;
    BOOL valid=sid&&owner&&CFGetTypeID(owner)==CFStringGetTypeID()&&CFEqual(name,owner)
        &&api->type(cid,sid)==0&&api->current(cid,name)==sid&&CGRectEqualToRect(CGDisplayBounds(matched),viewport);
    if(owner)CFRelease(owner);return valid?sid:0;
}
uint64_t DWNativeDisplaySpace(CGRect viewport) {
    DWNativeDisplayAPI *api=DWDisplayAPI();if(!api)return 0;
    CGDirectDisplayID ids[32]={0},matched=0;uint32_t count=0;
    if(CGGetActiveDisplayList(32,ids,&count)!=kCGErrorSuccess||count>=32)return 0;
    for(uint32_t i=0;i<count;i++)if(CGRectEqualToRect(CGDisplayBounds(ids[i]),viewport)){
        if(matched||CGDisplayMirrorsDisplay(ids[i])||!CGDisplayIsOnline(ids[i])||CGDisplayIsAsleep(ids[i]))return 0;
        matched=ids[i];
    }
    if(!matched)return 0;
    CFStringRef name=DWDisplayName(api,matched);if(!name)return 0;
    uint64_t sid=DWDisplayCurrentSpace(api,matched,name,viewport);CFRelease(name);return sid;
}

// The callback may run off main; it invalidates only an atomic generation.
// Cache contents and retained UUID strings are exclusively main-thread owned.
static _Atomic uint64_t DWDisplayGeneration=1;
static void DWDisplayReconfigured(CGDirectDisplayID display,CGDisplayChangeSummaryFlags flags,void *context) {
    (void)display;(void)flags;(void)context;atomic_fetch_add(&DWDisplayGeneration,1);
}
uint64_t DWNativePresentationDisplaySpace(CGRect viewport) {
    if(!NSThread.isMainThread)return DWNativeDisplaySpace(viewport);
    DWNativeDisplayAPI *api=DWDisplayAPI();if(!api)return 0;
    static BOOL registered;
    static dispatch_once_t once;
    dispatch_once(&once,^{registered=CGDisplayRegisterReconfigurationCallback(DWDisplayReconfigured,NULL)==kCGErrorSuccess;});
    if(!registered)return DWNativeDisplaySpace(viewport);
    typedef struct { CGDirectDisplayID display;CGRect bounds;CFStringRef name; } DWDisplayMetadata;
    static DWDisplayMetadata entries[32];
    static uint32_t count;
    static uint64_t generation;
    uint64_t observed=atomic_load(&DWDisplayGeneration);
    if(generation!=observed){
        for(uint32_t i=0;i<count;i++)if(entries[i].name)CFRelease(entries[i].name);
        memset(entries,0,sizeof(entries));count=0;generation=0;
        CGDirectDisplayID ids[32]={0};uint32_t found=0;
        if(CGGetActiveDisplayList(32,ids,&found)!=kCGErrorSuccess||found>=32)return 0;
        for(uint32_t i=0;i<found;i++)entries[i]=(DWDisplayMetadata){.display=ids[i],.bounds=CGDisplayBounds(ids[i])};
        count=found;
        if(atomic_load(&DWDisplayGeneration)!=observed)return 0;
        generation=observed;
    }
    DWDisplayMetadata *matched=NULL;
    for(uint32_t i=0;i<count;i++)if(CGRectEqualToRect(entries[i].bounds,viewport)){
        if(matched)return 0;matched=&entries[i];
    }
    if(!matched){generation=0;return 0;}
    // Power/online/mirroring status is checked on every use, rather than assuming
    // display callbacks cover every sleep or hardware transition. Bounds are
    // checked again by DWDisplayCurrentSpace before any result is returned.
    if(CGDisplayMirrorsDisplay(matched->display)||!CGDisplayIsOnline(matched->display)||CGDisplayIsAsleep(matched->display))return 0;
    if(!matched->name)matched->name=DWDisplayName(api,matched->display);
    if(!matched->name)return 0;
    uint64_t sid=DWDisplayCurrentSpace(api,matched->display,matched->name,viewport);
    if(atomic_load(&DWDisplayGeneration)!=observed){generation=0;return 0;}
    if(!sid)generation=0;
    return sid;
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
