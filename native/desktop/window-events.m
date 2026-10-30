// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from koekeishiya/yabai dd845723416f5fe92af49fad5ebab00369e07edd (MIT, Copyright (c) 2019 Åsmund Vikane; the licence
// text is native/families/YABAI-NOTICE.txt): src/workspace.m, src/application.h, src/application.c, src/window.h, src/window.c
// (window_observe, window_unobserve), src/event_loop.c and src/window_manager.c, as window-events.h says of each. Where this
// differs from yabai is said where it does.
// Adapted from spacefarm-digital/sunlight afeea74b18e70ca49bf462d6fe462cf65deb2b32 (MIT, Copyright (c) 2026 spacefarm):
// Sources/Canvas/RealWindows/WindowServerEvents.swift (the window-server events 1325/1326, their payload, main-thread delivery once an
// NSApplication exists).
#import "window-events.h"
#include <signal.h>
#include <errno.h>
#include <string.h>
#import "../focus/focus.h"
#include <dlfcn.h>
#include <os/lock.h>
// Signature provenance: yabai, same commit, src/misc/extern.h:8, as in window-manager.m.
typedef AXError (*GetWindow)(AXUIElementRef,uint32_t *);
// What an application is given to answer one Accessibility message. Asked on the worker only.
static const float answer=.25;
// One report per window per this long while notifications keep coming: the idle poll's period, so a window in a storm is
// looked at no more often than the poll looked at it.
static const NSTimeInterval coalesce=.08;
// yabai asks an application that did not answer again a tenth of a second later, for as long as it runs. Here that pace is
// kept for `quick` attempts; after them -reconcile asks, once a second.
static const NSTimeInterval retryDelay=.1;
static const int quick=5;
// yabai's application table (src/application.h) less the menu notifications, plus kAXWindowCreatedNotification. yabai has a new
// window from kAXCreatedNotification alone, which is posted for elements that are no window too; a window announced by either
// name is looked for, and watch() keeps only windows.
static CFStringRef const applicationNotifications[]={kAXCreatedNotification,kAXWindowCreatedNotification,kAXFocusedWindowChangedNotification,kAXWindowMovedNotification,kAXWindowResizedNotification,kAXTitleChangedNotification};
enum { applicationCount=6, every=(1<<applicationCount)-1 };
// In place of a window number in a coalescing key: the application's set of windows on screen may have changed.
static const CGWindowID appeared=UINT32_MAX;
// yabai's window table (src/window.h).
static CFStringRef const windowNotifications[]={kAXUIElementDestroyedNotification,kAXWindowMiniaturizedNotification,kAXWindowDeminiaturizedNotification};
enum { windowCount=3 };
// Every Accessibility message goes through this one serial queue, a stopped instance's removals ahead of its successor's
// registrations. yabai sends them from its event-loop thread, likewise not the thread its observers call back on.
static dispatch_queue_t worker(void) { static dispatch_queue_t queue;static dispatch_once_t once;dispatch_once(&once,^{queue=dispatch_queue_create("org.infinify.window-events",DISPATCH_QUEUE_SERIAL);});return queue; }
// LaunchServices reads are serial too, but cannot hold up an application's AX work.
static dispatch_queue_t applicationWorker(void) { static dispatch_queue_t queue;static dispatch_once_t once;dispatch_once(&once,^{queue=dispatch_queue_create("org.infinify.application-events",dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,QOS_CLASS_UTILITY,0));});return queue; }
static void *applicationObservation=&applicationObservation;
static NSArray<NSString *> *applicationProperties(void) { return @[@"processIdentifier",@"activationPolicy",@"terminated"]; }
enum { applicationAppeared=1, applicationChanged=2, applicationActivated=4 };
// NSRunningApplication documents these three properties as KVO-observable (including PID changes on automatic
// termination). One record retains one canonical object, not a cached PID. Equal catalog wrappers can name the same
// application; they never replace that object or its observer. Installation/removal and the registry
// are main-only. KVO can arrive on any thread: it invalidates the revision under the lock and coalesces one weak main
// notification. No LaunchServices property is read there, or while holding this lock.
@interface DWApplicationWatch : NSObject {
    os_unfair_lock _lock;
    uint64_t _revision, _identityRevision;
    BOOL _active, _queued, _observing;
}
@property (readonly) NSRunningApplication *running;
@property (copy) void (^changed)(DWApplicationWatch *);
@property BOOL pending, retry;
@property NSUInteger hints;
@property pid_t pid; // last accepted metadata; never native authority
@property pid_t boundPID;
@property uint64_t boundIdentityRevision, boundSeconds, boundMicroseconds;
- (instancetype)initWithRunning:(NSRunningApplication *)running;
- (uint64_t)revision;
- (uint64_t)identityRevision;
- (BOOL)matches:(uint64_t)revision;
- (void)invalidateMetadata;
- (void)invalidateIdentityMetadata;
- (void)invalidate;
@end
@implementation DWApplicationWatch
- (instancetype)initWithRunning:(NSRunningApplication *)running {
    if((self=[super init])){_lock=OS_UNFAIR_LOCK_INIT;_running=running;_active=YES;_revision=1;_identityRevision=1;_pending=YES;
        NSAssert(NSThread.isMainThread,@"application observation is installed on main");
        for(NSString *key in applicationProperties())[running addObserver:self forKeyPath:key options:0 context:applicationObservation];
        _observing=YES;
    }return self;
}
- (uint64_t)revision { os_unfair_lock_lock(&_lock);uint64_t revision=_revision;os_unfair_lock_unlock(&_lock);return revision; }
- (uint64_t)identityRevision { os_unfair_lock_lock(&_lock);uint64_t revision=_identityRevision;os_unfair_lock_unlock(&_lock);return revision; }
- (BOOL)matches:(uint64_t)revision { os_unfair_lock_lock(&_lock);BOOL matches=_active&&_revision==revision;os_unfair_lock_unlock(&_lock);return matches; }
- (void)invalidateIdentity:(BOOL)identity {
    os_unfair_lock_lock(&_lock);BOOL schedule=_active&&!_queued;if(_active){_revision++;if(identity)_identityRevision++;_queued=YES;}os_unfair_lock_unlock(&_lock);
    if(!schedule)return;__weak DWApplicationWatch *weak=self;
    dispatch_async(dispatch_get_main_queue(),^{DWApplicationWatch *record=weak;if(!record)return;
        os_unfair_lock_lock(&record->_lock);BOOL active=record->_active;record->_queued=NO;os_unfair_lock_unlock(&record->_lock);
        if(active&&record.changed)record.changed(record);
    });
}
- (void)invalidateMetadata { [self invalidateIdentity:NO]; }
- (void)invalidateIdentityMetadata { [self invalidateIdentity:YES]; }
- (void)observeValueForKeyPath:(NSString *)key ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if(context==applicationObservation){[self invalidateIdentity:[key isEqualToString:@"processIdentifier"]||[key isEqualToString:@"terminated"]];return;}
    [super observeValueForKeyPath:key ofObject:object change:change context:context];
}
- (void)invalidate {
    os_unfair_lock_lock(&_lock);_active=NO;_revision++;os_unfair_lock_unlock(&_lock);
    // Never remove an observer under the callback lock: removal may synchronize with an in-flight notification.
    if(_observing){NSAssert(NSThread.isMainThread,@"application observation is removed on main");_observing=NO;for(NSString *key in applicationProperties())[_running removeObserver:self forKeyPath:key context:applicationObservation];}
    _changed=nil;
}
- (void)dealloc { [self invalidate]; }
@end
static void *catalogObservation=&catalogObservation;
// NSRunningApplication.h explicitly recommends KVO of NSWorkspace.runningApplications instead of polling. The
// collection can change on any thread; one weak main notification carries its newest revision, not the array itself.
@interface DWApplicationCatalogWatch : NSObject {
    os_unfair_lock _lock;
    uint64_t _revision;
    BOOL _active, _queued, _observing;
}
@property (readonly) NSWorkspace *workspace;
@property (copy) void (^changed)(DWApplicationCatalogWatch *);
- (instancetype)initWithWorkspace:(NSWorkspace *)workspace;
- (uint64_t)revision;
- (BOOL)matches:(uint64_t)revision;
- (void)invalidate;
@end
@implementation DWApplicationCatalogWatch
- (instancetype)initWithWorkspace:(NSWorkspace *)workspace {
    if((self=[super init])){_lock=OS_UNFAIR_LOCK_INIT;_workspace=workspace;_active=YES;_revision=1;
        NSAssert(NSThread.isMainThread,@"application catalog observation is installed on main");
        [workspace addObserver:self forKeyPath:@"runningApplications" options:0 context:catalogObservation];_observing=YES;
    }return self;
}
- (uint64_t)revision { os_unfair_lock_lock(&_lock);uint64_t revision=_revision;os_unfair_lock_unlock(&_lock);return revision; }
- (BOOL)matches:(uint64_t)revision { os_unfair_lock_lock(&_lock);BOOL matches=_active&&_revision==revision;os_unfair_lock_unlock(&_lock);return matches; }
- (void)observeValueForKeyPath:(NSString *)key ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if(context!=catalogObservation){[super observeValueForKeyPath:key ofObject:object change:change context:context];return;}
    os_unfair_lock_lock(&_lock);BOOL schedule=_active&&!_queued;if(_active){_revision++;_queued=YES;}os_unfair_lock_unlock(&_lock);
    if(!schedule)return;__weak DWApplicationCatalogWatch *weak=self;
    dispatch_async(dispatch_get_main_queue(),^{DWApplicationCatalogWatch *watch=weak;if(!watch)return;
        os_unfair_lock_lock(&watch->_lock);BOOL active=watch->_active;watch->_queued=NO;os_unfair_lock_unlock(&watch->_lock);
        if(active&&watch.changed)watch.changed(watch);
    });
}
- (void)invalidate {
    os_unfair_lock_lock(&_lock);_active=NO;_revision++;os_unfair_lock_unlock(&_lock);
    // As for application observers, removal is main-only and outside the callback lock.
    if(_observing){NSAssert(NSThread.isMainThread,@"application catalog observation is removed on main");_observing=NO;[_workspace removeObserver:self forKeyPath:@"runningApplications" context:catalogObservation];}
    _changed=nil;
}
- (void)dealloc { [self invalidate]; }
@end
@interface DWApplicationMetadata : NSObject
@property DWApplicationWatch *watch;
@property NSRunningApplication *running; // catalog wrapper; never replaces a verified canonical observer
@property uint64_t revision, identityRevision, seconds, microseconds;
@property pid_t pid;
@property BOOL regular, terminated, born;
@property NSUInteger hints;
@property BOOL identityNotice;
@end
@implementation DWApplicationMetadata
@end
@class DWWindowEvents, DWObservedWindow;
// One observed application: yabai's struct application. Main thread, but for what a block on the worker is handed by value.
@interface DWObservedApplication : NSObject
@property pid_t pid;
@property uint64_t seconds, microseconds;
@property NSRunningApplication *running;
@property (weak) DWWindowEvents *events;
@property AXUIElementRef element;
// Created on the worker; its run-loop source is on the main run loop from the moment it is set and until it is cleared.
@property AXObserverRef observer;
// Accessibility window element → DWObservedWindow, for the windows whose own notifications are registered.
@property CFMutableDictionaryRef windows;
// Elements whose window is being looked up, or that answered and are no window: none is asked about twice before the windows are
// listed again. One its application did not answer for, or gave no window number for, is not kept.
@property CFMutableSetRef asked;
// Every DWObservedWindow the observer was given as a context. A context is never released while the observer can still call
// back with it: a destroyed window's is kept ten seconds more, for a notification that was already under way.
@property NSMutableArray<DWObservedWindow *> *contexts;
@property uint8_t registered; // one bit per applicationNotifications entry
@property int attempts;
@property NSTimeInterval retry; // when the next quick attempt is due; 0 for none
@property BOOL busy, listing, final, gone;
// It did not answer when one of its windows was looked up or when they were listed, or a window of it had no number yet: they
// are listed again at the next -reconcile.
@property BOOL unanswered;
@end
@implementation DWObservedApplication
- (void)dealloc { if(_element)CFRelease(_element);if(_observer)CFRelease(_observer);if(_windows)CFRelease(_windows);if(_asked)CFRelease(_asked); }
@end
// One watched window: what yabai's struct window is to its notifications, their context.
@interface DWObservedWindow : NSObject
@property (weak) DWObservedApplication *application;
@property CGWindowID window;
@property AXUIElementRef element;
@property uint8_t registered; // one bit per windowNotifications entry; written on the worker before the window is handed over
@property NSTimeInterval destroyed; // when its destroyed notification arrived; 0 while the window is there
@end
@implementation DWObservedWindow
- (void)dealloc { if(_element)CFRelease(_element); }
@end
@interface DWWindowEvents ()
@property (weak) id<DWWindowEventSink> sink;
@property NSDictionary<NSNumber *,NSArray<NSNumber *> *> *scope;
@property NSMutableDictionary<NSNumber *,DWObservedApplication *> *applications;
@property NSMapTable<NSRunningApplication *,DWApplicationWatch *> *applicationWatches;
@property DWApplicationCatalogWatch *applicationCatalogWatch;
@property NSNotificationCenter *workspaceNotifications;
@property uint64_t catalogRevision, observationEpoch, appliedCatalogRevision;
@property BOOL readingApplications, applicationReadQueued, hasApplicationCatalog, applicationCatalogDirty;
@property NSMutableArray<DWApplicationMetadata *> *applicationNotices;
@property BOOL resolvingApplicationNotices, applicationNoticeQueued;
// Coalescing, by pid<<32|window (`appeared` for an application's set of windows, 0 for native focus): when each was last
// reported, and which are owed one more report.
@property NSMutableDictionary<NSNumber *,NSNumber *> *sent;
@property NSMutableSet<NSNumber *> *owed;
// Subset of owed: every event in this pending batch was an exact known AXMoved.
// Generic changes only remove membership; a later move cannot narrow the batch.
@property NSMutableSet<NSNumber *> *moveOnly;
// The one timer: armed for the earliest report owed or quick attempt due.
@property NSTimer *timer;
@property NSTimeInterval checked;
@property NSTimeInterval creationTraceUntil; // DEBUG-only raw notifications for 150 ms after creation
@property pid_t creationTracePID;
@property NSUInteger creationTraceLines;
@property NSUInteger windowServerTraceLines; // DEBUG-only SkyLight 1325/1326 lines, counted apart from the Accessibility ones
@property BOOL trusted, stopped;
@property BOOL scanning; // one collection-KVO/initial catalog read is under way off the main thread
- (void)notified:(CFStringRef)notification element:(AXUIElementRef)element application:(DWObservedApplication *)application window:(DWObservedWindow *)window;
- (void)windowServerType:(uint32_t)type window:(CGWindowID)window;
@end
// yabai's application_notification_handler. On the main thread, from the observer's run-loop source. The context is the
// DWObservedApplication for an application's notifications and the DWObservedWindow for a window's own; both outlive the source.
static void notified(AXObserverRef observer,AXUIElementRef element,CFStringRef notification,void *context) {
    (void)observer;id record=(__bridge id)context;
    DWObservedWindow *window=[record isKindOfClass:DWObservedWindow.class]?record:nil;DWObservedApplication *application=window?window.application:record;
    [application.events notified:notification element:element application:application window:window];
}
// yabai's window_observe: the three notifications of one window, with the window as their context. On the worker. Only a window
// is watched: an element that reports another role would have its end taken for its window's. nil when the element did not
// say which window it is. `unanswered` is then set if that may yet change: its application did not answer in time (yabai's
// ax_retry case, as in -observe:), or answered with no window number, as a window announced before it has one would. yabai
// drops such an element for good (src/event_loop.c, WINDOW_CREATED); here it is asked about again. Left as it was for an element
// that answered and is no window. One whose notifications were all refused is returned too: it still names the element's window.
static DWObservedWindow *watch(AXObserverRef observer,AXUIElementRef element,DWObservedApplication *application,BOOL *unanswered) {
    GetWindow get=(GetWindow)dlsym(RTLD_DEFAULT,"_AXUIElementGetWindow");uint32_t wid=0;CFTypeRef role=NULL;
    if(!get||AXUIElementSetMessagingTimeout(element,answer))return nil;
    AXError error=get(element,&wid);if(error||!wid){if(!error||error==kAXErrorCannotComplete)*unanswered=YES;return nil;}
    error=AXUIElementCopyAttributeValue(element,kAXRoleAttribute,&role);BOOL window=error==kAXErrorSuccess&&role&&CFGetTypeID(role)==CFStringGetTypeID()&&CFEqual(role,kAXWindowRole);
    if(role)CFRelease(role);if(!window){if(error==kAXErrorCannotComplete)*unanswered=YES;return nil;}
    DWObservedWindow *watched=[DWObservedWindow new];watched.application=application;watched.window=wid;watched.element=(AXUIElementRef)CFRetain(element);uint8_t mask=0;
    for(int i=0;i<windowCount;i++)if(AXObserverAddNotification(observer,element,windowNotifications[i],(__bridge void *)watched)==kAXErrorSuccess)mask|=(uint8_t)(1<<i);
    watched.registered=mask;return watched;
}
BOOL DWInScope(NSDictionary<NSNumber *,NSArray<NSNumber *> *> *scope,pid_t pid) {
    if(!scope)return YES;
    NSArray<NSNumber *> *born=scope[@(pid)];uint64_t seconds=0,microseconds=0;
    return born.count==2&&dw_focus_birth(pid,&seconds,&microseconds)&&born[0].unsignedLongLongValue==seconds&&born[1].unsignedLongLongValue==microseconds;
}
// SkyLight's connection notifications, as Sunlight takes them: 1325 when a window is added to a Space, 1326 when it leaves one. The
// payload is the Space's id (8 bytes), then the window's (4 bytes, at offset 8). Looked up by name, as native-placement-validation.m
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
- (DWApplicationWatch *)watchApplication:(NSRunningApplication *)running {
    if(self.stopped||!self.trusted||!running)return nil;
    DWApplicationWatch *record=[self.applicationWatches objectForKey:running];if(record)return record;
    record=[[DWApplicationWatch alloc]initWithRunning:running];__weak DWWindowEvents *weak=self;
    record.changed=^(DWApplicationWatch *changed){DWWindowEvents *events=weak;if(!events||events.stopped||!events.trusted||[events.applicationWatches objectForKey:changed.running]!=changed)return;
        changed.pending=YES;changed.retry=NO;[events queueApplicationRead];};
    [self.applicationWatches setObject:record forKey:running];self.catalogRevision++;return record;
}
- (void)forgetApplication:(DWApplicationWatch *)record ended:(BOOL)ended {
    if(!record||[self.applicationWatches objectForKey:record.running]!=record)return;
    [record invalidate];[self.applicationWatches removeObjectForKey:record.running];self.catalogRevision++;
    DWObservedApplication *application=self.applications[@(record.pid)];
    if(application.running==record.running)[self remove:record.pid ended:ended];
}
- (void)clearApplicationWatches {
    if([self.sink respondsToSelector:@selector(windowCreationInvalidated:)])[self.sink windowCreationInvalidated:0];
    self.observationEpoch++;self.catalogRevision++;self.hasApplicationCatalog=NO;
    [self.applicationCatalogWatch invalidate];self.applicationCatalogWatch=nil;self.appliedCatalogRevision=0;self.applicationCatalogDirty=NO;
    for(DWApplicationWatch *record in self.applicationWatches.objectEnumerator)[record invalidate];
    [self.applicationWatches removeAllObjects];[self.applicationNotices removeAllObjects];
}
- (void)observeApplicationCatalog {
    if(self.applicationCatalogWatch||self.stopped||!self.trusted)return;
    DWApplicationCatalogWatch *watch=[[DWApplicationCatalogWatch alloc]initWithWorkspace:NSWorkspace.sharedWorkspace];__weak DWWindowEvents *weak=self;
    watch.changed=^(DWApplicationCatalogWatch *changed){DWWindowEvents *events=weak;if(!events||events.stopped||!events.trusted||events.applicationCatalogWatch!=changed)return;
        if(events.appliedCatalogRevision!=changed.revision){events.applicationCatalogDirty=YES;[events scanApplications];}
    };
    self.applicationCatalogWatch=watch;self.applicationCatalogDirty=YES;
}
- (void)reconcileApplications:(NSArray<NSRunningApplication *> *)running {
    self.hasApplicationCatalog=YES;
    NSHashTable *current=[NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality|NSPointerFunctionsStrongMemory];
    for(NSRunningApplication *application in running)[current addObject:application];
    for(DWApplicationWatch *record in self.applicationWatches.objectEnumerator.allObjects)if(![current containsObject:record.running])[self forgetApplication:record ended:NO];
    for(NSRunningApplication *application in running)[self watchApplication:application];
    [self queueApplicationRead];
}
- (NSArray<DWApplicationMetadata *> *)applicationCatalogBindings {
    NSMutableArray<DWApplicationMetadata *> *bindings=[NSMutableArray array];
    for(DWApplicationWatch *record in self.applicationWatches.objectEnumerator){
        DWApplicationMetadata *binding=[DWApplicationMetadata new];binding.watch=record;binding.revision=record.revision;binding.pid=record.pid;
        binding.seconds=record.boundSeconds;binding.microseconds=record.boundMicroseconds;
        binding.born=record.boundIdentityRevision==record.identityRevision&&record.boundPID==record.pid&&record.boundIdentityRevision!=0;
        [bindings addObject:binding];
    }return bindings;
}
- (BOOL)applicationBindingsCurrent:(NSArray<DWApplicationMetadata *> *)bindings {
    for(DWApplicationMetadata *binding in bindings)if([self.applicationWatches objectForKey:binding.watch.running]!=binding.watch||![binding.watch matches:binding.revision])return NO;
    return YES;
}
// NSRunningApplication.h tells callers to compare applications with isEqual:, not PID. runningApplications returns
// fresh wrappers in practice: pointer-only membership recreated all observers every second (2026-10-12 idle profile).
// Hashes are temporary numeric buckets, built off main on every pass; no mutable NSRunningApplication hash is a durable
// dictionary key. A semantic match is only a candidate: its exact record revision and kernel birth still have to agree.
static NSArray<DWApplicationMetadata *> *canonicalApplications(NSArray<NSRunningApplication *> *running,NSArray<DWApplicationMetadata *> *known) {
    NSMutableDictionary<NSNumber *,NSMutableArray<DWApplicationMetadata *> *> *buckets=[NSMutableDictionary dictionary];
    for(DWApplicationMetadata *binding in known)if([binding.watch matches:binding.revision]){
        NSNumber *hash=@(binding.watch.running.hash);if(!buckets[hash])buckets[hash]=[NSMutableArray array];[buckets[hash]addObject:binding];
    }
    NSMutableArray<DWApplicationMetadata *> *result=[NSMutableArray arrayWithCapacity:running.count];
    for(NSRunningApplication *application in running){
        DWApplicationMetadata *entry=[DWApplicationMetadata new];entry.running=application;
        for(DWApplicationMetadata *binding in buckets[@(application.hash)])if([binding.watch.running isEqual:application]&&[binding.watch matches:binding.revision]){
            entry.watch=binding.watch;entry.revision=binding.revision;entry.pid=binding.pid;entry.seconds=binding.seconds;entry.microseconds=binding.microseconds;
            uint64_t seconds=0,microseconds=0;
            entry.born=binding.born&&binding.pid>0&&dw_focus_birth(binding.pid,&seconds,&microseconds)&&seconds==binding.seconds&&microseconds==binding.microseconds;
            break;
        }
        [result addObject:entry];
    }return result;
}
- (BOOL)acceptApplicationCatalog:(NSArray<DWApplicationMetadata *> *)catalog {
    NSMutableArray<NSRunningApplication *> *running=[NSMutableArray arrayWithCapacity:catalog.count];
    for(DWApplicationMetadata *entry in catalog){DWApplicationWatch *record=entry.watch;BOOL current=record&&[self.applicationWatches objectForKey:record.running]==record&&[record matches:entry.revision];
        if(record&&!current){[self queueApplicationRead];return NO;}
        uint64_t seconds=0,microseconds=0;
        // An application without a PID has no native admission. Keep its semantic watcher so a later PID KVO can discover
        // it. Every positive PID, including accessory/out-of-scope applications, carries independently checked birth.
        BOOL born=current&&(entry.pid<=0||(entry.born&&dw_focus_birth(entry.pid,&seconds,&microseconds)&&seconds==entry.seconds&&microseconds==entry.microseconds));
        if(current){
            // Equality names the same application identity, even if the kernel fence now fails. Pointer freshness must
            // not give that identity a new birth affinity. Keep its observer, retire stale AX admission, and reread it.
            [running addObject:record.running];
            if(!born){record.pending=YES;DWObservedApplication *application=self.applications[@(record.pid)];
                if(application.running==record.running){record.retry=YES;[self remove:record.pid ended:NO];[self changed:0 pid:record.pid];}
            }
        }else [running addObject:entry.running];
    }
    [self reconcileApplications:running];return YES;
}
- (void)scanApplications {
    if(self.scanning||self.stopped||!self.trusted||!self.applicationCatalogDirty)return;
    DWApplicationCatalogWatch *watch=self.applicationCatalogWatch;if(!watch)return;
    self.scanning=YES;self.applicationCatalogDirty=NO;uint64_t epoch=self.observationEpoch,revision=self.catalogRevision,collectionRevision=watch.revision;__weak DWWindowEvents *weak=self;
    NSArray<DWApplicationMetadata *> *known=[self applicationCatalogBindings];
    dispatch_async(applicationWorker(),^{@autoreleasepool {
        NSArray<DWApplicationMetadata *> *running=[watch matches:collectionRevision]?canonicalApplications(watch.workspace.runningApplications,known):nil;
        dispatch_async(dispatch_get_main_queue(),^{DWWindowEvents *events=weak;if(!events)return;events.scanning=NO;
            if(events.stopped||!events.trusted)return;
            // A notification arriving during a read must produce a successor read without waiting for another event.
            BOOL current=events.observationEpoch==epoch&&events.applicationCatalogWatch==watch&&[watch matches:collectionRevision]&&events.catalogRevision==revision&&[events applicationBindingsCurrent:known];
            BOOL accepted=current&&[events acceptApplicationCatalog:running];
            if(accepted)events.appliedCatalogRevision=collectionRevision;
            events.applicationCatalogDirty=!accepted||![watch matches:collectionRevision];
            [events scanApplications];
        });
    }});
}
- (void)queueApplicationRead {
    if(self.stopped||!self.trusted||self.readingApplications||self.applicationReadQueued)return;
    BOOL pending=NO;for(DWApplicationWatch *record in self.applicationWatches.objectEnumerator)if(record.pending){pending=YES;break;}if(!pending)return;
    self.applicationReadQueued=YES;__weak DWWindowEvents *weak=self;
    dispatch_async(dispatch_get_main_queue(),^{DWWindowEvents *events=weak;if(!events)return;events.applicationReadQueued=NO;[events readApplications];});
}
- (void)readApplications {
    if(self.stopped||!self.trusted||self.readingApplications)return;
    NSMutableArray<DWApplicationMetadata *> *reads=[NSMutableArray array];
    for(DWApplicationWatch *record in self.applicationWatches.objectEnumerator)if(record.pending){record.pending=NO;
        DWApplicationMetadata *read=[DWApplicationMetadata new];read.watch=record;read.revision=record.revision;read.identityRevision=record.identityRevision;[reads addObject:read];}
    if(!reads.count)return;self.readingApplications=YES;uint64_t epoch=self.observationEpoch;__weak DWWindowEvents *weak=self;
    // One batch at a time, with one latest pending bit per live object. A notification storm cannot enqueue unbounded reads.
    dispatch_async(applicationWorker(),^{@autoreleasepool {
        for(DWApplicationMetadata *read in reads)if([read.watch matches:read.revision]){
            NSRunningApplication *running=read.watch.running;read.pid=running.processIdentifier;read.terminated=running.terminated;read.regular=running.activationPolicy==NSApplicationActivationPolicyRegular;
            uint64_t seconds=0,microseconds=0;read.born=read.pid>0&&!read.terminated&&dw_focus_birth(read.pid,&seconds,&microseconds);read.seconds=seconds;read.microseconds=microseconds;
        }
        dispatch_async(dispatch_get_main_queue(),^{DWWindowEvents *events=weak;if(!events)return;events.readingApplications=NO;
            if(!events.stopped&&events.trusted&&events.observationEpoch==epoch)for(DWApplicationMetadata *read in reads)[events acceptApplication:read];
            [events queueApplicationRead];
        });
    }});
}
- (void)acceptApplication:(DWApplicationMetadata *)read {
    DWApplicationWatch *record=read.watch;if([self.applicationWatches objectForKey:record.running]!=record)return;
    if(![record matches:read.revision]){record.pending=YES;return;}
    uint64_t seconds=0,microseconds=0;BOOL eligible=read.pid>0&&read.pid!=getpid()&&!read.terminated&&read.regular&&(!self.scope||self.scope[@(read.pid)]);
    // A failed worker/main identity fence cannot be repaired by silently assigning this unchanged object/PID a new
    // kernel birth on the next poll. Only a different application identity/PID, or an observed PID/termination lifecycle change, can
    // establish a new binding. Policy changes alone never do so.
    BOOL identity=YES;
    if(read.born){
        if(record.boundIdentityRevision!=read.identityRevision||record.boundPID!=read.pid){record.boundIdentityRevision=read.identityRevision;record.boundPID=read.pid;record.boundSeconds=read.seconds;record.boundMicroseconds=read.microseconds;}
        else identity=record.boundSeconds==read.seconds&&record.boundMicroseconds==read.microseconds;
    }
    // Metadata is discovery only. Admission rechecks the kernel birth now, as well as the caller's exact PID scope.
    BOOL born=eligible&&identity&&read.born&&dw_focus_birth(read.pid,&seconds,&microseconds)&&seconds==read.seconds&&microseconds==read.microseconds;
    BOOL admitted=born&&DWInScope(self.scope,read.pid);
    if(![record matches:read.revision]){record.pending=YES;return;}
    DWObservedApplication *old=self.applications[@(record.pid)];
    if(old.running==record.running&&(!born||old.pid!=read.pid||old.seconds!=seconds||old.microseconds!=microseconds)){
        [self remove:old.pid ended:read.terminated];[self changed:0 pid:old.pid];
    }
    record.pid=read.pid;record.retry=eligible&&!born;
    if(admitted){
        DWObservedApplication *application=self.applications[@(read.pid)];
        if(application&&application.running!=record.running){[self forgetApplication:[self.applicationWatches objectForKey:application.running] ended:NO];[self remove:read.pid ended:NO];application=nil;}
        if(!application){application=[DWObservedApplication new];application.pid=read.pid;application.seconds=seconds;application.microseconds=microseconds;
            application.running=record.running;application.events=self;application.contexts=[NSMutableArray array];
            application.windows=CFDictionaryCreateMutable(NULL,0,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);application.asked=CFSetCreateMutable(NULL,0,&kCFTypeSetCallBacks);
            self.applications[@(read.pid)]=application;[self observe:application];[self changed:appeared pid:read.pid];
        }else if(record.hints&applicationActivated)[self list:application];
    }
    NSUInteger hints=record.hints;record.hints=0;
    if(read.pid>0){if(hints&applicationAppeared)[self changed:appeared pid:read.pid];if(hints&applicationChanged)[self changed:0 pid:read.pid];}
}
// yabai's application_observe: one observer per application, every application notification with the application as its
// context. Unlike yabai the messages are sent with a timeout and off the main thread, an observer that could register only
// some of its notifications is kept for those, and an attempt adds only what is still missing.
- (void)observe:(DWObservedApplication *)application {
    if(self.stopped||application.gone||application.busy)return;application.busy=YES;application.retry=0;application.attempts++;
    pid_t pid=application.pid;uint8_t have=application.registered;AXObserverRef existing=application.observer;if(existing)CFRetain(existing);__weak DWWindowEvents *weak=self;
    dispatch_async(worker(),^{
        uint64_t seconds=0,microseconds=0;
        if(!dw_focus_birth(pid,&seconds,&microseconds)||seconds!=application.seconds||microseconds!=application.microseconds){
            if(existing)CFRelease(existing);
            dispatch_async(dispatch_get_main_queue(),^{DWWindowEvents *events=weak;application.busy=NO;
                if(events.applications[@(pid)]==application){
                    DWApplicationWatch *record=[events.applicationWatches objectForKey:application.running];record.retry=YES;
                    [events remove:pid ended:YES];[events changed:0 pid:pid];
                }
            });return;
        }
        AXObserverRef observer=existing;AXUIElementRef element=AXUIElementCreateApplication(pid);AXUIElementSetMessagingTimeout(element,answer);uint8_t mask=have;BOOL retry=NO,final=NO;
        if(observer||AXObserverCreate(pid,notified,&observer)==kAXErrorSuccess)for(int i=0;i<applicationCount;i++){
            if(mask&(1<<i))continue;
            AXError error=AXObserverAddNotification(observer,element,applicationNotifications[i],(__bridge void *)application);
            if(error==kAXErrorSuccess||error==kAXErrorNotificationAlreadyRegistered)mask|=(uint8_t)(1<<i);
            // yabai's ax_retry: an application that does not answer is asked again, one that refuses a notification is not.
            else if(error==kAXErrorCannotComplete){retry=YES;break;}else final=YES;
        }else {observer=NULL;retry=YES;}
        dispatch_async(dispatch_get_main_queue(),^{[weak observed:application observer:observer element:element registered:mask retry:retry final:final];if(observer)CFRelease(observer);CFRelease(element);});
    });
}
- (void)observed:(DWObservedApplication *)application observer:(AXObserverRef)observer element:(AXUIElementRef)element registered:(uint8_t)mask retry:(BOOL)retry final:(BOOL)final {
    application.busy=NO;if(self.stopped||application.gone)return;
    if(!application.observer&&observer){
        application.observer=(AXObserverRef)CFRetain(observer);application.element=(AXUIElementRef)CFRetain(element);
        // On the main run loop, in the common modes: every notification of this application arrives on the main thread.
        CFRunLoopAddSource(CFRunLoopGetMain(),AXObserverGetRunLoopSource(observer),kCFRunLoopCommonModes);
    }
    application.registered=mask;application.final=final&&!retry;
    // Its windows are listed once it has answered for every notification it will ever answer for.
    if(application.observer&&(mask==every||application.final)){[self list:application];return;}
    if(retry&&application.attempts<=quick){application.retry=NSProcessInfo.processInfo.systemUptime+retryDelay;[self arm:retryDelay];}
}
// yabai's window_manager_add_application_windows: the windows the application has now, each watched. An application lists
// only the windows of the active Space, so it is asked again when it is activated and when the Space changes.
- (void)list:(DWObservedApplication *)application {
    if(self.stopped||application.gone||!application.observer||application.listing)return;application.listing=YES;application.unanswered=NO;CFSetRemoveAllValues(application.asked);
    AXObserverRef observer=(AXObserverRef)CFRetain(application.observer);AXUIElementRef element=(AXUIElementRef)CFRetain(application.element);
    CFDictionaryRef known=CFDictionaryCreateCopy(NULL,application.windows);__weak DWWindowEvents *weak=self;
    dispatch_async(worker(),^{
        NSMutableArray<DWObservedWindow *> *found=[NSMutableArray array];CFTypeRef list=NULL;AXError error=AXUIElementCopyAttributeValue(element,kAXWindowsAttribute,&list);BOOL unanswered=error==kAXErrorCannotComplete;
        if(error==kAXErrorSuccess&&list&&CFGetTypeID(list)==CFArrayGetTypeID())for(CFIndex n=0;n<CFArrayGetCount(list);n++){
            AXUIElementRef window=(AXUIElementRef)CFArrayGetValueAtIndex(list,n);if(CFGetTypeID(window)!=AXUIElementGetTypeID()||CFDictionaryContainsKey(known,window))continue;
            DWObservedWindow *watched=watch(observer,window,application,&unanswered);if(watched)[found addObject:watched];
        }
        if(list)CFRelease(list);
        dispatch_async(dispatch_get_main_queue(),^{application.listing=NO;if(unanswered)application.unanswered=YES;[weak watched:found application:application];CFRelease(observer);CFRelease(element);CFRelease(known);});
    });
}
// One window a notification named that the table does not know: created just now, or on a Space that was not listed.
- (void)resolve:(AXUIElementRef)element application:(DWObservedApplication *)application {
    if(!application.observer||CFDictionaryContainsKey(application.windows,element)||CFSetContainsValue(application.asked,element))return;
    // Elements that turned out to be no window stay here so that none is asked about twice; an application that keeps making them starts over.
    if(CFSetGetCount(application.asked)>=256)CFSetRemoveAllValues(application.asked);
    CFSetAddValue(application.asked,element);AXObserverRef observer=(AXObserverRef)CFRetain(application.observer);CFRetain(element);__weak DWWindowEvents *weak=self;
    dispatch_async(worker(),^{
        BOOL unanswered=NO;DWObservedWindow *watched=watch(observer,element,application,&unanswered);
        dispatch_async(dispatch_get_main_queue(),^{
            if(watched)[weak watched:@[watched] application:application];
            // Nothing says the element is no window (its application did not answer, or gave no window number yet): the next
            // notification that names it asks again, and -reconcile lists the application's windows, for a window nothing
            // names again before it closes.
            else if(unanswered){CFSetRemoveValue(application.asked,element);application.unanswered=YES;}
            CFRelease(observer);CFRelease(element);});
    });
}
- (void)watched:(NSArray<DWObservedWindow *> *)found application:(DWObservedApplication *)application {
    if(self.stopped||application.gone)return;
    for(DWObservedWindow *window in found){
        CFSetRemoveValue(application.asked,window.element);BOOL known=CFDictionaryContainsKey(application.windows,window.element);
        // Watched twice, by a listing and by a notification at once: the second was refused every registration the first holds,
        // so the observer never calls back with it and the table has the first. It is not kept.
        if(known&&!window.registered&&!window.destroyed)continue;
        [application.contexts addObject:window];
        if(!window.destroyed&&!known)CFDictionarySetValue(application.windows,window.element,(__bridge void *)window);
    }
}
// yabai's window_unobserve, off the main thread: a window's own notifications go with the window.
- (void)unwatch:(DWObservedWindow *)window observer:(AXObserverRef)observer {
    uint8_t mask=window.registered;if(!observer||!mask)return;window.registered=0;CFRetain(observer);AXUIElementRef element=(AXUIElementRef)CFRetain(window.element);
    dispatch_async(worker(),^{for(int i=0;i<windowCount;i++)if(mask&(1<<i))AXObserverRemoveNotification(observer,element,windowNotifications[i]);CFRelease(observer);CFRelease(element);});
}
// yabai's application_unobserve: the observer leaves the run loop here, on the main thread, so no notification arrives after
// this line and every context it was given can go. An application that goes on running is told so, off the main thread; one
// that ended (`ended`) has nothing left to tell.
- (void)remove:(pid_t)pid ended:(BOOL)ended {
    DWObservedApplication *application=self.applications[@(pid)];if(!application)return;
    application.gone=YES;application.retry=0;[self.applications removeObjectForKey:@(pid)];
    for(NSNumber *key in self.sent.allKeys)if((pid_t)(key.unsignedLongLongValue>>32)==pid){[self.sent removeObjectForKey:key];[self.owed removeObject:key];[self.moveOnly removeObject:key];}
    AXObserverRef observer=application.observer;if(!observer)return;application.observer=NULL;
    CFRunLoopSourceRef source=AXObserverGetRunLoopSource(observer);CFRunLoopRemoveSource(CFRunLoopGetMain(),source,kCFRunLoopCommonModes);CFRunLoopSourceInvalidate(source);
    AXUIElementRef element=ended?NULL:(AXUIElementRef)CFRetain(application.element);uint8_t mask=application.registered;NSArray<DWObservedWindow *> *windows=ended?nil:[application.contexts copy];
    dispatch_async(worker(),^{
        if(element){
            for(int i=0;i<applicationCount;i++)if(mask&(1<<i))AXObserverRemoveNotification(observer,element,applicationNotifications[i]);
            for(DWObservedWindow *window in windows)for(int i=0;i<windowCount;i++)if(window.registered&(1<<i))AXObserverRemoveNotification(observer,window.element,windowNotifications[i]);
            CFRelease(element);
        }
        CFRelease(observer);
    });
}
// What each notification means is yabai's (src/event_loop.c); what is done about it is the sink's. Nothing here sends a
// message to the application: the element is looked up in the table, and one the table does not know is resolved on the worker.
- (void)notified:(CFStringRef)notification element:(AXUIElementRef)element application:(DWObservedApplication *)application window:(DWObservedWindow *)window {
    id<DWWindowEventSink> sink=self.sink;if(self.stopped||!application||application.gone)return;pid_t pid=application.pid;
    if(getenv("INFINIFY_DEBUG")){
        NSTimeInterval at=NSProcessInfo.processInfo.systemUptime;
        if(CFEqual(notification,kAXCreatedNotification)||CFEqual(notification,kAXWindowCreatedNotification)){self.creationTraceUntil=at+.15;self.creationTracePID=pid;}
        if(pid==self.creationTracePID&&at<=self.creationTraceUntil&&self.creationTraceLines<128){self.creationTraceLines++;
            fprintf(stderr,"debug: native creation event pid=%d at=%.6f notification=%s known_wid=%u\n",pid,at,[(__bridge NSString *)notification UTF8String],window.window);}
    }
    if(window){
        if(window.destroyed)return;
        if(CFEqual(notification,kAXUIElementDestroyedNotification)){
            // WINDOW_DESTROYED. Reported at once, and the window is looked at once more a moment later.
            NSTimeInterval now=NSProcessInfo.processInfo.systemUptime;window.destroyed=now;CFDictionaryRemoveValue(application.windows,window.element);[self unwatch:window observer:application.observer];
            NSNumber *key=@((uint64_t)(uint32_t)pid<<32|window.window);self.sent[key]=@(now);[self.owed addObject:key];[self.moveOnly removeObject:key];[self arm:coalesce];
            [sink windowDestroyed:window.window pid:pid];return;
        }
        // WINDOW_DEMINIMIZED: the window comes back on screen, where it may be a candidate again. WINDOW_MINIMIZED: it left.
        if((CFEqual(notification,kAXWindowMiniaturizedNotification)||CFEqual(notification,kAXWindowDeminiaturizedNotification))&&[sink respondsToSelector:@selector(windowVisibilityChanged:pid:)])[sink windowVisibilityChanged:window.window pid:pid];
        if(CFEqual(notification,kAXWindowDeminiaturizedNotification))[self changed:appeared pid:pid];
        [self changed:window.window pid:pid];return;
    }
    // WINDOW_FOCUSED: which window has the focus is the navigation coordinator's to read.
    if(CFEqual(notification,kAXFocusedWindowChangedNotification)){[self resolve:element application:application];[self changed:0 pid:0];return;}
    // WINDOW_CREATED: its own notifications are registered, and the sink looks for it on screen. Coalesced like the rest: an
    // application may report elements at any rate, and both names may announce one window.
    if(CFEqual(notification,kAXCreatedNotification)||CFEqual(notification,kAXWindowCreatedNotification)){
        [self resolve:element application:application];[self changed:appeared pid:pid];
        if(!self.stopped&&!application.gone&&[sink respondsToSelector:@selector(windowCreatedElement:pid:birth:)])
            [sink windowCreatedElement:element pid:pid birth:@[@(application.seconds),@(application.microseconds)]];
        return;
    }
    // WINDOW_MOVED, WINDOW_RESIZED, WINDOW_TITLE_CHANGED. A title change is reported for elements that are no window too.
    DWObservedWindow *known=(__bridge DWObservedWindow *)CFDictionaryGetValue(application.windows,element);
    if(!known&&!CFEqual(notification,kAXTitleChangedNotification))[self resolve:element application:application];
    if(known&&CFEqual(notification,kAXWindowMovedNotification))[self changed:known.window pid:pid moveOnly:YES];
    else [self changed:known?known.window:0 pid:pid];
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
// yabai's process manager has launch, end and front switch from Carbon; NSWorkspace says the same.
- (void)applyApplicationNotice:(DWApplicationMetadata *)notice {
    DWApplicationWatch *record=notice.watch;
    if(record&&([self.applicationWatches objectForKey:record.running]!=record||![record matches:notice.revision])){[self changed:appeared pid:0];return;}
    if(!record)record=[self watchApplication:notice.running];
    if(!record){[self changed:appeared pid:0];return;}
    record.hints|=notice.hints;
    if(notice.identityNotice)[record invalidateIdentityMetadata];else [record invalidateMetadata];
}
- (void)queueApplicationNotices {
    if(self.stopped||!self.trusted||self.resolvingApplicationNotices||self.applicationNoticeQueued||!self.applicationNotices.count)return;
    self.applicationNoticeQueued=YES;__weak DWWindowEvents *weak=self;
    dispatch_async(dispatch_get_main_queue(),^{DWWindowEvents *events=weak;if(!events)return;events.applicationNoticeQueued=NO;[events resolveApplicationNotices];});
}
- (void)resolveApplicationNotices {
    if(self.stopped||!self.trusted||self.resolvingApplicationNotices||!self.applicationNotices.count)return;
    self.resolvingApplicationNotices=YES;NSArray<DWApplicationMetadata *> *notices=self.applicationNotices.copy;[self.applicationNotices removeAllObjects];
    NSArray<DWApplicationMetadata *> *known=[self applicationCatalogBindings];uint64_t epoch=self.observationEpoch,revision=self.catalogRevision;__weak DWWindowEvents *weak=self;
    dispatch_async(applicationWorker(),^{@autoreleasepool {
        // Workspace notifications can contain fresh wrappers too. Coalesce equality on the worker; main uses only
        // exact object pointers. At most 64 notices wait here and 64 more wait for this single batch to finish.
        NSMutableDictionary<NSNumber *,NSMutableArray<DWApplicationMetadata *> *> *buckets=[NSMutableDictionary dictionary];
        NSMutableArray<DWApplicationMetadata *> *unique=[NSMutableArray array];NSMutableArray<NSRunningApplication *> *running=[NSMutableArray array];
        for(DWApplicationMetadata *notice in notices){NSNumber *hash=@(notice.running.hash);DWApplicationMetadata *same=nil;
            for(DWApplicationMetadata *prior in buckets[hash])if([prior.running isEqual:notice.running]){same=prior;break;}
            if(same){same.hints|=notice.hints;same.identityNotice|=notice.identityNotice;}
            else {if(!buckets[hash])buckets[hash]=[NSMutableArray array];[buckets[hash]addObject:notice];[unique addObject:notice];[running addObject:notice.running];}
        }
        NSArray<DWApplicationMetadata *> *resolved=canonicalApplications(running,known);
        for(NSUInteger i=0;i<resolved.count;i++){resolved[i].hints=unique[i].hints;resolved[i].identityNotice=unique[i].identityNotice;}
        dispatch_async(dispatch_get_main_queue(),^{DWWindowEvents *events=weak;if(!events)return;events.resolvingApplicationNotices=NO;
            if(!events.stopped&&events.trusted&&events.observationEpoch==epoch){
                if(events.catalogRevision==revision&&[events applicationBindingsCurrent:known])for(DWApplicationMetadata *notice in resolved)[events applyApplicationNotice:notice];
                else [events changed:appeared pid:0]; // A newer identity/catalog wins; the global hint still discovers windows.
            }
            [events queueApplicationNotices];
        });
    }});
}
- (void)applicationNotification:(NSNotification *)note hints:(NSUInteger)hints identity:(BOOL)identity {
    NSRunningApplication *running=note.userInfo[NSWorkspaceApplicationKey];if(self.stopped||!running)return;
    if(!self.trusted){[self changed:appeared pid:0];return;}
    DWApplicationWatch *record=[self.applicationWatches objectForKey:running];
    if((identity||(hints&(applicationAppeared|applicationChanged)))&&[self.sink respondsToSelector:@selector(windowCreationInvalidated:)])
        [self.sink windowCreationInvalidated:record.pid];
    if(record){DWApplicationMetadata *notice=[DWApplicationMetadata new];notice.watch=record;notice.revision=record.revision;notice.hints=hints;notice.identityNotice=identity;[self applyApplicationNotice:notice];return;}
    for(DWApplicationMetadata *pending in self.applicationNotices)if(pending.running==running){pending.hints|=hints;pending.identityNotice|=identity;return;}
    if(self.applicationNotices.count>=64){[self changed:appeared pid:0];return;}
    DWApplicationMetadata *notice=[DWApplicationMetadata new];notice.running=running;notice.hints=hints;notice.identityNotice=identity;[self.applicationNotices addObject:notice];[self queueApplicationNotices];
}
- (void)launched:(NSNotification *)note {
    if(!self.stopped)self.catalogRevision++;
    [self applicationNotification:note hints:applicationAppeared identity:YES];
}
// APPLICATION_TERMINATED: its observer is removed, and its windows are looked at, which finds their process gone.
- (void)terminated:(NSNotification *)note {
    if(self.stopped)return;self.catalogRevision++;DWApplicationWatch *record=[self.applicationWatches objectForKey:note.userInfo[NSWorkspaceApplicationKey]];
    pid_t pid=record.pid;[self forgetApplication:record ended:YES];
    // A different object in a late notification cannot remove the new record at a reused PID. The global hint/poll will
    // reconcile an unknown object without a synchronous main-thread LaunchServices read to guess which process it was.
    if(pid>0)[self changed:0 pid:pid];else [self changed:appeared pid:0];
}
// APPLICATION_FRONT_SWITCHED: windows of it not yet resolved are looked for again, and native focus may have moved.
- (void)activated:(NSNotification *)note {
    if(self.stopped)return;[self applicationNotification:note hints:applicationActivated identity:NO];[self changed:0 pid:0];
}
// APPLICATION_HIDDEN, APPLICATION_VISIBLE.
- (void)hidden:(NSNotification *)note { [self applicationNotification:note hints:applicationChanged identity:NO]; }
- (void)unhidden:(NSNotification *)note { [self applicationNotification:note hints:applicationAppeared|applicationChanged identity:NO]; }
// SPACE_CHANGED: every application lists the windows of the Space that is active now.
- (void)spaceChanged:(NSNotification *)note { (void)note;if(self.stopped)return;for(DWObservedApplication *application in self.applications.allValues)[self list:application];[self changed:appeared pid:0]; }
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
