// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from yabai (https://github.com/asmvik/yabai) dd845723416f5fe92af49fad5ebab00369e07edd (MIT, Copyright (c) 2019 Åsmund
// Vikane; the licence text is native/app/Resources/YABAI-NOTICE.txt): src/workspace.m, src/application.h, src/application.c, src/window.h, src/window.c
// (window_observe, window_unobserve), src/event_loop.c and src/window_manager.c, as DWWindowEvents.h says of each. Where this
// differs from yabai is said where it does.
// Adapted from Sunlight (https://github.com/spacefarm-digital/sunlight) afeea74b18e70ca49bf462d6fe462cf65deb2b32 (MIT, Copyright
// (c) 2026 spacefarm; the licence text is native/app/Resources/SUNLIGHT-NOTICE.txt):
// Sources/Canvas/RealWindows/WindowServerEvents.swift (the window-server events 1325/1326, their payload, main-thread delivery once an
// NSApplication exists).
// DWWindowEvents: the Accessibility observers - observe, list, resolve, watch, unwatch, remove and notified.
// Split from native/desktop/window-events.m at 37b27b1, moved verbatim.
#import "DWWindowEvents+Private.h"
// Signature provenance: yabai, same commit, src/misc/extern.h:8, as in DWWindowManager.m.
typedef AXError (*GetWindow)(AXUIElementRef,uint32_t *);
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
@implementation DWWindowEvents (Observation)
// yabai's application_observe: one observer per application, every application notification with the application as its
// context. Unlike yabai the messages are sent with a timeout and off the main thread, an observer that could register only
// some of its notifications is kept for those, and an attempt adds only what is still missing.
- (void)observe:(DWObservedApplication *)application {
    if(self.stopped||application.gone||application.busy)return;application.busy=YES;application.retry=0;application.attempts++;
    pid_t pid=application.pid;uint8_t have=application.registered;AXObserverRef existing=application.observer;if(existing)CFRetain(existing);__weak DWWindowEvents *weak=self;
    dispatch_async(DWWindowEventsQueue(),^{
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
    dispatch_async(DWWindowEventsQueue(),^{
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
    dispatch_async(DWWindowEventsQueue(),^{
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
    dispatch_async(DWWindowEventsQueue(),^{for(int i=0;i<windowCount;i++)if(mask&(1<<i))AXObserverRemoveNotification(observer,element,windowNotifications[i]);CFRelease(observer);CFRelease(element);});
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
    dispatch_async(DWWindowEventsQueue(),^{
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
@end
