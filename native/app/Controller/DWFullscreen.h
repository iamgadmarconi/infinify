// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import "DWControllerValue.h"
NS_ASSUME_NONNULL_BEGIN
@interface DWFullscreen : DWControllerValue
@property(nonatomic,readonly,nullable) NSNumber *window;
@property(nonatomic,readonly,nullable) NSString *backdrop;

@end
NS_ASSUME_NONNULL_END
