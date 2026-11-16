// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import "DWControllerValue.h"
NS_ASSUME_NONNULL_BEGIN
@interface DWAnimationSettings : DWControllerValue
@property(nonatomic,readonly,nullable) NSNumber *enabled;
@property(nonatomic,readonly,nullable) NSNumber *duration;

@end
NS_ASSUME_NONNULL_END
