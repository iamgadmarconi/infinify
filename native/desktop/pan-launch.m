// SPDX-License-Identifier: GPL-3.0-or-later
#import "pan-launch.h"

static const NSTimeInterval launchDelay=.05; // upstream's MOMENTUM_LAUNCH_DELAY
@implementation DWPanLaunch {
    void (^_launch)(NSNumber *);
    NSNumber *_output;
    NSTimer *_timer;
}
- (instancetype)initWithLaunch:(void (^)(NSNumber *))launch { if((self=[super init]))_launch=[launch copy];return self; }
- (void)panned:(NSNumber *)output {
    _output=output;NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:launchDelay];
    // One timer for the burst, pushed out by every pan, as upstream's reschedules itself onto its deadline.
    if(_timer){_timer.fireDate=deadline;return;}
    __weak DWPanLaunch *weak=self;
    _timer=[[NSTimer alloc]initWithFireDate:deadline interval:0 repeats:NO block:^(NSTimer *timer){(void)timer;[weak end];}];
    [NSRunLoop.mainRunLoop addTimer:_timer forMode:NSRunLoopCommonModes];
}
- (void)end { NSNumber *output=_output;[self cancel];if(output)_launch(output); }
- (void)cancel { [_timer invalidate];_timer=nil;_output=nil; }
- (void)dealloc { [_timer invalidate]; }
@end
