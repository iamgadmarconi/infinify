// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
typedef NS_ENUM(NSUInteger,DWTrackpadGesturePhase){DWTrackpadGestureBegin,DWTrackpadGestureUpdate,DWTrackpadGestureEnd};
// Native recognizer measurements, before the desktop supplies controller context.
// Optional scale/rotation/doubleTap preserve a recognizer's absent measurements.
@interface DWTrackpadGestureEvent : NSObject
@property(nonatomic,readonly) DWTrackpadGesturePhase phase;
@property(nonatomic,readonly) NSString *kind;
@property(nonatomic,readonly) NSUInteger fingers;
@property(nonatomic,readonly) NSNumber *time;
@property(nonatomic,readonly) NSNumber *doubleTap;
@property(nonatomic,readonly) CGPoint delta;
@property(nonatomic,readonly) NSNumber *scale;
@property(nonatomic,readonly) NSNumber *rotation;
@property(nonatomic,readonly) BOOL cancelled;
+ (instancetype)begin:(NSString *)kind fingers:(NSUInteger)fingers time:(NSNumber *)time doubleTap:(NSNumber *)doubleTap;
+ (instancetype)update:(CGPoint)delta scale:(NSNumber *)scale rotation:(NSNumber *)rotation time:(NSNumber *)time;
+ (instancetype)end:(BOOL)cancelled time:(NSNumber *)time;
@end
