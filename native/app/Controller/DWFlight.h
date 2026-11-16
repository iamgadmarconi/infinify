// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import "DWControllerValue.h"
NS_ASSUME_NONNULL_BEGIN
@interface DWFlight : DWControllerValue
@property(nonatomic,readonly,nullable) NSNumber *generation;
@property(nonatomic,readonly) CGPoint cameraTarget;
@property(nonatomic,readonly,nullable) NSNumber *zoomTarget;
@property(nonatomic,readonly) DWValuePresence cameraTargetPresence;
@property(nonatomic,readonly) BOOL cameraTargetHasNumericComponents;
@end
NS_ASSUME_NONNULL_END
