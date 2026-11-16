// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import "DWControllerValue.h"
NS_ASSUME_NONNULL_BEGIN
@interface DWGestureAction : DWControllerValue
@property(nonatomic,readonly,nullable) NSString *action;
@property(nonatomic,readonly,nullable) NSString *error;
@end
NS_ASSUME_NONNULL_END
