// SPDX-License-Identifier: GPL-3.0-or-later
// Actual lookup/cache with deterministic substituted read-only queries. No
// display, Space, window, settings or native process is inspected or changed.
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#include <dlfcn.h>
static CGError cacheDisplays(uint32_t capacity,CGDirectDisplayID *ids,uint32_t *count);
static CGRect cacheBounds(CGDirectDisplayID display);
static CGDirectDisplayID cacheMirror(CGDirectDisplayID display);
static boolean_t cacheOnline(CGDirectDisplayID display);
static boolean_t cacheAsleep(CGDirectDisplayID display);
static CGError cacheRegister(CGDisplayReconfigurationCallBack callback,void *context);
static void *cacheOpen(const char *path,int flags);
static void *cacheSymbol(void *handle,const char *name);
#define CGGetActiveDisplayList cacheDisplays
#define CGDisplayBounds cacheBounds
#define CGDisplayMirrorsDisplay cacheMirror
#define CGDisplayIsOnline cacheOnline
#define CGDisplayIsAsleep cacheAsleep
#define CGDisplayRegisterReconfigurationCallback cacheRegister
#define dlopen cacheOpen
#define dlsym cacheSymbol
#import "native-display-space.m"
#undef CGGetActiveDisplayList
#undef CGDisplayBounds
#undef CGDisplayMirrorsDisplay
#undef CGDisplayIsOnline
#undef CGDisplayIsAsleep
#undef CGDisplayRegisterReconfigurationCallback
#undef dlopen
#undef dlsym

typedef struct { CGDirectDisplayID id;CGRect bounds;uint64_t space;BOOL online,asleep,mirrored; } FakeDisplay;
static FakeDisplay displays[32];
static uint32_t displayCount=4;
static NSUInteger checks,listReads,boundsReads,uuidReads,currentReads,ownerReads,typeReads,registrations;
static NSUInteger changeSpaceAt,invalidateAt,changeBoundsAt;
static BOOL badOwner,badType,badList,badUUID,failRegistration;
static CGDisplayReconfigurationCallBack callback;
static void *callbackContext;
static void check(BOOL value,NSString *message) {
    checks++;if(!value){fprintf(stderr,"FAIL: %s\n",message.UTF8String);exit(1);}
}
static FakeDisplay *displayFor(CGDirectDisplayID display) {
    for(uint32_t i=0;i<displayCount&&i<32;i++)if(displays[i].id==display)return &displays[i];return NULL;
}
static NSString *displayName(CGDirectDisplayID display) { return [NSString stringWithFormat:@"%08X-0000-0000-0000-000000000000",display]; }
static void invalidate(void) { check(callback!=NULL,@"registered read-only display invalidation");callback(1,kCGDisplayMovedFlag,callbackContext); }
static void resetCounts(void) { listReads=boundsReads=uuidReads=currentReads=ownerReads=typeReads=0; }
static CGError cacheDisplays(uint32_t capacity,CGDirectDisplayID *ids,uint32_t *count) {
    listReads++;if(badList)return kCGErrorFailure;*count=displayCount;
    for(uint32_t i=0;i<MIN(capacity,displayCount);i++)ids[i]=displays[i].id;return kCGErrorSuccess;
}
static CGRect cacheBounds(CGDirectDisplayID display) {
    boundsReads++;FakeDisplay *entry=displayFor(display);
    if(changeBoundsAt&&boundsReads==changeBoundsAt)entry->bounds.origin.y+=100;
    return entry?entry->bounds:CGRectNull;
}
static CGDirectDisplayID cacheMirror(CGDirectDisplayID display) { FakeDisplay *entry=displayFor(display);return entry&&entry->mirrored?99:0; }
static boolean_t cacheOnline(CGDirectDisplayID display) { FakeDisplay *entry=displayFor(display);return entry&&entry->online; }
static boolean_t cacheAsleep(CGDirectDisplayID display) { FakeDisplay *entry=displayFor(display);return !entry||entry->asleep; }
static CGError cacheRegister(CGDisplayReconfigurationCallBack value,void *context) {
    registrations++;if(failRegistration)return kCGErrorFailure;callback=value;callbackContext=context;return kCGErrorSuccess;
}
static int cacheConnection(void) { return 7; }
static uint64_t cacheCurrent(int connection,CFStringRef name) {
    check(connection==7,@"lookup uses its own read-only connection");currentReads++;
    if(changeSpaceAt&&currentReads==changeSpaceAt)displays[0].space++;
    if(invalidateAt&&currentReads==invalidateAt)invalidate();
    for(uint32_t i=0;i<displayCount&&i<32;i++)if([(__bridge NSString *)name isEqual:displayName(displays[i].id)])return displays[i].space;
    return 0;
}
static CFStringRef cacheOwner(int connection,uint64_t space) {
    (void)connection;ownerReads++;if(badOwner)return CFBridgingRetain(@"wrong display");
    for(uint32_t i=0;i<displayCount&&i<32;i++)if(displays[i].space==space)return CFBridgingRetain(displayName(displays[i].id));return NULL;
}
static int cacheType(int connection,uint64_t space) { (void)connection;(void)space;typeReads++;return badType?4:0; }
static CFUUIDRef cacheUUID(uint32_t display) {
    uuidReads++;return badUUID?NULL:CFUUIDCreateFromString(NULL,(__bridge CFStringRef)displayName(display));
}
static void *cacheOpen(const char *path,int flags) { (void)path;(void)flags;return (void *)1; }
static void *cacheSymbol(void *handle,const char *name) {
    (void)handle;
    if(!strcmp(name,"SLSMainConnectionID"))return (void *)cacheConnection;
    if(!strcmp(name,"SLSManagedDisplayGetCurrentSpace"))return (void *)cacheCurrent;
    if(!strcmp(name,"SLSSpaceGetType"))return (void *)cacheType;
    if(!strcmp(name,"SLSCopyManagedDisplayForSpace"))return (void *)cacheOwner;
    if(!strcmp(name,"CGDisplayCreateUUIDFromDisplayID"))return (void *)cacheUUID;
    return NULL;
}
int main(int argc,const char *argv[]) { @autoreleasepool {
    failRegistration=argc>1&&!strcmp(argv[1],"--registration-failed");
    for(uint32_t i=0;i<4;i++)displays[i]=(FakeDisplay){.id=i+1,.bounds=CGRectMake(i*1000,0,1000,800),.space=10+i,.online=YES};
    const NSUInteger frames=120,lookups=frames*displayCount;
    for(NSUInteger frame=0;frame<frames;frame++)for(uint32_t i=0;i<displayCount;i++)
        check(DWNativeDisplaySpace(displays[i].bounds)==displays[i].space,@"uncached baseline resolves exact viewport");
    NSUInteger baselineLists=listReads,baselineUUIDs=uuidReads,baselineBounds=boundsReads;
    check(baselineLists==lookups&&baselineUUIDs==lookups,@"baseline performs enumeration and UUID creation per output/frame");
    resetCounts();
    for(NSUInteger frame=0;frame<frames;frame++)for(uint32_t i=0;i<displayCount;i++)
        check(DWNativePresentationDisplaySpace(displays[i].bounds)==displays[i].space,@"cached path preserves every requested Space");
    check(registrations==1,@"display callback is registered once");
    if(failRegistration){
        check(listReads==baselineLists&&uuidReads==baselineUUIDs,@"unavailable invalidation falls back to uncached lookup");
        printf("PASS: %lu substituted cache checks; callback failure uses uncached lookup; no native mutation\n",(unsigned long)checks);return 0;
    }
    check(listReads==1&&uuidReads==displayCount,@"steady camera frames reuse one display enumeration and one UUID per display");
    check(currentReads==lookups*2&&ownerReads==lookups&&typeReads==lookups,@"current Space, owner and type remain freshly validated");
    printf("CALLS: 120 frames / 4 outputs: enumeration %lu -> %lu; UUID %lu -> %lu; bounds %lu -> %lu; current Space reads unchanged (%lu)\n",
        (unsigned long)baselineLists,(unsigned long)listReads,(unsigned long)baselineUUIDs,(unsigned long)uuidReads,
        (unsigned long)baselineBounds,(unsigned long)boundsReads,(unsigned long)currentReads);
    CGRect first=displays[0].bounds;
    displays[0].space=100;
    check(DWNativePresentationDisplaySpace(first)==100,@"Space change is visible without an invalidation notification");
    changeSpaceAt=currentReads+2;
    check(DWNativePresentationDisplaySpace(first)==0,@"mid-query Space change is rejected");changeSpaceAt=0;
    check(DWNativePresentationDisplaySpace(first)==101,@"next frame observes new Space");
    badOwner=YES;check(DWNativePresentationDisplaySpace(first)==0,@"owner mismatch is never cached away");badOwner=NO;
    badType=YES;check(DWNativePresentationDisplaySpace(first)==0,@"nonordinary Space is rejected");badType=NO;
    check(DWNativePresentationDisplaySpace(first)==101,@"valid Space recovers after failed validation");
    displays[0].asleep=YES;check(DWNativePresentationDisplaySpace(first)==0,@"sleep is observed without display callback");displays[0].asleep=NO;
    displays[0].online=NO;check(DWNativePresentationDisplaySpace(first)==0,@"offline display is observed without display callback");displays[0].online=YES;
    displays[0].mirrored=YES;check(DWNativePresentationDisplaySpace(first)==0,@"mirroring is observed without display callback");displays[0].mirrored=NO;
    check(DWNativePresentationDisplaySpace(first)==101,@"display resumes with fresh native checks");
    NSUInteger oldLists=listReads,oldUUIDs=uuidReads;invalidate();
    check(DWNativePresentationDisplaySpace(first)==101&&listReads==oldLists+1&&uuidReads==oldUUIDs+1,@"reconfiguration rebuilds display metadata and UUID");
    invalidateAt=currentReads+1;
    check(DWNativePresentationDisplaySpace(first)==0,@"invalidation during lookup rejects the mixed generation");invalidateAt=0;
    check(DWNativePresentationDisplaySpace(first)==101,@"next lookup rebuilds after mixed generation");
    changeBoundsAt=boundsReads+1;
    check(DWNativePresentationDisplaySpace(first)==0,@"changed live bounds reject cached viewport");changeBoundsAt=0;
    first=displays[0].bounds;
    check(DWNativePresentationDisplaySpace(first)==101,@"changed bounds are rebuilt on the next lookup");
    displays[1].bounds=first;invalidate();
    check(DWNativePresentationDisplaySpace(first)==0,@"ambiguous display viewport is rejected");displays[1].bounds=CGRectMake(1000,0,1000,800);invalidate();
    badList=YES;check(DWNativePresentationDisplaySpace(first)==0,@"enumeration failure returns unknown");badList=NO;
    badUUID=YES;check(DWNativePresentationDisplaySpace(first)==0,@"missing UUID returns unknown");badUUID=NO;
    check(DWNativePresentationDisplaySpace(first)==101,@"failed UUID lookup retries without poisoning the cache");
    displayCount=32;invalidate();check(DWNativePresentationDisplaySpace(first)==0,@"truncated display lists remain rejected");displayCount=4;invalidate();
    check(DWNativePresentationDisplaySpace(first)==101,@"bounded display list recovers");
    __block uint64_t workerSpace=0;oldLists=listReads;
    dispatch_semaphore_t finished=dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT,0),^{workerSpace=DWNativePresentationDisplaySpace(first);dispatch_semaphore_signal(finished);});
    check(dispatch_semaphore_wait(finished,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC))==0,@"off-main lookup completes");
    check(workerSpace==101&&listReads==oldLists+1,@"off-main callers use uncached lookup");
    printf("PASS: %lu substituted cache checks; geometry/Space changes and fallback covered; no native mutation or FPS claim\n",(unsigned long)checks);
    return 0;
} }
