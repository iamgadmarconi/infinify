// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from spacefarm-digital/sunlight afeea74b18e70ca49bf462d6fe462cf65deb2b32 (MIT, Copyright (c) 2026 spacefarm):
// Sources/Canvas/TrackpadPan.swift, the technique and not its code: lines 58-63 (event type 30 is Dock control, and
// it is still dropped 0.3 s after the fingers lift), 201-254 (a session event tap that sees only that type, on a thread
// of its own with a 5 s watchdog that turns a disabled tap back on; the callback drops by a time the touch source
// keeps) and 288-299 (the drop time moves on while the fingers are down). Taken from the Infinify side: the decision
// is per finger count against the loaded gesture table, it is a plain function of a state, and the tap does nothing
// while no touch source is delivering.
// Nothing here has run on a physical trackpad. The regression feeds the decision and the filter synthetic states and
// an in-memory type-30 packet; it installs no tap.
#import "dock-guard.h"
#import <ApplicationServices/ApplicationServices.h>
#import <QuartzCore/QuartzCore.h>
#include <os/lock.h>
#include <stdatomic.h>

const NSTimeInterval DWDockTail=.3;
static BOOL bit(uint32_t mask,NSUInteger count) { return count>0&&count<32&&(mask&(1u<<count))!=0; }
BOOL DWDockGuardHolds(const DWDockGuardState *state) { return state->live&&!state->refused&&(bit(state->bound,state->fingers)||bit(state->bound,state->gesture)); }
BOOL DWDockGuardDrops(const DWDockGuardState *state,NSTimeInterval now) { return state->live&&(DWDockGuardHolds(state)||now<state->until); }
void DWDockGuardFingers(DWDockGuardState *state,NSUInteger fingers,NSTimeInterval now) {
    BOOL held=DWDockGuardHolds(state);
    if(!state->fingers&&fingers)state->contact++;
    state->fingers=(uint32_t)MIN(fingers,(NSUInteger)UINT32_MAX);
    // The pad is empty again: the next touch is the shell's to admit afresh. The tail covers the end of the system's swipe.
    if(!fingers){state->refused=NO;if(held)state->until=now+DWDockTail;}
}
void DWDockGuardGesture(DWDockGuardState *state,NSUInteger fingers,NSTimeInterval now) {
    BOOL held=DWDockGuardHolds(state);
    state->gesture=(uint32_t)MIN(fingers,(NSUInteger)UINT32_MAX);
    if(held&&!DWDockGuardHolds(state))state->until=now+DWDockTail;
}
void DWDockGuardRefuse(DWDockGuardState *state,uint32_t contact) { if(state->fingers&&contact==state->contact)state->refused=YES; }
void DWDockGuardBound(DWDockGuardState *state,uint32_t mask) { state->bound=mask; }
void DWDockGuardLive(DWDockGuardState *state,BOOL live) {
    state->live=live;
    if(!live){state->fingers=state->gesture=0;state->refused=NO;state->until=0;}
}

@implementation DWDockGuard {
    os_unfair_lock _lock;
    DWDockGuardState _state;
}
- (instancetype)init { if((self=[super init])){_lock=OS_UNFAIR_LOCK_INIT;}return self; }
- (void)setBound:(uint32_t)mask { os_unfair_lock_lock(&_lock);DWDockGuardBound(&_state,mask);os_unfair_lock_unlock(&_lock); }
- (void)setLive:(BOOL)live { os_unfair_lock_lock(&_lock);DWDockGuardLive(&_state,live);os_unfair_lock_unlock(&_lock); }
- (uint32_t)fingers:(NSUInteger)fingers at:(NSTimeInterval)now {
    os_unfair_lock_lock(&_lock);DWDockGuardFingers(&_state,fingers,now);uint32_t contact=_state.contact;os_unfair_lock_unlock(&_lock);return contact;
}
- (void)gesture:(NSUInteger)fingers at:(NSTimeInterval)now { os_unfair_lock_lock(&_lock);DWDockGuardGesture(&_state,fingers,now);os_unfair_lock_unlock(&_lock); }
- (void)refuseContact:(uint32_t)contact { os_unfair_lock_lock(&_lock);DWDockGuardRefuse(&_state,contact);os_unfair_lock_unlock(&_lock); }
- (BOOL)dropsAt:(NSTimeInterval)now { os_unfair_lock_lock(&_lock);BOOL drop=DWDockGuardDrops(&_state,now);os_unfair_lock_unlock(&_lock);return drop; }
- (DWDockGuardState)state { os_unfair_lock_lock(&_lock);DWDockGuardState state=_state;os_unfair_lock_unlock(&_lock);return state; }
@end

static const CGEventType dockControl=(CGEventType)30;
static CGEventRef dockTapCallback(CGEventTapProxy proxy,CGEventType type,CGEventRef event,void *context) {
    (void)proxy;
    return [(__bridge DWDockTap *)context filter:type event:event at:CACurrentMediaTime()];
}
@implementation DWDockTap {
    DWDockGuard *_guard;
    CFMachPortRef _tap;CFRunLoopSourceRef _source;CFRunLoopTimerRef _watchdog;CFRunLoopRef _loop;
    NSThread *_thread;dispatch_semaphore_t _done;
}
- (instancetype)initWithGuard:(DWDockGuard *)guard { if((self=[super init]))_guard=guard;return self; }
- (BOOL)running { return _tap&&CFMachPortIsValid(_tap)&&CGEventTapIsEnabled(_tap); }
- (CGEventRef)filter:(CGEventType)type event:(CGEventRef)event at:(NSTimeInterval)now {
    if(type==kCGEventTapDisabledByTimeout||type==kCGEventTapDisabledByUserInput){if(_tap)CGEventTapEnable(_tap,true);return event;}
    return type==dockControl&&[_guard dropsAt:now]?NULL:event;
}
- (BOOL)start {
    // A port the system invalidated (Accessibility taken away) is replaced, as Sunlight's watchdog replaces it.
    if(_tap&&CFMachPortIsValid(_tap))return self.running;
    [self stop];
    // Said once per process: the next attempt, a second later, finds the same thing.
    static atomic_flag noted=ATOMIC_FLAG_INIT;
    if(!AXIsProcessTrusted()||!(_tap=CGEventTapCreate(kCGSessionEventTap,kCGHeadInsertEventTap,kCGEventTapOptionDefault,CGEventMaskBit(30),dockTapCallback,(__bridge void *)self))){
        if(!atomic_flag_test_and_set(&noted))fprintf(stderr,"Dock-control suppression unavailable: the session event tap needs Accessibility access. The system's three- and four-finger gestures stay on.\n");
        _tap=NULL;return NO;
    }
    _source=CFMachPortCreateRunLoopSource(NULL,_tap,0);
    if(!_source){CFMachPortInvalidate(_tap);CFRelease(_tap);_tap=NULL;return NO;}
    // The tap's own thread: a main thread busy with a frame cannot make the system time the tap out.
    dispatch_semaphore_t ready=dispatch_semaphore_create(0);_done=dispatch_semaphore_create(0);
    __weak DWDockTap *weak=self;dispatch_semaphore_t done=_done;
    _thread=[[NSThread alloc]initWithBlock:^{
        @autoreleasepool{
            DWDockTap *tap=weak;CFRunLoopRef loop=CFRunLoopGetCurrent();
            if(tap&&tap->_tap&&tap->_source){
                CFRetain(loop);tap->_loop=loop;
                // Sunlight's watchdog: a tap the system disabled without telling is turned back on.
                tap->_watchdog=CFRunLoopTimerCreateWithHandler(NULL,CFAbsoluteTimeGetCurrent()+5,5,0,0,^(CFRunLoopTimerRef timer){(void)timer;DWDockTap *t=weak;if(t&&t->_tap&&!CGEventTapIsEnabled(t->_tap))CGEventTapEnable(t->_tap,true);});
                CFRunLoopAddTimer(loop,tap->_watchdog,kCFRunLoopCommonModes);CFRunLoopAddSource(loop,tap->_source,kCFRunLoopCommonModes);
            }
            dispatch_semaphore_signal(ready);tap=nil;
            CFRunLoopRun();
        }
        dispatch_semaphore_signal(done);
    }];
    _thread.name=@"infinify.dockguard";_thread.qualityOfService=NSQualityOfServiceUserInteractive;[_thread start];
    dispatch_semaphore_wait(ready,dispatch_time(DISPATCH_TIME_NOW,(int64_t)(2*NSEC_PER_SEC)));
    CGEventTapEnable(_tap,true);return YES;
}
- (void)stop {
    if(!_tap)return;
    // Nothing left in the thread's run loop, so that it ends even if it had not started running when it is stopped.
    CGEventTapEnable(_tap,false);CFMachPortInvalidate(_tap);if(_watchdog)CFRunLoopTimerInvalidate(_watchdog);
    if(_loop)CFRunLoopStop(_loop);
    dispatch_semaphore_wait(_done,dispatch_time(DISPATCH_TIME_NOW,(int64_t)(2*NSEC_PER_SEC)));
    if(_watchdog){CFRelease(_watchdog);_watchdog=NULL;}
    if(_loop){CFRelease(_loop);_loop=NULL;}
    if(_source){CFRelease(_source);_source=NULL;}
    CFRelease(_tap);_tap=NULL;_thread=nil;
}
- (void)dealloc { [self stop]; }
@end
