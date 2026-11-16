// SPDX-License-Identifier: GPL-3.0-or-later
#import "DWTrackpadGestureEvent.h"
@implementation DWTrackpadGestureEvent
+ (instancetype)begin:(NSString *)kind fingers:(NSUInteger)fingers time:(NSNumber *)time doubleTap:(NSNumber *)doubleTap {
    DWTrackpadGestureEvent *e=[self new];e->_phase=DWTrackpadGestureBegin;e->_kind=[kind copy];e->_fingers=fingers;e->_time=time;e->_doubleTap=doubleTap;return e;
}
+ (instancetype)update:(CGPoint)delta scale:(NSNumber *)scale rotation:(NSNumber *)rotation time:(NSNumber *)time {
    DWTrackpadGestureEvent *e=[self new];e->_phase=DWTrackpadGestureUpdate;e->_delta=delta;e->_scale=scale;e->_rotation=rotation;e->_time=time;return e;
}
+ (instancetype)end:(BOOL)cancelled time:(NSNumber *)time {
    DWTrackpadGestureEvent *e=[self new];e->_phase=DWTrackpadGestureEnd;e->_cancelled=cancelled;e->_time=time;return e;
}
@end
