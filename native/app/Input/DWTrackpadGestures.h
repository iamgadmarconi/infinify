// SPDX-License-Identifier: GPL-3.0-or-later
#import <Foundation/Foundation.h>
#import "DWTrackpadGestureEvent.h"
@class NSEvent;
// Raw native trackpad touches in, swipe/pinch/hold measurements out, before
// the desktop supplies modifiers, context, output and pointer. One and two fingers
// remain the pointer's, the scroll's and AppKit's magnify.
// A plain state machine: no AppKit, no clock and no timer of its own. Main thread only.
typedef NS_ENUM(NSInteger,DWTouchPhase){DWTouchBegan,DWTouchMoved,DWTouchEnded,DWTouchCancelled};
@interface DWTrackpadGestures : NSObject
// Every begin is ended before the next; optional measurements remain absent.
- (instancetype)initWithEmit:(void (^)(DWTrackpadGestureEvent *event))emit;
// One finger of one frame: millimetres from the pad's top left, y towards the user.
// `identity` names the finger for as long as it stays down. A frame reports every
// finger on the pad, moved or not, then closes with -frame:; a finger it leaves out
// is taken as cancelled.
- (void)touch:(id<NSCopying>)identity x:(double)x y:(double)y phase:(DWTouchPhase)phase time:(NSTimeInterval)time;
- (void)frame:(NSTimeInterval)time;
// Resting fingers send no frames, so time passes through here: when `deadline` is not
// 0 the owner calls -advance: at or after it (hold delay, finger-count debounce).
@property (readonly) NSTimeInterval deadline;
- (void)advance:(NSTimeInterval)time;
// The touches are no longer ours: a gesture in progress ends cancelled and every finger is forgotten.
- (void)cancel:(NSTimeInterval)time;
// A swipe or a pinch has begun and not ended.
@property (readonly) BOOL engaged;
@end
// "time_ms" for a time in seconds on the clock the touches are stamped with.
NSNumber *DWGestureTime(NSTimeInterval seconds);

// An immutable frame obtained only from an AppKit generic touch packet. Gesture
// magnify/swipe packets do not promise current touches and are never decoded here.
// Device selection prevents two trackpads from becoming one fictitious gesture.
@interface DWTrackpadTouchFrame : NSObject
@property (readonly) id device;
@property (readonly) NSArray<NSDictionary *> *touches;
@property (readonly) NSUInteger fingers;
@property (readonly) NSTimeInterval time;
+ (instancetype)frameWithEvent:(NSEvent *)event device:(id)device;
@end
