// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from koekeishiya/yabai dd845723416f5fe92af49fad5ebab00369e07edd (MIT, Copyright (c) 2019 Åsmund Vikane; the licence
// text is native/families/YABAI-NOTICE.txt): src/workspace.m, src/application.h, src/application.c, src/window.h, src/window.c
// (window_observe, window_unobserve), src/event_loop.c and src/window_manager.c, as window-events.h says of each. Where this
// differs from yabai is said where it does.
#import "window-events.h"
#include <dlfcn.h>
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
@class DWWindowEvents, DWObservedWindow;
// One observed application: yabai's struct application. Main thread, but for what a block on the worker is handed by value.
@interface DWObservedApplication : NSObject
@property pid_t pid;
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
@property NSMutableDictionary<NSNumber *,DWObservedApplication *> *applications;
// Coalescing, by pid<<32|window (`appeared` for an application's set of windows, 0 for native focus): when each was last
// reported, and which are owed one more report.
@property NSMutableDictionary<NSNumber *,NSNumber *> *sent;
@property NSMutableSet<NSNumber *> *owed;
// The one timer: armed for the earliest report owed or quick attempt due.
@property NSTimer *timer;
@property NSTimeInterval checked;
@property BOOL trusted, stopped;
- (void)notified:(CFStringRef)notification element:(AXUIElementRef)element application:(DWObservedApplication *)application window:(DWObservedWindow *)window;
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
@implementation DWWindowEvents
- (instancetype)initWithSink:(id<DWWindowEventSink>)sink {
    if((self=[super init])){_sink=sink;_applications=[NSMutableDictionary dictionary];_sent=[NSMutableDictionary dictionary];_owed=[NSMutableSet set];
        // yabai's workspace_context, less what a tiling window manager needs of the Dock, the menu bar and the displays, and with
        // launch, end and activation from NSWorkspace where yabai has them from its process manager's Carbon events.
        NSNotificationCenter *center=NSWorkspace.sharedWorkspace.notificationCenter;
        [center addObserver:self selector:@selector(launched:) name:NSWorkspaceDidLaunchApplicationNotification object:nil];
        [center addObserver:self selector:@selector(terminated:) name:NSWorkspaceDidTerminateApplicationNotification object:nil];
        [center addObserver:self selector:@selector(activated:) name:NSWorkspaceDidActivateApplicationNotification object:nil];
        [center addObserver:self selector:@selector(hidden:) name:NSWorkspaceDidHideApplicationNotification object:nil];
        [center addObserver:self selector:@selector(unhidden:) name:NSWorkspaceDidUnhideApplicationNotification object:nil];
        [center addObserver:self selector:@selector(spaceChanged:) name:NSWorkspaceActiveSpaceDidChangeNotification object:nil];
        [self reconcile];
    }return self;
}
// An application that is not observed in full yet, or will never be, reports less than the poll would find: the poll then keeps its pace.
- (BOOL)live {
    if(!self.trusted||self.stopped)return NO;
    for(DWObservedApplication *application in self.applications.allValues)if(application.registered!=every)return NO;
    return YES;
}
- (void)reconcile {
    NSTimeInterval now=NSProcessInfo.processInfo.systemUptime;if(self.stopped||(self.checked&&now-self.checked<.5))return;self.checked=now;
    // Access withdrawn: nothing is delivered any more, so nothing is kept, and the poll is the only mechanism again.
    if(!AXIsProcessTrusted()){self.trusted=NO;for(NSNumber *pid in self.applications.allKeys)[self remove:pid.intValue ended:NO];return;}
    // yabai's window_manager_begin, made again at every reconciliation: an application that became a regular one since, which
    // yabai learns from key-value observation of its activation policy, is found here within a second.
    self.trusted=YES;for(NSRunningApplication *running in NSWorkspace.sharedWorkspace.runningApplications)[self add:running];
    for(DWObservedApplication *application in self.applications.allValues){
        if(application.running.terminated){[self remove:application.pid ended:YES];continue;}
        if(application.registered!=every&&!application.final&&!application.retry)[self observe:application];
        // A window it did not answer for, or gave no number for, is watched once it does: its windows are listed again until then.
        if(application.unanswered)[self list:application];
        // A destroyed window's context has long been called back with for the last time.
        for(DWObservedWindow *window in application.contexts.copy)if(window.destroyed&&now-window.destroyed>10)[application.contexts removeObjectIdenticalTo:window];
    }
}
- (void)add:(NSRunningApplication *)running {
    pid_t pid=running.processIdentifier;
    if(self.stopped||!self.trusted||pid<=0||pid==getpid()||running.terminated||running.activationPolicy!=NSApplicationActivationPolicyRegular||self.applications[@(pid)])return;
    DWObservedApplication *application=[DWObservedApplication new];application.pid=pid;application.running=running;application.events=self;application.contexts=[NSMutableArray array];
    application.windows=CFDictionaryCreateMutable(NULL,0,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);application.asked=CFSetCreateMutable(NULL,0,&kCFTypeSetCallBacks);
    self.applications[@(pid)]=application;[self observe:application];
}
// yabai's application_observe: one observer per application, every application notification with the application as its
// context. Unlike yabai the messages are sent with a timeout and off the main thread, an observer that could register only
// some of its notifications is kept for those, and an attempt adds only what is still missing.
- (void)observe:(DWObservedApplication *)application {
    if(self.stopped||application.gone||application.busy)return;application.busy=YES;application.retry=0;application.attempts++;
    pid_t pid=application.pid;uint8_t have=application.registered;AXObserverRef existing=application.observer;if(existing)CFRetain(existing);__weak DWWindowEvents *weak=self;
    dispatch_async(worker(),^{
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
    for(NSNumber *key in self.sent.allKeys)if((pid_t)(key.unsignedLongLongValue>>32)==pid){[self.sent removeObjectForKey:key];[self.owed removeObject:key];}
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
    if(window){
        if(window.destroyed)return;
        if(CFEqual(notification,kAXUIElementDestroyedNotification)){
            // WINDOW_DESTROYED. Reported at once, and the window is looked at once more a moment later.
            NSTimeInterval now=NSProcessInfo.processInfo.systemUptime;window.destroyed=now;CFDictionaryRemoveValue(application.windows,window.element);[self unwatch:window observer:application.observer];
            NSNumber *key=@((uint64_t)(uint32_t)pid<<32|window.window);self.sent[key]=@(now);[self.owed addObject:key];[self arm:coalesce];
            [sink windowDestroyed:window.window pid:pid];return;
        }
        // WINDOW_DEMINIMIZED: the window comes back on screen, where it may be a candidate again. WINDOW_MINIMIZED: it left.
        if(CFEqual(notification,kAXWindowDeminiaturizedNotification))[self changed:appeared pid:pid];
        [self changed:window.window pid:pid];return;
    }
    // WINDOW_FOCUSED: which window has the focus is the navigation coordinator's to read.
    if(CFEqual(notification,kAXFocusedWindowChangedNotification)){[self resolve:element application:application];[self changed:0 pid:0];return;}
    // WINDOW_CREATED: its own notifications are registered, and the sink looks for it on screen. Coalesced like the rest: an
    // application may report elements at any rate, and both names may announce one window.
    if(CFEqual(notification,kAXCreatedNotification)||CFEqual(notification,kAXWindowCreatedNotification)){[self resolve:element application:application];[self changed:appeared pid:pid];return;}
    // WINDOW_MOVED, WINDOW_RESIZED, WINDOW_TITLE_CHANGED. A title change is reported for elements that are no window too.
    DWObservedWindow *known=(__bridge DWObservedWindow *)CFDictionaryGetValue(application.windows,element);
    if(!known&&!CFEqual(notification,kAXTitleChangedNotification))[self resolve:element application:application];
    [self changed:known?known.window:0 pid:pid];
}
// yabai's process manager has launch, end and front switch from Carbon; NSWorkspace says the same.
- (void)launched:(NSNotification *)note { NSRunningApplication *running=note.userInfo[NSWorkspaceApplicationKey];if(self.stopped||!running||running.processIdentifier<=0)return;[self add:running];[self changed:appeared pid:running.processIdentifier]; }
// APPLICATION_TERMINATED: its observer is removed, and its windows are looked at, which finds their process gone.
- (void)terminated:(NSNotification *)note { pid_t pid=[note.userInfo[NSWorkspaceApplicationKey]processIdentifier];if(self.stopped||pid<=0)return;[self remove:pid ended:YES];[self changed:0 pid:pid]; }
// APPLICATION_FRONT_SWITCHED: windows of it not yet resolved are looked for again, and native focus may have moved.
- (void)activated:(NSNotification *)note {
    NSRunningApplication *running=note.userInfo[NSWorkspaceApplicationKey];if(self.stopped||!running)return;
    DWObservedApplication *application=self.applications[@(running.processIdentifier)];if(application)[self list:application];else [self add:running];
    [self changed:0 pid:0];
}
// APPLICATION_HIDDEN, APPLICATION_VISIBLE.
- (void)hidden:(NSNotification *)note { pid_t pid=[note.userInfo[NSWorkspaceApplicationKey]processIdentifier];if(self.stopped||pid<=0)return;[self changed:0 pid:pid]; }
- (void)unhidden:(NSNotification *)note { pid_t pid=[note.userInfo[NSWorkspaceApplicationKey]processIdentifier];if(self.stopped||pid<=0)return;[self changed:appeared pid:pid];[self changed:0 pid:pid]; }
// SPACE_CHANGED: every application lists the windows of the Space that is active now.
- (void)spaceChanged:(NSNotification *)note { (void)note;if(self.stopped)return;for(DWObservedApplication *application in self.applications.allValues)[self list:application];[self changed:appeared pid:0]; }
- (void)deliver:(NSNumber *)key {
    uint64_t value=key.unsignedLongLongValue;id<DWWindowEventSink> sink=self.sink;CGWindowID window=(CGWindowID)(value&0xffffffff);pid_t pid=(pid_t)(value>>32);
    if(!value)[sink focusChanged];else if(window==appeared)[sink windowsChanged:pid];else [sink windowChanged:window pid:pid];
}
// A change of one window, of some window of an application (`window` 0), of the windows an application has on screen
// (`appeared`; pid 0 for every application's) or of native focus (both 0). Reported at once unless one was reported within
// the last 80 ms; either way one more report is owed 80 ms after the last one made.
- (void)changed:(CGWindowID)window pid:(pid_t)pid {
    if(self.stopped)return;NSNumber *key=@((uint64_t)(uint32_t)pid<<32|window),*last=self.sent[key];NSTimeInterval now=NSProcessInfo.processInfo.systemUptime;
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
        [self.owed removeObject:key];self.sent[key]=@(now);[self deliver:key];if(self.stopped)return;
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
    if(self.stopped)return;self.stopped=YES;self.sink=nil;
    [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:self];[self.timer invalidate];self.timer=nil;
    for(NSNumber *pid in self.applications.allKeys)[self remove:pid.intValue ended:NO];
    [self.owed removeAllObjects];[self.sent removeAllObjects];
}
- (void)dealloc { [self stop]; }
@end
