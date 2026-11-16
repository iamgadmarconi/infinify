// SPDX-License-Identifier: GPL-3.0-or-later
// Private implementation of press admission: physical pairs and cancellation tombstones.
// Event taps borrow packets and apply NULL/pass results; no native resources live here.
#import <Foundation/Foundation.h>
#import "DWPressAdmission.h"
#import <CoreGraphics/CoreGraphics.h>
@interface DWPressPairing : NSObject
- (instancetype)initWithConsume:(BOOL (^)(CGEventType,CGEventRef))consume earlyConsume:(BOOL (^)(CGEventType,CGEventRef))earlyConsume ignoreEvent:(BOOL (^)(CGEventRef))ignoreEvent nativeLookup:(id<DWPressNativeLookup>)native cancelled:(void (^)(void))cancelled;
@property (readonly) BOOL hasEarlyMousePress;
@property (copy) void (^dockControl)(CGEventRef event);
@property (copy) void (^nativeMouseOwnershipChanged)(CGEventRef event,NSIndexSet *buttons);
- (BOOL)takeNativeButton:(NSUInteger)button;
- (BOOL)holdsCapturedButton:(NSUInteger)button;
- (void)cancelIdleEarlyMousePress;
- (CGEventRef)handleEarly:(CGEventType)type event:(CGEventRef)event;
- (CGEventRef)handle:(CGEventType)type event:(CGEventRef)event;
- (void)detachConsumer;
- (void)started;
- (void)beginStop;
- (void)discardPairs;
@end
