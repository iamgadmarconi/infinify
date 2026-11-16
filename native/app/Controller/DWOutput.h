// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import "DWControllerValue.h"
@class DWFullscreen, DWFlight;
NS_ASSUME_NONNULL_BEGIN
@interface DWOutput : DWControllerValue
@property(nonatomic,readonly,nullable) NSNumber *identifier;
@property(nonatomic,readonly) CGPoint camera;
@property(nonatomic,readonly,nullable) NSNumber *zoom;
@property(nonatomic,readonly) CGRect screenBounds;
@property(nonatomic,readonly,nullable) DWFullscreen *fullscreen;
- (DWOutput *)outputWithCamera:(CGPoint)camera zoom:(NSNumber *)zoom screenBounds:(CGRect)screenBounds;
- (BOOL)hasSamePoseAsOutput:(DWOutput *)other;
@property(nonatomic,readonly) DWValuePresence cameraPresence;
@property(nonatomic,readonly) BOOL cameraHasNumericComponents;
@property(nonatomic,readonly) DWValuePresence screenBoundsPresence;
@property(nonatomic,readonly) BOOL screenBoundsHasNumericComponents;
@property(nonatomic,readonly,nullable) NSNumber *pick;
@property(nonatomic,readonly) DWValuePresence fullscreenPresence;
@property(nonatomic,readonly) CGRect screenBoundsOrNull;
@property(nonatomic,readonly) BOOL isDrawable;
- (BOOL)hasSameScreenBoundsAsOutput:(DWOutput *)other;
- (BOOL)hasSameCameraAndZoomAsFlight:(DWFlight *)flight;
// Pick-motion needs dictionary containers, but deliberately zero-defaults missing scalar fields.
@property(nonatomic,readonly) BOOL screenBoundsHasOriginAndSize;
@end
NS_ASSUME_NONNULL_END
