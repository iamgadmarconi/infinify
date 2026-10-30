// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from yabai (https://github.com/asmvik/yabai) dd845723416f5fe92af49fad5ebab00369e07edd (MIT, Copyright (c) 2019 Åsmund
// Vikane; the licence text is native/app/Resources/YABAI-NOTICE.txt): src/workspace.m, src/application.h, src/application.c, src/window.h, src/window.c
// (window_observe, window_unobserve), src/event_loop.c and src/window_manager.c, as DWWindowEvents.h says of each. Where this
// differs from yabai is said where it does.
// Adapted from Sunlight (https://github.com/spacefarm-digital/sunlight) afeea74b18e70ca49bf462d6fe462cf65deb2b32 (MIT, Copyright
// (c) 2026 spacefarm; the licence text is native/app/Resources/SUNLIGHT-NOTICE.txt):
// Sources/Canvas/RealWindows/WindowServerEvents.swift (the window-server events 1325/1326, their payload, main-thread delivery once an
// NSApplication exists).
// DWWindowEvents core: construction, the poll, window-server notifications, coalesced delivery, stop.
// Split from native/desktop/window-events.m at 37b27b1, moved verbatim.
#import "DWWindowEvents+Private.h"
// Every Accessibility message goes through this one serial queue, a stopped instance's removals ahead of its successor's
// registrations. yabai sends them from its event-loop thread, likewise not the thread its observers call back on.
dispatch_queue_t DWWindowEventsQueue(void) { static dispatch_queue_t queue;static dispatch_once_t once;dispatch_once(&once,^{queue=dispatch_queue_create("org.infinify.window-events",DISPATCH_QUEUE_SERIAL);});return queue; }
// LaunchServices reads are serial too, but cannot hold up an application's AX work.
dispatch_queue_t DWWindowEventsApplicationQueue(void) { static dispatch_queue_t queue;static dispatch_once_t once;dispatch_once(&once,^{queue=dispatch_queue_create("org.infinify.application-events",dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,QOS_CLASS_UTILITY,0));});return queue; }
BOOL DWInScope(NSDictionary<NSNumber *,NSArray<NSNumber *> *> *scope,pid_t pid) {
    if(!scope)return YES;
    NSArray<NSNumber *> *born=scope[@(pid)];uint64_t seconds=0,microseconds=0;
    return born.count==2&&dw_focus_birth(pid,&seconds,&microseconds)&&born[0].unsignedLongLongValue==seconds&&born[1].unsignedLongLongValue==microseconds;
}
// SkyLight's connection notifications, as Sunlight takes them: 1325 when a window is added to a Space, 1326 when it leaves one. The
// payload is the Space's id (8 bytes), then the window's (4 bytes, at offset 8). Looked up by name, as DWNativePlacementValidation.m
// does; the regression replaces this lookup with #define before it imports this file, so its fakes stand in for SkyLight.
#ifndef windowServerSymbol
static void *windowServerSymbol(const char *name) { static void *sky;static dispatch_once_t once;dispatch_once(&once,^{sky=dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",RTLD_NOW|RTLD_LOCAL);});return sky?dlsym(sky,name):NULL; }
#endif
typedef void (*WindowServerNotify)(uint32_t,void *,size_t,void *);
typedef int (*WindowServerConnection)(void);
typedef int (*WindowServerRegister)(int,WindowServerNotify,uint32_t,void *);
typedef CGError (*WindowServerOwner)(int,CGWindowID,int *);
typedef CGError (*WindowServerConnectionPID)(int,pid_t *);
static struct { int connection;WindowServerOwner owner;WindowServerConnectionPID connectionPID; } windowServerAPI;
// The one current instance: set by -initWithSink:scope:, cleared by -stop. Registration is once for the process (there is no
// unregister), so the handler reaches whichever instance is current, and none after that one has stopped.
static __weak DWWindowEvents *windowServerEvents;
// SkyLight calls this on the main thread, once the process has an NSApplication (measured on macOS 27.0.1). Should it come from another
// thread, the window id is copied out first, because the payload is SkyLight's only for the call. A payload shorter than 12 bytes,
// or window 0, is nothing.
static void windowServerNotified(uint32_t type,void *payload,size_t length,void *context) {
    (void)context;CGWindowID window=0;
    if(payload&&length>=12)memcpy(&window,(const char *)payload+8,sizeof window);
    if(!window)return;
    if(NSThread.isMainThread)[windowServerEvents windowServerType:type window:window];
    else dispatch_async(dispatch_get_main_queue(),^{[windowServerEvents windowServerType:type window:window];});
}
// Once for the process, the first time an instance starts. A missing symbol, or a nonzero result, leaves no hints and nothing else
// changes. 1325 is registered first, so its failure registers nothing; a failure of 1326 keeps 1325, which cannot be unregistered.
static void windowServerRegister(void) {
    static dispatch_once_t once;
    dispatch_once(&once,^{
        WindowServerConnection connection=(WindowServerConnection)windowServerSymbol("SLSMainConnectionID");
        WindowServerRegister registerProc=(WindowServerRegister)windowServerSymbol("SLSRegisterConnectionNotifyProc");
        windowServerAPI.owner=(WindowServerOwner)windowServerSymbol("SLSGetWindowOwner");windowServerAPI.connectionPID=(WindowServerConnectionPID)windowServerSymbol("SLSConnectionGetPID");
        if(!connection||!registerProc||!windowServerAPI.owner||!windowServerAPI.connectionPID){if(getenv("INFINIFY_DEBUG"))fprintf(stderr,"debug: native window events: SkyLight's window notifications are not there\n");return;}
        // Delivery needs the process's NSApplication (measured), so it is made before the connection is taken; the app has one already.
        [NSApplication sharedApplication];windowServerAPI.connection=connection();
        if(registerProc(windowServerAPI.connection,windowServerNotified,1325,NULL)){if(getenv("INFINIFY_DEBUG"))fprintf(stderr,"debug: native window events: registering for 1325 failed\n");return;}
        if(registerProc(windowServerAPI.connection,windowServerNotified,1326,NULL)&&getenv("INFINIFY_DEBUG"))fprintf(stderr,"debug: native window events: registering for 1326 failed; 1325 stays\n");
    });
}
@implementation DWWindowEvents
- (instancetype)initWithSink:(id<DWWindowEventSink>)sink scope:(NSDictionary<NSNumber *,NSArray<NSNumber *> *> *)scope {
    if((self=[super init])){_sink=sink;_scope=[scope copy];_applications=[NSMutableDictionary dictionary];_sent=[NSMutableDictionary dictionary];_owed=[NSMutableSet set];_moveOnly=[NSMutableSet set];
        _applicationWatches=[NSMapTable mapTableWithKeyOptions:NSPointerFunctionsStrongMemory|NSPointerFunctionsObjectPointerPersonality valueOptions:NSPointerFunctionsStrongMemory];_applicationNotices=[NSMutableArray array];
        // yabai's workspace_context, less what a tiling window manager needs of the Dock, the menu bar and the displays, and with
        // launch, end and activation from NSWorkspace where yabai has them from its process manager's Carbon events.
        NSNotificationCenter *center=NSWorkspace.sharedWorkspace.notificationCenter;_workspaceNotifications=center;
        [center addObserver:self selector:@selector(launched:) name:NSWorkspaceDidLaunchApplicationNotification object:nil];
        [center addObserver:self selector:@selector(terminated:) name:NSWorkspaceDidTerminateApplicationNotification object:nil];
        [center addObserver:self selector:@selector(activated:) name:NSWorkspaceDidActivateApplicationNotification object:nil];
        [center addObserver:self selector:@selector(hidden:) name:NSWorkspaceDidHideApplicationNotification object:nil];
        [center addObserver:self selector:@selector(unhidden:) name:NSWorkspaceDidUnhideApplicationNotification object:nil];
        [center addObserver:self selector:@selector(spaceChanged:) name:NSWorkspaceActiveSpaceDidChangeNotification object:nil];
        // The window server's own word for a window's appearance, forwarded here while this is the current instance (windowServerNotified).
        windowServerEvents=self;windowServerRegister();
        [self reconcile];
    }return self;
}
// An application that is not observed in full yet, or will never be, reports less than the poll would find: the poll then keeps its pace.
- (BOOL)live {
    if(!self.trusted||self.stopped||!self.hasApplicationCatalog||self.scanning||self.applicationCatalogDirty||self.readingApplications||self.applicationReadQueued||self.resolvingApplicationNotices||self.applicationNotices.count)return NO;
    for(DWApplicationWatch *record in self.applicationWatches.objectEnumerator)if(record.retry)return NO;
    for(DWObservedApplication *application in self.applications.allValues)if(application.registered!=every)return NO;
    return YES;
}
- (void)reconcile {
    NSTimeInterval now=NSProcessInfo.processInfo.systemUptime;if(self.stopped||(self.checked&&now-self.checked<.5))return;self.checked=now;
    // Access withdrawn: nothing is delivered any more, so nothing is kept, and the poll is the only mechanism again.
    if(!AXIsProcessTrusted()){self.trusted=NO;[self clearApplicationWatches];for(NSNumber *pid in self.applications.allKeys)[self remove:pid.intValue ended:NO];return;}
    self.trusted=YES;
    // Observe both the application collection and each member's PID, policy and termination. Catalog/metadata reads can
    // synchronously wait for LaunchServices, so initial or invalidated records are read only on the serial worker.
    // Collection KVO also discovers launches whose separate workspace notification was missed; there is no catalog poll.
    [self observeApplicationCatalog];
    [self scanApplications];
    for(DWApplicationWatch *record in self.applicationWatches.objectEnumerator)if(record.retry){record.retry=NO;record.pending=YES;}
    [self queueApplicationRead];
    for(DWObservedApplication *application in self.applications.allValues){
        // Periodic native identity checks are limited to admitted AX applications. Collection equality only preserves
        // observers; it cannot leave an old registration live when a numeric PID has been reused without a KVO update.
        uint64_t seconds=0,microseconds=0;
        if(!dw_focus_birth(application.pid,&seconds,&microseconds)||seconds!=application.seconds||microseconds!=application.microseconds){
            DWApplicationWatch *record=[self.applicationWatches objectForKey:application.running];record.retry=YES;
            BOOL ended=kill(application.pid,0)&&errno==ESRCH;[self remove:application.pid ended:ended];[self changed:0 pid:application.pid];continue;
        }
        if(application.registered!=every&&!application.final&&!application.retry)[self observe:application];
        // A window it did not answer for, or gave no number for, is watched once it does: its windows are listed again until then.
        if(application.unanswered)[self list:application];
        // A destroyed window's context has long been called back with for the last time.
        for(DWObservedWindow *window in application.contexts.copy)if(window.destroyed&&now-window.destroyed>10)[application.contexts removeObjectIdenticalTo:window];
    }
}
// SkyLight's 1325 or 1326 for one window, reported as the Accessibility observers report the same change: 1325, a window added to a
// Space, is the appearance an AXCreated gives, so the window list is read for that process at once, coalesced with the rest; 1326, a
// window left a Space, is a generic change of that window, which a minimize, a hide or a move to another Space gives too, so it is
// never a destruction. The window's process is asked of SkyLight. An event whose process cannot be found (or is pid 0), is this
// process's own window, or is outside the scope is ignored: the Accessibility observers and the poll still find it.
- (void)windowServerType:(uint32_t)type window:(CGWindowID)window {
    int owner=0;pid_t pid=0;
    if(self.stopped||windowServerAPI.owner(windowServerAPI.connection,window,&owner)!=kCGErrorSuccess||windowServerAPI.connectionPID(owner,&pid)!=kCGErrorSuccess||pid<=0)return;
    if(pid==getpid()||!DWInScope(self.scope,pid))return;
    if(getenv("INFINIFY_DEBUG")&&self.windowServerTraceLines<128){self.windowServerTraceLines++;
        fprintf(stderr,"debug: native creation event pid=%d at=%.6f notification=SLS%u known_wid=%u\n",pid,NSProcessInfo.processInfo.systemUptime,type,window);}
    [self changed:type==1325?appeared:window pid:pid];
}
- (void)deliver:(NSNumber *)key {
    uint64_t value=key.unsignedLongLongValue;id<DWWindowEventSink> sink=self.sink;CGWindowID window=(CGWindowID)(value&0xffffffff);pid_t pid=(pid_t)(value>>32);
    if(getenv("INFINIFY_DEBUG")&&pid==self.creationTracePID&&NSProcessInfo.processInfo.systemUptime<=self.creationTraceUntil&&self.creationTraceLines<128){self.creationTraceLines++;
        fprintf(stderr,"debug: native creation hint pid=%d wid=%u at=%.6f move_only=%d\n",pid,window,NSProcessInfo.processInfo.systemUptime,[self.moveOnly containsObject:key]);}
    if(!value)[sink focusChanged];else if(window==appeared)[sink windowsChanged:pid];
    else if([self.moveOnly containsObject:key])[sink windowMoved:window pid:pid];
    else [sink windowChanged:window pid:pid];
}
// A change of one window, of some window of an application (`window` 0), of the windows an application has on screen
// (`appeared`; pid 0 for every application's) or of native focus (both 0). Reported at once unless one was reported within
// the last 80 ms; either way one more report is owed 80 ms after the last one made.
- (void)changed:(CGWindowID)window pid:(pid_t)pid {
    [self changed:window pid:pid moveOnly:NO];
}
- (void)changed:(CGWindowID)window pid:(pid_t)pid moveOnly:(BOOL)moved {
    // This runs before coalescing can defer a raw change. A new sibling window
    // or a focus hint does not change the window being qualified.
    if(!self.stopped&&(window||pid)&&!(window==appeared&&pid>0)&&[self.sink respondsToSelector:@selector(windowCreationInvalidated:)])
        [self.sink windowCreationInvalidated:pid];
    if(self.stopped)return;NSNumber *key=@((uint64_t)(uint32_t)pid<<32|window),*last=self.sent[key];NSTimeInterval now=NSProcessInfo.processInfo.systemUptime;
    NSNumber *applicationKey=@((uint64_t)(uint32_t)pid<<32);
    moved=moved&&pid>0&&window&&window!=appeared&&![self.owed containsObject:applicationKey];
    if(!window&&pid>0)for(NSNumber *pending in self.moveOnly.allObjects)
        if((pid_t)(pending.unsignedLongLongValue>>32)==pid)[self.moveOnly removeObject:pending];
    if(!moved)[self.moveOnly removeObject:key];
    else if(![self.owed containsObject:key])[self.moveOnly addObject:key];
    [self.owed addObject:key];
    if(!last||now-last.doubleValue>=coalesce){self.sent[key]=@(now);[self deliver:key];if(self.stopped)return;}
    [self arm:self.sent[key].doubleValue+coalesce-NSProcessInfo.processInfo.systemUptime];
}
- (void)arm:(NSTimeInterval)delay {
    NSDate *due=[NSDate dateWithTimeIntervalSinceNow:MAX(0,delay)];
    if(self.timer){if([self.timer.fireDate compare:due]==NSOrderedDescending)self.timer.fireDate=due;return;}
    __weak DWWindowEvents *weak=self;
    self.timer=[[NSTimer alloc]initWithFireDate:due interval:0 repeats:NO block:^(NSTimer *timer){(void)timer;[weak due];}];
    [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];
}
- (void)due {
    self.timer=nil;if(self.stopped)return;NSTimeInterval now=NSProcessInfo.processInfo.systemUptime,next=0;
    for(NSNumber *key in self.owed.allObjects){
        NSTimeInterval at=self.sent[key].doubleValue+coalesce;if(at>now+.002){if(!next||at<next)next=at;continue;}
        [self.owed removeObject:key];self.sent[key]=@(now);[self deliver:key];[self.moveOnly removeObject:key];if(self.stopped)return;
    }
    for(NSNumber *key in self.sent.allKeys)if(![self.owed containsObject:key]&&now-self.sent[key].doubleValue>1)[self.sent removeObjectForKey:key];
    for(DWObservedApplication *application in self.applications.allValues){
        if(!application.retry)continue;
        if(application.retry>now+.002){if(!next||application.retry<next)next=application.retry;continue;}
        [self observe:application];
    }
    if(next)[self arm:next-NSProcessInfo.processInfo.systemUptime];
}
// Nothing here forms a weak reference to self: -dealloc calls it.
- (void)stop {
    if(self.stopped)return;self.stopped=YES;self.sink=nil;if(windowServerEvents==self)windowServerEvents=nil;
    [self.workspaceNotifications removeObserver:self];self.workspaceNotifications=nil;[self.timer invalidate];self.timer=nil;
    [self clearApplicationWatches];
    for(NSNumber *pid in self.applications.allKeys)[self remove:pid.intValue ended:NO];
    [self.owed removeAllObjects];[self.sent removeAllObjects];[self.moveOnly removeAllObjects];
}
- (void)dealloc { [self stop]; }
@end
