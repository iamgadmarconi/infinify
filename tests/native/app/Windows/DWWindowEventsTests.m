// SPDX-License-Identifier: GPL-3.0-or-later
// Production registry and KVO with substituted application catalog, kernel births,
// permissions and AX registration. No native windows, LaunchServices, AX or input.
#import <AppKit/AppKit.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>

static NSUInteger checks,metadataReads,catalogReads;
static BOOL inWorker,trusted=YES;
static NSMutableArray<dispatch_block_t> *mainBlocks,*workerBlocks;
static NSMutableDictionary<NSNumber *,NSArray<NSNumber *> *> *births;
static NSMutableDictionary<NSNumber *,NSNumber *> *birthReads;
static void check(BOOL condition,NSString *message) {
    checks++;if(!condition){fprintf(stderr,"FAIL: %s\n",message.UTF8String);exit(1);}
}
static void eventAsync(dispatch_queue_t queue,dispatch_block_t block) {
    NSMutableArray *blocks=queue==dispatch_get_main_queue()?mainBlocks:workerBlocks;
    @synchronized(blocks){[blocks addObject:[block copy]];}
}
static BOOL eventTrusted(void) { return trusted; }
static int eventKill(pid_t pid,int signal) { check(signal==0,@"only process liveness is requested");if(births[@(pid)])return 0;errno=ESRCH;return -1; }
static AXUIElementRef eventAXApplication(pid_t pid) { (void)pid;check(NO,@"headless regression must never create a native AX element");return NULL; }
// SkyLight's four symbols as DWWindowEvents.m looks them up: one main connection, each notification registered once, an owner
// connection for each window and a pid for each owner connection. A window or connection not in the tables is a failed call.
static NSUInteger windowServerRegistrations;
static uint32_t windowServerTypes[2];
static void (*windowServerProc)(uint32_t,void *,size_t,void *);
static NSMutableDictionary<NSNumber *,NSNumber *> *windowServerOwners,*windowServerPIDs;
static int fakeWindowServerConnection(void) { return 7; }
static int fakeWindowServerRegister(int connection,void (*proc)(uint32_t,void *,size_t,void *),uint32_t type,void *context) {
    check(connection==7&&!context&&windowServerRegistrations<2&&(type==1325||type==1326),@"each notification is registered once, on the main connection");
    windowServerTypes[windowServerRegistrations++]=type;windowServerProc=proc;return 0;
}
static CGError fakeWindowServerOwner(int connection,CGWindowID window,int *owner) {
    check(connection==7,@"owners are asked of the main connection");
    NSNumber *value=windowServerOwners[@(window)];if(!value)return kCGErrorFailure;*owner=value.intValue;return kCGErrorSuccess;
}
static CGError fakeWindowServerPID(int owner,pid_t *pid) {
    NSNumber *value=windowServerPIDs[@(owner)];if(!value)return kCGErrorFailure;*pid=value.intValue;return kCGErrorSuccess;
}
static void *fakeWindowServerSymbol(const char *name) {
    if(!strcmp(name,"SLSMainConnectionID"))return (void *)fakeWindowServerConnection;
    if(!strcmp(name,"SLSRegisterConnectionNotifyProc"))return (void *)fakeWindowServerRegister;
    if(!strcmp(name,"SLSGetWindowOwner"))return (void *)fakeWindowServerOwner;
    if(!strcmp(name,"SLSConnectionGetPID"))return (void *)fakeWindowServerPID;
    check(NO,@"only the four window-server symbols are looked up");return NULL;
}

@interface EventApplication : NSObject {
    pid_t _pid;
    NSApplicationActivationPolicy _policy;
    BOOL _terminated;
}
@property NSUInteger installed,removed;
@property NSString *applicationIdentity;
@property (readonly) pid_t processIdentifier;
@property (readonly) NSApplicationActivationPolicy activationPolicy;
@property (readonly,getter=isTerminated) BOOL terminated;
- (instancetype)initWithPID:(pid_t)pid policy:(NSApplicationActivationPolicy)policy;
- (void)changePID:(pid_t)pid;
- (void)changePolicy:(NSApplicationActivationPolicy)policy;
- (void)changeTerminated:(BOOL)terminated;
- (EventApplication *)freshWrapper;
@end
@implementation EventApplication
- (instancetype)initWithPID:(pid_t)pid policy:(NSApplicationActivationPolicy)policy { if((self=[super init])){_pid=pid;_policy=policy;_applicationIdentity=NSUUID.UUID.UUIDString;}return self; }
- (BOOL)isEqual:(id)other { return [other isKindOfClass:EventApplication.class]&&[self.applicationIdentity isEqual:((EventApplication *)other).applicationIdentity]; }
// Deliberately mutable across the modeled automatic PID transition: production must not keep these hash keys.
- (NSUInteger)hash { return (NSUInteger)_pid; }
- (EventApplication *)freshWrapper { EventApplication *wrapper=[[EventApplication alloc]initWithPID:_pid policy:_policy];wrapper.applicationIdentity=self.applicationIdentity;wrapper->_terminated=_terminated;return wrapper; }
- (pid_t)processIdentifier { check(inWorker,@"PID metadata is read only on the worker");metadataReads++;return _pid; }
- (NSApplicationActivationPolicy)activationPolicy { check(inWorker,@"policy metadata is read only on the worker");metadataReads++;return _policy; }
- (BOOL)isTerminated { check(inWorker,@"termination metadata is read only on the worker");metadataReads++;return _terminated; }
- (void)changePID:(pid_t)pid { [self willChangeValueForKey:@"processIdentifier"];_pid=pid;[self didChangeValueForKey:@"processIdentifier"]; }
- (void)changePolicy:(NSApplicationActivationPolicy)policy { [self willChangeValueForKey:@"activationPolicy"];_policy=policy;[self didChangeValueForKey:@"activationPolicy"]; }
- (void)changeTerminated:(BOOL)terminated { [self willChangeValueForKey:@"terminated"];_terminated=terminated;[self didChangeValueForKey:@"terminated"]; }
- (void)addObserver:(NSObject *)observer forKeyPath:(NSString *)key options:(NSKeyValueObservingOptions)options context:(void *)context {
    check(options==0,@"registration does not ask for synchronous initial/old/new property reads");self.installed++;
    [super addObserver:observer forKeyPath:key options:options context:context];
}
- (void)removeObserver:(NSObject *)observer forKeyPath:(NSString *)key context:(void *)context {
    self.removed++;[super removeObserver:observer forKeyPath:key context:context];
}
@end

@interface EventWorkspace : NSObject { NSArray *_catalog; }
@property NSArray *catalog;
@property NSNotificationCenter *notificationCenter;
@property NSUInteger installed,removed;
@property (readonly) NSArray<NSRunningApplication *> *runningApplications;
+ (instancetype)sharedWorkspace;
@end
@implementation EventWorkspace
+ (instancetype)sharedWorkspace { static EventWorkspace *workspace;static dispatch_once_t once;dispatch_once(&once,^{workspace=[EventWorkspace new];workspace.catalog=@[];workspace.notificationCenter=[NSNotificationCenter new];});return workspace; }
- (NSArray *)catalog { return _catalog; }
- (void)setCatalog:(NSArray *)catalog { [self willChangeValueForKey:@"runningApplications"];_catalog=[catalog copy];[self didChangeValueForKey:@"runningApplications"]; }
- (NSArray *)runningApplications { check(inWorker,@"catalog read is off main");catalogReads++;return self.catalog; }
- (void)addObserver:(NSObject *)observer forKeyPath:(NSString *)key options:(NSKeyValueObservingOptions)options context:(void *)context {
    check(NSThread.isMainThread&&[key isEqualToString:@"runningApplications"]&&options==0,@"catalog KVO registration is main-only without synchronous initial reads");self.installed++;
    [super addObserver:observer forKeyPath:key options:options context:context];
}
- (void)removeObserver:(NSObject *)observer forKeyPath:(NSString *)key context:(void *)context { check(NSThread.isMainThread,@"catalog KVO removal is main-only");self.removed++;[super removeObserver:observer forKeyPath:key context:context]; }
@end

#define dispatch_async eventAsync
#define AXIsProcessTrusted eventTrusted
#define AXUIElementCreateApplication eventAXApplication
#define kill eventKill
#define NSWorkspace EventWorkspace
#define windowServerSymbol fakeWindowServerSymbol
#import "DWWindowEvents.m"
#import "DWWindowEvents+Applications.m"
#import "DWWindowEvents+Observation.m"
#import "DWApplicationWatch.m"
#import "DWApplicationCatalogWatch.m"
#import "DWApplicationMetadata.m"
#import "DWObservedApplication.m"
#import "DWObservedWindow.m"
#undef dispatch_async
#undef AXIsProcessTrusted
#undef AXUIElementCreateApplication
#undef kill
#undef NSWorkspace
#undef windowServerSymbol

bool dw_focus_birth(pid_t pid,uint64_t *seconds,uint64_t *microseconds) {
    birthReads[@(pid)]=@(birthReads[@(pid)].unsignedIntegerValue+1);
    NSArray<NSNumber *> *value=births[@(pid)];if(!value)return false;
    *seconds=value[0].unsignedLongLongValue;*microseconds=value[1].unsignedLongLongValue;return true;
}
@interface EventEvents : DWWindowEvents
@property NSUInteger registrations,listings;
@property NSMutableArray<NSArray<NSNumber *> *> *reports;
- (void)registrationAttempt:(DWObservedApplication *)application;
@end
@implementation EventEvents
- (void)observe:(DWObservedApplication *)application { check(!inWorker,@"only main admits a registration");self.registrations++;application.registered=every; }
- (void)registrationAttempt:(DWObservedApplication *)application { [super observe:application]; }
- (void)list:(DWObservedApplication *)application { check(!application.gone,@"retired application is never listed");self.listings++; }
- (void)changed:(CGWindowID)window pid:(pid_t)pid { if(!self.stopped)[self.reports addObject:@[@(window),@(pid)]]; }
@end

static BOOL step(BOOL workerQueue) {
    NSMutableArray<dispatch_block_t> *blocks=workerQueue?workerBlocks:mainBlocks;dispatch_block_t block=nil;
    @synchronized(blocks){if(blocks.count){block=blocks.firstObject;[blocks removeObjectAtIndex:0];}}
    if(!block)return NO;inWorker=workerQueue;block();inWorker=NO;return YES;
}
static void drain(void) {
    NSUInteger turns=0;
    while(mainBlocks.count||workerBlocks.count){check(++turns<100,@"notification work remains bounded");if(!step(NO))step(YES);}
}
static void reconcile(EventEvents *events) { events.checked=0;[events reconcile]; }
static EventApplication *application(pid_t pid,NSApplicationActivationPolicy policy) {
    births[@(pid)]=@[@100,@20];return [[EventApplication alloc]initWithPID:pid policy:policy];
}
static EventEvents *events(NSArray *catalog,NSDictionary *scope) {
    EventWorkspace.sharedWorkspace.catalog=catalog;
    EventEvents *events=[[EventEvents alloc]initWithSink:nil scope:scope];events.reports=[NSMutableArray array];return events;
}
static NSNotification *note(EventApplication *application) { return [NSNotification notificationWithName:@"test" object:nil userInfo:@{NSWorkspaceApplicationKey:application}]; }

@interface EventDeliverySink : NSObject <DWWindowEventSink>
@property NSMutableArray<NSArray *> *reports;
@property NSMutableArray<NSNumber *> *creationInvalidations;
@property NSUInteger creations;
@property NSArray *creationBirth;
@property (assign) AXUIElementRef creationElement;
@end
@implementation EventDeliverySink
- (instancetype)init { if((self=[super init])){_reports=[NSMutableArray array];_creationInvalidations=[NSMutableArray array];}return self; }
- (void)windowCreationInvalidated:(pid_t)pid { [self.creationInvalidations addObject:@(pid)]; }
- (void)windowCreatedElement:(AXUIElementRef)element pid:(pid_t)pid birth:(NSArray<NSNumber *> *)birth {
    check(!inWorker&&pid==123,@"creation ingress carries the original event on main without AX reads");self.creations++;self.creationBirth=birth;self.creationElement=element;
}
- (void)windowsChanged:(pid_t)pid { [self.reports addObject:@[@"appeared",@0,@(pid)]]; }
- (void)windowMoved:(CGWindowID)window pid:(pid_t)pid { [self.reports addObject:@[@"moved",@(window),@(pid)]]; }
- (void)windowChanged:(CGWindowID)window pid:(pid_t)pid { [self.reports addObject:@[@"changed",@(window),@(pid)]]; }
- (void)windowDestroyed:(CGWindowID)window pid:(pid_t)pid { [self.reports addObject:@[@"destroyed",@(window),@(pid)]]; }
- (void)focusChanged { [self.reports addObject:@[@"focus",@0,@0]]; }
@end
// Advance only the coalescer's saved deadlines. No run-loop delay or native read.
static void deliveryDue(DWWindowEvents *events) {
    [events.timer invalidate];events.timer=nil;
    for(NSNumber *key in events.owed)events.sent[key]=@(NSProcessInfo.processInfo.systemUptime-1);
    [events due];
}
static void moveProvenance(void) {
    EventWorkspace.sharedWorkspace.catalog=@[];EventDeliverySink *sink=[EventDeliverySink new];
    DWWindowEvents *events=[[DWWindowEvents alloc]initWithSink:sink scope:nil];drain();
    DWObservedApplication *application=[DWObservedApplication new];application.pid=123;application.seconds=100;application.microseconds=20;
    application.windows=CFDictionaryCreateMutable(NULL,0,&kCFTypeDictionaryKeyCallBacks,NULL);
    DWObservedWindow *window=[DWObservedWindow new];window.window=42;window.application=application;
    window.element=(AXUIElementRef)CFRetain(CFSTR("known window"));
    CFDictionarySetValue(application.windows,window.element,(__bridge void *)window);
    void (^notify)(CFStringRef)=^(CFStringRef name){[events notified:name element:window.element application:application window:nil];};
    notify(kAXCreatedNotification);
    check(sink.creations==1&&sink.creationElement==window.element&&[sink.creationBirth isEqual:@[@100,@20]],@"created ingress preserves exact element and observed process birth");
    deliveryDue(events);
    [sink.reports removeAllObjects];[sink.creationInvalidations removeAllObjects];
    notify(kAXWindowMovedNotification);
    check([sink.reports isEqual:@[@[@"moved",@42,@123]]],@"known AXMoved is delivered separately at once");
    notify(kAXWindowMovedNotification);
    check([sink.creationInvalidations isEqual:@[@123,@123]],@"both raw move events invalidate creation before their coalesced delivery");deliveryDue(events);
    check(sink.reports.count==2&&[sink.reports.lastObject isEqual:@[@"moved",@42,@123]],@"move-only storm retains provenance in its single trailing report");
    [sink.reports removeAllObjects];notify(kAXWindowMovedNotification);notify(kAXWindowResizedNotification);notify(kAXWindowMovedNotification);deliveryDue(events);
    check([sink.reports isEqual:@[@[@"changed",@42,@123]]],@"resize dominates later moves in the same pending batch");
    [sink.reports removeAllObjects];notify(kAXTitleChangedNotification);notify(kAXWindowMovedNotification);deliveryDue(events);
    check([sink.reports isEqual:@[@[@"changed",@42,@123]]],@"retitle cannot be narrowed into origin-only movement");
    [sink.reports removeAllObjects];notify(kAXWindowMovedNotification);deliveryDue(events);
    check([sink.reports isEqual:@[@[@"moved",@42,@123]]],@"a later pure move batch recovers provenance after generic delivery");
    [sink.reports removeAllObjects];notify(kAXWindowMovedNotification);
    [events notified:kAXWindowMovedNotification element:(AXUIElementRef)CFSTR("unknown window") application:application window:nil];
    notify(kAXWindowMovedNotification);deliveryDue(events);
    check([sink.reports containsObject:@[@"changed",@0,@123]]&&[sink.reports containsObject:@[@"changed",@42,@123]]
        &&![sink.reports containsObject:@[@"moved",@42,@123]],@"unknown AXMoved invalidates the PID and downgrades its pending known moves");
    [sink.reports removeAllObjects];[events changed:0 pid:123];notify(kAXWindowMovedNotification);deliveryDue(events);
    check([sink.reports containsObject:@[@"changed",@42,@123]]&&![sink.reports containsObject:@[@"moved",@42,@123]],@"pending application-wide changes also dominate newly arriving moves");
    [sink.reports removeAllObjects];notify(kAXWindowMovedNotification);
    [events notified:kAXUIElementDestroyedNotification element:window.element application:application window:window];deliveryDue(events);
    check([sink.reports isEqual:@[@[@"destroyed",@42,@123],@[@"changed",@42,@123]]],@"destroyed remains immediate and its trailing report is generic");
    [sink.creationInvalidations removeAllObjects];[events spaceChanged:nil];
    check([sink.creationInvalidations.lastObject isEqual:@0],@"global Space hint invalidates every pending creation read immediately");
    [events stop];NSUInteger count=sink.reports.count;notify(kAXWindowMovedNotification);deliveryDue(events);
    check(sink.reports.count==count&&!events.moveOnly.count&&!events.owed.count,@"stop clears move provenance and fences late callbacks");drain();
}

// Advances the coalescer as 80 ms would: nothing was reported recently, so the next report is at once.
static void coalesceElapsed(DWWindowEvents *events) { [events.timer invalidate];events.timer=nil;[events.sent removeAllObjects];[events.owed removeAllObjects];[events.moveOnly removeAllObjects]; }
// A notification as SkyLight hands it over: the Space's id, then the window's id at offset 8.
static void windowServerPost(uint32_t type,CGWindowID window,size_t length) {
    uint8_t payload[16]={0};uint64_t space=0x1234;memcpy(payload,&space,sizeof space);memcpy(payload+8,&window,sizeof window);
    windowServerProc(type,payload,length,NULL);
}
static void windowServerHints(void) {
    EventWorkspace.sharedWorkspace.catalog=@[];EventDeliverySink *sink=[EventDeliverySink new];
    births[@123]=@[@100,@20];births[@(getpid())]=@[@100,@20];births[@999]=@[@5,@5];
    windowServerOwners=[NSMutableDictionary dictionary];windowServerPIDs=[NSMutableDictionary dictionary];
    windowServerOwners[@42]=@500;windowServerPIDs[@500]=@123;
    windowServerOwners[@43]=@501;windowServerPIDs[@501]=@(getpid());
    windowServerOwners[@44]=@502;windowServerPIDs[@502]=@999;
    windowServerOwners[@46]=@503;
    windowServerOwners[@47]=@504;windowServerPIDs[@504]=@0;
    DWWindowEvents *events=[[DWWindowEvents alloc]initWithSink:sink scope:@{@123:@[@100,@20],@(getpid()):@[@100,@20]}];drain();
    check(windowServerRegistrations==2&&windowServerTypes[0]==1325&&windowServerTypes[1]==1326&&windowServerProc==windowServerNotified&&windowServerEvents==events,@"both notifications are registered once and forwarded to the current instance");
    windowServerPost(1325,42,12);
    check([sink.reports isEqual:@[@[@"appeared",@0,@123]]],@"a window added to a Space in scope looks for its process's windows at once");
    windowServerPost(1325,42,12);
    check(sink.reports.count==1&&events.owed.count==1,@"a second window-added hint within 80 ms waits for the coalescer");
    deliveryDue(events);
    check(sink.reports.count==2&&[sink.reports.lastObject isEqual:@[@"appeared",@0,@123]],@"the owed report is delivered once, 80 ms after the last");
    coalesceElapsed(events);[sink.reports removeAllObjects];
    windowServerPost(1326,42,12);
    check([sink.reports isEqual:@[@[@"changed",@42,@123]]],@"a window left a Space is a generic change of that window, not a destruction");
    coalesceElapsed(events);[sink.reports removeAllObjects];
    windowServerPost(1325,43,12);windowServerPost(1326,43,12);windowServerPost(1325,44,12);windowServerPost(1325,45,12);
    windowServerPost(1325,46,12);windowServerPost(1325,47,12);windowServerPost(1325,42,11);windowServerPost(1325,0,12);
    check(sink.reports.count==0&&events.owed.count==0,@"this process's, out-of-scope, unowned, pid-less, short and zero-id notifications produce nothing");
    // A real secondary thread: dispatch_sync to a global queue may run its block on this one.
    dispatch_semaphore_t posted=dispatch_semaphore_create(0);
    [NSThread detachNewThreadWithBlock:^{check(!NSThread.isMainThread,@"the off-main post really is off main");windowServerPost(1325,42,12);dispatch_semaphore_signal(posted);}];
    dispatch_semaphore_wait(posted,DISPATCH_TIME_FOREVER);
    check(mainBlocks.count==1&&sink.reports.count==0,@"an off-main notification is handed to the main queue");drain();
    check([sink.reports isEqual:@[@[@"appeared",@0,@123]]],@"the main-queue hop reports as a main-thread notification would");
    coalesceElapsed(events);[sink.reports removeAllObjects];[events stop];
    check(windowServerEvents==nil,@"stop clears the current instance");
    windowServerPost(1325,42,12);windowServerPost(1326,42,12);drain();
    check(sink.reports.count==0,@"nothing is reported after stop");
    DWWindowEvents *next=[[DWWindowEvents alloc]initWithSink:sink scope:nil];drain();
    check(windowServerRegistrations==2&&windowServerEvents==next,@"a later instance is forwarded to without registering again");
    coalesceElapsed(next);windowServerPost(1326,42,12);
    check([sink.reports isEqual:@[@[@"changed",@42,@123]]],@"the later instance reports");
    [next stop];drain();
}

int main(void) {@autoreleasepool {
    check(NSThread.isMainThread,@"registry ownership is main-thread only");mainBlocks=[NSMutableArray array];workerBlocks=[NSMutableArray array];births=[NSMutableDictionary dictionary];birthReads=[NSMutableDictionary dictionary];
    EventApplication *regular=application(101,NSApplicationActivationPolicyRegular);
    EventApplication *accessory=application(102,NSApplicationActivationPolicyAccessory);
    EventEvents *owner=events(@[regular,accessory],nil);check(!owner.live,@"initial catalog discovery is not live");drain();
    check(owner.live&&owner.registrations==1&&owner.applicationWatches.count==2,@"all objects watched; only regular process admitted");
    check(regular.installed==3&&accessory.installed==3&&metadataReads==6,@"initial metadata read exactly once per object");
    NSUInteger reads=metadataReads;
    for(int n=0;n<4;n++){reconcile(owner);check(owner.live,@"stable periodic identity checks preserve live AX observation");drain();}
    check(metadataReads==reads&&catalogReads==1,@"periodic reconciliation does not poll the application catalog or stable metadata");
    for(int n=0;n<4;n++){
        EventApplication *a=regular.freshWrapper,*b=accessory.freshWrapper;EventWorkspace.sharedWorkspace.catalog=@[a,b];reconcile(owner);drain();
        check(!a.installed&&!b.installed&&!regular.removed&&!accessory.removed,@"fresh equal regular/accessory wrappers keep the canonical observers");
    }
    check(metadataReads==reads&&owner.registrations==1,@"equal catalog wrappers cause no metadata/AX/KVO churn");EventWorkspace.sharedWorkspace.catalog=@[regular,accessory];drain();
    NSUInteger catalogs=catalogReads;
    for(int n=0;n<100;n++)EventWorkspace.sharedWorkspace.catalog=@[regular,accessory];
    check(mainBlocks.count==1&&!workerBlocks.count,@"collection KVO storm coalesces to one weak main trigger");drain();
    check(catalogReads==catalogs+1&&metadataReads==reads,@"one catalog read handles the latest collection in a burst");

    [accessory changePolicy:NSApplicationActivationPolicyRegular];drain();
    check(owner.applications[@102]&&owner.registrations==2,@"KVO promotion admits an application without a launch notification");
    DWObservedApplication *old=owner.applications[@102];[accessory changePolicy:NSApplicationActivationPolicyAccessory];drain();
    check(!owner.applications[@102]&&old.gone,@"KVO demotion retires its exact AX record");
    [accessory changePolicy:NSApplicationActivationPolicyRegular];drain();
    old=owner.applications[@102];births[@103]=@[@200,@30];[accessory changePID:103];drain();
    check(!owner.applications[@102]&&old.gone&&owner.applications[@103].running==(id)accessory,@"automatic PID change retires old and admits fresh birth");
    [accessory changeTerminated:YES];drain();check(!owner.applications[@103],@"KVO termination removes its application");
    [accessory changeTerminated:NO];drain();check(owner.applications[@103]!=nil,@"same object can become running again");

    reads=metadataReads;
    for(int n=0;n<100;n++)[regular changePolicy:n%2?NSApplicationActivationPolicyRegular:NSApplicationActivationPolicyAccessory];
    check(mainBlocks.count==1&&workerBlocks.count==0,@"one hundred KVO changes coalesce to one main notification");drain();
    check(metadataReads==reads+3&&owner.applications[@101],@"one latest metadata read handles the burst");

    // Finish a worker probe, then change its PID before main accepts it. The old result must never be admitted.
    [regular changePolicy:NSApplicationActivationPolicyAccessory];check(step(NO)&&step(NO)&&step(YES),@"start an isolated metadata probe");
    births[@104]=@[@300,@40];[regular changePID:104];[regular changePolicy:NSApplicationActivationPolicyRegular];drain();
    check(!owner.applications[@101]&&owner.applications[@104].running==(id)regular,@"queued stale metadata is discarded before PID admission");
    EventApplication *movedWrapper=regular.freshWrapper;EventWorkspace.sharedWorkspace.catalog=@[movedWrapper,accessory.freshWrapper];reads=metadataReads;reconcile(owner);drain();
    check(owner.applications[@104].running==(id)regular&&!movedWrapper.installed&&metadataReads==reads,@"temporary hash buckets survive automatic PID/hash change");EventWorkspace.sharedWorkspace.catalog=@[regular,accessory];drain();

    // A fresh kernel birth, not cached LaunchServices state, guards worker-to-main admission.
    EventApplication *reused=application(105,NSApplicationActivationPolicyRegular);
    [owner launched:note(reused)];check(step(NO)&&step(YES)&&step(NO)&&step(NO)&&step(NO)&&step(YES),@"normalize a new launch, then probe identity before acceptance");
    births[@105]=@[@999,@99];drain();check(!owner.applications[@105]&&!owner.live,@"PID reuse between worker and main cannot admit stale metadata or claim full observation");
    EventWorkspace.sharedWorkspace.catalog=@[regular,accessory,reused];reconcile(owner);drain();
    check(!owner.applications[@105]&&!owner.live,@"periodic retry cannot silently rebind unchanged application object to reused PID");
    [reused changePolicy:NSApplicationActivationPolicyAccessory];[reused changePolicy:NSApplicationActivationPolicyRegular];drain();
    check(!owner.applications[@105],@"policy-only KVO preserves original birth affinity");
    [reused changeTerminated:YES];[reused changeTerminated:NO];drain();
    check(owner.applications[@105].seconds==999&&owner.live,@"actual identity lifecycle KVO allows a fresh automatic relaunch binding");
    births[@105]=@[@1000,@1];[reused changePolicy:NSApplicationActivationPolicyRegular];drain();check(!owner.applications[@105],@"unchanged object keeps birth affinity after a policy update");
    [owner launched:note(reused)];drain();check(owner.applications[@105].seconds==1000,@"explicit same-object launch permits a freshly validated identity binding");

    // A failed last-moment AX admission stays nonlive and retries only on periodic reconciliation.
    old=owner.applications[@104];[owner registrationAttempt:old];[births removeObjectForKey:@104];drain();
    check(old.gone&&!owner.applications[@104]&&!owner.live&&!mainBlocks.count&&!workerBlocks.count,@"pre-registration identity failure retires without an immediate retry loop");
    births[@104]=@[@300,@40];reconcile(owner);drain();check(owner.applications[@104]!=nil,@"transient pre-registration identity read can recover on periodic retry");

    // Replacing an NSRunningApplication object at the same PID invalidates queued old-object notifications/results.
    EventApplication *replacement=[[EventApplication alloc]initWithPID:105 policy:NSApplicationActivationPolicyRegular];
    old=owner.applications[@105];[reused changePolicy:NSApplicationActivationPolicyAccessory];
    [owner reconcileApplications:(id)@[regular,accessory,replacement]];drain();
    check(old.gone&&owner.applications[@105].running==(id)replacement&&reused.removed==3,@"exact-object replacement detaches old KVO and AX records");
    [owner terminated:note(reused)];drain();check(owner.applications[@105].running==(id)replacement,@"late termination from replaced object cannot remove successor");

    // A launch racing an older catalog must not be forgotten when that catalog arrives.
    EventWorkspace.sharedWorkspace.catalog=@[regular,accessory,replacement];reconcile(owner);check(step(NO)&&step(YES),@"take catalog before the launch notification");
    EventApplication *launched=application(106,NSApplicationActivationPolicyRegular);[owner launched:note(launched)];drain();
    check(owner.applications[@106]!=nil,@"newer launch survives an in-flight stale catalog");
    EventApplication *missed=application(107,NSApplicationActivationPolicyRegular);EventWorkspace.sharedWorkspace.catalog=@[regular,accessory,replacement,launched,missed];
    reconcile(owner);drain();check(owner.applications[@107]!=nil,@"membership pass discovers a missed launch");
    old=owner.applications[@106];EventWorkspace.sharedWorkspace.catalog=@[regular,accessory,replacement,missed];reconcile(owner);drain();
    check(!owner.applications[@106]&&old.gone&&launched.removed==3,@"membership removal retires exact object without an end notification");

    NSUInteger listings=owner.listings;[owner activated:note(missed)];[owner unhidden:note(missed)];[owner hidden:note(missed)];drain();
    check(owner.listings==listings+1,@"coalesced workspace hints preserve activated-window discovery");
    check([owner.reports containsObject:@[@(appeared),@107]]&&[owner.reports containsObject:@[@0,@107]]&&[owner.reports containsObject:@[@0,@0]],@"workspace hints preserve appearance, visibility and focus reports");
    EventApplication *activationWrapper=missed.freshWrapper,*hiddenWrapper=missed.freshWrapper,*unhiddenWrapper=missed.freshWrapper;
    listings=owner.listings;reads=metadataReads;NSUInteger registrations=owner.registrations;
    [owner activated:note(activationWrapper)];[owner hidden:note(hiddenWrapper)];[owner unhidden:note(unhiddenWrapper)];drain();
    check(!activationWrapper.installed&&!hiddenWrapper.installed&&!unhiddenWrapper.installed&&!missed.removed&&owner.registrations==registrations,@"equal notification wrappers retain canonical AX/KVO registrations");
    check(owner.listings==listings+1&&metadataReads==reads+3,@"equal-wrapper activation/visibility hints coalesce into one fresh metadata read");
    for(int n=0;n<100;n++)[owner activated:note(missed.freshWrapper)];
    check(owner.applicationNotices.count==64&&mainBlocks.count==1,@"unknown-wrapper notification storm has one bounded pending batch");drain();
    check(owner.registrations==registrations&&!missed.removed,@"overflow falls back to discovery without observer churn");

    // Revocation while a metadata result is queued, then regrant while that old batch completes.
    [missed changePolicy:NSApplicationActivationPolicyAccessory];check(step(NO)&&step(NO)&&step(YES),@"queue a pre-revocation result");
    trusted=NO;reconcile(owner);check(!owner.live&&!owner.applicationWatches.count&&!owner.applications.count,@"trust withdrawal tears down every KVO/AX record");
    trusted=YES;reconcile(owner);drain();check(owner.live&&!owner.applications[@107]&&owner.applications[@105],@"regrant ignores stale batch and independently discovers current policy");

    [regular changePID:108];[owner stop];NSUInteger reports=owner.reports.count;drain();
    check(!owner.live&&!owner.applicationWatches.count&&!owner.applications.count&&owner.reports.count==reports,@"stop fences pending notification and metadata work");
    NSUInteger removed=regular.removed;[regular changePID:109];drain();check(regular.removed==removed&&!mainBlocks.count,@"stopped object is no longer observed");

    // The record lock also handles a genuine background KVO delivery without touching main-owned registry state there.
    EventApplication *background=application(110,NSApplicationActivationPolicyRegular);owner=events(@[background],nil);drain();
    dispatch_sync(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{[background changePolicy:NSApplicationActivationPolicyAccessory];});
    [owner stop];drain();check(background.removed==3&&!owner.applications.count,@"background KVO queued before removal is harmless after stop");

    EventApplication *cancelled=application(113,NSApplicationActivationPolicyRegular);owner=events(@[cancelled],nil);drain();
    [cancelled changePolicy:NSApplicationActivationPolicyAccessory];check(step(NO)&&step(NO),@"queue metadata work before cancellation");
    reads=metadataReads;[owner stop];drain();check(metadataReads==reads,@"cancelled queued probe skips dynamic metadata reads entirely");

    EventApplication *allowed=application(111,NSApplicationActivationPolicyRegular),*outside=application(112,NSApplicationActivationPolicyRegular);
    [births removeObjectForKey:@112];
    owner=events(@[allowed,outside],@{@111:@[@100,@20]});drain();check(owner.registrations==1&&owner.applications[@111]&&!owner.applications[@112],@"fresh exact scope admission never registers outside process");
    check(owner.live,@"failed birth probe outside the explicit scope does not force fallback polling");
    births[@111]=@[@700,@1];[allowed changePolicy:NSApplicationActivationPolicyRegular];drain();
    check(!owner.applications[@111],@"scope birth mismatch retires stale scoped application");[owner stop];drain();

    EventApplication *recycled=application(114,NSApplicationActivationPolicyRegular);owner=events(@[recycled],nil);drain();
    EventApplication *equalRecycled=recycled.freshWrapper;EventWorkspace.sharedWorkspace.catalog=@[equalRecycled];check(step(NO)&&step(YES),@"worker validates an equal wrapper before kernel identity changes");
    births[@114]=@[@777,@12];drain();
    check(!recycled.removed&&!equalRecycled.installed&&!owner.applications[@114]&&!owner.live,@"equal stale wrapper cannot reset original birth affinity after the main fence fails");
    [owner activated:note(equalRecycled)];drain();
    check(!owner.applications[@114]&&!equalRecycled.installed,@"activation through an equal wrapper cannot rebind a recycled PID");
    [recycled changeTerminated:YES];[recycled changeTerminated:NO];drain();
    check(owner.applications[@114].running==(id)recycled&&owner.applications[@114].seconds==777,@"actual lifecycle KVO permits a fresh binding while retaining the canonical observer");
    [owner stop];drain();

    EventApplication *noticeStopped=application(116,NSApplicationActivationPolicyRegular);owner=events(@[noticeStopped],nil);drain();
    EventApplication *lateWrapper=noticeStopped.freshWrapper;[owner activated:note(lateWrapper)];check(step(NO)&&step(YES),@"normalize a notification before stopping");
    [owner stop];drain();check(!lateWrapper.installed&&!owner.applicationWatches.count,@"queued normalized notification cannot recreate observers after stop");

    EventApplication *withoutPID=application(-1,NSApplicationActivationPolicyAccessory);owner=events(@[withoutPID],nil);drain();
    EventApplication *withoutPIDWrapper=withoutPID.freshWrapper;EventWorkspace.sharedWorkspace.catalog=@[withoutPIDWrapper];reads=metadataReads;reconcile(owner);drain();
    check(!withoutPID.removed&&!withoutPIDWrapper.installed&&metadataReads==reads&&!owner.applications.count,@"equal PID-less wrappers stay bounded and have no native admission");
    births[@115]=@[@400,@5];[withoutPID changePID:115];[withoutPID changePolicy:NSApplicationActivationPolicyRegular];drain();
    check(owner.applications[@115].running==(id)withoutPID,@"PID-less canonical watcher admits only after fresh identity metadata");[owner stop];drain();

    // Membership observation is event-driven, but the periodic admitted-process identity fence remains independent.
    EventApplication *admitted=application(117,NSApplicationActivationPolicyRegular),*unscoped=application(118,NSApplicationActivationPolicyRegular),*agent=application(119,NSApplicationActivationPolicyAccessory);
    owner=events(@[admitted,unscoped,agent],@{@117:@[@100,@20]});drain();
    catalogs=catalogReads;reads=metadataReads;NSUInteger admittedBirths=birthReads[@117].unsignedIntegerValue,unscopedBirths=birthReads[@118].unsignedIntegerValue,agentBirths=birthReads[@119].unsignedIntegerValue;
    for(int n=0;n<10;n++){reconcile(owner);drain();}
    check(catalogReads==catalogs&&metadataReads==reads,@"ten idle reconciliations perform no catalog or LaunchServices metadata read");
    check(birthReads[@117].unsignedIntegerValue==admittedBirths+10&&birthReads[@118].unsignedIntegerValue==unscopedBirths&&birthReads[@119].unsignedIntegerValue==agentBirths,@"periodic kernel identity checks cover admitted applications only");
    old=owner.applications[@117];births[@117]=@[@1001,@4];reconcile(owner);
    check(old.gone&&!owner.applications[@117]&&!owner.live,@"periodic kernel birth catches PID reuse without a collection or property KVO");
    drain();reconcile(owner);drain();
    check(!owner.applications[@117]&&!owner.live&&!mainBlocks.count&&!workerBlocks.count,@"unchanged semantic identity cannot rebind through periodic retry or spin work");
    [admitted changeTerminated:YES];drain();[owner stop];drain();

    EventApplication *first=application(120,NSApplicationActivationPolicyRegular),*arriving=application(121,NSApplicationActivationPolicyRegular);
    owner=events(@[first],nil);drain();catalogs=catalogReads;
    EventWorkspace.sharedWorkspace.catalog=@[first];check(step(NO)&&step(YES),@"capture a catalog before its collection changes");
    EventWorkspace.sharedWorkspace.catalog=@[first,arriving];
    check(step(NO)&&step(YES),@"stale completion starts its one successor without another periodic reconciliation");drain();
    check(owner.applications[@121]&&catalogReads==catalogs+2,@"in-flight collection change is neither lost nor followed by an extra duplicate read");
    EventWorkspace.sharedWorkspace.catalog=@[arriving];drain();
    check(!owner.applications[@120]&&first.removed==3,@"collection KVO retires an application without a workspace end notification");

    EventApplication *backgroundArrival=application(122,NSApplicationActivationPolicyRegular);catalogs=catalogReads;
    dispatch_sync(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{EventWorkspace.sharedWorkspace.catalog=@[arriving,backgroundArrival];});drain();
    check(owner.applications[@122]&&catalogReads==catalogs+1,@"off-main collection KVO queues a bounded fresh main/worker reconciliation");
    NSUInteger catalogInstalled=EventWorkspace.sharedWorkspace.installed,catalogRemoved=EventWorkspace.sharedWorkspace.removed;
    EventWorkspace.sharedWorkspace.catalog=@[arriving,backgroundArrival];check(step(NO),@"queue a collection read before permission revocation");catalogs=catalogReads;
    trusted=NO;reconcile(owner);trusted=YES;reconcile(owner);drain();
    check(owner.live&&owner.applications.count==2&&catalogReads==catalogs+1,@"regrant reads its new observer epoch after the old queued scan is cancelled");
    check(EventWorkspace.sharedWorkspace.installed==catalogInstalled+1&&EventWorkspace.sharedWorkspace.removed==catalogRemoved+1,@"revocation removes the collection observer before installing its successor");
    EventWorkspace.sharedWorkspace.catalog=@[backgroundArrival];check(step(NO)&&step(YES),@"finish a collection read before stop accepts it");catalogs=catalogReads;
    [owner stop];drain();EventWorkspace.sharedWorkspace.catalog=@[];drain();
    check(!owner.applicationWatches.count&&!owner.applications.count&&catalogReads==catalogs,@"stop fences a queued catalog result and removes future collection callbacks");
    check(EventWorkspace.sharedWorkspace.installed==EventWorkspace.sharedWorkspace.removed,@"every installed collection observer was removed exactly once");
    moveProvenance();windowServerHints();
    printf("window-events registry: %lu checks passed\n",(unsigned long)checks);return 0;
}}
