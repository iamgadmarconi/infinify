// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import "DWControllerValue.h"
NS_ASSUME_NONNULL_BEGIN
@interface DWBlurSettings : DWControllerValue
@property(nonatomic,readonly,nullable) NSNumber *enabled;
@property(nonatomic,readonly,nullable) NSNumber *radius;
@property(nonatomic,readonly,nullable) NSNumber *passes;
@property(nonatomic,readonly,nullable) NSNumber *noise;

@end
NS_ASSUME_NONNULL_END
