// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import "DWControllerValue.h"
NS_ASSUME_NONNULL_BEGIN
@interface DWRenderEffects : DWControllerValue
@property(nonatomic,readonly,nullable) NSNumber *blurRadius;
@property(nonatomic,readonly,nullable) NSNumber *blurStrength;
@property(nonatomic,readonly,nullable) NSNumber *animateBlurFPS;
@property(nonatomic,readonly,nullable) NSNumber *animationSpeed;
@property(nonatomic,readonly,nullable) NSNumber *animationScale;

@end
NS_ASSUME_NONNULL_END
