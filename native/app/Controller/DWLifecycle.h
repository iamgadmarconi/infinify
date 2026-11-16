// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import "DWControllerValue.h"
NS_ASSUME_NONNULL_BEGIN
@interface DWLifecycle : DWControllerValue
@property(nonatomic,readonly,nullable) NSArray *relaunching;

@property(nonatomic,readonly,nullable) NSArray *standins;
@property(nonatomic,readonly,nullable) NSNumber *settled;
@property(nonatomic,readonly,nullable) NSArray *held;
@end
NS_ASSUME_NONNULL_END
