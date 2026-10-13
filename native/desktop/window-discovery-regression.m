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
static BOOL allowOverlayPermissionRead;
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
static BOOL fixtureCaptureAccess(void) { check(allowOverlayPermissionRead,@"only overlay creation reads capture permission");return NO; }
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
#define CACurrentMediaTime fixtureTime
#import "window-manager.m"
#undef DWWindowEvents
#undef NSProcessInfo
#undef NSWorkspace
#undef NSRunningApplication
#define NSRunningApplication DiscoveryApplication
#define CGWindowListCopyWindowInfo fixtureWindowList
#define proc_pidinfo fixtureProcessInfo
#import "window-observer.m"
#undef proc_pidinfo
#undef NSRunningApplication
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
static NSDictionary *candidateBases(NSArray<NSDictionary *> *rows) {
    NSMutableDictionary *bases=[NSMutableDictionary dictionary];for(NSDictionary *row in rows){NSNumber *wid=row[(id)kCGWindowNumber];
        bases[wid]=@{@"identity":@{@"pid":@123,@"wid":wid,@"birth_sec":@100,@"birth_usec":@20},@"native_bounds":row[(id)kCGWindowBounds],@"transform":@[@1,@0,@0,@1,@(-100),@(-100)]};
    }return bases.copy;
}
NSDictionary *DWNativeWindowDiscoveryBasis(NSDictionary *identity) {
    check(inWorker,@"native candidate basis is read only on the worker");candidateBasisReads++;return candidateBases(windowRows)[identity[@"wid"]];
}
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
    printf("PASS: %lu discovery scheduling checks; no native mutation or live latency claim\n",(unsigned long)checks);
}return 0;}
