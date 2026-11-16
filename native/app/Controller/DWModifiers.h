// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import "DWControllerValue.h"
NS_ASSUME_NONNULL_BEGIN
@interface DWModifiers : DWControllerValue
@property(nonatomic,readonly,nullable) NSNumber *command;
@property(nonatomic,readonly,nullable) NSNumber *control;
@property(nonatomic,readonly,nullable) NSNumber *option;
@property(nonatomic,readonly,nullable) NSNumber *shift;
@end
NS_ASSUME_NONNULL_END
