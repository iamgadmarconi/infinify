// SPDX-License-Identifier: GPL-3.0-or-later
// Production discovery/observation scheduling with in-memory metadata, clocks,
// applications and queues. No native windows, AX, WindowServer, helper or input.
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import "window-manager.h"
#import "window-events.h"
#import "native-presenter.h"
#include <libproc.h>

static NSUInteger checks;
static BOOL inWorker,listAvailable=YES,deliverDiscoveryDuringFamily;
static NSTimeInterval fixtureNow=100;
static NSArray<NSDictionary *> *windowRows;
static NSMutableArray<dispatch_block_t> *mainBlocks,*workerBlocks;
static void check(BOOL condition,NSString *message) {
    checks++;if(!condition){fprintf(stderr,"FAIL: %s\n",message.UTF8String);exit(1);}
}
static BOOL step(BOOL worker);
static void fixtureAsync(dispatch_queue_t queue,dispatch_block_t block) {
    [(queue==dispatch_get_main_queue()?mainBlocks:workerBlocks)addObject:[block copy]];
}
static CFTimeInterval fixtureTime(void) { return fixtureNow; }
static BOOL fixtureTrusted(void) { return NO; }
static BOOL fixtureCaptureAccess(void) { check(NO,@"native discovery does not preflight capture permission");return NO; }
static CFArrayRef fixtureWindowList(CGWindowListOption options,CGWindowID window) {
    (void)options;(void)window;check(inWorker,@"WindowServer metadata reads stay off main");
    return listAvailable?CFBridgingRetain(windowRows):NULL;
}
static int fixtureProcessInfo(int pid,int flavor,uint64_t argument,void *buffer,int size) {
    (void)argument;check(inWorker&&pid==123&&flavor==PROC_PIDTBSDINFO&&size==(int)sizeof(struct proc_bsdinfo),@"observation revalidates the modeled process birth on its worker");
    struct proc_bsdinfo process={.pbi_start_tvsec=100,.pbi_start_tvusec=20};memcpy(buffer,&process,sizeof(process));return size;
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

#define dispatch_async fixtureAsync
#define AXIsProcessTrusted fixtureTrusted
#define CGPreflightScreenCaptureAccess fixtureCaptureAccess
#define NSRunningApplication DiscoveryApplication
#define NSWorkspace DiscoveryWorkspace
#define NSProcessInfo DiscoveryProcessInfo
#define DWWindowEvents DiscoveryEvents
#import "window-manager.m"
#undef DWWindowEvents
#undef NSProcessInfo
#undef NSWorkspace
#undef NSRunningApplication
#define CACurrentMediaTime fixtureTime
#define CGWindowListCopyWindowInfo fixtureWindowList
#define proc_pidinfo fixtureProcessInfo
#import "window-observer.m"
#undef proc_pidinfo
#undef CGWindowListCopyWindowInfo
#undef CACurrentMediaTime
#undef CGPreflightScreenCaptureAccess
#undef AXIsProcessTrusted
#undef dispatch_async

BOOL DWInScope(NSDictionary *scope,pid_t pid) { return !scope||[scope[@(pid)]isEqual:@[@100,@20]]; }
bool dw_focus_owner(DWFocusIdentity identity,CGRect *bounds) { (void)identity;(void)bounds;check(NO,@"no native focus or close lookup is performed");return false; }
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
static NSDictionary *row(uint32_t window,CGFloat width) {
    return @{(id)kCGWindowNumber:@(window),(id)kCGWindowOwnerPID:@123,(id)kCGWindowLayer:@0,
        (id)kCGWindowBounds:CFBridgingRelease(CGRectCreateDictionaryRepresentation(CGRectMake(100,100,width,232)))};
}
@interface DiscoveryHost : NSObject <DWWindowHost>
@property NSUInteger requested,appeared,completed;
@end
@implementation DiscoveryHost
- (BOOL)managesWindow:(CGWindowID)window pid:(pid_t)pid { (void)window;(void)pid;return NO; }
- (void)windowAppeared:(DWWindowCandidate *)window { check(window.pid==123&&window.frame.size.width>=320,@"the candidate retains its actual metadata");self.appeared++; }
- (void)discoveryCompleted:(NSArray *)present { check(!present.count,@"native discovery does not enumerate off-screen capture windows");self.completed++; }
- (void)discoveryFailed:(NSString *)reason { (void)reason;check(NO,@"native metadata discovery has no capture failure"); }
- (void)windowChanged:(CGWindowID)window pid:(pid_t)pid { (void)window;(void)pid; }
- (void)windowDestroyed:(CGWindowID)window pid:(pid_t)pid { (void)window;(void)pid; }
- (void)focusChanged {}
- (void)windowDiscoveryRequested { self.requested++; }
@end
int main(void) {@autoreleasepool {
    mainBlocks=[NSMutableArray array];workerBlocks=[NSMutableArray array];windowRows=@[row(42,320)];
    DiscoveryHost *host=[DiscoveryHost new];DWWindowManager *manager=[DWWindowManager managerWithHost:host scope:nil mode:DWWindowDiscoveryModeNativePresentation];
    [manager pollWithWindowRecords:windowRows];NSTimer *first=manager.discoveryTimer;
    check(first&&fabs(manager.discoveryDeadline-100.05)<1e-9&&!host.appeared,@"first geometry observation schedules the existing exact 50 ms hold");
    fixtureNow=100.02;[manager pollWithWindowRecords:windowRows];
    check(manager.discoveryTimer==first&&fabs(manager.discoveryDeadline-100.05)<1e-9,@"intervening polling keeps the earliest deadline and one timer");
    fixtureNow=100.051;[first fire];check(host.requested==1&&!manager.discoveryTimer&&!host.appeared,@"deadline requests a fresh worker read instead of adopting cached geometry");
    [manager pollWithWindowRecords:windowRows];check(!host.appeared&&workerBlocks.count==1,@"role/title selection remains asynchronous after the stability check");drain();
    check(host.appeared==1&&host.completed==1,@"stable candidate is offered without another idle-poll interval");
    fixtureNow=101;windowRows=@[row(42,320),row(43,320)];[manager pollWithWindowRecords:windowRows];
    fixtureNow=101.02;windowRows=@[row(42,320),row(43,340)];[manager pollWithWindowRecords:windowRows];
    fixtureNow=101.051;[manager.discoveryTimer fire];[manager pollWithWindowRecords:windowRows];
    check(host.appeared==1&&fabs(manager.discoveryDeadline-101.07)<1e-9,@"a changed candidate still requires 50 ms at its new bounds");
    fixtureNow=101.071;[manager.discoveryTimer fire];[manager pollWithWindowRecords:windowRows];drain();check(host.appeared==2,@"fresh stable replacement geometry is eventually offered");
    fixtureNow=102;windowRows=@[row(42,320),row(43,340),row(45,320)];[manager pollWithWindowRecords:windowRows];
    fixtureNow=102.051;[manager.discoveryTimer fire];[manager pollWithWindowRecords:windowRows];check(workerBlocks.count==1,@"candidate role/title read is in flight");
    fixtureNow=102.061;windowRows=@[row(42,320),row(43,340),row(45,340)];[manager pollWithWindowRecords:windowRows];drain();
    check(host.appeared==2&&![manager.offered containsObject:@45],@"new metadata changing geometry invalidates the outstanding candidate selection");
    fixtureNow=102.112;[manager.discoveryTimer fire];[manager pollWithWindowRecords:windowRows];drain();check(host.appeared==3,@"changed bounds require their own fresh stable selection");
    fixtureNow=103;windowRows=@[row(42,320),row(43,340),row(45,340),row(46,320)];[manager pollWithWindowRecords:windowRows];
    fixtureNow=103.051;[manager.discoveryTimer fire];[manager pollWithWindowRecords:windowRows];
    fixtureNow=103.061;windowRows=@[row(42,320),row(43,340),row(45,340)];[manager pollWithWindowRecords:windowRows];drain();
    check(host.appeared==3&&![manager.offered containsObject:@46],@"candidate disappearing during role/title read is never offered");
    fixtureNow=104;windowRows=@[row(42,320),row(43,340),row(45,340),row(44,320)];[manager pollWithWindowRecords:windowRows];NSTimer *cancelled=manager.discoveryTimer;NSUInteger requested=host.requested;[manager stop];[cancelled fire];
    check(!manager.discoveryTimer&&host.requested==requested,@"stop invalidates pending candidate timers and callbacks");

    fixtureNow=200;windowRows=@[row(42,320)];DWWindowObserver *observer=[DWWindowObserver new];__block DWWindowObservationSnapshot *metadata=nil,*complete=nil;
    NSArray *requests=@[@{@"logical":@7,@"generation":@1,@"identity":@{@"pid":@123,@"wid":@42,@"birth_sec":@100,@"birth_usec":@20},@"native_bounds":@YES,@"families":@YES}];
    deliverDiscoveryDuringFamily=YES;
    check([observer requestSources:requests scope:@{@123:@[@100,@20]} discovery:^(DWWindowObservationSnapshot *snapshot){
        check(!inWorker&&observer.inFlight&&snapshot.sources.count==0&&snapshot.orderedOnScreen.count==1,@"discovery callback has immutable list metadata and leaves the batch in flight");
        check(fixtureNow-snapshot.startedAt<.1,@"timely discovery is delivered before the modeled slow family audit");metadata=snapshot;
        check(![observer requestSources:requests scope:nil discovery:nil completion:^(DWWindowObservationSnapshot *ignored){(void)ignored;}],@"discovery cannot queue a second global worker while its source audit runs");
    } completion:^(DWWindowObservationSnapshot *snapshot){check(!inWorker&&!observer.inFlight,@"final source callback ends single flight on main");complete=snapshot;}],@"start one split discovery/source observation");
    drain();check(metadata&&complete&&metadata!=complete&&metadata.sources.count==0&&complete.sources.count==1,@"final source assembly never mutates the earlier discovery snapshot");
    check(fixtureNow-complete.startedAt>.1&&fixtureNow-metadata.deliveredAt>.1&&metadata.finishedAt==200,@"slow final sources retain their original age for the unchanged freshness rejection");
    deliverDiscoveryDuringFamily=NO;__block NSUInteger cancelledCallbacks=0;
    check([observer requestSources:@[] scope:nil discovery:^(DWWindowObservationSnapshot *snapshot){(void)snapshot;cancelledCallbacks++;} completion:^(DWWindowObservationSnapshot *snapshot){(void)snapshot;cancelledCallbacks++;}],@"start cancellable metadata-only observation");
    [observer cancel];drain();check(!cancelledCallbacks,@"cancel drops both discovery and source completions");
    DWWindowObserver *finalOnly=[DWWindowObserver new];__block NSUInteger finalCallbacks=0;
    check([finalOnly requestSources:@[] scope:nil discovery:nil completion:^(DWWindowObservationSnapshot *snapshot){check(snapshot.listSucceeded,@"final-only callback still receives the successful list");finalCallbacks++;}],@"observation explicitly supports no discovery callback");drain();check(finalCallbacks==1,@"discovery:nil produces one final callback");[finalOnly cancel];
    printf("PASS: %lu discovery scheduling checks; no native mutation or live latency claim\n",(unsigned long)checks);
}return 0;}
