// SPDX-License-Identifier: GPL-3.0-or-later
// Production PID lanes and teardown with real dispatch, without AX, windows or application mutation.
#import <AppKit/AppKit.h>
#include <unistd.h>
static NSUInteger checks;
static dispatch_semaphore_t removed;
static void check(BOOL condition,NSString *message) {
    checks++;if(!condition){fprintf(stderr,"FAIL: %s\n",message.UTF8String);exit(1);}
}
static AXError queueRemove(AXObserverRef observer,AXUIElementRef element,CFStringRef notification) {
    (void)observer;(void)element;(void)notification;dispatch_semaphore_signal(removed);return kAXErrorSuccess;
}
static NSUInteger sourcesRemoved;
static CFRunLoopSourceRef queueSource(AXObserverRef observer) {
    check(NSThread.isMainThread,@"observer source is removed on main, even during off-main teardown");sourcesRemoved++;return (CFRunLoopSourceRef)observer;
}
#define AXObserverRemoveNotification queueRemove
#define AXObserverGetRunLoopSource queueSource
#import "DWWindowEvents.m"
#import "DWWindowEvents+Applications.m"
#import "DWWindowEvents+Observation.m"
#import "DWApplicationWatch.m"
#import "DWApplicationCatalogWatch.m"
#import "DWApplicationMetadata.m"
#import "DWObservedApplication.m"
#import "DWObservedWindow.m"
#undef AXObserverRemoveNotification
#undef AXObserverGetRunLoopSource
bool dw_focus_birth(pid_t pid,uint64_t *seconds,uint64_t *microseconds) { (void)pid;(void)seconds;(void)microseconds;return false; }
static BOOL awaitWork(dispatch_semaphore_t semaphore) { return dispatch_semaphore_wait(semaphore,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC))==0; }
static BOOL released(dispatch_queue_t __weak *queue) {
    NSTimeInterval until=NSProcessInfo.processInfo.systemUptime+2;
    do {@autoreleasepool {if(!*queue)return YES;}usleep(1000);}while(NSProcessInfo.processInfo.systemUptime<until);return NO;
}
static void lanes(void) {
    dispatch_semaphore_t started=dispatch_semaphore_create(0),release=dispatch_semaphore_create(0);
    dispatch_semaphore_t next=dispatch_semaphore_create(0),independent=dispatch_semaphore_create(0);
    __weak dispatch_queue_t idle;
    @autoreleasepool {
        idle=DWWindowEventsQueue(401);
        DWWindowEventsAsync(401,^{dispatch_semaphore_signal(started);dispatch_semaphore_wait(release,DISPATCH_TIME_FOREVER);});
    }
    check(awaitWork(started),@"slow work starts after all caller lane references are dropped");
    // A successor's work must join the pending teardown, not choose another lane.
    @autoreleasepool {
        DWWindowEventsAsync(401,^{dispatch_semaphore_signal(next);});
        DWWindowEventsAsync(402,^{dispatch_semaphore_signal(independent);});
    }
    BOOL progressed=awaitWork(independent),ordered=dispatch_semaphore_wait(next,dispatch_time(DISPATCH_TIME_NOW,100*NSEC_PER_MSEC))!=0;
    dispatch_semaphore_signal(release);BOOL finished=awaitWork(next);
    check(progressed,@"another PID progresses while the first is blocked");
    check(ordered&&finished,@"successor work stays behind the blocked PID and then completes");
    check(released(&idle),@"idle PID lane is released after submitted work drains");
    @autoreleasepool {
        idle=DWWindowEventsQueue(401);
        DWWindowEventsAsync(401,^{dispatch_semaphore_signal(next);});
    }
    check(awaitWork(next),@"a recreated PID lane accepts work");
    check(released(&idle),@"the recreated lane is released too");
}
static AXObserverRef observer(void) { CFRunLoopSourceContext context={0};return (AXObserverRef)CFRunLoopSourceCreate(NULL,0,&context); }
static void unwatch(void) {
    DWWindowEvents *events=[DWWindowEvents new];DWObservedWindow *window=[DWObservedWindow new];
    @autoreleasepool {DWObservedApplication *application=[DWObservedApplication new];application.pid=403;window.application=application;}
    check(!window.application,@"unwatch fixture has lost its weak application");
    window.registered=1;window.element=(AXUIElementRef)CFRetain(CFSTR("window"));removed=dispatch_semaphore_create(0);
    DWObservedApplication *application=[DWObservedApplication new];application.pid=403;application.observer=observer();
    application.windows=CFDictionaryCreateMutable(NULL,0,&kCFTypeDictionaryKeyCallBacks,NULL);
    dispatch_semaphore_t started=dispatch_semaphore_create(0),release=dispatch_semaphore_create(0),zero=dispatch_semaphore_create(0);
    DWWindowEventsAsync(403,^{dispatch_semaphore_signal(started);dispatch_semaphore_wait(release,DISPATCH_TIME_FOREVER);});check(awaitWork(started),@"unwatch lane is blocked");
    [events notified:kAXUIElementDestroyedNotification element:window.element application:application window:window];
    DWWindowEventsAsync(0,^{dispatch_semaphore_signal(zero);});check(awaitWork(zero),@"lane zero progresses independently of unwatch");
    BOOL ordered=dispatch_semaphore_wait(removed,dispatch_time(DISPATCH_TIME_NOW,100*NSEC_PER_MSEC))!=0;
    dispatch_semaphore_signal(release);BOOL finished=awaitWork(removed);
    check(ordered&&finished,@"unwatch uses the caller's PID even with a nil weak application");
}
static DWWindowEvents *observing(pid_t pid) {
    DWWindowEvents *events=[DWWindowEvents new];DWObservedApplication *application=[DWObservedApplication new];application.pid=pid;
    application.observer=observer();application.element=(AXUIElementRef)CFRetain(CFSTR("application"));application.registered=1;
    events.applications=[NSMutableDictionary dictionaryWithObject:application forKey:@(pid)];return events;
}
// A successor's first lane work, submitted on main after the teardown has been submitted: the removal must be ahead of it.
static void successorAfterTeardown(pid_t pid,dispatch_semaphore_t release,NSString *what) {
    dispatch_semaphore_t next=dispatch_semaphore_create(0);__block BOOL unregistered=NO;
    DWWindowEventsAsync(pid,^{unregistered=dispatch_semaphore_wait(removed,DISPATCH_TIME_NOW)==0;dispatch_semaphore_signal(next);});
    BOOL ordered=dispatch_semaphore_wait(removed,DISPATCH_TIME_NOW)!=0;dispatch_semaphore_signal(release);
    BOOL finished=awaitWork(next);
    check(ordered&&finished&&unregistered,what);
}
// Main-thread stop submits the teardown before it returns.
static void teardownOnMain(void) {
    DWWindowEvents *events=observing(405);removed=dispatch_semaphore_create(0);
    dispatch_semaphore_t started=dispatch_semaphore_create(0),release=dispatch_semaphore_create(0);
    DWWindowEventsAsync(405,^{dispatch_semaphore_signal(started);dispatch_semaphore_wait(release,DISPATCH_TIME_FOREVER);});check(awaitWork(started),@"main teardown lane is blocked");
    NSUInteger before=sourcesRemoved;[events stop];
    check(sourcesRemoved==before+1,@"main stop takes the observer off the run loop before returning");
    successorAfterTeardown(405,release,@"main stop: teardown stays behind pending work and ahead of a successor submitted next");
}
// Off main, -stop and -dealloc never wait for main: here main itself is blocked waiting for that caller, which deadlocked
// when an off-main stop hopped synchronously to main. The teardown then runs once main turns, still ahead of a successor.
static void teardown(BOOL explicit) {
    DWWindowEvents *events=observing(404);removed=dispatch_semaphore_create(0);
    dispatch_semaphore_t started=dispatch_semaphore_create(0),release=dispatch_semaphore_create(0),done=dispatch_semaphore_create(0);
    DWWindowEventsAsync(404,^{dispatch_semaphore_signal(started);dispatch_semaphore_wait(release,DISPATCH_TIME_FOREVER);});check(awaitWork(started),@"teardown lane is blocked");
    __block DWWindowEvents *owner=events;events=nil;NSUInteger before=sourcesRemoved;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{@autoreleasepool {if(explicit)[owner stop];owner=nil;}dispatch_semaphore_signal(done);});
    check(awaitWork(done),explicit?@"off-main stop returns while main waits for it (no main hop)":@"off-main dealloc returns while main waits for it (no main hop)");
    check(sourcesRemoved==before,@"the off-main teardown is scheduled, not yet run, while main has not turned");
    NSTimeInterval until=NSProcessInfo.processInfo.systemUptime+2;
    while(sourcesRemoved==before&&NSProcessInfo.processInfo.systemUptime<until)[NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.001]];
    check(sourcesRemoved==before+1,explicit?@"off-main stop's teardown runs on main once":@"off-main dealloc's teardown runs on main once");
    successorAfterTeardown(404,release,explicit?@"off-main stop: teardown stays behind pending work and ahead of a successor":@"off-main dealloc: teardown stays behind pending work and ahead of a successor");
}
int main(void) {@autoreleasepool {
    lanes();unwatch();teardownOnMain();teardown(YES);teardown(NO);
    printf("window-events PID lanes: %lu checks passed\n",(unsigned long)checks);return 0;
}}
