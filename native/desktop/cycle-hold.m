// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from malbiruk/driftwm 352333a8fa1b22171492d4b71a54102045c9a19d:
// src/input/keyboard.rs (on_keyboard: an open cycle ends on the first key event at
// which config.cycle_hold is no longer all held) and src/input/actions.rs
// (CycleWindows: a fire with no real modifier down is a single committed step).
// Upstream is handed every key event. macOS hands this app none without Input
// Monitoring, so the modifier state is sampled while a cycle session is open instead.
#import "cycle-hold.h"
#import <Carbon/Carbon.h>
@implementation DWCycleHold { NSTimer *_timer; }
+ (uint32_t)modifiersDown {
    CGEventFlags flags=CGEventSourceFlagsState(kCGEventSourceStateCombinedSessionState);
    return (flags&kCGEventFlagMaskControl?controlKey:0)|(flags&kCGEventFlagMaskAlternate?optionKey:0)|(flags&kCGEventFlagMaskShift?shiftKey:0)|(flags&kCGEventFlagMaskCommand?cmdKey:0);
}
- (void)start:(BOOL (^)(uint32_t))sample {
    [self stop];__weak DWCycleHold *weak=self;
    _timer=[NSTimer timerWithTimeInterval:1.0/60 repeats:YES block:^(NSTimer *timer){
        DWCycleHold *hold=weak;if(!hold||hold->_timer!=timer){[timer invalidate];return;}
        if(!sample(DWCycleHold.modifiersDown))[hold stop];
    }];
    [NSRunLoop.mainRunLoop addTimer:_timer forMode:NSRunLoopCommonModes];
}
- (void)stop { [_timer invalidate];_timer=nil; }
- (void)dealloc { [_timer invalidate]; }
@end
