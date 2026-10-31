// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from Sunlight, repository https://github.com/spacefarm-digital/sunlight, commit afeea74b18e70ca49bf462d6fe462cf65deb2b32
// (MIT, Copyright (c) 2026 spacefarm; notice in SUNLIGHT-NOTICE.txt), upstream path Sources/Canvas/TrackpadPan.swift;
// the line numbers below are those of that file at that commit. Translated function by function, with Sunlight's names where they fit:
//   TrackpadPan.dockTail, 58-60 .................... DWDockControlTail (DWDockControl.h) and DWDockTail
//   TrackpadPan.dockControl, 61-63 ................. DWDockControlType (DWDockControl.h)
//   TrackpadPan.threadMain, 203-209 ................ the thread block of -[DWDockTap start]: a thread of its own, a 5 s watchdog, CFRunLoopRun
//   TrackpadPan.installTap, 211-227 ................ -[DWDockTap start]: a session tap at the head, default options, event type 30 only, added to the
//                                                    run loop of the tap's own thread in the common modes and enabled
//   TrackpadPan.checkTap, 229-238 .................. the watchdog block: an invalidated port is replaced (the next -start), a disabled one enabled again
//   TrackpadPan.callback, 240-243 .................. dockTapCallback
//   TrackpadPan.filter, 245-253 .................... -[DWDockTap filter:event:at:]: a disabled-tap notice enables the tap again and passes; anything but
//                                                    type 30 passes; type 30 is dropped when the drop time has not come
//   TrackpadRecognizer.fourFingerTouch and
//   dropDockControlUntil, 288-292, 298-299 ......... DWDockGuardState.boundTouch and .until, moved on by DWDockGuardFingers: the flag is set when a count lands
//                                                    and cleared when the pad is empty; while it is set the drop time is `now + dockTail` at every report
// Deviations, each deliberate and none run on a trackpad: "four fingers" is any count a [gestures] binding takes (the shell tells the guard which),
// where Sunlight's is exactly four; the flag is also cleared, and the drop time with it, when the count grows past every bound one, since the system's
// gesture of more fingers than any binding is not the canvas's; a touch the shell declined is held back from the system all the same, for a bound count (Sunlight
// has no admission; an earlier version passed a declined touch to the Dock, and the owner's M5 Pro, 2026-10-30, opened the desktop view that way after a window drag; only a
// touch the shell yields, because the canvas is closed or the session away, is the system's whole); the
// recogniser's gesture in progress also holds; the drop time is set again at the lift, since frames may stop with the last finger; nothing is dropped unless
// a touch source says it delivers (Sunlight's tap and recogniser are one object); the tap installs on the main thread, the run loop is the thread's, and the
// shell tries again at its next native-input configuration where Sunlight retries after 3 s (line 217-219); and a stream of Dock-control packets is
// decided once, at its beginning (Sunlight asks again at every packet, and the touch flag makes the answer the same for the length of the touch).
// Added after the first run on a trackpad (the owner's M5 Pro, 2026-10-29: Show Desktop, Launchpad and Mission Control all reached the Dock): the
// stream rule, and every start, stop and decision traced under INFINIFY_DEBUG.
// Nothing here has run on a physical trackpad. The regression feeds the decision and the filter synthetic states and
// an in-memory type-30 packet; it installs no tap.
#import "DWDockGuard.h"
#import <ApplicationServices/ApplicationServices.h>
#import <QuartzCore/QuartzCore.h>
#include <os/lock.h>
#include <stdatomic.h>

const NSTimeInterval DWDockTail=DWDockControlTail;
static BOOL bit(uint32_t mask,NSUInteger count) { return count>0&&count<32&&(mask&(1u<<count))!=0; }
const char *DWDockReasonName(DWDockReason reason) {
    static const char *names[]={"source-not-delivering","count-not-bound","bound-refused","bound-fingers","bound-gesture","tail-after-lift","stream-began-dropped","stream-began-with-system","touch-yielded"};
    return reason>=0&&reason<(DWDockReason)(sizeof names/sizeof *names)?names[reason]:"?";
}
// A refused touch of a bound count is held all the same: the shell declining it (a button thought down, a view in a gesture) says nothing about whether macOS may
// have it, and the system reads the same fingers as Spaces or Mission Control. `refused` is kept to say why in the log.
BOOL DWDockGuardHolds(const DWDockGuardState *state) { return state->live&&!state->yielded&&(bit(state->bound,state->fingers)||bit(state->bound,state->gesture)); }
DWDockReason DWDockGuardReason(const DWDockGuardState *state,NSTimeInterval now,BOOL *drop) {
    DWDockReason reason=DWDockReasonUnbound;BOOL dropped=NO;
    if(!state->live)reason=DWDockReasonNotLive;
    else if(DWDockGuardHolds(state)){dropped=YES;reason=state->refused?DWDockReasonRefused:bit(state->bound,state->fingers)?DWDockReasonFingers:DWDockReasonGesture;}
    else if(now<state->until){dropped=YES;reason=DWDockReasonTail;}
    else if(state->yielded&&(bit(state->bound,state->fingers)||bit(state->bound,state->gesture)))reason=DWDockReasonYielded;
    if(drop)*drop=dropped;return reason;
}
BOOL DWDockGuardDrops(const DWDockGuardState *state,NSTimeInterval now) { BOOL drop=NO;DWDockGuardReason(state,now,&drop);return drop; }
BOOL DWDockGuardDecide(DWDockGuardState *state,DWDockControlKind kind,NSTimeInterval now,DWDockReason *reason) {
    BOOL drop=NO;DWDockReason why=DWDockGuardReason(state,now,&drop);
    if(!state->live){if(reason)*reason=why;return NO;}
    // A packet that is not a DockSwipe has no beginning to name: it joins the run before it only if that was a moment ago.
    NSTimeInterval idle=kind==DWDockControlOther?DWDockTail:1;
    if(kind!=DWDockControlBegan&&state->runOpen&&now-state->runAt<idle){drop=state->runDrop;why=drop?DWDockReasonRunDropped:DWDockReasonRunPassed;}
    else{state->runOpen=YES;state->runDrop=drop;}
    state->runAt=now;if(kind==DWDockControlEnded)state->runOpen=NO;
    if(reason)*reason=why;return drop;
}
void DWDockGuardFingers(DWDockGuardState *state,NSUInteger fingers,NSTimeInterval now) {
    BOOL held=DWDockGuardHolds(state);
    if(!state->fingers&&fingers)state->contact++;
    state->fingers=(uint32_t)MIN(fingers,(NSUInteger)UINT32_MAX);
    // TrackpadPan.swift 298-299: `if ids.count == 4 { fourFingerTouch = true } else if ids.isEmpty { fourFingerTouch = false }`, then
    // `if fourFingerTouch { dropDockControlUntil = now + TrackpadPan.dockTail }`. Fingers lift one by one, so the count passes through unbound ones on its
    // way to none: the touch is held all the same, to its end. A touch that grew past every bound count was handed to the system, at once and with no tail.
    uint32_t top=state->bound?31u-(uint32_t)__builtin_clz(state->bound):0;
    if(bit(state->bound,fingers)&&!state->yielded)state->boundTouch=YES;
    else if(fingers>top){state->boundTouch=NO;state->until=0;}
    if(state->boundTouch)state->until=now+DWDockTail;
    // The pad is empty again: the next touch is the shell's to admit afresh. The tail covers the end of the system's swipe.
    if(!fingers){state->refused=state->yielded=NO;if(held||state->boundTouch)state->until=now+DWDockTail;state->boundTouch=NO;}
}
void DWDockGuardGesture(DWDockGuardState *state,NSUInteger fingers,NSTimeInterval now) {
    BOOL held=DWDockGuardHolds(state);
    state->gesture=(uint32_t)MIN(fingers,(NSUInteger)UINT32_MAX);
    if(held&&!DWDockGuardHolds(state))state->until=now+DWDockTail;
}
void DWDockGuardRefuse(DWDockGuardState *state,uint32_t contact) { if(state->fingers&&contact==state->contact)state->refused=YES; }
void DWDockGuardYield(DWDockGuardState *state,uint32_t contact) { if(state->fingers&&contact==state->contact){state->yielded=YES;state->boundTouch=NO;state->until=0;} }
void DWDockGuardBound(DWDockGuardState *state,uint32_t mask) { state->bound=mask; }
void DWDockGuardLive(DWDockGuardState *state,BOOL live) {
    state->live=live;
    if(!live){state->fingers=state->gesture=0;state->refused=state->yielded=NO;state->until=0;state->boundTouch=NO;state->runOpen=NO;}
}

@implementation DWDockGuard {
    os_unfair_lock _lock;
    DWDockGuardState _state;
    NSUInteger _reports;
    uint64_t _decidedStamp;char _decidedVia[16];NSTimeInterval _decidedAt;DWDockControlVerdict _decidedVerdict; // the last packet decided, for the second tap that sees it
}
- (instancetype)init { if((self=[super init])){_lock=OS_UNFAIR_LOCK_INIT;}return self; }
- (NSUInteger)reports { os_unfair_lock_lock(&_lock);NSUInteger reports=_reports;os_unfair_lock_unlock(&_lock);return reports; }
// The bound counts as a list, for the log: 0x18 is [3,4].
static NSString *boundCounts(uint32_t mask) {
    NSMutableArray *counts=[NSMutableArray array];for(uint32_t n=1;n<32;n++)if(mask&(1u<<n))[counts addObject:@(n)];
    return [NSString stringWithFormat:@"[%@]",[counts componentsJoinedByString:@","]];
}
- (void)setBound:(uint32_t)mask {
    os_unfair_lock_lock(&_lock);uint32_t before=_state.bound;DWDockGuardBound(&_state,mask);os_unfair_lock_unlock(&_lock);
    if(DWDebugTrace()&&before!=mask)fprintf(stderr,"debug: dock-guard: Dock control is held back for the finger counts %s (was %s)\n",boundCounts(mask).UTF8String,boundCounts(before).UTF8String);
}
- (void)setLive:(BOOL)live {
    os_unfair_lock_lock(&_lock);BOOL before=_state.live;DWDockGuardLive(&_state,live);uint32_t bound=_state.bound;NSUInteger reports=_reports;os_unfair_lock_unlock(&_lock);
    if(DWDebugTrace()&&before!=live)fprintf(stderr,"debug: dock-guard: %s (bound counts %s, %lu frame reports so far)\n",live?"a touch source delivers: Dock control is held back for bound counts":"no touch source delivers: nothing is held back",boundCounts(bound).UTF8String,(unsigned long)reports);
}
- (uint32_t)fingers:(NSUInteger)fingers at:(NSTimeInterval)now {
    os_unfair_lock_lock(&_lock);_reports++;DWDockGuardFingers(&_state,fingers,now);uint32_t contact=_state.contact;os_unfair_lock_unlock(&_lock);return contact;
}
- (void)gesture:(NSUInteger)fingers at:(NSTimeInterval)now { os_unfair_lock_lock(&_lock);DWDockGuardGesture(&_state,fingers,now);os_unfair_lock_unlock(&_lock); }
- (void)refuseContact:(uint32_t)contact { os_unfair_lock_lock(&_lock);DWDockGuardRefuse(&_state,contact);os_unfair_lock_unlock(&_lock); }
- (void)yieldContact:(uint32_t)contact { os_unfair_lock_lock(&_lock);DWDockGuardYield(&_state,contact);os_unfair_lock_unlock(&_lock); }
- (BOOL)dropsAt:(NSTimeInterval)now { os_unfair_lock_lock(&_lock);BOOL drop=DWDockGuardDrops(&_state,now);os_unfair_lock_unlock(&_lock);return drop; }
- (DWDockGuardState)state { os_unfair_lock_lock(&_lock);DWDockGuardState state=_state;os_unfair_lock_unlock(&_lock);return state; }
- (DWDockControlVerdict)decide:(CGEventRef)event via:(const char *)via at:(NSTimeInterval)now {
    uint64_t stamp=event?CGEventGetTimestamp(event):0;NSInteger axis=0,phase=0;DWDockControlKind kind=DWDockControlClassify(event,&axis,&phase);
    os_unfair_lock_lock(&_lock);
    if(stamp&&stamp==_decidedStamp&&strcmp(via,_decidedVia)&&now-_decidedAt<.05){DWDockControlVerdict again=_decidedVerdict;os_unfair_lock_unlock(&_lock);return again;}
    DWDockReason reason=DWDockReasonNotLive;BOOL drop=DWDockGuardDecide(&_state,kind,now,&reason);
    DWDockGuardState state=_state;NSUInteger reports=_reports;
    DWDockControlVerdict verdict=state.live?(drop?DWDockControlDrop:DWDockControlPass):DWDockControlUndecided;
    _decidedStamp=stamp;strlcpy(_decidedVia,via,sizeof _decidedVia);_decidedAt=now;_decidedVerdict=verdict;
    os_unfair_lock_unlock(&_lock);
    if(DWDebugTrace()){
        char detail[192];snprintf(detail,sizeof detail,"fingers=%u gesture=%u bound=%s live=%d refused=%d tail_ms=%.0f reports=%lu",state.fingers,state.gesture,boundCounts(state.bound).UTF8String,state.live,state.refused,MAX(0,state.until-now)*1000,(unsigned long)reports);
        DWDockControlTrace(via,event,kind,verdict,DWDockReasonName(reason),detail);
    }
    return verdict;
}
@end

// TrackpadPan.callback, 240-243.
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
// TrackpadPan.filter, 245-253: the drop is the guard's, asked once per stream.
- (CGEventRef)filter:(CGEventType)type event:(CGEventRef)event at:(NSTimeInterval)now {
    if(type==kCGEventTapDisabledByTimeout||type==kCGEventTapDisabledByUserInput){
        if(_tap)CGEventTapEnable(_tap,true);
        if(DWDebugTrace())fprintf(stderr,"debug: dock-tap: the system disabled the tap (%s); enabled again: %d\n",type==kCGEventTapDisabledByTimeout?"timeout":"user input",_tap?(int)CGEventTapIsEnabled(_tap):0);
        return event;
    }
    // Only Dock control: anything else is the system's. The guard decides per stream, with the same answer for the other tap that may see the packet.
    return type==DWDockControlType&&event&&[_guard decide:event via:"dock-tap" at:now]==DWDockControlDrop?NULL:event;
}
// TrackpadPan.installTap, 211-227, with the thread of threadMain, 203-209, and the watchdog of checkTap, 229-238.
- (BOOL)start {
    // A port the system invalidated (Accessibility taken away) is replaced, as Sunlight's watchdog replaces it.
    if(_tap&&CFMachPortIsValid(_tap)){
        if(!self.running){CGEventTapEnable(_tap,true);if(DWDebugTrace())fprintf(stderr,"debug: dock-tap: found installed and disabled; enabled again: %d\n",(int)self.running);}
        return self.running;
    }
    [self stop];
    // Said once per process: the next attempt, a second later, finds the same thing.
    static atomic_flag noted=ATOMIC_FLAG_INIT;static NSTimeInterval lastTrace=0;
    BOOL trusted=AXIsProcessTrusted();
    if(!trusted||!(_tap=CGEventTapCreate(kCGSessionEventTap,kCGHeadInsertEventTap,kCGEventTapOptionDefault,CGEventMaskBit(30),dockTapCallback,(__bridge void *)self))){
        if(!atomic_flag_test_and_set(&noted))fprintf(stderr,"Dock-control suppression unavailable: the session event tap needs Accessibility access. The system's three- and four-finger gestures stay on.\n");
        NSTimeInterval now=CACurrentMediaTime();
        if(DWDebugTrace()&&now-lastTrace>=30){lastTrace=now;fprintf(stderr,"debug: dock-tap: not installed: AXIsProcessTrusted=%d, CGEventTapCreate %s (tried again at the next native-input configuration)\n",(int)trusted,trusted?"returned NULL":"not tried");}
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
                // TrackpadPan.checkTap, 229-238: a tap the system disabled without telling is turned back on.
                tap->_watchdog=CFRunLoopTimerCreateWithHandler(NULL,CFAbsoluteTimeGetCurrent()+5,5,0,0,^(CFRunLoopTimerRef timer){(void)timer;DWDockTap *t=weak;
                    if(t&&t->_tap&&!CGEventTapIsEnabled(t->_tap)){CGEventTapEnable(t->_tap,true);if(DWDebugTrace())fprintf(stderr,"debug: dock-tap: the watchdog found the tap disabled; enabled again: %d\n",(int)CGEventTapIsEnabled(t->_tap));}});
                CFRunLoopAddTimer(loop,tap->_watchdog,kCFRunLoopCommonModes);CFRunLoopAddSource(loop,tap->_source,kCFRunLoopCommonModes);
            }
            dispatch_semaphore_signal(ready);tap=nil;
            CFRunLoopRun();
        }
        dispatch_semaphore_signal(done);
    }];
    _thread.name=@"infinify.dockguard";_thread.qualityOfService=NSQualityOfServiceUserInteractive;[_thread start];
    dispatch_semaphore_wait(ready,dispatch_time(DISPATCH_TIME_NOW,(int64_t)(2*NSEC_PER_SEC)));
    CGEventTapEnable(_tap,true);
    if(DWDebugTrace())fprintf(stderr,"debug: dock-tap: installed (session tap, head insert, Dock-control events only), enabled=%d, tap thread %s\n",(int)CGEventTapIsEnabled(_tap),_loop?"running":"not confirmed within 2 s");
    return YES;
}
- (void)stop {
    if(!_tap)return;
    if(DWDebugTrace())fprintf(stderr,"debug: dock-tap: stopped\n");
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
