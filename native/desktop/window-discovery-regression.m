// SPDX-License-Identifier: GPL-3.0-or-later
// Production discovery/observation scheduling with in-memory metadata, clocks,
// applications and queues. No native windows, AX, WindowServer, helper or input.
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import "window-manager.h"
#import "window-events.h"
#import "native-presenter.h"
#include <libproc.h>

static NSUInteger checks,candidateBasisReads;
static BOOL inWorker,listAvailable=YES,deliverDiscoveryDuringFamily;
static BOOL allowOverlayPermissionRead,allListAvailable=YES,closeTesting,titleTesting;
static NSArray<NSDictionary *> *closeElements;
static NSUInteger closePresses,closeOwnerReads,closeOwnerFailsAt;
static NSUInteger allListReads,processReads,processMode;
static NSArray<NSDictionary *> *allWindowRows,*secondAllWindowRows;
static NSTimeInterval fixtureNow=100;
static NSArray<NSDictionary *> *windowRows;
static NSDictionary *candidateBasisOverride;
static NSMutableArray<dispatch_block_t> *mainBlocks,*workerBlocks;
static void check(BOOL condition,NSString *message) {
    checks++;if(!condition){fprintf(stderr,"FAIL: %s\n",message.UTF8String);exit(1);}
}
static BOOL step(BOOL worker);
static void fixtureAsync(dispatch_queue_t queue,dispatch_block_t block) {
    [(queue==dispatch_get_main_queue()?mainBlocks:workerBlocks)addObject:[block copy]];
}
static CFTimeInterval fixtureTime(void) { return fixtureNow; }
static BOOL fixtureTrusted(void) { return closeTesting||titleTesting; }
static BOOL fixtureCaptureAccess(void) { check(allowOverlayPermissionRead,@"only overlay creation reads capture permission");return NO; }
static CFArrayRef fixtureWindowList(CGWindowListOption options,CGWindowID window) {
    (void)window;check(inWorker,@"WindowServer metadata reads stay off main");
    if(options==(kCGWindowListOptionAll|kCGWindowListExcludeDesktopElements)){
        allListReads++;return allListAvailable?CFBridgingRetain(allListReads%2==0&&secondAllWindowRows?secondAllWindowRows:allWindowRows):NULL;
    }
    return listAvailable?CFBridgingRetain(windowRows):NULL;
}
static int fixtureProcessInfo(int pid,int flavor,uint64_t argument,void *buffer,int size) {
    (void)argument;check(inWorker&&pid==123&&flavor==PROC_PIDTBSDINFO&&size==(int)sizeof(struct proc_bsdinfo),@"observation revalidates the modeled process birth on its worker");
    processReads++;if(processMode==3)return 0;
    struct proc_bsdinfo process={.pbi_uid=processMode==1?getuid()+1:getuid(),.pbi_start_tvsec=processMode==2&&processReads>1?101:100,.pbi_start_tvusec=20};memcpy(buffer,&process,sizeof(process));return size;
}
// Exact production close path with AX dictionaries; no native AX object or
// action is created. The unnumbered scroll area is Finder's observed sibling.
static AXUIElementRef closeApplication(pid_t pid) { check((closeTesting||titleTesting)&&pid==123,@"close resolves only the expected process");return (AXUIElementRef)CFRetain((__bridge CFTypeRef)@{@"pid":@123}); }
static AXError closeTimeout(AXUIElementRef element,float seconds) { (void)element;check((closeTesting||titleTesting)&&seconds>0&&seconds<=1,@"close AX reads/actions keep their bounded messaging timeout");return kAXErrorSuccess; }
static AXError closePid(AXUIElementRef element,pid_t *pid) { NSDictionary *value=(__bridge NSDictionary *)element;*pid=[value[@"pid"]intValue];return [value[@"pid_error"]intValue]; }
static AXError closeWindowID(AXUIElementRef element,uint32_t *window) { NSDictionary *value=(__bridge NSDictionary *)element;*window=[value[@"wid"]unsignedIntValue];return [value[@"window_error"]intValue]; }
static void *closeSymbol(void *handle,const char *name) { (void)handle;return (closeTesting||titleTesting)&&!strcmp(name,"_AXUIElementGetWindow")?(void *)closeWindowID:NULL; }
static AXError closeCopy(AXUIElementRef element,CFStringRef attribute,CFTypeRef *out) {
    check(closeTesting||titleTesting,@"only modeled close/title lookup sends AX reads");NSDictionary *value=(__bridge NSDictionary *)element;id result=nil;
    if(CFEqual(attribute,kAXWindowsAttribute))result=closeElements;
    else if(CFEqual(attribute,kAXRoleAttribute)){if(value[@"role_error"])return [value[@"role_error"]intValue];result=value[@"role"];}
    else if(CFEqual(attribute,kAXSubroleAttribute))result=value[@"subrole"];
    else if(CFEqual(attribute,kAXTitleAttribute))result=value[@"title"];
    else if(CFEqual(attribute,kAXCloseButtonAttribute)){check([value[@"wid"]isEqual:@42],@"only exact target supplies a close button");result=@{@"pid":@123,@"button_for":@42};}
    if(!result)return kAXErrorNoValue;*out=CFRetain((__bridge CFTypeRef)result);return kAXErrorSuccess;
}
static AXError closePress(AXUIElementRef element,CFStringRef action) {
    check(closeTesting&&CFEqual(action,kAXPressAction)&&[((__bridge NSDictionary *)element)[@"button_for"]isEqual:@42],@"only exact target close button receives one modeled press");closePresses++;return kAXErrorSuccess;
}
@interface DiscoveryApplication : NSObject
@property(readonly) NSApplicationActivationPolicy activationPolicy;
@property(readonly) NSString *bundleIdentifier,*localizedName;
+ (instancetype)runningApplicationWithProcessIdentifier:(pid_t)pid;
@end
@implementation DiscoveryApplication
+ (instancetype)runningApplicationWithProcessIdentifier:(pid_t)pid { check(pid==123,@"only modeled application metadata is read");return [self new]; }
- (NSApplicationActivationPolicy)activationPolicy { return NSApplicationActivationPolicyRegular; }
- (NSString *)bundleIdentifier { return @"fixture.discovery"; }
- (NSString *)localizedName { return @"Discovery fixture"; }
@end
@interface DiscoveryWorkspace : NSObject
+ (instancetype)sharedWorkspace;
- (NSURL *)URLForApplicationWithBundleIdentifier:(NSString *)identifier;
- (void)openApplicationAtURL:(NSURL *)url configuration:(NSWorkspaceOpenConfiguration *)configuration completionHandler:(void (^)(DiscoveryApplication *,NSError *))completion;
@end
@implementation DiscoveryWorkspace
+ (instancetype)sharedWorkspace { check(NO,@"no workspace or application launch is requested");return nil; }
- (NSURL *)URLForApplicationWithBundleIdentifier:(NSString *)identifier { (void)identifier;return nil; }
- (void)openApplicationAtURL:(NSURL *)url configuration:(NSWorkspaceOpenConfiguration *)configuration completionHandler:(void (^)(DiscoveryApplication *,NSError *))completion { (void)url;(void)configuration;(void)completion;check(NO,@"no application is launched"); }
@end
@interface DiscoveryProcessInfo : NSObject
+ (instancetype)processInfo;
@property(readonly) NSTimeInterval systemUptime;
@end
@implementation DiscoveryProcessInfo
+ (instancetype)processInfo { return [self new]; }
- (NSTimeInterval)systemUptime { return fixtureNow; }
@end
@interface DiscoveryEvents : NSObject
- (instancetype)initWithSink:(id<DWWindowEventSink>)sink scope:(NSDictionary *)scope;
@property(readonly) BOOL live;
- (void)reconcile;
- (void)stop;
@end
@implementation DiscoveryEvents
- (instancetype)initWithSink:(id<DWWindowEventSink>)sink scope:(NSDictionary *)scope { (void)sink;(void)scope;return [super init]; }
- (BOOL)live { return YES; }
- (void)reconcile {}
- (void)stop {}
@end

#define AXUIElementCreateApplication closeApplication
#define AXUIElementSetMessagingTimeout closeTimeout
#define AXUIElementGetPid closePid
#define AXUIElementGetTypeID CFDictionaryGetTypeID
#define AXUIElementCopyAttributeValue closeCopy
#define AXUIElementPerformAction closePress
#define dlsym closeSymbol
#define CGWindowListCopyWindowInfo fixtureWindowList
#define proc_pidinfo fixtureProcessInfo
#define dispatch_async fixtureAsync
#define AXIsProcessTrusted fixtureTrusted
#define CGPreflightScreenCaptureAccess fixtureCaptureAccess
#define NSRunningApplication DiscoveryApplication
#define NSWorkspace DiscoveryWorkspace
#define NSProcessInfo DiscoveryProcessInfo
#define DWWindowEvents DiscoveryEvents
#define CACurrentMediaTime fixtureTime
#import "window-manager.m"
#undef AXUIElementCreateApplication
#undef AXUIElementSetMessagingTimeout
#undef AXUIElementGetPid
#undef AXUIElementGetTypeID
#undef AXUIElementCopyAttributeValue
#undef AXUIElementPerformAction
#undef dlsym
#undef DWWindowEvents
#undef NSProcessInfo
#undef NSWorkspace
#undef NSRunningApplication
#define NSRunningApplication DiscoveryApplication
#import "window-observer.m"
#undef proc_pidinfo
#undef NSRunningApplication
#undef CGWindowListCopyWindowInfo
#undef CACurrentMediaTime
#undef CGPreflightScreenCaptureAccess
#undef AXIsProcessTrusted
#undef dispatch_async

// Startup admission uses a private notification center and substituted public
// queries; no host session/display or NSWorkspace singleton is inspected.
static NSDictionary *sessionValues;
static NSUInteger sessionQueries;
static uint32_t sessionDisplayCount=1;
static CGError sessionDisplayError;
static BOOL sessionDisplayAwake,sessionDisplayActive=YES;
static CFDictionaryRef sessionCopy(void) { sessionQueries++;return sessionValues?CFBridgingRetain(sessionValues):NULL; }
static CGError sessionDisplays(uint32_t capacity,CGDirectDisplayID *ids,uint32_t *count) {
    check(capacity==32,@"session display query has a fixed bounded capacity");*count=sessionDisplayCount;if(capacity)ids[0]=1;return sessionDisplayError;
}
static CGDirectDisplayID sessionMain(void) { return 1; }
static boolean_t sessionOnline(CGDirectDisplayID display) { return display==1; }
static boolean_t sessionActive(CGDirectDisplayID display) { return display==1&&sessionDisplayActive; }
static boolean_t sessionAsleep(CGDirectDisplayID display) { return display!=1||!sessionDisplayAwake; }
@interface SessionWorkspace : NSObject
@property NSNotificationCenter *notificationCenter;
+ (instancetype)sharedWorkspace;
@end
@implementation SessionWorkspace
+ (instancetype)sharedWorkspace { static SessionWorkspace *workspace;if(!workspace){workspace=[self new];workspace.notificationCenter=[NSNotificationCenter new];}return workspace; }
@end
#define NSWorkspace SessionWorkspace
#define CGSessionCopyCurrentDictionary sessionCopy
#define CGGetOnlineDisplayList sessionDisplays
#define CGMainDisplayID sessionMain
#define CGDisplayIsOnline sessionOnline
#define CGDisplayIsActive sessionActive
#define CGDisplayIsAsleep sessionAsleep
#define CACurrentMediaTime fixtureTime
#import "session-watch.m"
#undef NSWorkspace
#undef CGSessionCopyCurrentDictionary
#undef CGGetOnlineDisplayList
#undef CGMainDisplayID
#undef CGDisplayIsOnline
#undef CGDisplayIsActive
#undef CGDisplayIsAsleep
#undef CACurrentMediaTime
static void sessionAdmission(void) {
    fixtureNow=1000;sessionValues=@{(__bridge NSString *)kCGSessionOnConsoleKey:@YES,(__bridge NSString *)kCGSessionLoginDoneKey:@YES};
    __block NSUInteger returns=0,leaves=0;
    DWSessionWatch *watch=[[DWSessionWatch alloc]initWithReturned:^{returns++;} left:^{leaves++;}];
    check(!watch.ready&&!returns&&!leaves,@"already asleep startup is blocked synchronously without departure/save callbacks");
    NSUInteger queries=sessionQueries;for(int i=0;i<10;i++)[watch poll];
    check(sessionQueries==queries,@"inactive admission does not query at idle-poll frequency");
    sessionDisplayAwake=YES;fixtureNow+=.5;[watch poll];
    check(watch.ready&&returns==1&&!leaves,@"missed prelaunch sleep notification recovers once current display becomes awake");
    queries=sessionQueries;fixtureNow+=5;[watch poll];check(sessionQueries==queries,@"active session has no polling query loop");
    NSNotificationCenter *center=SessionWorkspace.sharedWorkspace.notificationCenter;
    [center postNotificationName:NSWorkspaceWillSleepNotification object:nil];
    [center postNotificationName:NSWorkspaceScreensDidSleepNotification object:nil];
    [center postNotificationName:NSWorkspaceActiveSpaceDidChangeNotification object:nil];
    check(!watch.ready&&leaves==1&&returns==1,@"Space changes cannot release either notification-held departure");
    [center postNotificationName:NSWorkspaceDidWakeNotification object:nil];
    check(!watch.ready&&returns==1,@"system wake alone leaves display-sleep hold intact");
    sessionDisplayAwake=NO;[center postNotificationName:NSWorkspaceScreensDidWakeNotification object:nil];
    check(!watch.ready&&returns==1,@"early final wake notification does not override an asleep current display");
    queries=sessionQueries;sessionDisplayAwake=YES;fixtureNow+=.49;[watch poll];check(sessionQueries==queries,@"early-wake retry keeps its half-second budget");
    fixtureNow+=.02;[watch poll];check(watch.ready&&returns==2,@"wake readiness is retried without requiring another notification");
    [center postNotificationName:NSWorkspaceSessionDidResignActiveNotification object:nil];
    sessionValues=@{(__bridge NSString *)kCGSessionOnConsoleKey:@YES,(__bridge NSString *)kCGSessionLoginDoneKey:@YES,@"CGSSessionScreenIsLocked":@YES};
    [center postNotificationName:NSWorkspaceSessionDidBecomeActiveNotification object:nil];check(!watch.ready&&leaves==2,@"known locked state blocks a session-return hint");
    sessionValues=@{(__bridge NSString *)kCGSessionOnConsoleKey:@1,(__bridge NSString *)kCGSessionLoginDoneKey:@YES};fixtureNow+=.5;[watch poll];
    check(!watch.ready,@"malformed documented session boolean is not coerced into admission");
    sessionValues=nil;fixtureNow+=.5;[watch poll];check(!watch.ready,@"unavailable current session remains blocked");
    sessionValues=@{(__bridge NSString *)kCGSessionOnConsoleKey:@YES,(__bridge NSString *)kCGSessionLoginDoneKey:@YES};
    sessionDisplayCount=32;fixtureNow+=.5;[watch poll];check(!watch.ready,@"saturated display inventory cannot authorize admission");
    sessionDisplayCount=1;sessionDisplayActive=NO;fixtureNow+=.5;[watch poll];check(!watch.ready,@"awake but inactive main display remains blocked");
    sessionDisplayActive=YES;fixtureNow+=.5;[watch poll];check(watch.ready&&returns==3,@"public readiness with unknown optional lock metadata recovers without asserting unlocked");
    [watch stop];queries=sessionQueries;fixtureNow+=1;[watch poll];[center postNotificationName:NSWorkspaceActiveSpaceDidChangeNotification object:nil];
    check(!watch.ready&&sessionQueries==queries&&returns==3&&leaves==2,@"stop removes callbacks and pending retry authority");
}

BOOL DWInScope(NSDictionary *scope,pid_t pid) { return !scope||[scope[@(pid)]isEqual:@[@100,@20]]; }
bool dw_focus_owner(DWFocusIdentity identity,CGRect *bounds) {
    (void)bounds;check(closeTesting&&identity.pid==123&&identity.window==42&&identity.seconds==100&&identity.microseconds==20,@"close revalidates exact process birth/window identity");
    closeOwnerReads++;return closeOwnerReads!=closeOwnerFailsAt;
}
bool DWNativeBounds(uint32_t window,CGRect *bounds) { check(inWorker&&window==42,@"bound-source native bounds stay on the worker");*bounds=CGRectMake(100,100,320,232);return true; }
NSDictionary *DWNativeWindowFamily(NSDictionary *identity,NSString *__autoreleasing *why) {
    (void)why;check(inWorker&&[identity[@"wid"]isEqual:@42],@"family audit belongs to the bound source's worker");
    if(deliverDiscoveryDuringFamily){check(mainBlocks.count==1,@"discovery is queued before existing-family audit completes");check(step(NO),@"main can receive discovery while the family worker is still in flight");fixtureNow+=.2;}
    return @{@"identity":identity,@"root":@42,@"members":@[]};
}
static BOOL step(BOOL worker) {
    NSMutableArray *blocks=worker?workerBlocks:mainBlocks;if(!blocks.count)return NO;
    dispatch_block_t block=blocks.firstObject;[blocks removeObjectAtIndex:0];BOOL previous=inWorker;inWorker=worker;block();inWorker=previous;return YES;
}
static void drain(void) { NSUInteger turns=0;while(mainBlocks.count||workerBlocks.count){check(++turns<20,@"discovery work is bounded");if(!step(NO))step(YES);} }
static NSDictionary *candidateBases(NSArray<NSDictionary *> *rows) {
    NSMutableDictionary *bases=[NSMutableDictionary dictionary];for(NSDictionary *row in rows){NSNumber *wid=row[(id)kCGWindowNumber];
        bases[wid]=@{@"identity":@{@"pid":@123,@"wid":wid,@"birth_sec":@100,@"birth_usec":@20},@"native_bounds":row[(id)kCGWindowBounds],@"transform":@[@1,@0,@0,@1,@(-100),@(-100)]};
    }return bases.copy;
}
NSDictionary *DWNativeWindowDiscoveryBasis(NSDictionary *identity) {
    check(inWorker,@"native candidate basis is read only on the worker");candidateBasisReads++;return (candidateBasisOverride?:candidateBases(windowRows))[identity[@"wid"]];
}
static NSDictionary *row(uint32_t window,CGFloat width) {
    return @{(id)kCGWindowNumber:@(window),(id)kCGWindowOwnerPID:@123,(id)kCGWindowLayer:@0,(id)kCGWindowName:@"Discovery window",
        (id)kCGWindowBounds:CFBridgingRelease(CGRectCreateDictionaryRepresentation(CGRectMake(100,100,width,232)))};
}
@interface DiscoveryHost : NSObject <DWWindowHost>
@property NSUInteger requested,appeared,completed,failed,moved,changed;
@property NSArray<NSDictionary *> *present;
@property NSMutableArray<NSString *> *titles;
@property NSSet<NSNumber *> *managed;
@end
@implementation DiscoveryHost
- (BOOL)managesWindow:(CGWindowID)window pid:(pid_t)pid { (void)pid;return [self.managed containsObject:@(window)]; }
- (void)windowAppeared:(DWWindowCandidate *)window { check(window.pid==123&&window.frame.size.width>=320,@"the candidate retains its actual metadata");self.appeared++;if(!self.titles)self.titles=[NSMutableArray array];[self.titles addObject:window.title?:@"<unknown>"]; }
- (void)discoveryCompleted:(NSArray *)present { self.present=[present copy];self.completed++; }
- (void)discoveryFailed:(NSString *)reason { check(reason.length>0,@"metadata failure retains its reason");self.failed++; }
- (void)windowMoved:(CGWindowID)window pid:(pid_t)pid { check(window==42&&pid==123,@"move forwarding retains exact event target");self.moved++; }
- (void)windowChanged:(CGWindowID)window pid:(pid_t)pid { (void)window;(void)pid;self.changed++; }
- (void)windowDestroyed:(CGWindowID)window pid:(pid_t)pid { (void)window;(void)pid; }
- (void)focusChanged {}
- (void)windowDiscoveryRequested { self.requested++; }
@end
static void titleRetryInvalidation(void) {
    NSMutableDictionary *unknown=[row(74,320)mutableCopy];[unknown removeObjectForKey:(id)kCGWindowName];NSArray *rows=@[unknown];
    for(NSString *mode in @[@"event",@"basis",@"appearance",@"deadline"]){
        fixtureNow=120;DiscoveryHost *host=[DiscoveryHost new];DWWindowManager *manager=[DWWindowManager managerWithHost:host scope:nil mode:DWWindowDiscoveryModeNativePresentation];
        NSDictionary *basis=candidateBases(rows);
        [manager pollWithWindowRecords:rows nativeCandidateBases:basis sampledAt:fixtureTime()];fixtureNow=120.051;
        [manager pollWithWindowRecords:rows nativeCandidateBases:basis sampledAt:fixtureTime()];drain();
        check(!host.appeared&&!host.completed, @"unknown candidate retains its own retry before invalidation");
        fixtureNow=120.06;
        if([mode isEqual:@"event"]){
            [manager windowChanged:74 pid:124];[manager pollWithWindowRecords:rows nativeCandidateBases:basis sampledAt:fixtureTime()];
            check(!workerBlocks.count,@"another PID cannot clear this candidate's title retry");
            [manager windowChanged:74 pid:123];
        }else if([mode isEqual:@"basis"]){
            NSMutableDictionary *changed=[basis[@74]mutableCopy];changed[@"identity"]=@{@"pid":@123,@"wid":@74,@"birth_sec":@101,@"birth_usec":@20};basis=@{@74:changed};
            [manager pollWithWindowRecords:rows nativeCandidateBases:basis sampledAt:fixtureTime()];
            check(!workerBlocks.count,@"a changed exact process basis still owes the ordinary stability hold");fixtureNow=120.111;
        }else if([mode isEqual:@"appearance"]){
            [manager pollWithWindowRecords:@[] nativeCandidateBases:@{} sampledAt:fixtureTime()];drain();fixtureNow=120.07;
            [manager pollWithWindowRecords:rows nativeCandidateBases:basis sampledAt:fixtureTime()];
            check(!workerBlocks.count,@"a new appearance still owes the ordinary stability hold");fixtureNow=120.121;
        }else {
            fixtureNow=122.052;[manager.discoveryTimer fire];[manager pollWithWindowRecords:rows nativeCandidateBases:basis sampledAt:fixtureTime()];
            check(!workerBlocks.count,@"retry deadline cannot reuse aged native stability evidence");fixtureNow=122.103;
        }
        [manager pollWithWindowRecords:rows nativeCandidateBases:basis sampledAt:fixtureTime()];
        check(workerBlocks.count==1,[NSString stringWithFormat:@"title retry %@ permits a fresh bounded read",mode]);
        titleTesting=YES;closeElements=@[@{@"pid":@123,@"wid":@74,@"subrole":(__bridge NSString *)kAXStandardWindowSubrole,@"title":@"Ready title"}];drain();titleTesting=NO;closeElements=nil;
        check(host.appeared==1&&[host.titles isEqual:@[@"Ready title"]],@"retry admits only the newly read real title");[manager stop];
    }
    for(NSString *mode in @[@"event",@"cg"]){
        fixtureNow=125;DiscoveryHost *host=[DiscoveryHost new];DWWindowManager *manager=[DWWindowManager managerWithHost:host scope:nil mode:DWWindowDiscoveryModeNativePresentation];
        [manager pollWithWindowRecords:rows nativeCandidateBases:candidateBases(rows) sampledAt:fixtureTime()];fixtureNow=125.051;
        [manager pollWithWindowRecords:rows nativeCandidateBases:candidateBases(rows) sampledAt:fixtureTime()];check(step(YES),@"unknown title reply can wait on main while a fresh hint arrives");
        fixtureNow=125.06;NSMutableDictionary *named=[unknown mutableCopy];named[(id)kCGWindowName]=@"Fresh title";
        NSArray *fresh=[mode isEqual:@"cg"]?@[named]:rows;
        if([mode isEqual:@"event"])[manager windowChanged:74 pid:123];
        [manager pollWithWindowRecords:fresh nativeCandidateBases:candidateBases(fresh) sampledAt:fixtureTime()];drain();
        fixtureNow=125.07;[manager pollWithWindowRecords:fresh nativeCandidateBases:candidateBases(fresh) sampledAt:fixtureTime()];
        check(workerBlocks.count==1,[NSString stringWithFormat:@"old nil-title reply cannot reinstate backoff after a fresh %@ hint",mode]);
        drain();[manager stop];
    }
}
static void nativeMetadataOverlap(void) {
    titleTesting=YES;
    for(NSString *mode in @[@"ready",@"empty",@"missing",@"role",@"basis",@"appearance",@"event",@"cg",@"stale",@"stop"]){
        fixtureNow=500;DiscoveryHost *host=[DiscoveryHost new];DWWindowManager *manager=[DWWindowManager managerWithHost:host scope:nil mode:DWWindowDiscoveryModeNativePresentation];manager.completed=YES;
        NSArray *rows=@[row(88,320)];NSDictionary *bases=candidateBases(rows);
        NSMutableDictionary *element=[@{@"pid":@123,@"wid":@88,@"subrole":(__bridge NSString *)kAXStandardWindowSubrole,@"title":[mode isEqual:@"empty"]?@"":@"Prefetched AX title"}mutableCopy];
        if([mode isEqual:@"missing"])[element removeObjectForKey:@"title"];
        if([mode isEqual:@"role"])element[@"subrole"]=@"AXUnknown";
        closeElements=@[element.copy];
        [manager pollWithWindowRecords:rows nativeCandidateBases:bases sampledAt:fixtureTime()];
        check(workerBlocks.count==1&&!host.appeared,@"native AX metadata starts inside the 50 ms hold without offering the window");
        check(step(YES)&&mainBlocks.count==1&&!host.appeared,@"early AX result remains an asynchronous read-only selection");
        fixtureNow=500.02;
        if([mode isEqual:@"basis"]){rows=@[row(88,340)];bases=candidateBases(rows);[manager pollWithWindowRecords:rows nativeCandidateBases:bases sampledAt:fixtureTime()];}
        if([mode isEqual:@"appearance"]){[manager pollWithWindowRecords:@[] nativeCandidateBases:@{} sampledAt:fixtureTime()];[manager pollWithWindowRecords:rows nativeCandidateBases:bases sampledAt:fixtureTime()];}
        if([mode isEqual:@"event"])[manager windowChanged:88 pid:123];
        if([mode isEqual:@"cg"]){NSMutableDictionary *named=[rows[0]mutableCopy];named[(id)kCGWindowName]=@"Changed CG title";rows=@[named];[manager pollWithWindowRecords:rows nativeCandidateBases:bases sampledAt:fixtureTime()];}
        if([mode isEqual:@"stale"]){fixtureNow=500.051;[manager pollWithWindowRecords:rows nativeCandidateBases:bases sampledAt:fixtureTime()];fixtureNow=500.101;}
        if([mode isEqual:@"stop"])[manager stop];
        drain();check(!host.appeared,@"AX completion alone never substitutes for the fresh stable geometry pass");
        if([mode isEqual:@"stop"]){check(!manager.discoveryTimer&&!host.requested,@"stopped prefetch cannot schedule or offer a candidate");continue;}
        BOOL cached=[mode isEqual:@"ready"]||[mode isEqual:@"empty"];
        closeElements=@[@{@"pid":@123,@"wid":@88,@"subrole":(__bridge NSString *)kAXStandardWindowSubrole,@"title":@"Fresh AX title"}];
        fixtureNow=[mode isEqual:@"stale"]?500.11:([mode isEqual:@"basis"]||[mode isEqual:@"appearance"]?500.071:500.051);
        [manager.discoveryTimer fire];check(!host.appeared,@"stability timer requests observation without adopting old geometry");
        [manager pollWithWindowRecords:rows nativeCandidateBases:bases sampledAt:fixtureTime()];
        check(cached?(host.appeared==1&&!workerBlocks.count):(!host.appeared&&workerBlocks.count==1),
            [NSString stringWithFormat:@"prefetch %@ %@",mode,cached?@"eliminates the serial AX read after stability":@"requires fresh ordinary AX selection"]);
        drain();NSString *expected=cached?([mode isEqual:@"empty"]?@"":@"Prefetched AX title"):@"Fresh AX title";
        check(host.appeared==1&&[host.titles isEqual:@[expected]],@"only current positive metadata preserves AX title precedence and empty-title meaning");[manager stop];
    }
    titleTesting=NO;closeElements=nil;
}
static void nativeEarlyAdmission(void) {
    NSArray *savedRows=windowRows;titleTesting=YES;
    for(NSString *mode in @[@"ready",@"empty",@"startup",@"dialog",@"missing",@"matrix",@"post_size",@"post_birth",@"event",@"move",@"family",@"space",@"appearance",@"stale",@"stop"]){
        fixtureNow=600;DiscoveryHost *host=[DiscoveryHost new];DWWindowManager *manager=[DWWindowManager managerWithHost:host scope:nil mode:DWWindowDiscoveryModeNativePresentation];manager.completed=![mode isEqual:@"startup"];
        windowRows=@[row(42,320)];NSMutableDictionary *bases=[candidateBases(windowRows)mutableCopy];
        NSMutableDictionary *element=[@{@"pid":@123,@"wid":@42,@"subrole":[mode isEqual:@"dialog"]?(__bridge NSString *)kAXDialogSubrole:(__bridge NSString *)kAXStandardWindowSubrole,@"title":[mode isEqual:@"empty"]?@"":@"Early AX title"}mutableCopy];
        if([mode isEqual:@"missing"])[element removeObjectForKey:@"title"];
        if([mode isEqual:@"matrix"]){NSMutableDictionary *basis=[bases[@42]mutableCopy];basis[@"transform"]=@[@1.001,@0,@0,@1,@(-100),@(-100)];bases[@42]=basis;}
        candidateBasisOverride=bases.copy;closeElements=@[element.copy];
        [manager pollWithWindowRecords:windowRows nativeCandidateBases:bases sampledAt:fixtureTime()];
        check(workerBlocks.count==1&&!host.appeared,@"early admission still waits for positive asynchronous AX metadata");
        if([mode isEqual:@"post_size"])candidateBasisOverride=candidateBases(@[row(42,340)]);
        if([mode isEqual:@"post_birth"]){NSMutableDictionary *basis=[bases[@42]mutableCopy];basis[@"identity"]=@{@"pid":@123,@"wid":@42,@"birth_sec":@101,@"birth_usec":@20};candidateBasisOverride=@{@42:basis};}
        fixtureNow=600.01;check(step(YES),@"early admission revalidates only on its metadata worker");fixtureNow=600.02;
        if([mode isEqual:@"event"])[manager windowChanged:42 pid:123];
        if([mode isEqual:@"move"])[manager windowMoved:42 pid:123];
        if([mode isEqual:@"family"])[manager windowsChanged:123];
        if([mode isEqual:@"space"])[manager windowsChanged:0];
        if([mode isEqual:@"appearance"]){[manager pollWithWindowRecords:@[] nativeCandidateBases:@{} sampledAt:fixtureTime()];[manager pollWithWindowRecords:windowRows nativeCandidateBases:bases sampledAt:fixtureTime()];}
        if([mode isEqual:@"stale"])fixtureNow=600.101;
        if([mode isEqual:@"stop"])[manager stop];
        drain();BOOL early=[mode isEqual:@"ready"]||[mode isEqual:@"empty"];
        check(host.appeared==(early?1u:0u),[NSString stringWithFormat:@"early %@ admits only fresh unchanged canonical standard windows before 50 ms",mode]);
        if(early){check([host.titles isEqual:@[[mode isEqual:@"empty"]?@"":@"Early AX title"]],@"early admission retains AX title precedence and known empty titles");
            fixtureNow=600.051;[manager pollWithWindowRecords:windowRows nativeCandidateBases:bases sampledAt:fixtureTime()];drain();check(host.appeared==1,@"ordinary follow-up cannot offer an early window twice");}
        else if(![mode isEqual:@"stop"]){
            candidateBasisOverride=bases.copy;closeElements=@[@{@"pid":@123,@"wid":@42,@"subrole":(__bridge NSString *)kAXStandardWindowSubrole,@"title":@"Ordinary AX title"}];
            fixtureNow=[mode isEqual:@"stale"]?600.11:600.071;[manager pollWithWindowRecords:windowRows nativeCandidateBases:bases sampledAt:fixtureTime()];drain();
            if([mode isEqual:@"stale"]){fixtureNow=600.161;[manager pollWithWindowRecords:windowRows nativeCandidateBases:bases sampledAt:fixtureTime()];drain();}
            check(host.appeared==1,[NSString stringWithFormat:@"early %@ refusal retains the ordinary stable admission path",mode]);
        }
        [manager stop];candidateBasisOverride=nil;
    }
    windowRows=savedRows;titleTesting=NO;closeElements=nil;
}
int main(void) {@autoreleasepool {
    mainBlocks=[NSMutableArray array];workerBlocks=[NSMutableArray array];windowRows=@[row(42,320)];allWindowRows=@[];
    DiscoveryHost *host=[DiscoveryHost new];DWWindowManager *manager=[DWWindowManager managerWithHost:host scope:nil mode:DWWindowDiscoveryModeNativePresentation];
    [manager windowMoved:42 pid:123];[manager windowChanged:42 pid:123];
    check(host.moved==1&&host.changed==1,@"manager forwards pure move separately without weakening generic invalidation");
    [manager pollWithWindowRecords:windowRows nativeCandidateBases:candidateBases(windowRows) sampledAt:fixtureTime()];NSTimer *first=manager.discoveryTimer;
    check(first&&fabs(manager.discoveryDeadline-100.05)<1e-9&&!host.appeared,@"first geometry observation schedules the existing exact 50 ms hold");
    fixtureNow=100.02;[manager pollWithWindowRecords:windowRows nativeCandidateBases:candidateBases(windowRows) sampledAt:fixtureTime()];
    check(manager.discoveryTimer==first&&fabs(manager.discoveryDeadline-100.05)<1e-9,@"intervening polling keeps the earliest deadline and one timer");
    fixtureNow=100.051;[first fire];check(host.requested==1&&!manager.discoveryTimer&&!host.appeared,@"deadline requests a fresh worker read instead of adopting cached geometry");
    [manager pollWithWindowRecords:windowRows nativeCandidateBases:candidateBases(windowRows) sampledAt:fixtureTime()];check(!host.appeared&&workerBlocks.count==1,@"role/title selection remains asynchronous after the stability check");drain();
    check(host.appeared==1&&host.completed==1,@"stable candidate is offered without another idle-poll interval");
    fixtureNow=101;windowRows=@[row(42,320),row(43,320)];[manager pollWithWindowRecords:windowRows nativeCandidateBases:candidateBases(windowRows) sampledAt:fixtureTime()];
    fixtureNow=101.02;windowRows=@[row(42,320),row(43,340)];[manager pollWithWindowRecords:windowRows nativeCandidateBases:candidateBases(windowRows) sampledAt:fixtureTime()];
    fixtureNow=101.051;[manager.discoveryTimer fire];[manager pollWithWindowRecords:windowRows nativeCandidateBases:candidateBases(windowRows) sampledAt:fixtureTime()];
    check(host.appeared==1&&fabs(manager.discoveryDeadline-101.07)<1e-9,@"a changed candidate still requires 50 ms at its new bounds");
    fixtureNow=101.071;[manager.discoveryTimer fire];[manager pollWithWindowRecords:windowRows nativeCandidateBases:candidateBases(windowRows) sampledAt:fixtureTime()];drain();check(host.appeared==2,@"fresh stable replacement geometry is eventually offered");
    fixtureNow=102;windowRows=@[row(42,320),row(43,340),row(45,320)];[manager pollWithWindowRecords:windowRows nativeCandidateBases:candidateBases(windowRows) sampledAt:fixtureTime()];
    fixtureNow=102.051;[manager.discoveryTimer fire];[manager pollWithWindowRecords:windowRows nativeCandidateBases:candidateBases(windowRows) sampledAt:fixtureTime()];check(workerBlocks.count==1,@"candidate role/title read is in flight");
    fixtureNow=102.061;windowRows=@[row(42,320),row(43,340),row(45,340)];[manager pollWithWindowRecords:windowRows nativeCandidateBases:candidateBases(windowRows) sampledAt:fixtureTime()];drain();
    check(host.appeared==2&&![manager.offered containsObject:@45],@"new metadata changing geometry invalidates the outstanding candidate selection");
    fixtureNow=102.112;[manager.discoveryTimer fire];[manager pollWithWindowRecords:windowRows nativeCandidateBases:candidateBases(windowRows) sampledAt:fixtureTime()];drain();check(host.appeared==3,@"changed bounds require their own fresh stable selection");
    fixtureNow=103;windowRows=@[row(42,320),row(43,340),row(45,340),row(46,320)];[manager pollWithWindowRecords:windowRows nativeCandidateBases:candidateBases(windowRows) sampledAt:fixtureTime()];
    fixtureNow=103.051;[manager.discoveryTimer fire];[manager pollWithWindowRecords:windowRows nativeCandidateBases:candidateBases(windowRows) sampledAt:fixtureTime()];
    fixtureNow=103.061;windowRows=@[row(42,320),row(43,340),row(45,340)];[manager pollWithWindowRecords:windowRows nativeCandidateBases:candidateBases(windowRows) sampledAt:fixtureTime()];drain();
    check(host.appeared==3&&![manager.offered containsObject:@46],@"candidate disappearing during role/title read is never offered");
    fixtureNow=104;windowRows=@[row(42,320),row(43,340),row(45,340),row(44,320)];[manager pollWithWindowRecords:windowRows nativeCandidateBases:candidateBases(windowRows) sampledAt:fixtureTime()];NSTimer *cancelled=manager.discoveryTimer;NSUInteger requested=host.requested;[manager stop];[cancelled fire];
    check(!manager.discoveryTimer&&host.requested==requested,@"stop invalidates pending candidate timers and callbacks");
    [manager windowMoved:42 pid:123];[manager windowChanged:42 pid:123];
    check(host.moved==1&&host.changed==1,@"stopped manager cannot forward either event kind");

    // Missing title metadata must not consume a saved slot as literal Untitled.
    // A later exact CG title or successful AX title permits the normal adoption.
    DiscoveryHost *titleHost=[DiscoveryHost new];DWWindowManager *titleManager=[DWWindowManager managerWithHost:titleHost scope:nil mode:DWWindowDiscoveryModeNativePresentation];
    NSMutableDictionary *untitled=[row(74,320)mutableCopy];[untitled removeObjectForKey:(id)kCGWindowName];NSArray *titleRows=@[untitled];
    fixtureNow=110;[titleManager pollWithWindowRecords:titleRows nativeCandidateBases:candidateBases(titleRows) sampledAt:fixtureTime()];
    fixtureNow=110.051;[titleManager pollWithWindowRecords:titleRows nativeCandidateBases:candidateBases(titleRows) sampledAt:fixtureTime()];drain();
    check(!titleHost.appeared&&!titleHost.completed&&![titleManager.offeredWindows containsObject:@74],@"unknown native title is retried before offering or completing saved-slot adoption");
    fixtureNow=110.1;[titleManager pollWithWindowRecords:titleRows nativeCandidateBases:candidateBases(titleRows) sampledAt:fixtureTime()];
    check(!workerBlocks.count,@"unknown title uses existing bounded retry instead of an AX polling loop");
    titleRows=@[untitled,row(75,320)];fixtureNow=110.11;
    [titleManager pollWithWindowRecords:titleRows nativeCandidateBases:candidateBases(titleRows) sampledAt:fixtureTime()];
    fixtureNow=110.161;[titleManager pollWithWindowRecords:titleRows nativeCandidateBases:candidateBases(titleRows) sampledAt:fixtureTime()];drain();
    check(titleHost.appeared==1&&[titleHost.titles isEqual:@[@"Discovery window"]]&&!titleHost.completed,@"one unknown title cannot delay a newly stable named window or prematurely complete startup");
    fixtureNow=110.17;[titleManager pollWithWindowRecords:titleRows nativeCandidateBases:candidateBases(titleRows) sampledAt:fixtureTime()];
    check(!workerBlocks.count&&!titleHost.completed,@"a pending title alone cannot spin empty startup-preservation reads");
    NSMutableDictionary *named=[untitled mutableCopy];named[(id)kCGWindowName]=@"Saved document";titleRows=@[named,row(75,320)];
    fixtureNow=110.18;[titleManager pollWithWindowRecords:titleRows nativeCandidateBases:candidateBases(titleRows) sampledAt:fixtureTime()];drain();
    check(titleHost.appeared==2&&[titleHost.titles isEqual:@[@"Discovery window",@"Saved document"]]&&titleHost.completed==1,@"fresh CG title clears only its own backoff before two seconds and preserves the real saved-slot name");[titleManager stop];
    titleTesting=YES;closeElements=@[@{@"pid":@123,@"wid":@75,@"subrole":(__bridge NSString *)kAXStandardWindowSubrole,@"title":@"Current AX title"},@{@"pid":@123,@"wid":@76,@"subrole":(__bridge NSString *)kAXStandardWindowSubrole,@"title":@""}];
    titleHost=[DiscoveryHost new];titleManager=[DWWindowManager managerWithHost:titleHost scope:nil mode:DWWindowDiscoveryModeNativePresentation];
    titleRows=@[row(75,320),row(76,320)];fixtureNow=115;[titleManager pollWithWindowRecords:titleRows nativeCandidateBases:candidateBases(titleRows) sampledAt:fixtureTime()];drain();
    fixtureNow=115.051;[titleManager pollWithWindowRecords:titleRows nativeCandidateBases:candidateBases(titleRows) sampledAt:fixtureTime()];drain();
    check(titleHost.appeared==2&&[titleHost.titles isEqual:@[@"",@"Current AX title"]],@"successful AX title overrides CG and known empty title remains distinct from unavailable");[titleManager stop];titleTesting=NO;closeElements=nil;
    titleRetryInvalidation();nativeMetadataOverlap();nativeEarlyAdmission();

    DiscoveryHost *nativeHost=[DiscoveryHost new];DWWindowManager *nativeManager=[DWWindowManager managerWithHost:nativeHost scope:nil mode:DWWindowDiscoveryModeNativePresentation];
    fixtureNow=150;NSArray *animated=@[row(72,604)];NSDictionary *stableOwn=candidateBases(@[row(72,610)]);
    [nativeManager pollWithWindowRecords:animated nativeCandidateBases:stableOwn sampledAt:fixtureTime()];fixtureNow=150.04;animated=@[row(72,612)];
    [nativeManager pollWithWindowRecords:animated nativeCandidateBases:stableOwn sampledAt:fixtureTime()];
    check(fabs(nativeManager.discoveryDeadline-150.05)<1e-9,@"owner CG opening animation does not restart a stable native bounds/transform hold");
    fixtureNow=150.051;[nativeManager.discoveryTimer fire];[nativeManager pollWithWindowRecords:animated nativeCandidateBases:stableOwn sampledAt:fixtureTime()];drain();
    check(nativeHost.appeared==1,@"fresh native basis permits adoption despite CG opening overshoot");
    fixtureNow=151;animated=@[row(72,612),row(73,640)];NSMutableDictionary *changedBasis=[candidateBases(animated)mutableCopy];
    [nativeManager pollWithWindowRecords:animated nativeCandidateBases:changedBasis sampledAt:fixtureTime()];fixtureNow=151.04;NSMutableDictionary *shifted=[changedBasis[@73]mutableCopy];shifted[@"transform"]=@[@1,@0,@0,@1,@(-101),@(-100)];changedBasis[@73]=shifted;
    [nativeManager pollWithWindowRecords:animated nativeCandidateBases:changedBasis sampledAt:fixtureTime()];fixtureNow=151.051;[nativeManager.discoveryTimer fire];[nativeManager pollWithWindowRecords:animated nativeCandidateBases:changedBasis sampledAt:fixtureTime()];
    check(nativeHost.appeared==1&&fabs(nativeManager.discoveryDeadline-151.09)<1e-9,@"changing owner affine basis restarts the unchanged 50 ms hold even at fixed native bounds");
    fixtureNow=151.091;[nativeManager.discoveryTimer fire];[nativeManager pollWithWindowRecords:animated nativeCandidateBases:changedBasis sampledAt:fixtureTime()];drain();check(nativeHost.appeared==2,@"the new owner transform must independently settle before adoption");
    fixtureNow=152;animated=@[row(72,612),row(73,640),row(75,640)];NSDictionary *slowBasis=candidateBases(animated);
    [nativeManager pollWithWindowRecords:animated nativeCandidateBases:slowBasis sampledAt:fixtureTime()];fixtureNow=152.051;[nativeManager.discoveryTimer fire];[nativeManager pollWithWindowRecords:animated nativeCandidateBases:slowBasis sampledAt:fixtureTime()];
    fixtureNow=152.152;drain();check(nativeHost.appeared==2&&![nativeManager.offered containsObject:@75]&&nativeManager.discoveryTimer,@"an async role result cannot adopt a native basis older than 100 ms");
    [nativeManager.discoveryTimer fire];[nativeManager pollWithWindowRecords:animated nativeCandidateBases:slowBasis sampledAt:fixtureTime()];
    check(nativeHost.appeared==2&&fabs(nativeManager.discoveryDeadline-152.202)<1e-9,@"a freshness gap restarts the hold from a new native observation");
    fixtureNow=152.203;[nativeManager.discoveryTimer fire];[nativeManager pollWithWindowRecords:animated nativeCandidateBases:slowBasis sampledAt:fixtureTime()];drain();check(nativeHost.appeared==3,@"fresh same-geometry native observations can recover from a late role reply");[nativeManager stop];
    DiscoveryHost *missingHost=[DiscoveryHost new];DWWindowManager *missing=[DWWindowManager managerWithHost:missingHost scope:nil mode:DWWindowDiscoveryModeNativePresentation];fixtureNow=160;
    [missing pollWithWindowRecords:@[row(74,640)] nativeCandidateBases:@{} sampledAt:fixtureTime()];
    check(missing.bounds[@74]!=nil&&missing.discoveryTimer&&!missingHost.appeared&&!missingHost.completed,@"a failed native getter retains actual CG presence and withholds startup adoption");[missing stop];

    fixtureNow=200;windowRows=@[row(42,320)];DWWindowObserver *observer=[DWWindowObserver new];__block DWWindowObservationSnapshot *metadata=nil,*complete=nil;
    NSArray *requests=@[@{@"logical":@7,@"generation":@1,@"identity":@{@"pid":@123,@"wid":@42,@"birth_sec":@100,@"birth_usec":@20},@"native_bounds":@YES,@"families":@YES}];
    deliverDiscoveryDuringFamily=YES;
    check([observer requestSources:requests scope:@{@123:@[@100,@20]} nativeDiscoveryExclusions:nil discovery:^(DWWindowObservationSnapshot *snapshot){
        check(!inWorker&&observer.inFlight&&snapshot.sources.count==0&&snapshot.orderedOnScreen.count==1,@"discovery callback has immutable list metadata and leaves the batch in flight");
        check(fixtureNow-snapshot.startedAt<.1,@"timely discovery is delivered before the modeled slow family audit");metadata=snapshot;
        check(![observer requestSources:requests scope:nil nativeDiscoveryExclusions:nil discovery:nil completion:^(DWWindowObservationSnapshot *ignored){(void)ignored;}],@"discovery cannot queue a second global worker while its source audit runs");
    } completion:^(DWWindowObservationSnapshot *snapshot){check(!inWorker&&!observer.inFlight,@"final source callback ends single flight on main");complete=snapshot;}],@"start one split discovery/source observation");
    drain();check(metadata&&complete&&metadata!=complete&&metadata.sources.count==0&&complete.sources.count==1,@"final source assembly never mutates the earlier discovery snapshot");
    check(fixtureNow-complete.startedAt>.1&&fixtureNow-metadata.deliveredAt>.1&&metadata.finishedAt==200,@"slow final sources retain their original age for the unchanged freshness rejection");
    deliverDiscoveryDuringFamily=NO;__block NSUInteger cancelledCallbacks=0;
    check([observer requestSources:@[] scope:nil nativeDiscoveryExclusions:nil discovery:^(DWWindowObservationSnapshot *snapshot){(void)snapshot;cancelledCallbacks++;} completion:^(DWWindowObservationSnapshot *snapshot){(void)snapshot;cancelledCallbacks++;}],@"start cancellable metadata-only observation");
    [observer cancel];drain();check(!cancelledCallbacks,@"cancel drops both discovery and source completions");
    DWWindowObserver *finalOnly=[DWWindowObserver new];__block NSUInteger finalCallbacks=0;
    check([finalOnly requestSources:@[] scope:nil nativeDiscoveryExclusions:nil discovery:nil completion:^(DWWindowObservationSnapshot *snapshot){check(snapshot.listSucceeded,@"final-only callback still receives the successful list");finalCallbacks++;}],@"observation explicitly supports no discovery callback");drain();check(finalCallbacks==1,@"discovery:nil produces one final callback");[finalOnly cancel];
    fixtureNow=210;windowRows=@[row(42,320),row(48,340)];DWWindowObserver *nativeCandidates=[DWWindowObserver new];NSUInteger reads=candidateBasisReads;
    check([nativeCandidates requestSources:requests scope:nil nativeDiscoveryExclusions:[NSSet set] discovery:^(DWWindowObservationSnapshot *snapshot){
        check(snapshot.nativeCandidateBases.count==1&&snapshot.nativeCandidateBases[@48]&&!snapshot.nativeCandidateBases[@42]&&snapshot.orderedOnScreen.count==2,
            @"explicit native mode probes unknown candidates only and preserves the CG discovery rows");
    } completion:^(DWWindowObservationSnapshot *snapshot){(void)snapshot;}],@"native candidate mode is explicit beside bound-source requests");drain();
    check(candidateBasisReads==reads+1,@"an already bound root incurs no redundant native candidate getters");[nativeCandidates cancel];
    allowOverlayPermissionRead=YES;DiscoveryHost *overlayHost=[DiscoveryHost new];DWWindowManager *overlay=[DWWindowManager managerWithHost:overlayHost scope:@{@123:@[@100,@20]} mode:DWWindowDiscoveryModeCaptureOverlay];allowOverlayPermissionRead=NO;
    fixtureNow=220;NSArray *overlayRows=@[row(82,610)];NSDictionary *irrelevantNative=candidateBases(@[row(82,999)]);
    [overlay pollWithWindowRecords:overlayRows nativeCandidateBases:irrelevantNative sampledAt:fixtureTime()];fixtureNow=220.04;overlayRows=@[row(82,620)];
    [overlay pollWithWindowRecords:overlayRows nativeCandidateBases:irrelevantNative sampledAt:fixtureTime()];fixtureNow=220.051;[overlay.discoveryTimer fire];[overlay pollWithWindowRecords:overlayRows nativeCandidateBases:irrelevantNative sampledAt:fixtureTime()];
    check(!overlay.capturing&&!overlayHost.appeared&&fabs(overlay.discoveryDeadline-220.09)<1e-9,@"scoped overlay without recording still waits on CG geometry and ignores native candidate bases");
    fixtureNow=220.091;[overlay.discoveryTimer fire];[overlay pollWithWindowRecords:overlayRows nativeCandidateBases:nil sampledAt:fixtureTime()];drain();
    check(overlayHost.appeared==1&&[overlay.bounds[@82][@"Width"]isEqual:@620],@"overlay adoption retains its actual CG rectangle");[overlay stop];
    // Startup names are preservation-only. These windows never enter the
    // on-screen stability/adoption path, even when titled and otherwise normal.
    fixtureNow=300;NSMutableDictionary *offscreen=[row(90,400)mutableCopy];offscreen[(id)kCGWindowName]=@"Saved document";offscreen[(id)kCGWindowIsOnscreen]=@NO;
    NSMutableDictionary *duplicate=[offscreen mutableCopy];duplicate[(id)kCGWindowNumber]=@91;
    NSMutableDictionary *unnamed=[offscreen mutableCopy];unnamed[(id)kCGWindowNumber]=@92;[unnamed removeObjectForKey:(id)kCGWindowName];
    allWindowRows=@[offscreen,duplicate,unnamed];allListReads=processReads=0;
    DiscoveryHost *savedHost=[DiscoveryHost new];DWWindowManager *saved=[DWWindowManager managerWithHost:savedHost scope:nil mode:DWWindowDiscoveryModeNativePresentation];
    [saved pollWithWindowRecords:@[] nativeCandidateBases:@{} sampledAt:fixtureTime()];drain();
    NSArray *names=@[@{@"bundle_id":@"fixture.discovery",@"title":@"Saved document"},@{@"bundle_id":@"fixture.discovery",@"title":@"Saved document"}];
    check(savedHost.completed==1&&[savedHost.present isEqual:names]&&!savedHost.appeared&&saved.offeredWindows.count==0,@"same-user offscreen windows preserve duplicate exact-title slots without adoption; unreadable titles are not invented");
    check(allListReads==2&&processReads==2,@"startup metadata rechecks list ownership and exact process birth");
    [saved pollWithWindowRecords:@[] nativeCandidateBases:@{} sampledAt:fixtureTime()];drain();check(allListReads==2,@"successful startup preservation is not repeated by ordinary polling");[saved stop];
    for(NSUInteger fault=1;fault<=5;fault++){
        processMode=fault<=3?fault:0;processReads=allListReads=0;allWindowRows=@[offscreen];secondAllWindowRows=fault==4?@[]:nil;
        NSDictionary *scope=fault==5?@{@123:@[@99,@20]}:nil;
        DiscoveryHost *refusedHost=[DiscoveryHost new];DWWindowManager *refused=[DWWindowManager managerWithHost:refusedHost scope:scope mode:DWWindowDiscoveryModeNativePresentation];
        [refused pollWithWindowRecords:@[] nativeCandidateBases:@{} sampledAt:fixtureTime()];drain();
        check(refusedHost.completed==1&&!refusedHost.present.count&&!refusedHost.appeared,@"other UID, changed/unknown process, disappeared WID or stale scoped birth never names or adopts a window");[refused stop];
    }
    processMode=0;processReads=allListReads=0;secondAllWindowRows=nil;allWindowRows=@[offscreen];
    DiscoveryHost *boundHost=[DiscoveryHost new];boundHost.managed=[NSSet setWithObject:@90];DWWindowManager *bound=[DWWindowManager managerWithHost:boundHost scope:nil mode:DWWindowDiscoveryModeNativePresentation];
    [bound pollWithWindowRecords:@[] nativeCandidateBases:@{} sampledAt:fixtureTime()];drain();check(boundHost.completed==1&&!boundHost.present.count,@"a slot already bound during startup is not held a second time");[bound stop];
    DiscoveryHost *retryHost=[DiscoveryHost new];DWWindowManager *retryManager=[DWWindowManager managerWithHost:retryHost scope:nil mode:DWWindowDiscoveryModeNativePresentation];allListAvailable=NO;allListReads=0;
    [retryManager pollWithWindowRecords:@[] nativeCandidateBases:@{} sampledAt:fixtureTime()];drain();check(retryHost.failed==1&&!retryHost.completed,@"failed all-window read does not turn unknown presence into empty saved-slot completion");
    fixtureNow=301;[retryManager pollWithWindowRecords:@[] nativeCandidateBases:@{} sampledAt:fixtureTime()];drain();check(allListReads==1,@"metadata retry is bounded and does not query capture permission");
    fixtureNow=302.01;allListAvailable=YES;allListReads=0;[retryManager pollWithWindowRecords:@[] nativeCandidateBases:@{} sampledAt:fixtureTime()];drain();
    check(retryHost.completed==1&&retryHost.present.count==1&&!retryHost.appeared,@"metadata-only retry recovers exact saved-slot presence");[retryManager stop];
    DiscoveryHost *stoppedHost=[DiscoveryHost new];DWWindowManager *stoppedManager=[DWWindowManager managerWithHost:stoppedHost scope:nil mode:DWWindowDiscoveryModeNativePresentation];
    [stoppedManager pollWithWindowRecords:@[] nativeCandidateBases:@{} sampledAt:fixtureTime()];step(YES);step(NO);check(stoppedManager.reading&&workerBlocks.count==1,@"preservation worker can outlive its initial on-screen pass");
    [stoppedManager stop];drain();check(!stoppedHost.completed&&!stoppedHost.failed&&!stoppedHost.appeared,@"stop discards pending saved-slot completion without native lifecycle changes");
    closeTesting=YES;NSDictionary *closeIdentity=@{@"pid":@123,@"wid":@42,@"birth_sec":@100,@"birth_usec":@20};
    NSDictionary *target=@{@"pid":@123,@"wid":@42,@"role":(id)kAXWindowRole};
    NSDictionary *desktop=@{@"pid":@123,@"role":(id)kAXScrollAreaRole,@"window_error":@(kAXErrorIllegalArgument)};
    for(NSArray *elements in @[@[target,desktop],@[desktop,target]]){
        closeElements=elements;closePresses=closeOwnerReads=closeOwnerFailsAt=0;
        check(DWCloseWindow(closeIdentity)==nil&&closePresses==1&&closeOwnerReads==3,@"Finder target closes once with verified windowless desktop before or after it");
    }
    NSArray *refused=@[
        @[target,desktop,target],
        @[target,@{@"pid":@124,@"role":(id)kAXScrollAreaRole,@"window_error":@(kAXErrorIllegalArgument)}],
        @[target,@{@"pid":@123,@"role":(id)kAXWindowRole,@"window_error":@(kAXErrorIllegalArgument)}],
        @[target,@{@"pid":@123,@"role":(id)kAXScrollAreaRole,@"window_error":@(kAXErrorCannotComplete)}],
        @[target,@{@"pid":@123,@"role":(id)kAXScrollAreaRole,@"role_error":@(kAXErrorCannotComplete),@"window_error":@(kAXErrorIllegalArgument)}],
        @[target,@{@"pid":@123,@"pid_error":@(kAXErrorCannotComplete),@"role":(id)kAXScrollAreaRole,@"window_error":@(kAXErrorIllegalArgument)}]
    ];
    for(NSArray *elements in refused){closeElements=elements;closePresses=closeOwnerReads=closeOwnerFailsAt=0;
        check(DWCloseWindow(closeIdentity)!=nil&&!closePresses,@"duplicate target or unknown/error/foreign desktop candidate refuses without press");}
    closeElements=@[target,desktop];closePresses=closeOwnerReads=0;closeOwnerFailsAt=3;
    check(DWCloseWindow(closeIdentity)!=nil&&!closePresses&&closeOwnerReads==3,@"identity change immediately before close retains no-mutation refusal");closeTesting=NO;
    sessionAdmission();
    printf("PASS: %lu discovery, session admission and close checks; no native mutation or live latency claim\n",(unsigned long)checks);
}return 0;}
