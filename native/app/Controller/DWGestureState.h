// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import "DWControllerValue.h"
NS_ASSUME_NONNULL_BEGIN
@interface DWGestureState : DWControllerValue
@property(nonatomic,readonly,nullable) NSString *state;
@property(nonatomic,readonly,nullable) NSNumber *output;
@property(nonatomic,readonly,nullable) NSNumber *window;
@end
NS_ASSUME_NONNULL_END
