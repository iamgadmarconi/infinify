// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import "DWControllerValue.h"
NS_ASSUME_NONNULL_BEGIN
@interface DWWindowRule : DWControllerValue
@property(nonatomic,readonly,nullable) NSNumber *preserveAspectRatio;

@end
NS_ASSUME_NONNULL_END
